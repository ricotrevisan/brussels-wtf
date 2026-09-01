defmodule BrusselsWtfWeb.RegisteredFeedBrowserTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.{Council, Follow, Identity}
  alias BrusselsWtf.Council.PublicationLifecycle
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Test.PublicProfileFixture

  @moduletag :browser
  @port 4104

  test "registered citizen follows public pages and keeps authoritative feed read state across browsers" do
    Application.put_env(
      :brussels_wtf,
      :public_follow_update_provider,
      Follow.PublicUpdates.Published
    )

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

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

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

    %{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        "UPDATE citizen_follows SET inserted_at = $1 WHERE id = $2::uuid",
        [
          DateTime.add(person_fact.verified_at, -1, :microsecond),
          Ecto.UUID.dump!(person_follow.id)
        ]
      )

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
               :publication_revision_new_decisions
             ])

    expected = %{
      dossier: "/meetings/ixelles/268?lang=fr##{item.stable_anchor}",
      person: "/people/#{person.id}?lang=fr#fact-#{person_fact.id}",
      commune: "/meetings/ixelles/268?lang=fr#revision-#{revision.id}"
    }

    run_browser!("verify", mail, expected)

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
