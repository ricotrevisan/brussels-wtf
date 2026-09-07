defmodule BrusselsWtfWeb.InactivityRetentionBrowserTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.{Accounts, Follow}
  require Ash.Query

  @moduletag :browser
  @port 4105
  @email "retention-browser@example.test"

  test "managed Chromium covers the localized inactivity lifecycle and exact retention boundary" do
    baseline = ~U[2026-09-10 12:00:00.000000Z]
    BrusselsWtf.Clock.Controlled.set(baseline)

    mail =
      Path.join(
        System.tmp_dir!(),
        "retention-browser-mail-#{System.unique_integer([:positive])}.json"
      )

    state = mail <> ".state.json"
    payload = mail <> ".payload.json"
    previous = Application.get_env(:brussels_wtf, :citizen_mailer)
    Application.put_env(:brussels_wtf, :citizen_mailer, Accounts.Mail.File)
    Application.put_env(:brussels_wtf, :citizen_mail_file, mail)
    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :citizen_mailer, previous)
      Application.delete_env(:brussels_wtf, :citizen_mail_file)
      Enum.each([mail, state, payload], &File.rm/1)
      if Process.alive?(server), do: Process.exit(server, :normal)
    end)

    browser!("signin", mail, state, payload, %{})
    citizen = citizen!()
    original_sign_in = citizen.last_sign_in_at

    {:ok, _collection, secret} = Follow.create_collection()
    {:ok, owned} = Follow.claim_collection(secret, citizen)
    {:ok, owned} = Follow.owner_set_visibility(citizen, owned.id, :unlisted)

    # Keep a recently opened real browser session while arranging an old sign-in cycle.
    cycle = DateTime.shift(baseline, month: -6) |> DateTime.add(30, :day)
    citizen = record_sign_in!(citizen, cycle)

    at_30 = DateTime.add(DateTime.shift(cycle, month: 6), -30, :day)
    BrusselsWtf.Clock.Controlled.set(at_30)
    assert :ok = BrusselsWtf.Workers.ProcessCitizenInactivity.perform(%Oban.Job{args: %{}})
    assert :ok = BrusselsWtf.Workers.ProcessCitizenInactivity.perform(%Oban.Job{args: %{}})

    browser!("warn30", mail, state, payload, %{
      locale: "fr",
      expected: "30 jours",
      resolution: "Résolvez les collections"
    })

    assert citizen!().last_sign_in_at == cycle
    assert [warning30] = warnings(citizen.id)
    assert warning30.days_before_deletion == 30
    assert warning30.delivery_status == :delivered
    delivered = Jason.decode!(File.read!(mail))

    assert delivered["idempotency_key"] ==
             "inactivity-warning:#{citizen.id}:#{DateTime.to_iso8601(cycle)}:30"

    at_7 = DateTime.add(DateTime.shift(cycle, month: 6), -7, :day)
    BrusselsWtf.Clock.Controlled.set(at_7)
    assert :ok = BrusselsWtf.Workers.ProcessCitizenInactivity.perform(%Oban.Job{args: %{}})

    browser!("warn7", mail, state, payload, %{
      locale: "nl",
      expected: "7 dagen",
      resolution: "Los collecties op"
    })

    assert citizen!().last_sign_in_at == cycle
    assert Enum.sort(Enum.map(warnings(citizen.id), & &1.days_before_deletion)) == [7, 30]

    browser!("select", mail, state, payload, %{})
    assert {:ok, [_]} = Follow.inactivity_resolutions(citizen!())

    # A later real magic-link sign-in starts a new cycle and clears old warnings/choices.
    BrusselsWtf.Clock.Controlled.set(DateTime.add(at_7, 1, :day))
    browser!("resignin", mail, state, payload, %{})
    renewed = citizen!()
    assert DateTime.after?(renewed.last_sign_in_at, cycle)
    assert warnings(renewed.id) == []
    assert {:ok, []} = Follow.inactivity_resolutions(renewed)

    # The new cycle warns independently. At the deadline unresolved public ownership blocks deletion.
    new_30 = DateTime.add(DateTime.shift(renewed.last_sign_in_at, month: 6), -30, :day)
    BrusselsWtf.Clock.Controlled.set(new_30)
    refresh_sessions!(renewed.id, new_30)
    assert :ok = BrusselsWtf.Workers.ProcessCitizenInactivity.perform(%Oban.Job{args: %{}})

    browser!("warn30", mail, state, payload, %{
      locale: "en",
      expected: "30 days",
      resolution: "Resolve collections"
    })

    # Notification rows, including read state, exist at the 12 calendar month boundary and purge after it.
    occurred = ~U[2025-01-31 10:00:00.000000Z]
    update = feed_update!(renewed.id, occurred)
    set_update_retention_clock!(update.id, occurred)
    boundary = DateTime.shift(occurred, month: 12)
    Follow.purge_notifications(DateTime.add(boundary, -1, :microsecond))
    assert Ash.get!(Follow.FeedUpdate, update.id, authorize?: false, domain: Follow)
    Follow.purge_notifications(boundary)
    assert {:error, _} = Ash.get(Follow.FeedUpdate, update.id, authorize?: false, domain: Follow)

    deadline = DateTime.shift(renewed.last_sign_in_at, month: 6)
    BrusselsWtf.Clock.Controlled.set(deadline)
    refresh_sessions!(renewed.id, deadline)
    assert :ok = BrusselsWtf.Workers.ProcessCitizenInactivity.perform(%Oban.Job{args: %{}})
    assert citizen!().id == renewed.id
    assert {:ok, still_owned} = Follow.owner_collection(citizen!(), owned.id)
    assert still_owned.id == owned.id
    browser!("select", mail, state, payload, %{})

    assert :ok = BrusselsWtf.Workers.ProcessCitizenInactivity.perform(%Oban.Job{args: %{}})
    assert [] == Ash.read!(Accounts.Citizen, authorize?: false, domain: Accounts)
    assert [] == Ash.read!(Follow.Collection, authorize?: false, domain: Follow)
    assert [_audit] = Ash.read!(Follow.DeletionAudit, authorize?: false, domain: Follow)
    browser!("deleted", mail, state, payload, %{})

    assert original_sign_in == baseline
  end

  defp citizen! do
    Accounts.Citizen
    |> Ash.Query.filter(email == ^@email)
    |> Ash.read_one!(authorize?: false, domain: Accounts)
  end

  defp record_sign_in!(citizen, at) do
    citizen
    |> Ash.Changeset.for_update(:record_sign_in, %{last_sign_in_at: at})
    |> Ash.update!(
      actor: %{id: citizen.id, principal: :citizen},
      authorize?: true,
      domain: Accounts
    )
  end

  defp refresh_sessions!(citizen_id, now) do
    BrusselsWtf.Repo.query!(
      "UPDATE citizen_sessions SET last_active_at = $1, expires_at = $2 WHERE citizen_id = $3",
      [now, DateTime.add(now, 90, :day), Ecto.UUID.dump!(citizen_id)]
    )

    :ok
  end

  defp warnings(id) do
    Follow.RetentionWarning
    |> Ash.Query.filter(citizen_id == ^id)
    |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: Follow)
  end

  defp set_update_retention_clock!(id, at) do
    BrusselsWtf.Repo.query!(
      "UPDATE citizen_feed_updates SET inserted_at = $1, updated_at = $1, read_at = $1 WHERE id = $2",
      [at, Ecto.UUID.dump!(id)]
    )
  end

  defp feed_update!(citizen_id, occurred) do
    Follow.FeedUpdate
    |> Ash.Changeset.for_create(:deliver_once, %{
      citizen_id: citizen_id,
      target_type: :commune,
      target_identifier: "ixelles",
      event_identity: Ash.UUID.generate(),
      event_kind: :published_meeting_page,
      public_url: "/meetings/ixelles/1",
      occurred_at: occurred
    })
    |> Ash.create!(actor: %{principal: :system}, authorize?: true, domain: Follow)
    |> Ash.Changeset.for_update(:mark_read, %{})
    |> Ash.update!(
      actor: %{id: citizen_id, principal: :citizen},
      authorize?: true,
      domain: Follow
    )
  end

  defp browser!(phase, mail, state, payload, data) do
    File.write!(payload, Jason.encode!(data))

    args = [
      "run",
      "--project",
      "test/browser",
      "--frozen",
      "python",
      "test/browser/inactivity_retention.py",
      phase,
      "--base",
      "http://127.0.0.1:#{@port}",
      "--mail",
      mail,
      "--state",
      state,
      "--payload",
      payload
    ]

    options =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          executable -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", executable}]]
        end

    {output, status} = System.cmd("uv", args, options)
    assert status == 0, output
  end
end
