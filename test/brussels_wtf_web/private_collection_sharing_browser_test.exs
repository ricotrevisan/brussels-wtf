defmodule BrusselsWtfWeb.PrivateCollectionSharingBrowserTest do
  use BrusselsWtf.DataCase, async: false
  alias BrusselsWtf.{Accounts, Follow}
  @moduletag :browser
  @port 4104

  test "owner grant, view-only recipient, revoke, accepted transfer, and deletion resolution" do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)

    on_exit(fn ->
      if Process.whereis(BrusselsWtf.Accounts.Mailbox) == self(),
        do: Process.unregister(BrusselsWtf.Accounts.Mailbox)
    end)

    {owner, owner_token} = citizen("browser-owner@example.test")
    {recipient, recipient_token} = citizen("browser-recipient@example.test")
    {:ok, _collection, secret} = Follow.create_collection()
    {:ok, collection} = Follow.claim_collection(secret, owner)
    {:ok, collection} = Follow.owner_set_visibility(owner, collection.id, :private)
    {:ok, _} = Follow.add_member_session(collection.id, :commune, "ixelles")
    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :shutdown)
    end)

    # A transfer is recipient-bound and only valid after the collection is non-private.
    {:ok, _} = Follow.owner_set_visibility(owner, collection.id, :unlisted)

    {:ok, _offer, transfer_token} =
      Follow.offer_collection_transfer(owner, collection.id, recipient.id)

    # Restore private for the grant/revoke browser phase; the offer remains bound.
    {:ok, _} = Follow.owner_set_visibility(owner, collection.id, :private)

    args = [
      "run",
      "--project",
      "test/browser",
      "--frozen",
      "python",
      "test/browser/private_collection_sharing.py",
      "--base",
      "http://127.0.0.1:#{@port}",
      "--owner-token",
      owner_token,
      "--recipient-token",
      recipient_token,
      "--collection",
      collection.id,
      "--recipient-id",
      recipient.id,
      "--transfer-token",
      transfer_token
    ]

    opts =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          e -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", e}]]
        end

    {output, status} = System.cmd("uv", args, opts)
    assert status == 0, output
  end

  defp citizen(email) do
    :ok = Accounts.request_link(email)
    assert_receive {:magic_link, ^email, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, _} = Accounts.consume(token)
    # Browser needs a fresh single-use token.
    :ok = Accounts.request_link(email)
    assert_receive {:magic_link, ^email, browser_link, _}

    browser_token =
      browser_link
      |> URI.parse()
      |> Map.fetch!(:fragment)
      |> URI.decode_query()
      |> Map.fetch!("token")

    {citizen, browser_token}
  end
end
