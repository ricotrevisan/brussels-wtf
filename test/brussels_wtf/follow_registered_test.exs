defmodule BrusselsWtf.FollowRegisteredTest do
  use BrusselsWtf.DataCase, async: false
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

  defp citizen(email) do
    Accounts.request_link(email)
    assert_receive {:magic_link, ^email, link, _}

    token =
      link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")

    {:ok, citizen, session} = Accounts.consume(token)
    {citizen, session}
  end
end
