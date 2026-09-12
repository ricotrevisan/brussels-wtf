defmodule BrusselsWtfWeb.FactPathsTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Test.GazetteManagementFixture, as: Gazette

  setup do
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    scenario = BrusselsWtf.Test.Harness.load("ixelles/final-267")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "267")
    [item] = meeting.agenda_items

    {:ok, scenario: scenario, meeting: meeting, item: item}
  end

  test "a resolved company mention plus verified manager renders a two-edge fact path", %{
    conn: conn,
    scenario: scenario,
    item: item
  } do
    %{company: company, person: person} = publish_gazette_manager!()
    attach_resolved_mention!(item, company)

    before = sourced_fact_ids()

    html =
      conn
      |> get(scenario.expected.path <> "?lang=en")
      |> html_response(200)

    assert html =~ "Fact paths"
    assert html =~ "named in"
    assert html =~ "director of"
    assert html =~ "Public Example ASBL"
    assert html =~ person.legal_name
    assert html =~ Gazette.appointment_url()
    assert html =~ "https://www.ixelles.be/"
    assert html =~ "2026-01-15"
    refute html =~ "connection"
    refute html =~ "influence"
    refute html =~ "conflict"
    refute html =~ "PRIVATE HOME ADDRESS"

    for {locale, mention_label, role_label} <- [
          {"fr", "cité dans", "administrateur de"},
          {"nl", "genoemd in", "bestuurder van"}
        ] do
      localized =
        build_conn()
        |> get(scenario.expected.path <> "?lang=#{locale}")
        |> html_response(200)

      assert localized =~ "Fact paths" or localized =~ "Chemins de faits" or
               localized =~ "Feitenpaden"

      assert localized =~ mention_label
      assert localized =~ role_label
    end

    assert sourced_fact_ids() == before
  end

  test "an unresolved mention or unverified manager hides the whole path", %{
    conn: conn,
    scenario: scenario,
    item: item
  } do
    %{company: company} = publish_gazette_manager!(verify?: false)

    Identity.record_mention!(%{
      occurrence_key: "ixelles-267:unresolved-org",
      source_version_id: item.current_source_version_id,
      agenda_item_id: item.id,
      text: "Public Example ASBL",
      kind: :organization,
      explicit_identifier: Gazette.enterprise_number()
    })

    html =
      conn
      |> get(scenario.expected.path <> "?lang=en")
      |> html_response(200)

    refute html =~ "Fact paths"
    refute html =~ "director of"
    refute html =~ "named in"

    attach_resolved_mention!(item, company)

    still_unverified =
      build_conn()
      |> get(scenario.expected.path <> "?lang=en")
      |> html_response(200)

    refute still_unverified =~ "Fact paths"
    refute still_unverified =~ "director of"
  end

  defp publish_gazette_manager!(opts \\ []) do
    BrusselsWtf.Clock.Controlled.set(~U[2026-04-01 12:00:00Z])
    publisher = Gazette.publisher!()
    company = Gazette.company!()
    person = Gazette.person!()
    appointment = Gazette.source!(publisher, :appointment)

    text =
      File.read!(
        Path.expand(
          "../support/fixtures/gazette/management-appointment/appointment.extract.txt",
          __DIR__
        )
      )

    Gazette.extract!(appointment.source_version, text)
    fact = Gazette.record_appointment!(person, company, appointment.source_version)

    if Keyword.get(opts, :verify?, true) do
      assert :ok =
               perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: fact.id})

      assert Identity.get_sourced_fact!(fact.id).verification_status == :verified
    end

    %{company: company, person: person, fact: fact}
  end

  defp attach_resolved_mention!(item, company) do
    mention =
      Identity.record_mention!(%{
        occurrence_key: "ixelles-267:public-example-asbl",
        source_version_id: item.current_source_version_id,
        agenda_item_id: item.id,
        text: "Public Example ASBL",
        kind: :organization,
        explicit_identifier: Gazette.enterprise_number()
      })

    Identity.resolve_mention_to_legal_entity!(mention, %{
      resolved_legal_entity_id: company.id
    })
  end

  defp sourced_fact_ids do
    BrusselsWtf.Identity.SourcedFact
    |> Ash.Query.sort(:id)
    |> Ash.read!(authorize?: false, domain: Identity)
    |> Enum.map(& &1.id)
  end
end
