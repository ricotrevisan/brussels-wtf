defmodule BrusselsWtf.UnfollowConcurrencyTest do
  use ExUnit.Case, async: false
  alias BrusselsWtf.{Follow, Repo}
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Publication do
    def list(target, locale, _imported) do
      {parent, event} = Application.fetch_env!(:brussels_wtf, :unfollow_race)
      send(parent, {:publication_locked, self()})

      receive do
        :publish -> :ok
      after
        5_000 -> raise "publication barrier timed out"
      end

      [
        %{
          target: %{type: target.type, id: target.identifier},
          eventType: :correction,
          publicEventId: event,
          revisionId: event,
          title: "Concurrency fixture",
          url: "/meetings/ixelles/268?lang=#{locale}#revision-#{event}",
          occurredAt: DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    end
  end

  test "publication holding the follow lock finishes before removal; queued stale synchronization skips deletion" do
    Sandbox.unboxed_run(Repo, fn ->
      id = Ash.UUID.generate()
      citizen = %{id: id}

      dossier =
        BrusselsWtf.Council.create_dossier!(%{
          slug: "unfollow-race-#{id}",
          title: "Concurrency fixture",
          localized_titles: %{}
        })

      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO citizens (id,email) VALUES ($1,$2)",
        [Ecto.UUID.dump!(id), "#{id}@example.test"]
      )

      old = Application.get_env(:brussels_wtf, :public_follow_update_provider)
      Application.put_env(:brussels_wtf, :public_follow_update_provider, Publication)
      Application.put_env(:brussels_wtf, :unfollow_race, {self(), Ash.UUID.generate()})
      BrusselsWtf.Clock.Controlled.set(DateTime.add(DateTime.utc_now(), 60, :second))

      try do
        {:ok, follow} = Follow.follow(citizen, :dossier, dossier.slug)

        sync =
          Task.async(fn -> Sandbox.unboxed_run(Repo, &Follow.synchronize_registered_feeds/0) end)

        assert_receive {:publication_locked, publisher}, 5_000

        removal =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn -> Follow.unfollow(citizen, follow.id) end)
          end)

        assert Task.yield(removal, 100) == nil
        send(publisher, :publish)
        assert {:ok, 1} = Task.await(sync)
        assert :ok = Task.await(removal)
        assert {:ok, [history]} = Follow.registered_feed(citizen)
        assert history.target_identifier == dossier.slug
        assert {:ok, 0} = Follow.synchronize_registered_feeds()

        {:ok, second} = Follow.follow(citizen, :dossier, dossier.slug)
        # Hold the row until the worker has selected it and is waiting for its lock.
        {:ok, queued} =
          Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(
              Repo,
              "SELECT id FROM citizen_follows WHERE id=$1 FOR UPDATE",
              [Ecto.UUID.dump!(second.id)]
            )

            queued =
              Task.async(fn ->
                Sandbox.unboxed_run(Repo, &Follow.synchronize_registered_feeds/0)
              end)

            wait_for_lock!()
            assert :ok = Follow.unfollow(citizen, second.id)
            queued
          end)

        assert {:ok, 0} = Task.await(queued)
        refute_receive {:publication_locked, _}, 50
        assert {:ok, [retained]} = Follow.registered_feed(citizen)
        assert retained.id == history.id
      after
        if old,
          do: Application.put_env(:brussels_wtf, :public_follow_update_provider, old),
          else: Application.delete_env(:brussels_wtf, :public_follow_update_provider)

        Application.delete_env(:brussels_wtf, :unfollow_race)

        for table <- ["citizen_feed_updates", "citizen_follows"] do
          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table} WHERE citizen_id=$1", [
            Ecto.UUID.dump!(id)
          ])
        end

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM citizens WHERE id=$1", [Ecto.UUID.dump!(id)])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM dossiers WHERE id=$1", [
          Ecto.UUID.dump!(dossier.id)
        ])
      end
    end)
  end

  defp wait_for_lock!(attempts \\ 100)
  defp wait_for_lock!(0), do: flunk("synchronization never waited for the follow row lock")

  defp wait_for_lock!(attempts) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_stat_clear_snapshot()", [])

    %{rows: [[waiting]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'SELECT id FROM citizen_follows%'",
        []
      )

    if waiting == 0 do
      Process.sleep(10)
      wait_for_lock!(attempts - 1)
    end
  end
end
