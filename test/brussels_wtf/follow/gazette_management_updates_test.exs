defmodule BrusselsWtf.Follow.GazetteManagementUpdatesTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Follow.PublicUpdates
  alias BrusselsWtf.{Accounts, Follow, Identity}
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

  test "registered company delivery uses the public fact identity, excludes private work and revalidates",
       %{
         company: company,
         person: person,
         appointment: appointment
       } do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    {alice, _} = citizen("gazette-alice@example.test")
    {bob, _} = citizen("gazette-bob@example.test")
    assert {:ok, follow} = Follow.follow(alice, :legal_entity, company.enterprise_number)
    BrusselsWtf.Clock.Controlled.set(DateTime.add(follow.inserted_at, 1, :second))

    # Retrieval and extraction alone have no public fact to deliver.
    Gazette.extract!(
      appointment.source_version,
      File.read!("test/support/fixtures/gazette/management-appointment/appointment.extract.txt")
    )

    assert {:ok, []} = Follow.registered_feed(alice)

    candidate = Gazette.record_appointment!(person, company, appointment.source_version)
    assert {:ok, []} = Follow.registered_feed(alice)

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: candidate.id})

    fact = Identity.get_sourced_fact!(candidate.id)
    assert fact.verification_status == :verified

    [public] = company_updates(company, follow.inserted_at)
    assert {:ok, 1} = Follow.synchronize_registered_feeds()
    assert {:ok, [delivered]} = Follow.registered_feed(alice)
    assert delivered.event_identity == public.publicEventId
    assert public.publicEventId == fact.id
    assert delivered.public_url == public.url
    assert delivered.event_kind == public.eventType
    assert delivered.occurred_at == fact.verified_at
    assert {:ok, []} = Follow.registered_feed(bob)
    assert {:error, _} = Follow.mark_read(bob, delivered.id)
    assert {:ok, read} = Follow.mark_read(alice, delivered.id)

    # Re-recording/extracting/verifying identical evidence cannot reset read state.
    assert publish_appointment!(person, company, appointment).id == fact.id
    assert {:ok, 0} = Follow.synchronize_registered_feeds()
    assert {:ok, [same]} = Follow.registered_feed(alice)
    assert same.id == delivered.id
    assert same.read_at == read.read_at

    private = Gazette.person!(%{legal_name: "PRIVATE REVIEW CANDIDATE"})
    rejected = Gazette.record_appointment!(private, company, appointment.source_version)
    assert :ok = perform_job(BrusselsWtf.Workers.VerifyGazetteManagement, %{fact_id: rejected.id})
    assert Identity.get_sourced_fact!(rejected.id).verification_status == :unreviewed
    assert {:ok, 0} = Follow.synchronize_registered_feeds()
    assert {:ok, [^same]} = Follow.registered_feed(alice)
    rendered = inspect(Map.take(same, [:event_identity, :event_kind, :public_url, :occurred_at]))

    for excluded <- ["PRIVATE", "email", "object_key", "review", "@", "0123456749-appointment"] do
      refute rendered =~ excluded
    end

    # A retired subject fails the public gate; previously delivered rows disappear too.
    person |> Ash.Changeset.for_update(:retire, %{}) |> Ash.update!()
    assert company_updates(company, follow.inserted_at) == []
    assert {:ok, []} = Follow.registered_feed(alice)
    assert Ash.read!(Follow.FeedUpdate, authorize?: false, domain: Follow) == []
    assert {:error, _} = Follow.mark_read(alice, delivered.id)
  end

  defp citizen(email) do
    Accounts.request_link(email)
    assert_receive {:magic_link, ^email, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, session} = Accounts.consume(token)
    {citizen, session}
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
