defmodule BrusselsWtfWeb.PrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "captured Ixelles sources become immutable proposal history with an unknown outcome", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    assert :ok = BrusselsWtf.Ingestion.poll_now(scenario.commune.slug)
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting_locators =
      scenario.commune.id
      |> BrusselsWtf.Ingestion.list_document_locators!()
      |> Enum.filter(&(&1.meeting_identifier == "268"))

    assert [agenda_locator, project_locator, recording_locator] = meeting_locators
    assert recording_locator.role == :recording

    assert Enum.any?(
             BrusselsWtf.Ingestion.list_document_locators!(scenario.commune.id),
             &(&1.meeting_identifier == "267" and &1.role == :minutes)
           )

    assert {agenda_locator.meeting_identifier, project_locator.meeting_identifier} ==
             {"268", "268"}

    assert agenda_locator.url == scenario.sources.agenda.url
    assert project_locator.url == scenario.sources.projects.url
    assert project_locator.parent_index_url == scenario.index_url
    assert project_locator.scheduled_on == ~D[2026-07-02]

    index_locator =
      scenario.commune.id
      |> BrusselsWtf.Ingestion.list_locators!()
      |> Enum.find(&(&1.role == :index))

    assert [%{status: :success, response_headers: %{"etag" => ["\"captured-index-268\""]}}] =
             BrusselsWtf.Ingestion.list_observations!(index_locator.id)

    agenda_history =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.agenda.url)

    project_history =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.projects.url)

    assert [%{sha256: agenda_hash}] = agenda_history.versions
    assert agenda_hash == scenario.sources.agenda.sha256
    assert [%{sha256: project_hash}] = project_history.versions
    assert project_hash == scenario.sources.projects.sha256

    assert [%{status: :success, response_headers: headers}] = project_history.observations
    assert headers["etag"] == ["\"28e875-654fe1bae46a5\""]

    assert [redirect] = hd(project_history.observations).redirect_chain
    assert redirect["status"] == 302

    assert hd(project_history.observations).final_url ==
             "https://redirect.fixtures.test/ixelles/268-projects.pdf"

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    assert meeting.scheduled_on == ~D[2026-07-02]

    assert [%{kind: :complementary, source_version_id: agenda_version_id} = agenda] =
             meeting.agendas

    assert agenda_version_id == hd(agenda_history.versions).id

    assert [
             %{authoritative_identifier: "4", procedural_state: :proposal, outcome: :unknown} =
               item
           ] = meeting.agenda_items

    agenda_membership = Enum.find(item.versions, &(&1.source_version_id == agenda_version_id))
    assert agenda_membership.agenda_id == agenda.id
    assert [%{status: :proposed, text: proposal_text} = proposal] = item.proposals
    assert proposal_text == scenario.expected.proposal_text

    assert [%{claim: :proposal, source_version_id: evidence_version_id} = evidence] =
             proposal.evidence

    assert evidence_version_id == hd(project_history.versions).id
    assert evidence.citation_url == scenario.expected.citation_url
    assert evidence.location == "Notes explicatives publiques, page 6/483"

    conn = get(conn, scenario.expected.path <> "?lang=en")
    html = html_response(conn, 200)
    assert html =~ scenario.expected.title_en
    assert html =~ scenario.expected.proposal_text
    assert html =~ "Unknown outcome"
    assert html =~ scenario.expected.citation_url
    assert html =~ project_hash
  end

  test "unchanged, changed, and failed checks append observations without overwriting bytes" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    assert %{
             "if-none-match" => ["\"28e875-654fe1bae46a5\""],
             "if-modified-since" => ["Wed, 24 Jun 2026 11:23:43 GMT"]
           } = List.last(BrusselsWtf.HTTP.Stub.requests(scenario.sources.projects.url)).headers

    BrusselsWtf.HTTP.Stub.put(scenario.sources.projects.url, %{
      status: 304,
      headers: %{"etag" => ["\"28e875-6558c5680f90c\""]},
      final_url: scenario.sources.projects.url
    })

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    unchanged =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.projects.url)

    assert Enum.map(unchanged.observations, & &1.status) == [:success, :unchanged, :unchanged]
    assert List.last(unchanged.observations).http_status == 304
    assert length(unchanged.versions) == 1
    assert length(unchanged.processing_runs) == 1

    changed_bytes = scenario.sources.projects.bytes <> "
replacement captured at the same locator"
    changed_hash = "6356d799c2a44e86feb0bd027aa32ef207fae26882f57e40032370ffa2ebe604"

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-11 10:00:00Z])

    corrected_wording =
      "Corrected captured wording for the proposed outdoor film screening."

    changed_outputs =
      put_in(
        scenario.sources.projects.outputs,
        [:normalize, "items", Access.at(0), "source_wording"],
        corrected_wording
      )

    BrusselsWtf.Test.Harness.respond_with_changed_source(
      :projects,
      changed_bytes,
      changed_outputs
    )

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    changed =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.projects.url)

    assert Enum.map(changed.observations, & &1.status) == [
             :success,
             :unchanged,
             :unchanged,
             :success
           ]

    assert MapSet.new(Enum.map(changed.versions, & &1.sha256)) ==
             MapSet.new([scenario.sources.projects.sha256, changed_hash])

    Enum.each(changed.versions, fn version ->
      assert {:ok, archived} = BrusselsWtf.Archive.get(version.object_key)
      assert BrusselsWtf.Digest.sha256(archived) == version.sha256
    end)

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    assert [item] = meeting.agenda_items
    changed_version = Enum.find(changed.versions, &(&1.sha256 == changed_hash))
    assert item.current_source_version_id == changed_version.id
    assert item.source_wording == corrected_wording

    assert MapSet.new(Enum.map(item.versions, & &1.source_wording))
           |> MapSet.member?(corrected_wording)

    assert Enum.any?(item.versions, &(&1.source_wording != corrected_wording))

    BrusselsWtf.Test.Harness.fail_source(:projects, %{
      reason: :timeout,
      final_url: "https://redirect.fixtures.test/ixelles/partial-target.pdf",
      response_headers: %{"server" => ["fixture-edge"]},
      redirect_chain: [
        %{
          "status" => 302,
          "url" => scenario.sources.projects.url,
          "location" => "https://redirect.fixtures.test/ixelles/partial-target.pdf"
        }
      ]
    })

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    failed =
      BrusselsWtf.Ingestion.source_history!(scenario.commune.id, scenario.sources.projects.url)

    assert %{status: :failure, error_kind: "timeout", error_message: error_message} =
             List.last(failed.observations)

    assert error_message =~ "timeout"

    assert List.last(failed.observations).final_url ==
             "https://redirect.fixtures.test/ixelles/partial-target.pdf"

    assert List.last(failed.observations).response_headers == %{"server" => ["fixture-edge"]}
    assert length(List.last(failed.observations).redirect_chain) == 1
    assert length(failed.versions) == 2
  end

  test "a structurally invalid index is a parser failure and does not mark locators disappeared" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    project_locator =
      scenario.commune.id
      |> BrusselsWtf.Ingestion.list_document_locators!()
      |> Enum.find(&(&1.url == scenario.sources.projects.url))

    assert [%{status: :success}] =
             BrusselsWtf.Ingestion.list_observations!(project_locator.id)

    BrusselsWtf.HTTP.Stub.put(scenario.index_url, %{
      body: "<html><body>maintenance response without council structure</body></html>",
      headers: %{"content-type" => ["text/html"]}
    })

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    assert [%{status: :success}] =
             BrusselsWtf.Ingestion.list_observations!(project_locator.id)

    index_locator =
      scenario.commune.id
      |> BrusselsWtf.Ingestion.list_locators!()
      |> Enum.find(&(&1.role == :index))

    assert %{status: :failure, error_kind: "parser_failure"} =
             List.last(BrusselsWtf.Ingestion.list_observations!(index_locator.id))
  end
end
