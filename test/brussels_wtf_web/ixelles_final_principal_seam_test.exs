defmodule BrusselsWtfWeb.IxellesFinalPrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "authoritative minutes revise the same Ixelles page without rewriting its proposal", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/final-267")

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    proposed = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "267")
    assert [%{procedural_state: :proposal, outcome: :unknown} = item] = proposed.agenda_items
    assert [%{text: proposal_text}] = item.proposals
    assert proposal_text == scenario.expected.proposal_text
    assert item.decision == nil

    page = proposed |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert page.publication_status == :published
    [proposal_revision] = BrusselsWtf.Council.list_publication_revisions!(page.id)
    stable_anchor = item.stable_anchor

    initial = conn |> get("/?lang=en") |> html_response(200)
    assert initial =~ "Coming up"
    assert initial =~ "Outcome unknown"
    assert initial =~ "#{scenario.expected.path}?lang=en##{stable_anchor}"

    assert :ok = BrusselsWtf.Test.Harness.advance("final")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :normalize)

    still_published =
      BrusselsWtf.Council.get_published_meeting_page!("ixelles", "267")

    still_item = hd(still_published.council_meeting.agenda_items)
    assert still_item.procedural_state == :decision
    assert still_item.published_procedural_state == :proposal
    assert is_nil(loaded_or_nil(still_item.published_decision))

    staged_html = build_conn() |> get("/meetings/ixelles/267?lang=en") |> html_response(200)
    assert staged_html =~ "The council has not yet decided"
    assert staged_html =~ "Outcome unknown"
    refute staged_html =~ "Decision: approved"
    refute staged_html =~ "37 for"

    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(from: :publish)

    final = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "267")

    assert [%{id: item_id, procedural_state: :decision, outcome: :approved} = decided] =
             final.agenda_items

    assert item_id == item.id
    assert decided.stable_anchor == stable_anchor
    assert [%{text: ^proposal_text}] = decided.proposals

    assert %{disposition: :approved, statement: "Le Conseil approuve.", votes_for: 37} =
             decided.decision

    assert decided.decision.votes_against == nil
    assert decided.decision.abstentions == nil
    assert Enum.sort(Enum.map(decided.decision.evidence, & &1.claim)) == [:decision, :vote]

    minutes_history =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.minutes.url)

    assert [%{sha256: minutes_hash} = minutes_version] = minutes_history.versions
    assert minutes_hash == scenario.sources.minutes.sha256
    assert {:ok, archived_minutes} = BrusselsWtf.Archive.get(minutes_version.object_key)
    assert archived_minutes == scenario.sources.minutes.bytes
    assert decided.decision.source_version_id == minutes_version.id
    assert Enum.all?(decided.decision.evidence, &(&1.source_version_id == minutes_version.id))

    agenda_version =
      scenario.commune.id
      |> BrusselsWtf.Ingestion.source_history!(scenario.sources.agenda.url)
      |> Map.fetch!(:versions)
      |> List.first()

    assert_raise Ash.Error.Invalid,
                 ~r/decision evidence must use the decision source version/,
                 fn ->
                   BrusselsWtf.Council.record_decision_evidence!(%{
                     decision_id: decided.decision.id,
                     source_version_id: agenda_version.id,
                     claim: :decision,
                     excerpt: "Unrelated agenda excerpt",
                     location: "agenda",
                     citation_url: scenario.sources.agenda.url,
                     retrieved_at: agenda_version.first_retrieved_at
                   })
                 end

    assert_raise Ash.Error.Invalid, ~r/outcome must match/, fn ->
      BrusselsWtf.Council.mark_agenda_item_decided!(decided, %{
        current_decision_id: decided.decision.id,
        outcome: :rejected
      })
    end

    revised_page = final |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    revisions = BrusselsWtf.Council.list_publication_revisions!(revised_page.id)
    assert length(revisions) == 2
    assert Enum.any?(revisions, &(&1.id == proposal_revision.id))
    assert Enum.all?(revisions, &(&1.meeting_page_id == page.id))

    timeline = build_conn() |> get("/?lang=en") |> html_response(200)
    assert timeline =~ "What they decided"
    assert timeline =~ "Decision: approved"
    refute timeline =~ "37 against"

    for {locale, title, vote} <- [
          {"fr", "Approbation du procès-verbal du 21 mai", "37 pour"},
          {"nl", "Goedkeuring van het proces-verbaal van 21 mei", "37 voor"},
          {"en", "Approval of the 21 May minutes", "37 for"}
        ] do
      html =
        build_conn()
        |> get(scenario.expected.path <> "?lang=#{locale}")
        |> html_response(200)

      assert html =~ title
      assert html =~ stable_anchor
      assert html =~ vote
      assert html =~ scenario.sources.minutes.url
      assert html =~ minutes_hash
    end
  end

  test "decision-shaped output from a pre-meeting source cannot create a final outcome" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/final-267")
    agenda = scenario.sources.agenda

    invalid =
      put_in(
        agenda.outputs,
        [:normalize, "items", Access.at(0), "decisions"],
        [
          %{
            "disposition" => "approved",
            "statement" => "Unsupported",
            "evidence" => %{"excerpt" => "Unsupported", "location" => "agenda"}
          }
        ]
      )

    BrusselsWtf.Processors.Stub.put(agenda.sha256, invalid)
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")

    assert_raise Ash.Error.Invalid,
                 ~r/authoritative final minutes or register are required/,
                 fn ->
                   BrusselsWtf.Test.Harness.drain_pipeline()
                 end
  end

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value
end
