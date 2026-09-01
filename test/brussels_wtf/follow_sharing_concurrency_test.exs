defmodule BrusselsWtf.FollowSharingConcurrencyTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.{Accounts, Follow}
  alias BrusselsWtf.Follow.Collection
  require Ash.Query

  setup do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-02 12:00:00.000000Z])

    on_exit(fn ->
      if Process.whereis(BrusselsWtf.Accounts.Mailbox) == self(),
        do: Process.unregister(BrusselsWtf.Accounts.Mailbox)
    end)

    :ok
  end

  test "accept racing cancel has one valid terminal state" do
    {owner, recipient, collection, offer, token} = transfer_fixture("cancel")

    [accept, cancel] =
      race([
        fn -> Follow.accept_collection_transfer(recipient, token) end,
        fn -> Follow.cancel_collection_transfer(owner, offer.id) end
      ])

    assert_terminal_transfer(collection.id, recipient.id, accept, cancel)
  end

  test "accept racing decline has one valid terminal state" do
    {_owner, recipient, collection, _offer, token} = transfer_fixture("decline")

    [accept, decline] =
      race([
        fn -> Follow.accept_collection_transfer(recipient, token) end,
        fn -> Follow.decline_collection_transfer(recipient, token) end
      ])

    assert_terminal_transfer(collection.id, recipient.id, accept, decline)
  end

  test "accept racing owner deletion leaves no accepted offer for a missing collection" do
    {owner, recipient, collection, _offer, token} = transfer_fixture("delete")

    race([
      fn -> Follow.accept_collection_transfer(recipient, token) end,
      fn -> Follow.delete_owned_collection(owner, collection.id) end
    ])

    assert_no_dangling_rows(collection.id)
  end

  test "two accepts transfer exactly once" do
    {_owner, recipient, collection, _offer, token} = transfer_fixture("twice")

    results =
      race([
        fn -> Follow.accept_collection_transfer(recipient, token) end,
        fn -> Follow.accept_collection_transfer(recipient, token) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert collection!(collection.id).owner_citizen_id == recipient.id
    assert length(offers(collection.id)) == 1
    assert Enum.count(offers(collection.id), &(not is_nil(&1.accepted_at))) == 1
  end

  test "duplicate grants persist one authorization" do
    {owner, recipient, collection} = private_fixture("grant")

    race([
      fn -> Follow.grant_private_view(owner, collection.id, recipient.id) end,
      fn -> Follow.grant_private_view(owner, collection.id, recipient.id) end
    ])

    assert length(grants(collection.id)) == 1
    assert {:ok, _} = Follow.private_collection(collection.id, recipient)
  end

  test "revoke racing view is linearizable and ends revoked" do
    {owner, recipient, collection} = private_fixture("view")
    {:ok, grant} = Follow.grant_private_view(owner, collection.id, recipient.id)

    [view, _revoke] =
      race([
        fn -> Follow.private_collection(collection.id, recipient) end,
        fn -> Follow.revoke_private_view(owner, collection.id, grant.id) end
      ])

    assert match?({:ok, _}, view) or view == {:error, :not_found}
    assert grants(collection.id) == []
    assert {:error, :not_found} = Follow.private_collection(collection.id, recipient)
  end

  test "revoke racing collection deletion leaves no orphan" do
    {owner, recipient, collection} = private_fixture("revoke-delete")
    {:ok, grant} = Follow.grant_private_view(owner, collection.id, recipient.id)

    race([
      fn -> Follow.revoke_private_view(owner, collection.id, grant.id) end,
      fn -> Follow.delete_owned_collection(owner, collection.id) end
    ])

    assert_no_dangling_rows(collection.id)
  end

  test "duplicate revoke performs at most one mutation and ends revoked" do
    {owner, recipient, collection} = private_fixture("duplicate-revoke")
    {:ok, grant} = Follow.grant_private_view(owner, collection.id, recipient.id)

    results =
      race([
        fn -> Follow.revoke_private_view(owner, collection.id, grant.id) end,
        fn -> Follow.revoke_private_view(owner, collection.id, grant.id) end
      ])

    assert Enum.count(results, &match?(:ok, &1)) <= 1
    assert grants(collection.id) == []
    assert {:error, :not_found} = Follow.private_collection(collection.id, recipient)
  end

  defp race(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        receive do
          {:ready, pid} -> pid
        end
      end)

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp private_fixture(suffix) do
    owner = citizen("owner-#{suffix}@example.test")
    recipient = citizen("recipient-#{suffix}@example.test")
    {:ok, _, secret} = Follow.create_collection()
    {:ok, collection} = Follow.claim_collection(secret, owner)
    {:ok, collection} = Follow.owner_set_visibility(owner, collection.id, :private)
    {owner, recipient, collection}
  end

  defp transfer_fixture(suffix) do
    {owner, recipient, collection} = private_fixture(suffix)
    {:ok, collection} = Follow.owner_set_visibility(owner, collection.id, :unlisted)
    {:ok, offer, token} = Follow.offer_collection_transfer(owner, collection.id, recipient.id)
    {owner, recipient, collection, offer, token}
  end

  defp citizen(email) do
    :ok = Accounts.request_link(email)
    assert_receive {:magic_link, ^email, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, _} = Accounts.consume(token)
    citizen
  end

  defp collection!(id),
    do: Ash.get!(Collection, id, actor: %{principal: :system}, authorize?: false, domain: Follow)

  defp grants(id) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM follow_collection_grants WHERE collection_id = $1", [
        Ecto.UUID.dump!(id)
      ])

    rows
  end

  defp offers(id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT accepted_at, cancelled_at FROM follow_collection_transfer_offers WHERE collection_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    Enum.map(rows, fn [accepted_at, cancelled_at] ->
      %{accepted_at: accepted_at, cancelled_at: cancelled_at}
    end)
  end

  defp assert_no_dangling_rows(id) do
    collection =
      Ash.get(Collection, id, actor: %{principal: :system}, authorize?: false, domain: Follow)

    if match?({:ok, nil}, collection) do
      assert grants(id) == []
      assert offers(id) == []
    end
  end

  defp assert_terminal_transfer(id, recipient_id, accept, other) do
    collection = collection!(id)

    if match?({:ok, _}, accept) do
      assert collection.owner_citizen_id == recipient_id
      assert match?({:error, _}, other)
      assert Enum.count(offers(id), &(not is_nil(&1.accepted_at))) == 1
    else
      refute collection.owner_citizen_id == recipient_id
      assert match?({:ok, _}, other)
      assert Enum.all?(offers(id), &is_nil(&1.accepted_at))
    end
  end
end
