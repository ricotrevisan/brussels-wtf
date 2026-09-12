defmodule BrusselsWtf.Follow.GazetteManagementUpdatesTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Follow.PublicUpdates
  alias BrusselsWtf.Identity
  alias BrusselsWtf.Test.GazetteManagementFixture, as: Gazette

  setup do
    previous_time = BrusselsWtf.Clock.utc_now()
    previous_provider = Application.get_env(:brussels_wtf, :public_follow_update_provider)

    on_exit(fn ->
      BrusselsWtf.Clock.Controlled.set(previous_time)
      Application.put_env(:brussels_wtf, :public_follow_update_provider, previous_provider)
    end)

    Application.put_env(
      :brussels_wtf,
      :public_follow_update_provider,
      BrusselsWtf.Follow.PublicUpdates.Published
    )

    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-03-01 12:00:00Z])

    imported_at = ~U[2026-03-01 12:00:00Z]
    publisher = Gazette.publisher!()
    company = Gazette.company!()
    person = Gazette.person!()
    appointment = Gazette.source!(publisher, :appointment)

    {:ok,
     imported_at: imported_at,
     publisher: publisher,
     company: company,
     person: person,
     appointment: appointment}
  end

  test "publishing a gazette management fact emits one person and one company update", %{
    imported_at: imported_at,
    company: company,
    person: person,
    appointment: appointment
  } do
    refute_updates(person, company, imported_at)

    fact = publish_appointment!(person, company, appointment)

    person_updates = person_updates(person, imported_at)
    company_updates = company_updates(company, imported_at)

    assert [person_update] = person_updates
    assert [company_update] = company_updates

    assert person_update.eventType == :verified_management_role
    assert company_update.eventType == :verified_management_role
    assert person_update.factId == fact.id
    assert company_update.factId == fact.id
    assert person_update.publicEventId == fact.id

    assert company_update.url ==
             "/companies/#{Gazette.enterprise_number()}?lang=en#fact-#{fact.id}"

    assert person_update.url == "/people/#{person.id}?lang=en#fact-#{fact.id}"
    assert person_update.title =~ person.legal_name
    assert company_update.title =~ "Public Example ASBL"

    rendered = inspect(person_updates ++ company_updates)
    refute rendered =~ "PRIVATE HOME ADDRESS"
    refute rendered =~ "PRIVATE FAMILY"
    refute rendered =~ "PRIVATE-CBE-RELEASE-KEY"
    refute rendered =~ "email"

    assert person_updates(person, imported_at) == person_updates
    assert company_updates(company, imported_at) == company_updates
  end

  test "a superseding cessation emits a distinct dated update and unverified facts emit none", %{
    imported_at: imported_at,
    publisher: publisher,
    company: company,
    person: person,
    appointment: appointment
  } do
    appointed = publish_appointment!(person, company, appointment)
    [first] = company_updates(company, imported_at)
    assert first.factId == appointed.id

    cessation = Gazette.source!(publisher, :cessation)

    cessation_text =
      File.read!(
        Path.expand(
          "../../support/fixtures/gazette/management-appointment/cessation.extract.txt",
          __DIR__
        )
      )

    Gazette.extract!(cessation.source_version, cessation_text)
    ended = Gazette.record_cessation!(person, company, cessation.source_version, appointed.id)
    assert :ok = perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: ended.id})

    fact_ids = company_updates(company, imported_at) |> Enum.map(& &1.factId) |> Enum.sort()
    assert appointed.id in fact_ids
    assert ended.id in fact_ids
    assert fact_ids != [appointed.id]

    other = Gazette.person!(%{legal_name: "Unverified Public"})
    unverified = Gazette.record_appointment!(other, company, appointment.source_version)

    refute Identity.get_sourced_fact!(unverified.id).verification_status == :verified
    refute Enum.any?(company_updates(company, imported_at), &(&1.factId == unverified.id))
  end

  defp publish_appointment!(person, company, appointment) do
    text =
      File.read!(
        Path.expand(
          "../../support/fixtures/gazette/management-appointment/appointment.extract.txt",
          __DIR__
        )
      )

    Gazette.extract!(appointment.source_version, text)
    fact = Gazette.record_appointment!(person, company, appointment.source_version)
    assert :ok = perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: fact.id})
    verified = Identity.get_sourced_fact!(fact.id)
    assert verified.verification_status == :verified
    verified
  end

  defp person_updates(person, imported_at) do
    PublicUpdates.list(
      [
        %{
          "type" => "person",
          "id" => person.id,
          "importedAt" => DateTime.to_iso8601(imported_at)
        }
      ],
      "en"
    )
  end

  defp company_updates(company, imported_at) do
    PublicUpdates.list(
      [
        %{
          "type" => "legal_entity",
          "id" => company.enterprise_number,
          "importedAt" => DateTime.to_iso8601(imported_at)
        }
      ],
      "en"
    )
  end

  defp refute_updates(person, company, imported_at) do
    assert person_updates(person, imported_at) == []
    assert company_updates(company, imported_at) == []
  end
end
