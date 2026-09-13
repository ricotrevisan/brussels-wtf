defmodule BrusselsWtf.FollowRegisteredTest do
  use BrusselsWtf.DataCase, async: false
  import ExUnit.CaptureLog
  alias BrusselsWtf.{Accounts, Follow}
  require Ash.Query
  alias BrusselsWtf.Follow.{CitizenFollow, CollectionGrant, CollectionTransferOffer, FeedUpdate}

  setup do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    BrusselsWtf.Accounts.Mail.Memory.reset_inactivity_dedup()
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

    assert {:ok, _follow} =
             CitizenFollow
             |> Ash.Changeset.for_create(:import, %{
               citizen_id: alice.id,
               target_type: :commune,
               target_identifier: "ixelles"
             })
             |> Ash.create(
               actor: %{id: alice.id, principal: :citizen},
               authorize?: true,
               domain: Follow
             )

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

    # Reads revalidate stored rows against authoritative public state. A caller-shaped
    # row has no persisted public event/revision evidence and is removed fail-closed.
    assert {:ok, []} = Follow.registered_feed(alice)
    assert {:ok, []} = Follow.registered_feed(bob)
    assert {:error, _} = Follow.mark_read(bob, original.id)
    assert {:error, _} = Follow.mark_read(alice, original.id)
  end

  test "individual removal is actor-scoped, idempotent and retains read history" do
    {alice, _} = citizen("alice-unfollow@example.test")
    {bob, _} = citizen("bob-unfollow@example.test")
    actor = %{id: alice.id, principal: :citizen}
    other = %{id: bob.id, principal: :citizen}

    create = fn owner, target ->
      CitizenFollow
      |> Ash.Changeset.for_create(:follow, %{
        citizen_id: owner.id,
        target_type: :commune,
        target_identifier: target
      })
      |> Ash.create!(
        actor: %{id: owner.id, principal: :citizen},
        authorize?: true,
        domain: Follow
      )
    end

    removed = create.(alice, "ixelles")
    kept = create.(alice, "uccle")
    other_follow = create.(bob, "ixelles")

    history =
      FeedUpdate
      |> Ash.Changeset.for_create(:deliver_once, %{
        citizen_id: alice.id,
        target_type: :commune,
        target_identifier: "ixelles",
        event_identity: Ash.UUID.generate(),
        event_kind: :published_meeting_page,
        public_url: "/meetings/ixelles/42?lang=en#revision-one",
        occurred_at: DateTime.utc_now()
      })
      |> Ash.create!(actor: %{principal: :system}, authorize?: true, domain: Follow)

    {:ok, history} = Follow.mark_read(alice, history.id)

    assert {:ok, nil} =
             CitizenFollow
             |> Ash.Query.filter(id == ^removed.id)
             |> Ash.read_one(actor: other, authorize?: true, domain: Follow)

    assert {:error, _} =
             Ash.destroy(removed, action: :remove, actor: other, authorize?: true, domain: Follow)

    assert {:error, _} =
             Ash.destroy(removed, action: :remove, actor: nil, authorize?: true, domain: Follow)

    assert {:error, _} =
             Ash.destroy(%{removed | citizen_id: bob.id},
               action: :remove,
               actor: other,
               authorize?: true,
               domain: Follow
             )

    assert :ok = Follow.unfollow(bob, removed.id)
    assert Enum.any?(Follow.citizen_follows(alice), &(&1.id == removed.id))
    assert :ok = Follow.unfollow(alice, removed.id)
    assert :ok = Follow.unfollow(alice, removed.id)
    assert Enum.map(Follow.citizen_follows(alice), & &1.id) == [kept.id]
    assert Enum.map(Follow.citizen_follows(bob), & &1.id) == [other_follow.id]
    assert {:ok, [retained]} = Follow.registered_feed(alice)
    assert retained.id == history.id and retained.read_at == history.read_at
    assert {:error, _} = Follow.mark_read(bob, history.id)
    expiry = DateTime.shift(history.inserted_at, month: 12)
    Follow.purge_notifications(expiry)
    assert {:ok, []} = Follow.registered_feed(alice)

    assert {:ok, _} =
             Ash.get(CitizenFollow, kept.id, actor: actor, authorize?: true, domain: Follow)
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

  test "concurrent retention passes claim one warning delivery" do
    {citizen, _} = citizen("concurrent-retention@example.test")
    signed_in = citizen.last_sign_in_at || citizen.inserted_at
    now = DateTime.add(signed_in, 153, :day)

    tasks = for _ <- 1..8, do: Task.async(fn -> Accounts.run_inactivity_retention(now) end)
    Enum.each(tasks, &Task.await(&1, 5_000))

    assert_receive {:inactivity_warning, "concurrent-retention@example.test", _, _, _, _}
    refute_receive {:inactivity_warning, "concurrent-retention@example.test", _, _, _, _}, 50

    [warning] =
      Follow.RetentionWarning
      |> Ash.Query.filter(citizen_id == ^citizen.id)
      |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)

    assert warning.delivery_status == :delivered
    assert is_nil(warning.claim_token)
    assert is_nil(warning.lease_expires_at)
  end

  test "warning claims recover across crashes and adapter deduplicates ambiguous delivery" do
    {citizen, _} = citizen("crash-retention@example.test")
    signed_in = citizen.last_sign_in_at || citizen.inserted_at
    due = DateTime.add(signed_in, 153, :day)

    Application.put_env(:brussels_wtf, :inactivity_warning_crash, :before_send)
    ref = Process.monitor(spawn(fn -> Accounts.run_inactivity_retention(due) end))
    assert_receive {:DOWN, ^ref, :process, _, {:injected_warning_crash, :before_send}}
    Application.delete_env(:brussels_wtf, :inactivity_warning_crash)
    Accounts.run_inactivity_retention(DateTime.add(due, 301, :second))
    assert_receive {:inactivity_warning, "crash-retention@example.test", _, _, _, _}

    {ambiguous, _} = citizen("ambiguous-retention@example.test")
    ambiguous_due = DateTime.add(ambiguous.last_sign_in_at || ambiguous.inserted_at, 153, :day)
    Application.put_env(:brussels_wtf, :inactivity_warning_crash, :after_send)
    ref = Process.monitor(spawn(fn -> Accounts.run_inactivity_retention(ambiguous_due) end))
    assert_receive {:DOWN, ^ref, :process, _, {:injected_warning_crash, :after_send}}
    assert_receive {:inactivity_warning, "ambiguous-retention@example.test", _, _, _, _}
    Application.delete_env(:brussels_wtf, :inactivity_warning_crash)
    Accounts.run_inactivity_retention(DateTime.add(ambiguous_due, 301, :second))
    refute_receive {:inactivity_warning, "ambiguous-retention@example.test", _, _, _, _}, 50

    {failed, _} = citizen("failed-retention@example.test")
    failed_due = DateTime.add(failed.last_sign_in_at || failed.inserted_at, 153, :day)
    Application.put_env(:brussels_wtf, :inactivity_mail_failure, :adapter_failure)
    assert {:warning_delivery_failed, 30} in Accounts.run_inactivity_retention(failed_due)
    Application.delete_env(:brussels_wtf, :inactivity_mail_failure)
    Accounts.run_inactivity_retention(DateTime.add(failed_due, 1, :second))
    assert_receive {:inactivity_warning, "failed-retention@example.test", _, _, _, _}

    warnings =
      Follow.RetentionWarning
      |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)

    assert Enum.count(warnings, &(&1.citizen_id in [citizen.id, ambiguous.id, failed.id])) == 3
  after
    Application.delete_env(:brussels_wtf, :inactivity_warning_crash)
    Application.delete_env(:brussels_wtf, :inactivity_mail_failure)
  end

  test "later sign-in clears ownership choices, warnings, and any active lease" do
    {citizen, _} = citizen("reset-retention@example.test")
    {:ok, collection, secret} = Follow.create_collection()
    {:ok, owned} = Follow.claim_collection(secret, citizen)
    {:ok, _} = Follow.owner_set_visibility(citizen, owned.id, :public)
    {:ok, _} = Follow.select_inactivity_resolution(citizen, collection.id, :delete)

    due = DateTime.add(citizen.last_sign_in_at || citizen.inserted_at, 153, :day)
    Application.put_env(:brussels_wtf, :inactivity_warning_crash, :before_send)
    ref = Process.monitor(spawn(fn -> Accounts.run_inactivity_retention(due) end))
    assert_receive {:DOWN, ^ref, :process, _, {:injected_warning_crash, :before_send}}
    Application.delete_env(:brussels_wtf, :inactivity_warning_crash)

    # Successful sign-in invokes this reset immediately after record_sign_in.
    :ok = Follow.clear_inactivity_resolutions(citizen.id)

    {:ok, signed_in} =
      citizen
      |> Ash.Changeset.for_update(:record_sign_in, %{
        last_sign_in_at: ~U[2026-09-02 12:01:00.000000Z]
      })
      |> Ash.update(
        actor: %{id: citizen.id, principal: :citizen},
        authorize?: true,
        domain: Accounts
      )

    assert {:ok, []} = Follow.inactivity_resolutions(signed_in)

    assert [] ==
             Follow.RetentionWarning
             |> Ash.Query.filter(citizen_id == ^citizen.id)
             |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)
  after
    Application.delete_env(:brussels_wtf, :inactivity_warning_crash)
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

    guest_actor = %{id: guest.id, principal: :citizen}
    owner_actor = %{id: owner.id, principal: :citizen}

    assert {:error, _} =
             Ash.destroy(grant, actor: guest_actor, authorize?: true, domain: Follow)

    assert {:error, _} =
             CollectionGrant
             |> Ash.Changeset.for_create(:grant_view, %{
               collection_id: private.id,
               citizen_id: stranger.id,
               owner_citizen_id: owner.id
             })
             |> Ash.create(actor: guest_actor, authorize?: true, domain: Follow)

    assert {:error, _} =
             CitizenFollow
             |> Ash.Changeset.for_create(:follow, %{
               citizen_id: owner.id,
               target_type: :commune,
               target_identifier: "ixelles"
             })
             |> Ash.create(actor: guest_actor, authorize?: true, domain: Follow)

    {:ok, personal_follow} =
      CitizenFollow
      |> Ash.Changeset.for_create(:follow, %{
        citizen_id: owner.id,
        target_type: :commune,
        target_identifier: "ixelles"
      })
      |> Ash.create(actor: owner_actor, authorize?: true, domain: Follow)

    assert {:error, _} =
             Ash.destroy(personal_follow,
               action: :remove,
               actor: guest_actor,
               authorize?: true,
               domain: Follow
             )

    {:ok, offer} =
      CollectionTransferOffer
      |> Ash.Changeset.for_create(:offer, %{
        collection_id: private.id,
        from_citizen_id: owner.id,
        to_citizen_id: stranger.id,
        token_hash: :crypto.hash(:sha256, "negative-offer"),
        expires_at: DateTime.add(BrusselsWtf.Clock.Controlled.utc_now(), 7, :day)
      })
      |> Ash.create(actor: owner_actor, authorize?: true, domain: Follow)

    assert {:error, _} =
             CollectionTransferOffer
             |> Ash.Changeset.for_create(:offer, %{
               collection_id: private.id,
               from_citizen_id: owner.id,
               to_citizen_id: stranger.id,
               token_hash: :crypto.hash(:sha256, "spoofed-offer"),
               expires_at: DateTime.add(BrusselsWtf.Clock.Controlled.utc_now(), 7, :day)
             })
             |> Ash.create(actor: guest_actor, authorize?: true, domain: Follow)

    assert {:error, _} =
             offer
             |> Ash.Changeset.for_update(:cancel, %{
               cancelled_at: BrusselsWtf.Clock.Controlled.utc_now()
             })
             |> Ash.update(actor: guest_actor, authorize?: true, domain: Follow)

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

    logs =
      capture_log(fn ->
        assert {:ok, _offer, token} = Follow.offer_collection_transfer(owner, c.id, recipient.id)
        assert {:ok, _offer} = Follow.collection_transfer_offer(recipient, token)
        assert {:ok, _} = Follow.accept_collection_transfer(recipient, token)
      end)

    refute logs =~ "Missed"
    refute logs =~ "notifications"
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
