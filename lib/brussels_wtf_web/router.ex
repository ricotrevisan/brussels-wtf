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

  pipeline :reviewer do
    plug BrusselsWtfWeb.Plugs.RequireReviewer
  end

  scope "/health", BrusselsWtfWeb do
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
    get "/version", HealthController, :version
  end

  scope "/", BrusselsWtfWeb do
    pipe_through :browser

    get "/review/login", ReviewSessionController, :new
    post "/review/session", ReviewSessionController, :create
    delete "/review/session", ReviewSessionController, :delete

    dstar("/", TimelinePage)
    dstar("/meetings/:commune/:municipal_id", MeetingPage)
    dstar("/dossiers/:slug", DossierPage)
    dstar("/companies/:enterprise_number", PublicProfilePage)
    dstar("/people/:id", PublicProfilePage)
    post "/dossiers/:slug/links/:link_id/reports", DossierReportController, :create

    post "/companies/:enterprise_number/suggestions/:kind", SuggestionController, :create
    post "/people/:id/suggestions/:kind", SuggestionController, :create
  end

  scope "/review", BrusselsWtfWeb do
    pipe_through [:browser, :reviewer]

    dstar("/", ReviewInboxPage)
    post "/polls", PollController, :create
    post "/coverage-batches", CoverageBatchController, :create
    post "/corpus-batches", CorpusImportBatchController, :create
    post "/corpus-batches/:id/refresh", CorpusImportBatchController, :refresh
    post "/corpus-batches/:id/prepare-coverage", CorpusImportBatchController, :prepare_coverage
    dstar("/cases/:id", ReviewCasePage)
    post "/cases/:case_id/actions/:action", ReviewActionController, :create
    post "/cases/:case_id/notes", ReviewNoteController, :create
    post "/cases/:case_id/suggestion/reject", SuggestionActionController, :reject
    post "/cases/:case_id/suggestion/approve", SuggestionActionController, :approve

    post "/publications/:page_id/factual-corrections",
         PublicationActionController,
         :factual_correction

    post "/publications/:page_id/typography-corrections",
         PublicationActionController,
         :typography_correction

    post "/publications/:page_id/withdraw", PublicationActionController, :withdraw
    post "/publications/:page_id/republish", PublicationActionController, :republish
    get "/artifacts/source-versions/:id", ReviewArtifactController, :source_version
    get "/artifacts/derived/:id", ReviewArtifactController, :derived_artifact
  end

  if Application.compile_env(:brussels_wtf, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BrusselsWtfWeb.Telemetry
    end
  end
end
