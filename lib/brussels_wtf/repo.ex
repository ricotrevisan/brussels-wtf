defmodule BrusselsWtf.Repo do
  use AshPostgres.Repo,
    otp_app: :brussels_wtf

  # Ash attribute redaction does not redact Ecto SQL parameters. The private
  # index scopes every operation (including bulk inserts) to this process flag.
  @impl true
  def default_options(_operation) do
    if Process.get(:brussels_wtf_private_cbe_index), do: [log: false], else: []
  end

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    ["ash-functions"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 17, minor: 0, patch: 0}
  end
end
