defmodule BrusselsWtfWeb.PrivateCollectionSharingBrowserTest do
  use BrusselsWtf.DataCase, async: false
  alias BrusselsWtf.{Accounts, Follow}
  @moduletag :browser
  @port 4104

  test "sharing, transfer choices, and self-service account deletion are browser-complete" do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)

    on_exit(fn ->
      if Process.whereis(BrusselsWtf.Accounts.Mailbox) == self(),
        do: Process.unregister(BrusselsWtf.Accounts.Mailbox)
    end)

    {owner, owner_token} = citizen("browser-owner@example.test")
    {recipient, recipient_token} = citizen("browser-recipient@example.test")
    private = collection(owner, :private, "Private browser collection", true)
    accept = collection(owner, :unlisted, "Accepted transfer", true)
    decline = collection(owner, :public, "Declined transfer", false)
    cancel = collection(owner, :unlisted, "Cancelled transfer", false)
    delete = collection(owner, :public, "Explicit deletion", true)
    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :shutdown) end)

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
      "--private",
      private.id,
      "--accept",
      accept.id,
      "--decline",
      decline.id,
      "--cancel",
      cancel.id,
      "--delete",
      delete.id,
      "--recipient-id",
      recipient.id
    ]

    opts =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          e -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", e}]]
        end

    {output, status} = System.cmd("uv", args, opts)
    assert status == 0, output

    assert {:ok, transferred} = Follow.owner_collection(recipient, accept.id)
    assert transferred.owner_citizen_id == recipient.id

    for id <- [private.id, decline.id, cancel.id, delete.id],
        do: assert({:error, :not_found} = Follow.owner_collection(owner, id))

    owner_id = Ecto.UUID.dump!(owner.id)

    for {table, predicate} <- [
          {"citizen_follows", "citizen_id = $1"},
          {"citizen_feed_updates", "citizen_id = $1"},
          {"follow_collection_grants", "citizen_id = $1"},
          {"follow_collection_transfer_offers", "from_citizen_id = $1 OR to_citizen_id = $1"}
        ] do
      assert %{rows: [[0]]} =
               Ecto.Adapters.SQL.query!(
                 BrusselsWtf.Repo,
                 "SELECT count(*) FROM #{table} WHERE #{predicate}",
                 [owner_id]
               )
    end

    [audit] = Ash.read!(Follow.DeletionAudit, authorize?: false, domain: Follow)
    refute Map.has_key?(Map.from_struct(audit), :email)
    refute inspect(audit) =~ owner.id
    refute inspect(audit) =~ "browser-owner@example.test"
  end

  defp collection(owner, visibility, title, member?) do
    {:ok, _, secret} = Follow.create_collection()
    {:ok, collection} = Follow.claim_collection(secret, owner)
    {:ok, collection} = Follow.owner_set_visibility(owner, collection.id, visibility)
    collection = %{collection | title: title}
    if member?, do: {:ok, _} = Follow.add_member_session(collection.id, :commune, "ixelles")
    collection
  end

  defp citizen(email) do
    :ok = Accounts.request_link(email)
    assert_receive {:magic_link, ^email, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, _} = Accounts.consume(token)
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
