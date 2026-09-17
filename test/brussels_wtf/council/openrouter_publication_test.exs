defmodule BrusselsWtf.Council.OpenRouterPublicationTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.{CoverageBudget, CoverageReservation, Publication}
  alias BrusselsWtf.Processors.{OpenRouterCoverage, Stub}

  @actual_model "deepseek/deepseek-v4-flash-0731"

  setup do
    keys = [:coverage_generation, :coverage_processor, OpenRouterCoverage]
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
    Application.put_env(:brussels_wtf, :coverage_processor, OpenRouterCoverage)

    Application.put_env(:brussels_wtf, OpenRouterCoverage,
      api_key: "test-key-not-a-real-credential",
      req_options: [plug: {Req.Test, OpenRouterCoverage}]
    )

    owner = self()

    Req.Test.stub(OpenRouterCoverage, fn conn ->
      send(owner, :unexpected_openrouter_call)
      Plug.Conn.send_resp(conn, 500, "No HTTP call expected")
    end)

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert page.publication_status == :draft
    assert Council.list_coverage_runs!(page.id) == []
    refute_received :unexpected_openrouter_call

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
      assert run.processor_name == "openrouter-coverage"
      assert run.provider_category == "openrouter"
      assert run.model == @actual_model

      assert run.usage == %{
               "model" => @actual_model,
               "network_calls" => 1,
               "input_tokens" => 100,
               "output_tokens" => 20,
               "cost_cents" => 1
             }

      assert run.output == ctx.bundles[locale]
      assert page.current_revision.content["page"][locale] == ctx.bundles[locale]["page"]
      assert_reserved_request(locale, page.id)
    end

    reservations = Ash.read!(CoverageReservation, domain: Council)
    assert length(reservations) == 3

    for reservation <- reservations do
      assert reservation.status == :settled
      assert reservation.final_cost_cents == 1
      assert reservation.coverage_run_id == by_locale[reservation.locale].id
      assert reservation.input_usage == %{"input_tokens" => 100}
      assert reservation.output_usage == %{"output_tokens" => 20, "cost_cents" => 1}
    end

    assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 3
    assert budget.reserved_cents == 0
    refute_received {:openrouter_call, _, _}
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
    assert failed.model == @actual_model
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

  test "a fully reserved monthly budget sends no OpenRouter request", ctx do
    generation(:paid)

    assert {:ok, reservation} =
             CoverageBudget.reserve(
               %{
                 meeting_page_id: ctx.page.id,
                 publication_input_hash: "sha256:other-reserved-input",
                 operation: :canonical_generation,
                 locale: "fr",
                 provider: "openrouter",
                 model: OpenRouterCoverage.metadata().model,
                 retry: 1,
                 call_key: "other-call-consumes-whole-month",
                 estimated_cost_cents: 100
               },
               100,
               BrusselsWtf.Clock.utc_now()
             )

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)
    refute_received :unexpected_openrouter_call
    assert Council.list_coverage_runs!(ctx.page.id) == []
    assert Council.get_meeting_page!(ctx.page.id).publication_status == :draft
    assert [remaining] = Ash.read!(CoverageReservation, domain: Council)
    assert remaining.id == reservation.id
    assert remaining.status == :reserved
    assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 0
    assert budget.reserved_cents == 100
  end

  test "disabled generation needs no credential and sends no OpenRouter request", ctx do
    Application.put_env(:brussels_wtf, OpenRouterCoverage,
      req_options: [plug: {Req.Test, OpenRouterCoverage}]
    )

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)
    refute_received :unexpected_openrouter_call
    assert Council.list_coverage_runs!(ctx.page.id) == []
    assert Ash.read!(CoverageReservation, domain: Council) == []
    assert Ash.read!(CoverageBudget, domain: Council) == []
    assert Council.get_meeting_page!(ctx.page.id).publication_status == :draft
  end

  defp generation(mode) do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: mode,
      backfill_enabled: false,
      monthly_budget_cents: if(mode == :paid, do: 100, else: nil)
    })
  end

  defp stub_bundles(bundles, opts \\ []) do
    owner = self()
    queue = start_supervised!({Agent, fn -> ~w(fr nl en) end}, id: make_ref())

    Req.Test.stub(OpenRouterCoverage, fn conn ->
      locale = Agent.get_and_update(queue, fn [locale | rest] -> {locale, rest} end)
      reservations = Ash.read!(CoverageReservation, domain: Council)
      send(owner, {:openrouter_call, locale, reservations})

      Req.Test.json(conn, %{
        "id" => "mock-#{locale}",
        "model" => @actual_model,
        "choices" => [
          %{
            "finish_reason" => if(opts[:incomplete] == locale, do: "length", else: "stop"),
            "message" => %{"role" => "assistant", "content" => Jason.encode!(bundles[locale])}
          }
        ],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 20, "cost" => 0.001}
      })
    end)
  end

  defp assert_reserved_request(locale, page_id) do
    assert_received {:openrouter_call, ^locale, reservations}
    assert [executing] = Enum.filter(reservations, &(&1.status == :executing))
    assert executing.locale == locale
    assert executing.meeting_page_id == page_id
    assert executing.reserved_cents > 0
    assert executing.estimated_cost_cents == executing.reserved_cents
    assert is_nil(executing.coverage_run_id)
  end
end
