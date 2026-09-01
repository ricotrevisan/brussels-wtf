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

  test "caller assertions cannot publish and delivery identity is immutable and citizen-private" do
    {alice, _} = citizen("alice-feed@example.test")
    {bob, _} = citizen("bob-feed@example.test")

    refute function_exported?(Follow, :publish_update, 1)
    assert {:ok, _follow} = Follow.follow(alice, :commune, "ixelles")

    attrs = %{
      citizen_id: alice.id,
      target_type: :commune,
      target_identifier: "ixelles",
      event_identity: Ash.UUID.generate(),
      event_kind: :published_meeting_page,
      public_url: "/meetings/ixelles/42?lang=en#revision-one",
      occurred_at: ~U[2026-09-02 12:00:00Z]
    }

    assert {:error, _} =
             FeedUpdate
             |> Ash.Changeset.for_create(:deliver_once, attrs)
             |> Ash.create(
               actor: %{id: alice.id, principal: :citizen},
               authorize?: true,
               domain: Follow
             )

    assert {:ok, original} =
             FeedUpdate
             |> Ash.Changeset.for_create(:deliver_once, attrs)
             |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: Follow)

    assert {:error, _} =
             FeedUpdate
             |> Ash.Changeset.for_create(:deliver_once, %{attrs | public_url: "/spoofed"})
             |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: Follow)

    assert {:ok, [visible]} = Follow.registered_feed(alice)
    assert visible.id == original.id
    assert {:ok, []} = Follow.registered_feed(bob)
    assert {:error, _} = Follow.mark_read(bob, original.id)
    assert {:ok, marked} = Follow.mark_read(alice, original.id)
    assert marked.read_at
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

  test "deletion rolls back all state at every lifecycle phase and retry is idempotent" do
    stages = [
      :owned_collections,
      :private_collections,
      :selected_collections,
      :transfer_offers,
      :grants_created,
      :grants_received,
      :feed_updates,
      :feed_read_state,
      :follows,
      :warnings,
      :sessions,
      :outstanding_links,
      :authentication_tokens,
      :citizen,
      :audit,
      :notification_collection
    ]

    Enum.each(stages, fn stage ->
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

      resolutions = deletion_collection_fixture(stage, citizen)
      Application.put_env(:brussels_wtf, :account_security_failure, stage)
      assert {:error, _} = Accounts.delete_citizen(citizen, resolutions)
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

    {citizen, _session} = citizen("idempotent-delete@example.test")
    operation_id = Ash.UUID.generate()
    resolutions = %{operation_id: operation_id}
    assert {:ok, ^operation_id} = Accounts.delete_citizen(citizen, resolutions)
    assert {:ok, ^operation_id} = Accounts.delete_citizen(citizen, resolutions)

    assert 1 ==
             Follow.DeletionAudit
             |> Ash.Query.filter(operation_id == ^operation_id)
             |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)
             |> length()
  after
    Application.delete_env(:brussels_wtf, :account_security_failure)
  end

  defp deletion_collection_fixture(stage, citizen)
       when stage in [:private_collections, :selected_collections] do
    {:ok, _collection, secret} = Follow.create_collection()
    {:ok, collection} = Follow.claim_collection(secret, citizen)

    visibility = if stage == :private_collections, do: :private, else: :public
    {:ok, collection} = Follow.owner_set_visibility(citizen, collection.id, visibility)
    if visibility == :public, do: %{collection.id => :delete}, else: %{}
  end

  defp deletion_collection_fixture(_stage, _citizen), do: %{}

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
    assert {:ok, _offer, token} = Follow.offer_collection_transfer(owner, c.id, recipient.id)
    assert {:ok, _offer} = Follow.collection_transfer_offer(recipient, token)
    assert {:ok, _} = Follow.accept_collection_transfer(recipient, token)
    assert {:ok, _} = Accounts.delete_citizen(owner)

    assert {:ok, transferred} = Follow.owner_collection(recipient, c.id)
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
