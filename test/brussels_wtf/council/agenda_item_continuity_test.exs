defmodule BrusselsWtf.Council.AgendaItemContinuityTest do
  use BrusselsWtf.DataCase, async: true

  test "authoritative identifiers survive renumbering and distinguish reused numbers" do
    meeting = meeting!()
    version_1 = source_version!(meeting, "one")
    version_2 = source_version!(meeting, "two")

    original =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "4",
        authoritative_identifier: "ixelles-item-a",
        source_wording: "Original wording",
        current_source_version_id: version_1.id,
        current_version_order: "1",
        outcome: :unknown
      })

    renumbered =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "44",
        authoritative_identifier: "ixelles-item-a",
        source_wording: "Renumbered wording",
        current_source_version_id: version_2.id,
        current_version_order: "2",
        outcome: :unknown
      })

    reused_number =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "44",
        authoritative_identifier: "ixelles-item-b",
        source_wording: "Different authoritative matter",
        current_source_version_id: version_2.id,
        current_version_order: "1",
        outcome: :unknown
      })

    assert renumbered.id == original.id
    assert renumbered.item_number == "44"
    assert reused_number.id != original.id
  end

  test "meeting item number is the continuity fallback only without an authoritative id" do
    meeting = meeting!()
    version_1 = source_version!(meeting, "fallback-one")
    version_2 = source_version!(meeting, "fallback-two")

    first =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "F-1",
        source_wording: "Fallback wording one",
        current_source_version_id: version_1.id,
        current_version_order: "1",
        outcome: :unknown
      })

    repeated =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "F-1",
        source_wording: "Fallback wording two",
        current_source_version_id: version_1.id,
        current_version_order: "2",
        outcome: :unknown
      })

    assert repeated.id == first.id

    reused_number_in_new_version =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "F-1",
        source_wording: "Unidentified matter in a new source version",
        current_source_version_id: version_2.id,
        current_version_order: "3",
        outcome: :unknown
      })

    assert reused_number_in_new_version.id != first.id
  end

  defp source_version!(meeting, suffix) do
    record =
      BrusselsWtf.Ingestion.upsert_source_record!(%{
        commune_id: meeting.commune_id,
        origin_url: "https://continuity.invalid/#{suffix}",
        role: :agenda,
        original_language: :fr
      })

    BrusselsWtf.Ingestion.upsert_source_version!(%{
      source_record_id: record.id,
      sha256: BrusselsWtf.Digest.sha256(suffix),
      byte_size: byte_size(suffix),
      media_type: "text/plain",
      object_key: "sha256/#{suffix}",
      first_retrieved_at: BrusselsWtf.Clock.utc_now()
    })
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
