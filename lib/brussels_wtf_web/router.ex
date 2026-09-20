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

  scope "/internal/discovery", BrusselsWtfWeb do
    pipe_through :api
    post "/claim", DiscoveryController, :claim, log: false
    post "/:id/result", DiscoveryController, :result, log: false
    post "/:id/fail", DiscoveryController, :fail, log: false
  end

  scope "/health", BrusselsWtfWeb do
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
    get "/version", HealthController, :version
  end

  scope "/", BrusselsWtfWeb do
    pipe_through :browser

    get "/citizen/sign-in", CitizenSessionController, :new
    post "/citizen/magic-link", CitizenSessionController, :create
    get "/citizen/magic-link", CitizenSessionController, :confirm
    post "/citizen/magic-link/consume", CitizenSessionController, :consume
    delete "/citizen/session", CitizenSessionController, :delete
    get "/citizen/account", CitizenSessionController, :account
    delete "/citizen/account", CitizenSessionController, :delete_account
    post "/citizen/feed/follows/:id/remove", FollowCollectionController, :unfollow
    post "/citizen/feed/follows", FollowCollectionController, :follow
    post "/citizen/feed/:id/read", FollowCollectionController, :mark_read
    post "/citizen/collections/:id/visibility", FollowCollectionController, :registered_visibility
    post "/citizen/collections/:id/members", FollowCollectionController, :registered_add
    patch "/citizen/email", CitizenSessionController, :change_email
    get "/citizen/registration", CitizenSessionController, :registration
    post "/citizen/registration/import-follows", CitizenSessionController, :import_follows
    post "/citizen/registration/claim-collection", CitizenSessionController, :claim_collection

    get "/review/login", ReviewSessionController, :new
    post "/review/session", ReviewSessionController, :create
    delete "/review/session", ReviewSessionController, :delete

    dstar("/coverage", PublicationInfoPage)
    dstar("/about", PublicationInfoPage)
    dstar("/", TimelinePage)
    dstar("/meetings/:commune/:municipal_id", MeetingPage)
    dstar("/dossiers/:slug", DossierPage)
    dstar("/companies/:enterprise_number", PublicProfilePage)
    dstar("/people/:id", PublicProfilePage)
    get "/feed", FollowCollectionController, :feed
    post "/feed/updates", FollowCollectionController, :updates
    post "/collections", FollowCollectionController, :create
    get "/collections/manage-capability", FollowCollectionController, :bootstrap
    post "/collections/manage-capability", FollowCollectionController, :exchange
    get "/collections/manage", FollowCollectionController, :manage
    get "/collections/private/:id", SharedCollectionController, :private_show
    get "/collections/:token", FollowCollectionController, :show
    get "/citizen/collections/:id", SharedCollectionController, :owner_show
    post "/citizen/collections/:id/grants", SharedCollectionController, :grant
    delete "/citizen/collections/:id/grants/:grant_id", SharedCollectionController, :revoke
    post "/citizen/collections/:id/transfer-offers", SharedCollectionController, :offer_transfer

    delete "/citizen/collections/:id/transfer-offers/:offer_id",
           SharedCollectionController,
           :cancel_transfer

    delete "/citizen/collections/:id", SharedCollectionController, :delete_collection
    get "/citizen/collection-transfers/:id", SharedCollectionController, :transfer_show
    post "/citizen/collection-transfers/:id/accept", SharedCollectionController, :accept_transfer
    post "/citizen/collection-transfers/:id/reject", SharedCollectionController, :reject_transfer
    get "/citizen/account/deletion", SharedCollectionController, :deletion_resolution

    post "/citizen/collections/:id/inactivity-resolution",
         SharedCollectionController,
         :select_inactivity_resolution

    delete "/citizen/collections/:id/inactivity-resolution",
           SharedCollectionController,
           :revoke_inactivity_resolution

    patch "/collections/manage", FollowCollectionController, :update
    post "/collections/manage/members", FollowCollectionController, :add
    delete "/collections/manage/members", FollowCollectionController, :remove
    post "/dossiers/:slug/links/:link_id/reports", DossierReportController, :create

    post "/companies/:enterprise_number/suggestions/:kind", SuggestionController, :create
    post "/people/:id/suggestions/:kind", SuggestionController, :create
    post "/items/:agenda_item_id/suggestions/:kind", SuggestionController, :create
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
    post "/cases/:case_id/suggestion/address", SuggestionActionController, :address
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
