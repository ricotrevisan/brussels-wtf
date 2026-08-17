defmodule BrusselsWtf.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BrusselsWtfWeb.Telemetry,
        BrusselsWtf.Repo,
        {DNSCluster, query: Application.get_env(:brussels_wtf, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: BrusselsWtf.PubSub}
      ] ++
        archive_children() ++
        [
          {Oban, Application.fetch_env!(:brussels_wtf, Oban)},
          BrusselsWtfWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BrusselsWtf.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BrusselsWtfWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp archive_children do
    case Application.get_env(:brussels_wtf, :archive) do
      BrusselsWtf.Archive.Memory -> [BrusselsWtf.Archive.Memory]
      BrusselsWtf.Archive.Unconfigured -> [BrusselsWtf.Archive.Unconfigured]
      _ -> []
    end
  end
end
