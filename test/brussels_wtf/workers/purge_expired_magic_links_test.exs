defmodule BrusselsWtf.Workers.PurgeExpiredMagicLinksTest do
  use BrusselsWtf.DataCase, async: false
  alias BrusselsWtf.{Accounts, Clock.Controlled}
  alias BrusselsWtf.Accounts.OutstandingMagicLink

  test "cron schedules durable cleanup" do
    cron =
      Application.fetch_env!(:brussels_wtf, Oban)[:plugins]
      |> Keyword.fetch!(Oban.Plugins.Cron)
      |> Keyword.fetch!(:crontab)

    assert {"*/15 * * * *", BrusselsWtf.Workers.PurgeExpiredMagicLinks, [args: %{}]} in cron
  end

  test "worker removes the expiry boundary, retains future rows, and is idempotent" do
    now = ~U[2026-09-02 12:00:00.000000Z]
    Controlled.set(now)
    expired = record!("expired", DateTime.add(now, -1, :second))
    boundary = record!("boundary", now)
    retained = record!("retained", DateTime.add(now, 1, :second))

    assert :ok = BrusselsWtf.Workers.PurgeExpiredMagicLinks.perform(%Oban.Job{})
    assert {:error, _} = get(expired.id)
    assert {:error, _} = get(boundary.id)
    assert {:ok, %{id: id}} = get(retained.id)
    assert id == retained.id
    assert :ok = BrusselsWtf.Workers.PurgeExpiredMagicLinks.perform(%Oban.Job{})
    assert {:ok, _} = get(retained.id)
  end

  defp record!(jti, expires_at) do
    OutstandingMagicLink
    |> Ash.Changeset.for_create(:record, %{
      email_hash: :crypto.hash(:sha256, jti),
      jti: jti,
      subject: "citizen",
      expires_at: expires_at
    })
    |> Ash.create!(actor: %{principal: :system}, authorize?: true, domain: Accounts)
  end

  defp get(id),
    do:
      Ash.get(OutstandingMagicLink, id,
        actor: %{principal: :system},
        authorize?: true,
        domain: Accounts
      )
end
