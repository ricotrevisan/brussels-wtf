defmodule BrusselsWtf.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = BrusselsWtf.Council.GenerationControl.validate_configuration!()
    :ok = BrusselsWtf.Suggestions.validate_configuration!()
    oban_config = oban_config()
    Application.put_env(:brussels_wtf, Oban, oban_config, persistent: true)

    children =
      [
        BrusselsWtfWeb.Telemetry,
        BrusselsWtf.Repo,
        {AshAuthentication.Supervisor, otp_app: :brussels_wtf},
        {DNSCluster, query: Application.get_env(:brussels_wtf, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: BrusselsWtf.PubSub}
      ] ++
        archive_children() ++
        [
          {Task.Supervisor, name: BrusselsWtf.Readiness.TaskSupervisor},
          BrusselsWtf.Readiness.Monitor,
          {Oban, oban_config}
        ] ++
        page_view_children() ++
        [
          BrusselsWtfWeb.PublicSitemap.Cache,
          BrusselsWtfWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BrusselsWtf.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def oban_config(role \\ Application.get_env(:brussels_wtf, :process_role))

  def oban_config(role) when role in [:app, :ocr] do
    BrusselsWtf.ProcessRole.oban(role, Application.fetch_env!(:brussels_wtf, Oban))
  end

  def oban_config(nil), do: Application.fetch_env!(:brussels_wtf, Oban)

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BrusselsWtfWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp page_view_children do
    if Application.get_env(:brussels_wtf, :page_view_buffer, true) do
      [BrusselsWtf.Readership.PageViewBuffer.isolated_child_spec()]
    else
      []
    end
  end

  defp archive_children do
    case Application.get_env(:brussels_wtf, :archive) do
      BrusselsWtf.Archive.Memory -> [BrusselsWtf.Archive.Memory]
      BrusselsWtf.Archive.Unconfigured -> [BrusselsWtf.Archive.Unconfigured]
      _ -> []
    end
  end
end
