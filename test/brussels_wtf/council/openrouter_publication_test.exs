defmodule BrusselsWtf.Council.OpenRouterPublicationTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.{CoverageBudget, CoverageReservation, Publication}
  alias BrusselsWtf.Processors.OpenRouterCoverage
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

  @primary "deepseek/deepseek-v4.1-flash"
  @reviewer %Actor{id: "rico", role: :reviewer}

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

    %{meeting: meeting, page: page}
  end

  test "a meeting larger than one batch publishes complete FR/NL/EN coverage", ctx do
    grow_meeting(ctx.meeting, 11)
    input = Publication.generation_input(ctx.meeting.id)
    assert length(input["items"]) == 12
    assert {:ok, [first, second]} = OpenRouterCoverage.batch_keys(input)
    assert {length(first), length(second)} == {8, 4}

    generation(:paid)
    stub_provider()

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)

    page =
      Council.get_meeting_page!(ctx.page.id) |> Ash.load!([:locale_variants, :current_revision])

    assert page.publication_status == :published
    assert %{ready?: true} = Council.publication_readiness!(page.id)
    assert Enum.sort(Enum.map(page.locale_variants, & &1.locale)) == ~w(en fr nl)
    assert page.current_revision.content["page"]["fr"]["title"] == "Séance du conseil"
    assert page.current_revision.content["page"]["nl"]["title"] == "[nl] Séance du conseil"

    for locale <- ~w(fr nl en), {key, item} <- page.current_revision.content["items"] do
      assert item["variants"][locale]["title"] =~ "Point #{key}"
    end

    assert map_size(page.current_revision.content["items"]) == 12

    runs = Map.new(Council.list_coverage_runs!(page.id), &{&1.locale, &1})
    assert map_size(runs) == 3
    assert runs["nl"].parent_run_id == runs["fr"].id
    assert runs["en"].parent_run_id == runs["fr"].id
    assert page.current_revision.canonical_run_id == runs["fr"].id

    # FR: two item batches plus the page call; NL/EN: two translation batches.
    assert {runs["fr"].usage["batches"], runs["fr"].usage["network_calls"]} == {2, 3}
    assert {runs["nl"].usage["batches"], runs["nl"].usage["network_calls"]} == {2, 2}
    assert {runs["en"].usage["batches"], runs["en"].usage["network_calls"]} == {2, 2}
    assert Enum.all?(Map.values(runs), &(&1.status == :succeeded and &1.model == @primary))

    reservations = Ash.read!(CoverageReservation, domain: Council)
    assert length(reservations) == 3

    for reservation <- reservations do
      run = runs[reservation.locale]
      assert reservation.status == :settled
      assert reservation.coverage_run_id == run.id
      assert reservation.final_cost_cents == run.usage["cost_cents"]
      assert reservation.final_cost_cents <= reservation.estimated_cost_cents
    end

    # Every HTTP call ran while exactly its operation's reservation was executing.
    calls = collect_calls()
    assert length(calls) == 7

    for {locale, executing} <- calls do
      assert [reservation] = executing
      assert reservation.locale == locale
      assert reservation.estimated_cost_cents > 0
    end

    assert {:ok, budget} = CoverageBudget.ensure_month(1000, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == Enum.sum(Enum.map(reservations, & &1.final_cost_cents))
    assert budget.reserved_cents == 0
  end

  test "one failed batch publishes nothing and opens an operator-visible case at once", ctx do
    grow_meeting(ctx.meeting, 11)
    generation(:paid)
    stub_provider(fail: {"nl", 2})

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)

    page = Council.get_meeting_page!(ctx.page.id) |> Ash.load!(:locale_variants)
    assert page.publication_status == :draft
    assert is_nil(page.current_revision_id)
    assert page.locale_variants == []
    assert Council.list_publication_revisions!(page.id) == []

    runs = Map.new(Council.list_coverage_runs!(page.id), &{&1.locale, &1})
    assert Map.keys(runs) |> Enum.sort() == ~w(fr nl)
    assert runs["nl"].status == :failed
    assert runs["nl"].failure_details == %{"classification" => "invalid_generation_output"}
    assert runs["nl"].output == %{}

    assert [review_case] = Review.list_review_cases!(%{kind: :publication}, actor: @reviewer)
    assert review_case.status == :open
    assert review_case.affected_record_id == page.id
    assert review_case.summary == "Coverage processor failed; a retry cannot change the result"

    assert review_case.diagnostics == %{
             "attempt" => 1,
             "classification" => "invalid_generation_output",
             "coverage_run_id" => runs["nl"].id,
             "locale" => "nl"
           }

    refute inspect(review_case.diagnostics) =~ "Point"

    assert {:ok, budget} = CoverageBudget.ensure_month(1000, BrusselsWtf.Clock.utc_now())
    assert budget.reserved_cents == 0
    assert budget.spent_cents == runs["fr"].usage["cost_cents"] + runs["nl"].usage["cost_cents"]
  end

  test "an oversized item fails closed without a call or a retry", ctx do
    grow_meeting(ctx.meeting, 1, String.duplicate("Très long point. ", 4_000))
    generation(:paid)

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)
    refute_received :unexpected_openrouter_call

    assert [run] = Council.list_coverage_runs!(ctx.page.id)
    assert run.failure_details == %{"classification" => "input_too_large"}
    assert run.usage["network_calls"] == 0

    assert [review_case] = Review.list_review_cases!(%{kind: :publication}, actor: @reviewer)
    assert review_case.diagnostics["classification"] == "input_too_large"
    assert review_case.diagnostics["attempt"] == 1

    assert [reservation] = Ash.read!(CoverageReservation, domain: Council)
    assert {reservation.status, reservation.final_cost_cents} == {:settled, 0}
  end

  test "a retryable provider failure is retried and reported only on the last attempt", ctx do
    generation(:paid)
    stub_provider(unavailable: "fr")

    assert {:error, _} = Council.generate_meeting_coverage(ctx.meeting.id, 1, 3)
    assert Review.list_review_cases!(%{kind: :publication}, actor: @reviewer) == []
    assert [run] = Council.list_coverage_runs!(ctx.page.id)
    assert run.failure_details["classification"] == "provider_http_error"
    assert run.usage["network_calls"] == 3
    # Each uncertain stage is charged at its own bound, never above the reservation.
    assert [reservation] = Ash.read!(CoverageReservation, domain: Council)
    assert reservation.final_cost_cents == run.usage["cost_cents"]
    assert reservation.final_cost_cents <= reservation.estimated_cost_cents

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 3, 3)
    assert [review_case] = Review.list_review_cases!(%{kind: :publication}, actor: @reviewer)
    assert review_case.summary == "Coverage processor failed after bounded retries"
    assert review_case.diagnostics["attempt"] == 3
  end

  test "an incomplete replacement retains the prior public revision and every locale", ctx do
    generation(:paid)
    stub_provider()
    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)

    before =
      Council.get_meeting_page!(ctx.page.id) |> Ash.load!([:locale_variants, :current_revision])

    assert before.publication_status == :published
    before_variants = Enum.sort_by(before.locale_variants, & &1.locale)

    stub_provider(incomplete: "en")
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
                 estimated_cost_cents: 1000
               },
               1000,
               BrusselsWtf.Clock.utc_now()
             )

    assert :ok = Council.generate_meeting_coverage!(ctx.meeting.id, 1, 3)
    refute_received :unexpected_openrouter_call
    assert Council.list_coverage_runs!(ctx.page.id) == []
    assert Council.get_meeting_page!(ctx.page.id).publication_status == :draft
    assert [remaining] = Ash.read!(CoverageReservation, domain: Council)
    assert remaining.id == reservation.id
    assert remaining.status == :reserved
    assert {:ok, budget} = CoverageBudget.ensure_month(1000, BrusselsWtf.Clock.utc_now())
    assert budget.spent_cents == 0
    assert budget.reserved_cents == 1000
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
      monthly_budget_cents: if(mode == :paid, do: 1000, else: nil)
    })
  end

  # Clones the fixture's evidenced item into more votable points of the same meeting.
  defp grow_meeting(meeting, count, wording \\ nil) do
    [item] = Publication.load_meeting(meeting.id).agenda_items
    [proposal] = item.proposals
    [evidence] = proposal.evidence

    for n <- 1..count do
      number = "#{100 + n}"

      added =
        Council.upsert_agenda_item!(%{
          council_meeting_id: meeting.id,
          item_number: number,
          authoritative_identifier: number,
          source_wording: wording || "#{item.source_wording} (#{number})",
          current_source_version_id: item.current_source_version_id,
          current_version_order: item.current_version_order,
          procedural_state: item.procedural_state,
          outcome: item.outcome
        })

      cloned =
        Council.record_proposal!(%{
          agenda_item_id: added.id,
          source_version_id: proposal.source_version_id,
          source_version_order: proposal.source_version_order,
          text: wording || "#{proposal.text} (#{number})"
        })

      Council.record_evidence!(%{
        proposal_id: cloned.id,
        source_version_id: evidence.source_version_id,
        claim: evidence.claim,
        excerpt: evidence.excerpt,
        location: evidence.location,
        citation_url: evidence.citation_url,
        retrieved_at: evidence.retrieved_at
      })
    end
  end

  # Answers each OpenRouter request from its own content, so concurrent batch
  # calls need no ordering. Records the reservations executing during each call.
  defp stub_provider(opts \\ []) do
    owner = self()
    seen = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    Req.Test.stub(OpenRouterCoverage, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["reasoning"] == %{"enabled" => false}
      system = hd(request["messages"])["content"]
      data = Jason.decode!(List.last(request["messages"])["content"])

      locale =
        case Regex.run(~r/to (nl|en)\./, system) do
          [_, locale] -> locale
          nil -> "fr"
        end

      executing =
        CoverageReservation
        |> Ash.read!(domain: Council)
        |> Enum.filter(&(&1.status == :executing))

      send(owner, {:openrouter_call, locale, executing})

      n =
        Agent.get_and_update(
          seen,
          &{Map.get(&1, locale, 0) + 1, Map.update(&1, locale, 1, fn v -> v + 1 end)}
        )

      cond do
        opts[:unavailable] == locale ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        opts[:fail] == {locale, n} ->
          reply(
            conn,
            put_in(
              answer(locale, system, data),
              ["items", hd(Map.keys(data["items"])), "claim_refs"],
              ["invented"]
            ),
            "stop"
          )

        opts[:incomplete] == locale ->
          reply(conn, answer(locale, system, data), "length")

        true ->
          reply(conn, answer(locale, system, data), "stop")
      end
    end)
  end

  defp answer("fr", system, data) do
    if system =~ "exactly two keys, title and summary" do
      %{"title" => "Séance du conseil", "summary" => "Points proposés au conseil."}
    else
      refs = Enum.flat_map(data["items"], fn item -> Enum.map(item["claims"], & &1["key"]) end)

      %{
        "meeting_identifier" => data["meeting_identifier"],
        "page" => %{"title" => "Séance du conseil", "summary" => "Points.", "claim_refs" => refs},
        "items" =>
          Map.new(data["items"], fn item ->
            {item["key"],
             %{
               "claim_refs" => Enum.map(item["claims"], & &1["key"]),
               "variant" => %{
                 "title" => "Point #{item["key"]}",
                 "summary" => "Proposition au conseil.",
                 "proposal_summary" => "L'issue reste inconnue."
               }
             }}
          end)
      }
    end
  end

  defp answer(locale, _system, data) do
    prefix = fn text -> "[#{locale}] " <> text end

    data
    |> update_in(["page", "title"], prefix)
    |> update_in(["page", "summary"], prefix)
    |> Map.update!("items", fn items ->
      Map.new(items, fn {key, item} ->
        {key, Map.update!(item, "variant", &Map.new(&1, fn {k, v} -> {k, prefix.(v)} end))}
      end)
    end)
  end

  defp reply(conn, output, finish_reason) do
    Req.Test.json(conn, %{
      "id" => "gen-mock",
      "model" => @primary,
      "choices" => [
        %{
          "finish_reason" => finish_reason,
          "message" => %{"role" => "assistant", "content" => Jason.encode!(output)}
        }
      ],
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 20, "cost" => 0.001}
    })
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:openrouter_call, locale, executing} -> collect_calls([{locale, executing} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
