defmodule BrusselsWtfWeb.RegisteredFeedBrowserTest do
  use BrusselsWtf.DataCase, async: false
  @moduletag :browser
  @port 4104
  test "managed Chromium joins all four registered targets, exact links, exclusions and cross-session read state" do
    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    BrusselsWtf.Accounts.request_link("joined@example.test")
    assert_receive {:magic_link, _, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, _} = BrusselsWtf.Accounts.consume(token)
    actor = %{id: citizen.id, principal: :citizen}

    matrix = [
      {:dossier, "clean-air", :decision, "rev-dossier",
       "/dossiers/clean-air?revision=rev-dossier"},
      {:person, "person-1", :verified_public_mandate, "fact-person",
       "/people/00000000-0000-0000-0000-000000000001?fact=fact-person"},
      {:legal_entity, "0123456789", :verified_management_role, "fact-company",
       "/companies/0123456789?fact=fact-company"},
      {:commune, "ixelles", :revision_with_new_decisions, "rev-commune",
       "/meetings/ixelles/2026-09?revision=rev-commune"}
    ]

    Enum.each(matrix, fn {type, id, kind, identity, url} ->
      {:ok, _} =
        BrusselsWtf.Follow.CitizenFollow
        |> Ash.Changeset.for_create(:import, %{
          citizen_id: citizen.id,
          target_type: type,
          target_identifier: id
        })
        |> Ash.create(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)

      {:ok, [_]} =
        BrusselsWtf.Follow.publish_update(%{
          target_type: type,
          target_identifier: id,
          kind: kind,
          identity: identity,
          public_url: url,
          occurred_at: ~U[2026-09-02 12:00:00Z],
          public?: true
        })
    end)

    assert {:ok, []} =
             BrusselsWtf.Follow.publish_update(%{
               target_type: :dossier,
               target_identifier: "clean-air",
               kind: :typography_only,
               identity: "excluded",
               public_url: "/excluded",
               occurred_at: ~U[2026-09-02 12:00:00Z],
               public?: true
             })

    {:ok, _private_collection, private_secret} = BrusselsWtf.Follow.create_collection()
    {:ok, private_collection} = BrusselsWtf.Follow.claim_collection(private_secret, citizen)
    {:ok, _} = BrusselsWtf.Follow.owner_set_visibility(citizen, private_collection.id, :private)
    {:ok, _public_collection, public_secret} = BrusselsWtf.Follow.create_collection()
    {:ok, public_collection} = BrusselsWtf.Follow.claim_collection(public_secret, citizen)
    {:ok, _} = BrusselsWtf.Follow.owner_set_visibility(citizen, public_collection.id, :public)

    {:ok, _} =
      BrusselsWtf.Follow.grant_private_view(citizen, private_collection.id, Ash.UUID.generate())

    Process.unregister(BrusselsWtf.Accounts.Mailbox)

    mail =
      Path.join(System.tmp_dir!(), "registered-feed-#{System.unique_integer([:positive])}.json")

    previous = Application.get_env(:brussels_wtf, :citizen_mailer)
    Application.put_env(:brussels_wtf, :citizen_mailer, BrusselsWtf.Accounts.Mail.File)
    Application.put_env(:brussels_wtf, :citizen_mail_file, mail)
    :ok = BrusselsWtf.Accounts.request_link("joined@example.test")

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :citizen_mailer, previous)
      Application.delete_env(:brussels_wtf, :citizen_mail_file)
      File.rm(mail)
      if Process.alive?(server), do: Process.exit(server, :normal)
    end)

    args = [
      "run",
      "--project",
      "test/browser",
      "--frozen",
      "python",
      "test/browser/registered_feed.py",
      "--base",
      "http://127.0.0.1:#{@port}",
      "--mail",
      mail
    ]

    opts =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          exe -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", exe}]]
        end

    {output, status} = System.cmd("uv", args, opts)
    assert status == 0, output

    assert {:error, _} =
             Ash.get(BrusselsWtf.Accounts.Citizen, citizen.id,
               authorize?: false,
               domain: BrusselsWtf.Accounts
             )

    assert [_audit] =
             Ash.read!(BrusselsWtf.Follow.DeletionAudit,
               actor: %{principal: :system},
               authorize?: true,
               domain: BrusselsWtf.Follow
             )

    assert [] ==
             Ash.read!(BrusselsWtf.Follow.CollectionGrant,
               actor: %{principal: :system},
               authorize?: true,
               domain: BrusselsWtf.Follow
             )
  end
end
