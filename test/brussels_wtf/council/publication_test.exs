defmodule BrusselsWtf.Council.PublicationTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

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
               %{code: :missing_official_evidence, item_key: "4", claim_key: claim_key}
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

    assert %{
             ready?: false,
             failures: [%{code: :unsupported_claim_reference, item_key: "4"}]
           } = Council.publication_readiness!(page.id)

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
             BrusselsWtf.Council.PublicationGate.evaluate(page.id, page.publication_input_hash)

    assert Enum.any?(failures, &(&1.code == :missing_provenance and &1.locale == "en"))
  end

  test "a completed initial publication cannot leak a later partial generated revision", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    page = poll_and_page!()
    meeting = Council.get_ingested_meeting!("ixelles", "268")

    revised =
      put_in(
        scenario.coverage,
        ["items", "4", "variants", "en", "title"],
        "UNPUBLISHED-REVISION-SENTINEL"
      )

    BrusselsWtf.Processors.Stub.put_locales("268", revised)
    assert :ok = BrusselsWtf.Council.Publication.generate_and_publish(meeting.id)

    html = conn |> get("/meetings/ixelles/268?lang=en") |> html_response(200)
    refute html =~ "UNPUBLISHED-REVISION-SENTINEL"

    assert Council.get_meeting_page!(page.id).publication_input_hash ==
             page.publication_input_hash
  end

  defp poll_and_page! do
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
  end
end
