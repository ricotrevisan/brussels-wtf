defmodule BrusselsWtfWeb.RegisteredFeedBrowserTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.{Council, Follow, Identity}
  alias BrusselsWtf.Council.PublicationLifecycle
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Test.PublicProfileFixture
  alias BrusselsWtf.Test.GazetteManagementFixture, as: Gazette

  @moduletag :browser
  @port 4104

  test "registered citizen follows public pages and keeps authoritative feed read state across browsers" do
    Application.put_env(
      :brussels_wtf,
      :public_follow_update_provider,
      Follow.PublicUpdates.Published
    )

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    fixture = PublicProfileFixture.load!(["Registered Browser Person"])

    %{person: person, fact: person_fact} =
      PublicProfileFixture.publish_person!(fixture, "Registered Browser Person", 1)

    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    company =
      PublicProfileFixture.company!(%{
        enterprise_number: "0123456749",
        release_key: "registered-browser-cbe",
        sha256: String.duplicate("d", 64)
      })

    meeting =
      Council.get_ingested_meeting!("ixelles", "268") |> Ash.load!([:agenda_items, :meeting_page])

    [item] = meeting.agenda_items
    page = meeting.meeting_page

    dossier =
      Council.create_dossier!(%{
        slug: "registered-browser-dossier",
        title: "Registered browser dossier",
        localized_titles: %{}
      })

    Council.upsert_dossier_link!(%{
      agenda_item_id: item.id,
      dossier_id: dossier.id,
      match_method: :editorial,
      status: :active,
      disposition: :confirmed
    })

    BrusselsWtf.Clock.Controlled.set(DateTime.utc_now())

    mail =
      Path.join(
        System.tmp_dir!(),
        "registered-feed-mail-#{System.unique_integer([:positive])}.json"
      )

    previous_mailer = Application.get_env(:brussels_wtf, :citizen_mailer)
    Application.put_env(:brussels_wtf, :citizen_mailer, BrusselsWtf.Accounts.Mail.File)
    Application.put_env(:brussels_wtf, :citizen_mail_file, mail)

    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :citizen_mailer, previous_mailer)
      Application.delete_env(:brussels_wtf, :citizen_mail_file)
      File.rm(mail)
      if Process.alive?(server), do: Process.exit(server, :normal)
    end)

    targets = %{
      dossier: dossier.slug,
      person: person.id,
      company: company.enterprise_number,
      commune: fixture.commune.slug
    }

    run_browser!("follow", mail, targets)
    baseline = DateTime.utc_now()

    follows = Ash.read!(Follow.CitizenFollow, authorize?: false, domain: Follow)

    assert Enum.sort(Enum.map(follows, &{&1.target_type, &1.target_identifier})) ==
             Enum.sort([
               {:dossier, dossier.slug},
               {:person, person.id},
               {:legal_entity, company.enterprise_number},
               {:commune, fixture.commune.slug}
             ])

    # All accepted notifications are strictly later than the durable follow rows.
    BrusselsWtf.Clock.Controlled.set(DateTime.add(baseline, 1, :second))
    actor = %Actor{id: "registered-browser-reviewer", role: :reviewer}
    original = Council.list_publication_revisions!(page.id) |> List.last()

    typography =
      bundle(original.content, "nl") |> put_in(["page", "title"], "Typografie zonder melding")

    PublicationLifecycle.typography_correction!(page.id, "nl", typography, actor)

    BrusselsWtf.Clock.Controlled.set(DateTime.add(baseline, 2, :second))
    current = Council.list_publication_revisions!(page.id) |> List.last()

    corrected =
      Map.new(~w(fr nl en), fn locale ->
        value = bundle(current.content, locale)

        item_key =
          Enum.find_value(current.content["items"], fn {key, item} ->
            if Enum.all?(Map.values(item["variants"]), &(&1["decision_summary"] in [nil, ""])),
              do: key
          end)

        {locale,
         put_in(value, ["items", item_key, "variant", "decision_summary"], "Décision publiée")}
      end)

    notes = %{
      "fr" => "Correction factuelle.",
      "nl" => "Feitelijke correctie.",
      "en" => "Factual correction."
    }

    revision = PublicationLifecycle.factual_correction!(page.id, corrected, notes, actor)

    Council.record_publication_event!(%{
      meeting_page_id: page.id,
      publication_revision_id: revision.id,
      event_type: :republished,
      occurred_at: DateTime.add(baseline, 2, :second),
      actor_id: actor.id,
      publication_metadata: revision.publication_metadata,
      details: %{}
    })

    BrusselsWtf.Clock.Controlled.set(DateTime.add(baseline, 3, :second))

    person_follow = Enum.find(follows, &(&1.target_type == :person))
    verified_at = DateTime.add(person_follow.inserted_at, 1, :second)
    BrusselsWtf.Clock.Controlled.set(verified_at)

    later_fact =
      Identity.record_sourced_fact!(%{
        subject_type: :person,
        subject_id: person.id,
        object_type: :commune,
        object_id: fixture.commune.id,
        object_label: "Second public mandate publication",
        kind: :public_mandate,
        effective_from: ~D[2025-01-01],
        effective_to: ~D[2025-12-31],
        source_version_id: fixture.source_version.id,
        authoritative_url: "https://www.ixelles.be/uploads/conseil/pv/267.pdf",
        source_authority: :municipal_decision,
        evidence_kind: :official_decision,
        evidence_excerpt:
          "2025-01-01 Registered Browser Person [municipal-mandate-registered-browser-person] is appointed to the Ixelles municipal council.",
        evidence_location: "decision 267",
        supersedes_id: person_fact.id
      })

    assert :ok =
             BrusselsWtf.Workers.VerifyIxellesPublicMandate.perform(%Oban.Job{
               args: %{"fact_id" => later_fact.id}
             })

    later_fact = Identity.get_sourced_fact!(later_fact.id)

    assert later_fact.verification_status == :verified
    assert DateTime.after?(later_fact.verified_at, person_follow.inserted_at)

    # Use the exact isolated Gazette contract from the public update slice, after follow.
    company_follow = Enum.find(follows, &(&1.target_type == :legal_entity))
    BrusselsWtf.Clock.Controlled.set(DateTime.add(company_follow.inserted_at, 4, :second))
    publisher = Gazette.publisher!()
    manager = Gazette.person!()
    appointment = Gazette.source!(publisher, :appointment)

    Gazette.extract!(
      appointment.source_version,
      File.read!("test/support/fixtures/gazette/management-appointment/appointment.extract.txt")
    )

    management_fact = Gazette.record_appointment!(manager, company, appointment.source_version)

    assert :ok =
             BrusselsWtf.Workers.VerifyGazetteManagement.perform(%Oban.Job{
               args: %{"fact_id" => management_fact.id}
             })

    management_fact = Identity.get_sourced_fact!(management_fact.id)
    assert management_fact.verification_status == :verified
    assert DateTime.after?(management_fact.verified_at, company_follow.inserted_at)

    # Persist an unverified candidate. It must never reach the public projection or feed.
    Identity.record_sourced_fact!(%{
      subject_type: :person,
      subject_id: person.id,
      object_type: :commune,
      object_id: fixture.commune.id,
      object_label: "PRIVATE REVIEW CANDIDATE",
      kind: :public_mandate,
      effective_from: ~D[2026-09-04],
      source_version_id: fixture.source_version.id,
      authoritative_url: "https://www.ixelles.be/private-review",
      source_authority: :municipal_decision,
      evidence_kind: :official_decision,
      evidence_excerpt: "UNVERIFIED PRIVATE REVIEW CHANGE",
      evidence_location: "private review queue"
    })

    assert :ok = BrusselsWtf.Workers.SynchronizeRegisteredFeeds.perform(%Oban.Job{args: %{}})

    updates = Ash.read!(Follow.FeedUpdate, authorize?: false, domain: Follow)

    assert Enum.sort(Enum.map(updates, & &1.event_kind)) ==
             Enum.sort([
               :correction,
               :verified_public_mandate,
               :verified_management_role,
               :publication_revision_new_decisions
             ])

    expected = %{
      dossier: "/meetings/ixelles/268?lang=fr##{item.stable_anchor}",
      person: "/people/#{person.id}?lang=fr#fact-#{later_fact.id}",
      commune: "/meetings/ixelles/268?lang=fr#revision-#{revision.id}",
      company: "/companies/#{company.enterprise_number}?lang=fr#fact-#{management_fact.id}"
    }

    [company_update] = Enum.filter(updates, &(&1.target_type == :legal_entity))
    assert company_update.event_identity == management_fact.id
    assert company_update.public_url == String.replace(expected.company, "lang=fr", "lang=en")
    assert {:ok, 0} = Follow.synchronize_registered_feeds()

    run_browser!("verify", mail, expected)
    run_browser!("unfollow", mail, targets)
    assert [] = Ash.read!(Follow.CitizenFollow, authorize?: false, domain: Follow)
    assert {:ok, 0} = Follow.synchronize_registered_feeds()
    assert length(Ash.read!(Follow.FeedUpdate, authorize?: false, domain: Follow)) == 4

    assert Enum.all?(
             Ash.read!(Follow.FeedUpdate, authorize?: false, domain: Follow),
             & &1.read_at
           )
  end

  defp bundle(content, locale) do
    %{
      "page" => content["page"][locale],
      "items" =>
        Map.new(content["items"], fn {key, item} ->
          {key, %{"claim_refs" => item["claim_refs"], "variant" => item["variants"][locale]}}
        end)
    }
  end

  defp run_browser!(phase, mail, payload) do
    payload_file = mail <> ".#{phase}"
    File.write!(payload_file, Jason.encode!(payload))
    on_exit(fn -> File.rm(payload_file) end)

    args = [
      "run",
      "--project",
      "test/browser",
      "--frozen",
      "python",
      "test/browser/registered_feed.py",
      phase,
      "--base",
      "http://127.0.0.1:#{@port}",
      "--mail",
      mail,
      "--payload",
      payload_file
    ]

    options =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          executable -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", executable}]]
        end

    {output, status} = System.cmd("uv", args, options)
    assert status == 0, output
  end
end
