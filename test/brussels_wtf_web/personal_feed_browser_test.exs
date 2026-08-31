defmodule BrusselsWtfWeb.PersonalFeedBrowserTest do
  use BrusselsWtf.DataCase, async: false
  alias BrusselsWtf.{Council, Follow}

  @moduletag :browser
  @port 4102

  test "real Chromium imports an immutable subset and reads a later exact localized update" do
    Application.put_env(
      :brussels_wtf,
      :public_follow_update_provider,
      Follow.PublicUpdates.Published
    )

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    BrusselsWtf.Clock.Controlled.set(DateTime.utc_now())

    dossier =
      Council.create_dossier!(%{
        slug: "browser-dossier",
        title: "Browser dossier",
        localized_titles: %{}
      })

    {:ok, collection, _secret} = Follow.create_collection()
    {:ok, collection} = Follow.add_member_session(collection.id, :commune, "ixelles")
    {:ok, collection} = Follow.add_member_session(collection.id, :dossier, dossier.slug)
    {:ok, collection} = Follow.set_visibility_session(collection.id, :public)

    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    profile =
      Path.join(System.tmp_dir!(), "brussels-wtf-browser-#{System.unique_integer([:positive])}")

    File.mkdir_p!(profile)

    on_exit(fn ->
      File.rm_rf!(profile)
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    run_browser!("import", profile, "/collections/#{collection.view_token}")

    # Mutating the source collection after import must not mutate browser-local follows.
    {:ok, _} = Follow.remove_member_session(collection.id, :commune, "ixelles")

    page =
      Council.MeetingPage
      |> Ash.Query.for_read(:published)
      |> Ash.read!(authorize?: false, domain: Council)
      |> hd()

    imported = DateTime.utc_now()

    _event =
      Council.PublicationEvent
      |> Ash.Changeset.for_create(:record, %{
        meeting_page_id: page.id,
        publication_revision_id: page.current_revision_id,
        event_type: :published,
        occurred_at: DateTime.add(imported, 1, :second),
        publication_metadata: %{},
        details: %{}
      })
      |> Ash.create!(authorize?: false, domain: Council)

    BrusselsWtf.Clock.Controlled.set(DateTime.add(imported, 2, :second))

    run_browser!("verify", profile, nil)
  end

  defp run_browser!(phase, profile, collection) do
    args =
      [
        "run",
        "--with-requirements",
        "test/browser/requirements.txt",
        "python",
        "test/browser/personal_feed.py",
        phase,
        "--base",
        "http://127.0.0.1:#{@port}",
        "--profile",
        profile
      ] ++ if(collection, do: ["--collection", collection], else: [])

    {output, status} =
      System.cmd("uv", args,
        stderr_to_stdout: true,
        env: [
          {"PLAYWRIGHT_CHROMIUM_EXECUTABLE",
           System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE", "/usr/bin/chromium")}
        ]
      )

    assert status == 0, output
  end
end
