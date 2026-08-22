defmodule BrusselsWtfWeb.CityOfBrusselsPrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "City indexes crawl item listings into separate French and Dutch evidence records", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("city_of_brussels/end-to-end")
    assert :ok = BrusselsWtf.Ingestion.poll_now("city-of-brussels")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    locators = BrusselsWtf.Ingestion.list_document_locators!(scenario.commune.id)
    assert Enum.count(locators, &(&1.role == :document_listing)) == 2
    assert Enum.count(locators, &(&1.role == :item_listing)) == 2
    assert Enum.count(locators, &(&1.role == :supporting_document)) == 4

    attachments = Enum.filter(locators, &(&1.role == :supporting_document))
    assert MapSet.new(Enum.map(attachments, & &1.language)) == MapSet.new([:fr, :nl])
    assert MapSet.new(Enum.map(attachments, & &1.item_identifier)) == MapSet.new(["003", "084"])

    assert Enum.all?(attachments, &String.contains?(&1.parent_index_url, "/show_documents/"))

    meeting = BrusselsWtf.Council.get_ingested_meeting!("city-of-brussels", "2026-06-29")
    assert length(meeting.agenda_items) == 2

    assert Enum.all?(
             meeting.agenda_items,
             &(&1.procedural_state == :proposal and &1.outcome == :unknown)
           )

    assert Enum.all?(meeting.agenda_items, &is_nil(&1.decision))

    item = Enum.find(meeting.agenda_items, &(&1.authoritative_identifier == "2719271"))
    assert item.item_number == "3"

    fr_record =
      BrusselsWtf.Ingestion.get_source_record_by_origin!(
        scenario.commune.id,
        scenario.sources.item_003_fr.url
      )

    nl_record =
      BrusselsWtf.Ingestion.get_source_record_by_origin!(
        scenario.commune.id,
        scenario.sources.item_003_nl.url
      )

    assert fr_record.id != nl_record.id
    assert fr_record.original_language == :fr
    assert nl_record.original_language == :nl
    assert fr_record.agenda_item_id == item.id
    assert nl_record.agenda_item_id == item.id

    for source_name <- [:base_listing, :supplement_listing, :item_003_listing, :item_084_listing] do
      source = Map.fetch!(scenario.sources, source_name)
      history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, source.url)
      assert [%{sha256: hash}] = history.versions
      assert hash == source.sha256
      assert history.processing_runs == []
    end

    timeline = conn |> get("/?lang=en") |> html_response(200)
    assert timeline =~ "City of Brussels"
    assert timeline =~ "Coming up"
    assert timeline =~ "#{scenario.expected.path}?lang=en##{item.stable_anchor}"

    page =
      build_conn()
      |> get(scenario.expected.path <> "?lang=en")
      |> html_response(200)

    assert page =~ scenario.sources.item_003_fr.url
    assert page =~ scenario.sources.item_003_fr.sha256
    refute page =~ "Decision:"

    assert :ok = BrusselsWtf.Ingestion.poll_now("city-of-brussels")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    Enum.each(attachments, fn locator ->
      history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, locator.url)
      assert length(history.versions) == 1
      assert Enum.map(history.observations, & &1.status) == [:success, :unchanged]
    end)
  end
end
