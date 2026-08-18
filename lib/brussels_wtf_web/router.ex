defmodule BrusselsWtfWeb.Router do
  use BrusselsWtfWeb, :router

  import Dstar.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BrusselsWtfWeb.Layouts, :root}
    plug Dstar.Plugs.RenameCsrfParam
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BrusselsWtfWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/health", BrusselsWtfWeb do
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/", BrusselsWtfWeb do
    pipe_through :browser

    dstar("/", TimelinePage)
    dstar("/meetings/:commune/:municipal_id", MeetingPage)
    dstar("/dossiers/:slug", DossierPage)
  end

  if Application.compile_env(:brussels_wtf, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BrusselsWtfWeb.Telemetry
    end
  end
end
