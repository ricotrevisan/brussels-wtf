defmodule BrusselsWtfWeb.GazetteManagementFactTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Review
  alias BrusselsWtf.Test.GazetteManagementFixture, as: Fixture

  setup do
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-04-01 12:00:00Z])

    publisher = Fixture.publisher!()
    company = Fixture.company!()
    person = Fixture.person!()
    appointment = Fixture.source!(publisher, :appointment)

    {:ok, publisher: publisher, company: company, person: person, appointment: appointment}
  end

  test "a gazette appointment fixture publishes a verified management fact on company and person pages",
       %{conn: conn, company: company, person: person, appointment: appointment} do
    text =
      File.read!(
        Path.expand(
          "../support/fixtures/gazette/management-appointment/appointment.extract.txt",
          __DIR__
        )
      )

    Fixture.extract!(appointment.source_version, text)

    fact =
      Fixture.record_appointment!(person, company, appointment.source_version)

    assert_enqueued(
      worker: BrusselsWtf.Workers.VerifyGazetteManagement,
      args: %{fact_id: fact.id}
    )

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: fact.id})

    verified = Identity.get_sourced_fact!(fact.id)
    assert verified.verification_status == :verified
    assert verified.verified_by == "belgian_official_gazette_management_v1"
    refute verified.verified_by =~ "human"

    company_html =
      conn
      |> get("/companies/#{Fixture.enterprise_number()}?lang=en")
      |> html_response(200)

    assert company_html =~ "Verified facts"
    assert company_html =~ "Current facts"
    assert company_html =~ "director of"
    assert company_html =~ person.legal_name
    assert company_html =~ "Public Example ASBL"
    assert company_html =~ "2026-01-15"
    assert company_html =~ Fixture.appointment_url()
    refute company_html =~ "owner"
    refute company_html =~ "Ownership"
    refute company_html =~ "influence"
    refute company_html =~ "conflict"
    refute company_html =~ "PRIVATE HOME ADDRESS"
    refute company_html =~ "PRIVATE FAMILY"

    person_html =
      build_conn()
      |> get("/people/#{person.id}?lang=en")
      |> html_response(200)

    assert person_html =~ "Verified facts"
    assert person_html =~ "director of"
    assert person_html =~ "Public Example ASBL"
    assert person_html =~ Fixture.appointment_url()
    refute person_html =~ "PRIVATE HOME ADDRESS"

    for {locale, label} <- [{"fr", "administrateur de"}, {"nl", "bestuurder van"}] do
      html =
        build_conn()
        |> get("/companies/#{Fixture.enterprise_number()}?lang=#{locale}")
        |> html_response(200)

      assert html =~ label
      refute html =~ "propriétaire"
      refute html =~ "eigenaar"
    end
  end

  test "a later gazette cessation supersedes the current appointment and keeps dated history",
       %{
         conn: conn,
         publisher: publisher,
         company: company,
         person: person,
         appointment: appointment
       } do
    appointment_text =
      File.read!(
        Path.expand(
          "../support/fixtures/gazette/management-appointment/appointment.extract.txt",
          __DIR__
        )
      )

    Fixture.extract!(appointment.source_version, appointment_text)
    appointed = Fixture.record_appointment!(person, company, appointment.source_version)

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: appointed.id})

    cessation = Fixture.source!(publisher, :cessation)

    cessation_text =
      File.read!(
        Path.expand(
          "../support/fixtures/gazette/management-appointment/cessation.extract.txt",
          __DIR__
        )
      )

    Fixture.extract!(cessation.source_version, cessation_text)

    ended =
      Fixture.record_cessation!(
        person,
        company,
        cessation.source_version,
        appointed.id
      )

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: ended.id})

    assert Identity.get_sourced_fact!(appointed.id).verification_status == :superseded
    assert Identity.get_sourced_fact!(ended.id).verification_status == :verified

    html =
      conn
      |> get("/companies/#{Fixture.enterprise_number()}?lang=en")
      |> html_response(200)

    assert html =~ "Current facts"
    assert html =~ "Dated history"
    assert html =~ "2026-03-15"
    assert html =~ "2026-01-15"
    assert html =~ Fixture.cessation_url()
    assert html =~ Fixture.appointment_url()
  end

  test "name-only, mismatched CBE, and proposal wording publish no fact and open a review case",
       %{company: company, appointment: appointment} do
    text =
      File.read!(
        Path.expand(
          "../support/fixtures/gazette/management-appointment/appointment.extract.txt",
          __DIR__
        )
      )

    Fixture.extract!(appointment.source_version, text)

    name_only =
      Fixture.person!(%{legal_name: "Alex Public", corroborating_facts: %{"note" => "name only"}})

    name_fact =
      Fixture.record_appointment!(name_only, company, appointment.source_version)

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: name_fact.id})

    assert Identity.get_sourced_fact!(name_fact.id).verification_status == :unreviewed
    assert review_opened?(name_fact.id)

    mismatched =
      Fixture.person!(%{
        legal_name: "Other Public",
        corroborating_facts: %{"enterprise_number" => "0202239951"}
      })

    mismatch_fact =
      Fixture.record_appointment!(mismatched, company, appointment.source_version, %{
        evidence_excerpt:
          "2026-01-15 Other Public est nommé administrateur de Public Example ASBL (0123456749)."
      })

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{
               fact_id: mismatch_fact.id
             })

    assert Identity.get_sourced_fact!(mismatch_fact.id).verification_status == :unreviewed
    assert review_opened?(mismatch_fact.id)

    person = Fixture.person!(%{legal_name: "Proposed Public"})

    proposal_fact =
      Fixture.record_appointment!(person, company, appointment.source_version, %{
        evidence_excerpt:
          "2026-01-15 Proposed Public est proposé comme administrateur de Public Example ASBL (0123456749)."
      })

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{
               fact_id: proposal_fact.id
             })

    assert Identity.get_sourced_fact!(proposal_fact.id).verification_status == :unreviewed
    assert review_opened?(proposal_fact.id)
  end

  defp review_opened?(fact_id) do
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    Review.list_review_cases!(%{kind: :evidence, status: :open}, actor: actor)
    |> Enum.any?(&(&1.affected_record_id == fact_id))
  end
end
