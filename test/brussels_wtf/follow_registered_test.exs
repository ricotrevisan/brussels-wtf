defmodule BrusselsWtf.FollowRegisteredTest do
  use BrusselsWtf.DataCase, async: false
  import ExUnit.CaptureLog
  alias BrusselsWtf.{Accounts, Follow}
  require Ash.Query
  alias BrusselsWtf.Follow.{CitizenFollow, FeedUpdate}

  setup do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-02 12:00:00.000000Z])

    on_exit(fn ->
      if Process.whereis(BrusselsWtf.Accounts.Mailbox) == self(),
        do: Process.unregister(BrusselsWtf.Accounts.Mailbox)
    end)

    :ok
  end

  test "the exact trigger matrix is idempotent and citizen-private" do
    {alice, _} = citizen("alice-feed@example.test")
    {bob, _} = citizen("bob-feed@example.test")
    actor = %{id: alice.id, principal: :citizen}

    matrix = %{
      dossier: [:linked_agenda_item, :decision, :correction, :merge, :split],
      person: [:verified_public_mandate, :verified_management_role, :relevant_council_item],
      legal_entity: [:verified_management_role, :contract_award, :relevant_council_item],
      commune: [:published_meeting_page, :revision_with_new_decisions]
    }

    Enum.each(matrix, fn {type, kinds} ->
      {:ok, _} =
        CitizenFollow
        |> Ash.Changeset.for_create(:import, %{
          citizen_id: alice.id,
          target_type: type,
          target_identifier: "target"
        })
        |> Ash.create(actor: actor, authorize?: true, domain: Follow)

      Enum.each(kinds, fn kind ->
        event = %{
          target_type: type,
          target_identifier: "target",
          kind: kind,
          identity: "#{type}:#{kind}",
          public_url: "/exact/#{type}/#{kind}",
          occurred_at: ~U[2026-09-02 12:00:00Z],
          public?: true
        }

        assert {:ok, [_]} = Follow.publish_update(event)
        assert {:ok, [_]} = Follow.publish_update(event)
      end)
    end)

    assert {:ok, updates} = Follow.registered_feed(alice)
    assert length(updates) == 13
    assert Enum.all?(updates, &String.starts_with?(&1.public_url, "/exact/"))

    assert {:ok, []} =
             Follow.publish_update(%{
               target_type: :dossier,
               target_identifier: "target",
               kind: :typography_only,
               identity: "excluded",
               public_url: "/no",
               occurred_at: ~U[2026-09-02 12:00:00Z],
               public?: true
             })

    assert {:ok, []} =
             Ash.read(FeedUpdate,
               actor: %{id: bob.id, principal: :citizen},
               authorize?: true,
               domain: Follow
             )

    [first | _] = updates
    assert {:ok, marked} = Follow.mark_read(alice, first.id)
    assert marked.read_at
    assert {:error, _} = Follow.mark_read(bob, first.id)
  end

  test "cleanup uses the twelve month maximum and warning does not change sign-in" do
    {citizen, _} = citizen("retention@example.test")

    {:ok, current} =
      Ash.get(Accounts.Citizen, citizen.id,
        actor: %{id: citizen.id, principal: :citizen},
        authorize?: true,
        domain: Accounts
      )

    signed_in = current.last_sign_in_at || current.inserted_at
    now = DateTime.add(signed_in, 153, :day)
    Accounts.run_inactivity_retention(now)

    {:ok, reloaded} =
      Ash.get(Accounts.Citizen, citizen.id,
        actor: %{id: citizen.id, principal: :citizen},
        authorize?: true,
        domain: Accounts
      )

    assert reloaded.last_sign_in_at == signed_in

    warnings =
      Follow.RetentionWarning
      |> Ash.Query.filter(citizen_id == ^citizen.id)
      |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)

    assert Enum.map(warnings, & &1.days_before_deletion) == [30]
  end

  test "private grants are view-only and direct Ash actions cannot cross citizen boundaries" do
    {owner, _} = citizen("owner-grants@example.test")
    {guest, _} = citizen("guest-grants@example.test")
    {stranger, _} = citizen("stranger-grants@example.test")
    {:ok, _collection, secret} = Follow.create_collection()
    {:ok, claimed} = Follow.claim_collection(secret, owner)
    assert {:ok, private} = Follow.owner_set_visibility(owner, claimed.id, :private)
    assert {:ok, grant} = Follow.grant_private_view(owner, private.id, guest.id)
    assert {:ok, viewed} = Follow.private_collection(private.id, guest)
    assert viewed.id == private.id
    assert {:error, :not_found} = Follow.private_collection(private.id, stranger)
    assert {:error, :not_found} = Follow.owner_set_visibility(guest, private.id, :public)

    assert {:error, _} =
             Ash.destroy(grant,
               actor: %{id: guest.id, principal: :citizen},
               authorize?: true,
               domain: Follow
             )

    assert :ok = Follow.revoke_private_view(owner, private.id, grant.id)
    assert {:error, :not_found} = Follow.private_collection(private.id, guest)
  end

  test "deletion rolls back personal state and audit at every authentication failure stage" do
    Enum.each([:sessions, :outstanding_links, :authentication_tokens], fn stage ->
      {citizen, session} = citizen("rollback-#{stage}@example.test")
      actor = %{id: citizen.id, principal: :citizen}

      {:ok, _} =
        CitizenFollow
        |> Ash.Changeset.for_create(:import, %{
          citizen_id: citizen.id,
          target_type: :commune,
          target_identifier: "ixelles"
        })
        |> Ash.create(actor: actor, authorize?: true, domain: Follow)

      Application.put_env(:brussels_wtf, :account_security_failure, stage)
      assert {:error, _} = Accounts.delete_citizen(citizen)
      Application.delete_env(:brussels_wtf, :account_security_failure)
      assert {:ok, _} = Accounts.authenticate_session(session.id)

      assert {:ok, [_]} =
               CitizenFollow
               |> Ash.Query.for_read(:mine, %{}, actor: actor)
               |> Ash.read(actor: actor, authorize?: true, domain: Follow)

      assert [] ==
               Follow.DeletionAudit
               |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)
    end)
  after
    Application.delete_env(:brussels_wtf, :account_security_failure)
  end

  test "security logs contain no citizen email, token, feed/grant identifiers or private notes" do
    logs =
      capture_log([level: :debug], fn ->
        {owner, _} = citizen("private-log@example.test")
        {guest, _} = citizen("guest-log@example.test")
        {:ok, _c, secret} = Follow.create_collection()
        {:ok, c} = Follow.claim_collection(secret, owner)
        {:ok, c} = Follow.owner_set_visibility(owner, c.id, :private)
        {:ok, g} = Follow.grant_private_view(owner, c.id, guest.id)

        Process.put(:log_secrets, [
          owner.id,
          guest.id,
          c.id,
          g.id,
          secret,
          "private-note-never-log"
        ])

        assert {:ok, _} = Follow.private_collection(c.id, guest)
      end)

    Enum.each(Process.delete(:log_secrets), fn secret -> refute logs =~ secret end)
    refute logs =~ "private-log@example.test"
    refute logs =~ "guest-log@example.test"
  end

  test "public collection never becomes maintainerless during deletion transfer" do
    {owner, _} = citizen("transfer-owner@example.test")
    {recipient, _} = citizen("transfer-recipient@example.test")
    {:ok, _c, secret} = Follow.create_collection()
    {:ok, c} = Follow.claim_collection(secret, owner)
    {:ok, c} = Follow.owner_set_visibility(owner, c.id, :public)
    assert {:error, :owned_collection_requires_resolution} = Accounts.delete_citizen(owner)
    assert {:ok, _} = Accounts.delete_citizen(owner, %{c.id => {:transfer, recipient.id, true}})

    assert {:ok, transferred} =
             Ash.get(Follow.Collection, c.id, authorize?: false, domain: Follow)

    assert transferred.owner_citizen_id == recipient.id
  end

  defp citizen(email) do
    Accounts.request_link(email)
    assert_receive {:magic_link, ^email, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, session} = Accounts.consume(token)
    {citizen, session}
  end
end
