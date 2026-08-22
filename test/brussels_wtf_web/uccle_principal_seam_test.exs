defmodule BrusselsWtfWeb.UcclePrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "Uccle base, complementary, malformed, and final sources retain exact history", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("uccle/end-to-end")
    assert :ok = BrusselsWtf.Ingestion.poll_now("uccle")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    locators = BrusselsWtf.Ingestion.list_document_locators!(scenario.commune.id)

    assert MapSet.new(Enum.map(locators, & &1.role)) ==
             MapSet.new([
               :agenda,
               :complementary_agenda,
               :explanatory_note,
               :complementary_explanatory_note,
               :register,
               :question,
               :interpellation,
               :motion
             ])

    malformed = Enum.find(locators, &(&1.role == :explanatory_note))
    assert malformed.url =~ "CC-2025-05-22-NE"
    assert malformed.meeting_identifier == "2025-06-26"

    meeting = BrusselsWtf.Council.get_ingested_meeting!("uccle", "2025-06-26")

    assert MapSet.new(Enum.map(meeting.agendas, & &1.kind)) ==
             MapSet.new([:base, :complementary, :final])

    assert [item1, item2] = Enum.sort_by(meeting.agenda_items, & &1.item_number)
    assert item1.authoritative_identifier == "26.06.2025/A/0002"
    assert item1.source_wording == "Approbation du registre du Conseil du 24 avril 2025."
    assert length(item1.versions) == 3
    assert length(item1.proposals) == 2
    assert item1.procedural_state == :decision
    assert item1.decision.disposition == :approved
    assert item1.decision.votes_for == 35
    assert item2.authoritative_identifier == "26.06.2025/A/0003"
    assert length(item2.versions) == 2

    for source <- Map.values(scenario.sources) do
      history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, source.url)
      assert [%{sha256: hash}] = history.versions
      assert hash == source.sha256
      assert [%{status: :success}] = history.observations

      roles = Enum.map(history.processing_runs, & &1.processor_role)

      if source.url == malformed.url do
        assert Enum.sort(roles) == [:native_extraction, :ocr]
      else
        assert roles == [:native_extraction]
      end
    end

    html = conn |> get("/?lang=en") |> html_response(200)
    assert html =~ "Uccle"
    assert html =~ "Previously"
    assert html =~ "#{scenario.expected.path}?lang=en##{item1.stable_anchor}"

    meeting = conn |> recycle() |> get(scenario.expected.path <> "?lang=en") |> html_response(200)
    assert meeting =~ "Decision: approved"

    for locale <- ["fr", "nl", "en"] do
      page =
        build_conn() |> get(scenario.expected.path <> "?lang=#{locale}") |> html_response(200)

      assert page =~ scenario.sources.register.url
      assert page =~ scenario.sources.register.sha256
      assert page =~ "Rico Trevisan"
    end
  end
end
