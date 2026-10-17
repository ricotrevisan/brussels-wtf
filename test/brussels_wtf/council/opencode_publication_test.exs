defmodule BrusselsWtf.Council.OpenCodePublicationTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.{CoverageBudget, CoverageReservation, Publication}
  alias BrusselsWtf.Processors.{OpenCodeCoverage, Stub}

  @primary "qwen3.8-max"
  @fallback "deepseek-v4.1-flash"

  setup do
    keys = [:coverage_generation, :coverage_processor, OpenCodeCoverage]
    previous = Map.new(keys, &{&1, Application.fetch_env(:brussels_wtf, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, config} -> Application.put_env(:brussels_wtf, key, config)
          :error -> Application.delete_env(:brussels_wtf, key)
        end
      end
    end)

    generation(:disabled)
    Application.put_env(:brussels_wtf, :coverage_processor, OpenCodeCoverage)

    Application.put_env(:brussels_wtf, OpenCodeCoverage,
      api_key: "test-key-not-a-real-credential",
      req_options: [plug: {Req.Test, OpenCodeCoverage}]
    )

    owner = self()

    Req.Test.stub(OpenCodeCoverage, fn conn ->
      send(owner, :unexpected_opencode_call)
      Plug.Conn.send_resp(conn, 500, "No HTTP call expected")
    end)

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert page.publication_status == :draft
    assert Council.list_coverage_runs!(page.id) == []
    refute_received :unexpected_opencode_call

    input = Publication.generation_input(meeting.id)
    {:ok, fr} = Stub.generate_fr(input)
    {:ok, nl} = Stub.translate(fr, "nl")
    {:ok, en} = Stub.translate(fr, "en")

    bundles =
      Map.new(%{"fr" => fr, "nl" => nl, "en" => en}, fn {locale, bundle} ->
        {locale,
         Map.update!(bundle, "items", fn items ->
           Map.new(items, fn {key, item} -> {key, Map.delete(item, "item_number")} end)
         end)}
      end)

    %{meeting: meeting, page: page, bundles: bundles}
  end

  test "paid generation publishes all locales and settles each reserved call with actual usage",
       ctx do
    generation(:paid)
    stub_bundles(ctx.bundles)

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)

    page =
      Council.get_meeting_page!(ctx.page.id) |> Ash.load!([:locale_variants, :current_revision])

    assert page.publication_status == :published
    assert %{ready?: true} = Council.publication_readiness!(page.id)
    assert Enum.sort(Enum.map(page.locale_variants, & &1.locale)) == ~w(en fr nl)

    runs = Council.list_coverage_runs!(page.id)
    assert length(runs) == 3
    by_locale = Map.new(runs, &{&1.locale, &1})
    assert is_nil(by_locale["fr"].parent_run_id)
    assert by_locale["nl"].parent_run_id == by_locale["fr"].id
    assert by_locale["en"].parent_run_id == by_locale["fr"].id
    assert page.current_revision.canonical_run_id == by_locale["fr"].id
    assert page.current_revision.nl_run_id == by_locale["nl"].id
    assert page.current_revision.en_run_id == by_locale["en"].id

    for locale <- ~w(fr nl en) do
      run = by_locale[locale]
      assert run.status == :succeeded
      assert run.processor_name == "opencode-coverage"
      assert run.provider_category == "opencode"
      assert run.model == @primary
      assert [%{"status" => "ok", "model" => @primary}] = run.usage["stages"]

      assert Map.drop(run.usage, ["stages"]) == %{
               "model" => @primary,
               "response_id" => "mock-#{locale}",
               "network_calls" => 1,
               "input_tokens" => 100,
               "output_tokens" => 20,
               "cost_cents" => 1
             }

      assert run.output == ctx.bundles[locale]
      assert page.current_revision.content["page"][locale] == ctx.bundles[locale]["page"]
      assert_reserved_request(locale, page.id, [:primary])
    end

    reservations = Ash.read!(CoverageReservation, domain: Council)
    assert length(reservations) == 3

    for reservation <- reservations do
      assert reservation.status == :settled
      assert reservation.reserved_cents == 38
      assert reservation.final_cost_cents == 1
      assert reservation.coverage_run_id == by_locale[reservation.locale].id
      assert reservation.input_usage == %{"input_tokens" => 100}
      assert reservation.output_usage == %{"output_tokens" => 20, "cost_cents" => 1}
    end

    assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 3
    assert budget.reserved_cents == 0
    refute_received {:opencode_call, _, _, _}
  end

  test "a fallback runs under the same reservation and charges it in full when cost is unknown",
       ctx do
    generation(:paid, 200)
    stub_bundles(ctx.bundles, fallback: true)

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)

    page = Council.get_meeting_page!(ctx.page.id)
    assert page.publication_status == :published

    for run <- Council.list_coverage_runs!(page.id) do
      assert run.status == :succeeded
      assert run.model == @fallback
      assert [primary, fallback] = run.usage["stages"]

      assert primary == %{
               "status" => "provider_http_error",
               "http_status" => 429,
               "network_calls" => 1,
               "model" => @primary
             }

      assert fallback["status"] == "ok"
      assert fallback["model"] == @fallback
      assert fallback["cost_cents"] == 1
      assert run.usage["network_calls"] == 2
      refute Map.has_key?(run.usage, "cost_cents")
      assert_reserved_request(run.locale, page.id, [:primary, :fallback])
    end

    reservations = Ash.read!(CoverageReservation, domain: Council)
    assert length(reservations) == 3
    assert Enum.all?(reservations, &(&1.status == :settled and is_nil(&1.final_cost_cents)))
    assert {:ok, budget} = CoverageBudget.ensure_month(200, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 3 * 38
    assert budget.reserved_cents == 0
  end

  test "an incomplete English response leaves the entire page in draft", ctx do
    generation(:paid)
    stub_bundles(ctx.bundles, incomplete: "en")

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 3, 3)

    page = Council.get_meeting_page!(ctx.page.id) |> Ash.load!(:locale_variants)
    assert page.publication_status == :draft
    assert is_nil(page.current_revision_id)
    assert page.locale_variants == []
    assert Council.list_publication_revisions!(page.id) == []

    runs = Council.list_coverage_runs!(page.id)
    assert length(runs) == 3
    failed = Enum.find(runs, &(&1.locale == "en"))
    assert failed.status == :failed
    assert failed.failure_details["classification"] == "incomplete_generation"
    assert failed.model == @primary
    assert failed.usage["cost_cents"] == 1
    assert failed.output == %{}
    assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 3
    assert budget.reserved_cents == 0
  end

  test "an incomplete replacement retains the prior public revision and every locale", ctx do
    generation(:paid)
    stub_bundles(ctx.bundles)
    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)

    before =
      Council.get_meeting_page!(ctx.page.id) |> Ash.load!([:locale_variants, :current_revision])

    before_variants = Enum.sort_by(before.locale_variants, & &1.locale)

    replacement = put_in(ctx.bundles, ["fr", "page", "title"], "Nouvelle version non publiée")
    stub_bundles(replacement, incomplete: "en")
    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 3, 3)

    after_page =
      Council.get_meeting_page!(ctx.page.id) |> Ash.load!([:locale_variants, :current_revision])

    assert after_page.publication_status == :published
    assert after_page.current_revision_id == before.current_revision_id
    assert after_page.current_revision.content == before.current_revision.content
    assert Enum.sort_by(after_page.locale_variants, & &1.locale) == before_variants
    assert length(Council.list_publication_revisions!(ctx.page.id)) == 1
    assert length(Council.list_coverage_runs!(ctx.page.id)) == 6
  end

  test "a fully reserved monthly budget sends no OpenCode request", ctx do
    generation(:paid)

    assert {:ok, reservation} =
             CoverageBudget.reserve(
               %{
                 meeting_page_id: ctx.page.id,
                 publication_input_hash: "sha256:other-reserved-input",
                 operation: :canonical_generation,
                 locale: "fr",
                 provider: "opencode",
                 model: OpenCodeCoverage.metadata().model,
                 retry: 1,
                 call_key: "other-call-consumes-whole-month",
                 estimated_cost_cents: 100
               },
               100,
               BrusselsWtf.Clock.utc_now()
             )

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)
    refute_received :unexpected_opencode_call
    assert Council.list_coverage_runs!(ctx.page.id) == []
    assert Council.get_meeting_page!(ctx.page.id).publication_status == :draft
    assert [remaining] = Ash.read!(CoverageReservation, domain: Council)
    assert remaining.id == reservation.id
    assert remaining.status == :reserved
    assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 0
    assert budget.reserved_cents == 100
  end

  test "disabled generation needs no credential and sends no OpenCode request", ctx do
    Application.put_env(:brussels_wtf, OpenCodeCoverage,
      req_options: [plug: {Req.Test, OpenCodeCoverage}]
    )

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)
    refute_received :unexpected_opencode_call
    assert Council.list_coverage_runs!(ctx.page.id) == []
    assert Ash.read!(CoverageReservation, domain: Council) == []
    assert Ash.read!(CoverageBudget, domain: Council) == []
    assert Council.get_meeting_page!(ctx.page.id).publication_status == :draft
  end

  defp generation(mode, budget \\ 100) do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: mode,
      backfill_enabled: false,
      monthly_budget_cents: if(mode == :paid, do: budget, else: nil)
    })
  end

  defp stub_bundles(bundles, opts \\ []) do
    owner = self()
    stages = if opts[:fallback], do: [:primary, :fallback], else: [:primary]
    calls = for locale <- ~w(fr nl en), stage <- stages, do: {locale, stage}
    queue = start_supervised!({Agent, fn -> calls end}, id: make_ref())

    Req.Test.stub(OpenCodeCoverage, fn conn ->
      {{locale, stage}, reservations} = {
        Agent.get_and_update(queue, fn [call | rest] -> {call, rest} end),
        Ash.read!(CoverageReservation, domain: Council)
      }

      send(owner, {:opencode_call, locale, stage, reservations})
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      if stage == :primary and opts[:fallback] do
        assert request["model"] == @primary

        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"type" => "rate_limit", "message" => "Rate limited"}})
      else
        assert request["model"] == if(stage == :primary, do: @primary, else: @fallback)

        Req.Test.json(conn, %{
          "id" => "mock-#{locale}",
          "choices" => [
            %{
              "finish_reason" => if(opts[:incomplete] == locale, do: "length", else: "stop"),
              "message" => %{"role" => "assistant", "content" => Jason.encode!(bundles[locale])}
            }
          ],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 20}
        })
      end
    end)
  end

  defp assert_reserved_request(locale, page_id, stages) do
    observed =
      for stage <- stages do
        assert_received {:opencode_call, ^locale, ^stage, reservations}
        assert [executing] = Enum.filter(reservations, &(&1.status == :executing))
        executing
      end

    executing = hd(observed)
    assert Enum.all?(observed, &(&1.id == executing.id))
    assert executing.locale == locale
    assert executing.meeting_page_id == page_id
    assert executing.reserved_cents == 38
    assert executing.estimated_cost_cents == executing.reserved_cents
    assert is_nil(executing.coverage_run_id)
  end
end
