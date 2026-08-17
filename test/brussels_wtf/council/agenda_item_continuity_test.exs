defmodule BrusselsWtf.Council.AgendaItemContinuityTest do
  use BrusselsWtf.DataCase, async: true

  test "authoritative identifiers survive renumbering and distinguish reused numbers" do
    meeting = meeting!()

    original =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "4",
        authoritative_identifier: "ixelles-item-a",
        source_wording: "Original wording",
        current_version_order: "1",
        outcome: :unknown
      })

    renumbered =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "44",
        authoritative_identifier: "ixelles-item-a",
        source_wording: "Renumbered wording",
        current_version_order: "2",
        outcome: :unknown
      })

    reused_number =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "44",
        authoritative_identifier: "ixelles-item-b",
        source_wording: "Different authoritative matter",
        current_version_order: "1",
        outcome: :unknown
      })

    assert renumbered.id == original.id
    assert renumbered.item_number == "44"
    assert reused_number.id != original.id
  end

  test "meeting item number is the continuity fallback only without an authoritative id" do
    meeting = meeting!()

    first =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "F-1",
        source_wording: "Fallback wording one",
        current_version_order: "1",
        outcome: :unknown
      })

    repeated =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "F-1",
        source_wording: "Fallback wording two",
        current_version_order: "2",
        outcome: :unknown
      })

    assert repeated.id == first.id
  end

  defp meeting! do
    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: "continuity-#{System.unique_integer([:positive])}",
        name: "Continuity fixture",
        index_url: "https://continuity.invalid/index"
      })

    BrusselsWtf.Council.upsert_meeting!(%{
      commune_id: commune.id,
      municipal_identifier: "meeting-1",
      scheduled_on: ~D[2026-07-02]
    })
  end
end
