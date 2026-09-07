defmodule BrusselsWtfWeb.ForestPrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "Forest replacement history and final-only matters reach one revised meeting page", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("forest/end-to-end")
    assert :ok = BrusselsWtf.Ingestion.poll_now("forest")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    proposed = BrusselsWtf.Council.get_ingested_meeting!("forest", "2026-03-24")

    assert [%{procedural_state: :proposal, outcome: :unknown} = proposal_item] =
             proposed.agenda_items

    initial_page = proposed |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    [initial_revision] = BrusselsWtf.Council.list_publication_revisions!(initial_page.id)

    assert :ok = BrusselsWtf.Test.Harness.advance("final")
    assert :ok = BrusselsWtf.Ingestion.poll_now("forest")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    agenda_history =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.agenda.url)

    assert length(agenda_history.observations) == 2
    assert length(agenda_history.versions) == 2

    Enum.each(agenda_history.versions, fn version ->
      assert {:ok, bytes} = BrusselsWtf.Archive.get(version.object_key)
      assert BrusselsWtf.Digest.sha256(bytes) == version.sha256
    end)

    final = BrusselsWtf.Council.get_ingested_meeting!("forest", "2026-03-24")
    assert [final_only, continued] = Enum.sort_by(final.agenda_items, & &1.item_number)
    assert continued.id == proposal_item.id
    assert continued.decision.disposition == :approved
    assert length(continued.proposals) == 2

    assert final_only.authoritative_identifier == nil
    assert final_only.source_wording =~ "Ajouté en séance"
    assert final_only.proposals == []
    assert final_only.procedural_state == :decision
    assert final_only.decision.votes_for == 32

    roles =
      scenario.commune.id
      |> BrusselsWtf.Ingestion.list_document_locators!()
      |> MapSet.new(& &1.role)

    assert MapSet.subset?(
             MapSet.new([
               :complementary_agenda,
               :complementary_explanatory_note,
               :minutes,
               :motion
             ]),
             roles
           )

    page = final |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    revisions = BrusselsWtf.Council.list_publication_revisions!(page.id)
    assert length(revisions) == 2
    assert Enum.any?(revisions, &(&1.id == initial_revision.id))

    timeline = conn |> get("/?lang=en") |> html_response(200)
    assert timeline =~ "Successor installed during the meeting"
    assert timeline =~ "What they decided"

    meeting_html =
      build_conn()
      |> get(scenario.expected.path <> "?lang=en")
      |> html_response(200)

    assert meeting_html =~ scenario.sources.minutes.url
    assert meeting_html =~ scenario.sources.minutes.sha256
    assert meeting_html =~ "32 for"
  end
end
