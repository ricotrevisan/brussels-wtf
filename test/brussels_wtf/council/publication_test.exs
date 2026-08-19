defmodule BrusselsWtf.Council.PublicationTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

  defmodule FailingCoverageProcessor do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    def generate_fr(_input),
      do:
        {:error,
         {:provider_unavailable,
          %{retryable: true, stage: :canonical, private_message: "must not persist"}},
         %{"request_units" => 1}}

    @impl true
    def translate(_canonical, _locale), do: {:error, :should_not_run}

    @impl true
    def metadata do
      %{
        processor_name: "failing-coverage-processor",
        processor_version: "1",
        config_hash: "sha256:failing-coverage-processor",
        provider_category: "test_failure",
        model: nil,
        canonical_method: :ai_generation,
        translation_method: :machine_translation,
        usage: %{}
      }
    end
  end

  test "a missing item locale keeps all locales private and reports the exact gate failure", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    incomplete = pop_in(scenario.coverage, ["items", "4", "variants", "nl"]) |> elem(1)
    BrusselsWtf.Processors.Stub.put_locales("268", incomplete)

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    assert page.publication_status == :draft

    assert %{
             ready?: false,
             failures: [
               %{code: :missing_coverage_variant, item_key: "4", locale: "nl"}
             ]
           } = Council.publication_readiness!(page.id)

    for locale <- ["fr", "nl", "en"] do
      response = get(recycle(conn), "/meetings/ixelles/268?lang=#{locale}")
      assert html_response(response, 404) =~ "Not Found"
    end

    actor = %Actor{id: "rico", role: :reviewer}
    assert [review_case] = Review.list_review_cases!(%{kind: :publication}, actor: actor)
    assert review_case.affected_record_id == page.id
    assert review_case.processing_generation =~ "sha256:"

    assert review_case.diagnostics["failures"] == [
             %{
               "code" => "missing_coverage_variant",
               "item_key" => "4",
               "claim_key" => nil,
               "locale" => "nl"
             }
           ]

    assert {:error, _gate_error} =
             Council.publish_meeting_page(page, %{
               revision_published_at: BrusselsWtf.Clock.utc_now(),
               publication_input_hash: page.publication_input_hash,
               gate_input_hash: page.publication_input_hash,
               last_gate_failures: [],
               gate_checked_at: BrusselsWtf.Clock.utc_now()
             })

    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "a missing page locale is reported without partial publication" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    incomplete = pop_in(scenario.coverage, ["page", "en"]) |> elem(1)
    BrusselsWtf.Processors.Stub.put_locales("268", incomplete)

    page = poll_and_page!()

    assert %{ready?: false, failures: [%{code: :missing_page_variant, locale: "en"}]} =
             Council.publication_readiness!(page.id)
  end

  test "a normalized claim without official evidence is reported precisely" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    outputs =
      put_in(
        scenario.sources.projects.outputs,
        [:normalize, "items", Access.at(0), "proposals", Access.at(0), "evidence"],
        nil
      )

    BrusselsWtf.Processors.Stub.put(scenario.sources.projects.sha256, outputs)
    page = poll_and_page!()

    assert %{
             ready?: false,
             failures: [
               %{code: :missing_evidence, item_key: "4", claim_key: claim_key}
             ]
           } = Council.publication_readiness!(page.id)

    assert claim_key == "proposal:#{scenario.sources.projects.sha256}"
  end

  test "generated copy cannot introduce a claim absent from normalized state" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    unsupported =
      update_in(scenario.coverage, ["items", "4", "claim_refs"], fn refs ->
        refs ++ ["proposal:invented"]
      end)

    BrusselsWtf.Processors.Stub.put_locales("268", unsupported)
    page = poll_and_page!()

    assert %{ready?: false, failures: failures} = Council.publication_readiness!(page.id)
    assert Enum.any?(failures, &(&1.code == :unsupported_page_claim_reference))
    assert Enum.any?(failures, &(&1.code == :unsupported_claim_reference and &1.item_key == "4"))

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    [item] = meeting.agenda_items
    assert Ash.load!(item, :coverage_variants).coverage_variants == []
  end

  test "the persisted gate requires applicable generation provenance" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    page = poll_and_page!()
    meeting = Council.get_ingested_meeting!("ixelles", "268")
    [item] = meeting.agenda_items

    [english] =
      Ash.load!(item, :coverage_variants).coverage_variants |> Enum.filter(&(&1.locale == "en"))

    Council.stage_meeting_page_revision!(page)

    Council.upsert_coverage_variant!(%{
      agenda_item_id: item.id,
      coverage_run_id: english.coverage_run_id,
      locale: english.locale,
      title: english.title,
      summary: english.summary,
      proposal_summary: english.proposal_summary,
      provenance: [:ai_generated]
    })

    assert %{ready?: false, failures: failures} =
             Council.evaluate_publication_gate!(page.id, page.publication_input_hash)

    assert Enum.any?(failures, &(&1.code == :missing_provenance and &1.locale == "en"))
  end

  test "a complete later generation replaces all published locale variants atomically", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    page = poll_and_page!()
    meeting = Council.get_ingested_meeting!("ixelles", "268")
    before_run_ids = Council.list_locale_variants!(page.id) |> MapSet.new(& &1.coverage_run_id)

    revised =
      put_in(
        scenario.coverage,
        ["items", "4", "variants", "en", "title"],
        "PUBLISHED-REVISION-SENTINEL"
      )

    BrusselsWtf.Processors.Stub.put_locales("268", revised)
    assert :ok = Council.generate_meeting_coverage!(meeting.id, 1, 3)

    html = conn |> get("/meetings/ixelles/268?lang=en") |> html_response(200)
    assert html =~ "PUBLISHED-REVISION-SENTINEL"

    after_run_ids = Council.list_locale_variants!(page.id) |> MapSet.new(& &1.coverage_run_id)
    assert MapSet.disjoint?(before_run_ids, after_run_ids)
    assert MapSet.size(after_run_ids) == 3

    assert [first, second] = Council.list_publication_revisions!(page.id)
    refute get_in(first.content, ["items", "4", "variants", "en", "title"]) =~ "SENTINEL"

    assert get_in(second.content, ["items", "4", "variants", "en", "title"]) ==
             "PUBLISHED-REVISION-SENTINEL"

    assert MapSet.new([second.canonical_run_id, second.nl_run_id, second.en_run_id]) ==
             after_run_ids

    assert Council.get_meeting_page!(page.id).current_revision_id == second.id
  end

  test "published variants cannot change before a revision is staged" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    page = poll_and_page!()
    [variant] = Council.list_locale_variants!(page.id) |> Enum.filter(&(&1.locale == "en"))

    assert {:error, _error} =
             Council.upsert_locale_variant(%{
               meeting_page_id: page.id,
               coverage_run_id: variant.coverage_run_id,
               locale: "en",
               title: "BYPASS",
               summary: variant.summary,
               provenance: variant.provenance
             })

    refute Council.list_locale_variants!(page.id) |> Enum.any?(&(&1.title == "BYPASS"))
  end

  test "gate-ready pages require a matching immutable revision" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    page = poll_and_page!()
    staged_page = Council.stage_meeting_page_revision!(page)

    assert Council.evaluate_publication_gate!(page.id, page.publication_input_hash).ready?

    assert {:error, _error} =
             Council.publish_meeting_page(staged_page, %{
               revision_published_at: DateTime.add(BrusselsWtf.Clock.utc_now(), 1, :second),
               publication_input_hash: page.publication_input_hash,
               gate_input_hash: page.publication_input_hash,
               last_gate_failures: [],
               gate_checked_at: BrusselsWtf.Clock.utc_now()
             })

    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "publication revisions reject content unrelated to their run trio" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    page = poll_and_page!()
    [revision] = Council.list_publication_revisions!(page.id)

    assert {:error, _error} =
             Council.record_publication_revision(%{
               meeting_page_id: page.id,
               publication_input_hash: revision.publication_input_hash,
               published_at: BrusselsWtf.Clock.utc_now(),
               canonical_run_id: revision.canonical_run_id,
               nl_run_id: revision.nl_run_id,
               en_run_id: revision.en_run_id,
               content: %{}
             })
  end

  test "processor failures retain every execution and become actionable after bounded retry" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    previous = Application.fetch_env!(:brussels_wtf, :coverage_processor)
    Application.put_env(:brussels_wtf, :coverage_processor, FailingCoverageProcessor)
    on_exit(fn -> Application.put_env(:brussels_wtf, :coverage_processor, previous) end)

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")

    for queue <- [:poll, :fetch, :extract, :normalize] do
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: queue, with_safety: false)
    end

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    job = %Oban.Job{args: %{"meeting_id" => meeting.id}, attempt: 1, max_attempts: 3}

    assert {:error, :coverage_generation_failed} =
             BrusselsWtf.Workers.PublishMeeting.perform(job)

    assert :ok =
             BrusselsWtf.Workers.PublishMeeting.perform(%{job | attempt: 3})

    assert page.id
           |> Council.list_coverage_runs!()
           |> Enum.map(&{&1.status, &1.failure_details, &1.usage}) == [
             {:failed,
              %{
                "classification" => "provider_unavailable",
                "retryable" => true,
                "stage" => "canonical"
              }, %{"request_units" => 1}},
             {:failed,
              %{
                "classification" => "provider_unavailable",
                "retryable" => true,
                "stage" => "canonical"
              }, %{"request_units" => 1}}
           ]

    assert Council.get_meeting_page!(page.id).publication_status == :draft

    actor = %Actor{id: "rico", role: :reviewer}
    assert [review_case] = Review.list_review_cases!(%{kind: :publication}, actor: actor)
    assert review_case.summary =~ "bounded retries"
    assert review_case.diagnostics["classification"] == "provider_unavailable"
    assert review_case.diagnostics["attempt"] == 3
  end

  test "an open normalization case blocks the current generation" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")

    for queue <- [:poll, :fetch, :extract, :normalize] do
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: queue, with_safety: false)
    end

    meeting = Council.get_ingested_meeting!("ixelles", "268")

    [item] = meeting.agenda_items

    Review.open_review_case!(%{
      kind: :normalization,
      commune_id: scenario.commune.id,
      affected_record_id: item.id,
      affected_record_type: "agenda_item",
      processing_generation: "blocking-normalization",
      urgency: :high,
      summary: "Normalization requires review"
    })

    assert :ok =
             BrusselsWtf.Workers.PublishMeeting.perform(%Oban.Job{
               args: %{"meeting_id" => meeting.id},
               attempt: 1,
               max_attempts: 3
             })

    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert Council.get_meeting_page!(page.id).publication_status == :draft

    assert %{ready?: false, failures: [%{code: :blocking_review_case}]} =
             Council.publication_readiness!(page.id)
  end

  test "repairing the same generation resolves its publication gate case" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    incomplete = pop_in(scenario.coverage, ["items", "4", "variants", "nl"]) |> elem(1)
    BrusselsWtf.Processors.Stub.put_locales("268", incomplete)
    page = poll_and_page!()

    actor = %Actor{id: "rico", role: :reviewer}
    assert [%{status: :open}] = Review.list_review_cases!(%{kind: :publication}, actor: actor)

    BrusselsWtf.Processors.Stub.put_locales("268", scenario.coverage)
    meeting = Council.get_ingested_meeting!("ixelles", "268")
    assert :ok = Council.generate_meeting_coverage!(meeting.id, 1, 3)

    assert Council.get_meeting_page!(page.id).publication_status == :published
    assert [%{status: :resolved}] = Review.list_review_cases!(%{kind: :publication}, actor: actor)
  end

  defp poll_and_page! do
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
  end
end
