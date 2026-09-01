# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :brussels_wtf,
  ecto_repos: [BrusselsWtf.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  release_sha: "development",
  ash_domains: [
    BrusselsWtf.Ingestion,
    BrusselsWtf.Council,
    BrusselsWtf.Review,
    BrusselsWtf.Identity,
    BrusselsWtf.Follow,
    BrusselsWtf.Accounts
  ],
  clock: BrusselsWtf.Clock.System,
  http: BrusselsWtf.HTTP.Req,
  http_max_body_bytes: 25 * 1_024 * 1_024,
  http_receive_timeout: 30_000,
  poll_stale_after_seconds: 12 * 60 * 60,
  archive: BrusselsWtf.Archive.Unconfigured,
  readiness: BrusselsWtf.Readiness.Monitor,
  processors: BrusselsWtf.Processors.RecordedCorpus,
  cbe_source: BrusselsWtf.CBE.Unconfigured,
  pdf_processor: BrusselsWtf.PDF.PopplerOcr,
  pdf_quality_thresholds: %{
    min_characters: 40,
    min_words: 6,
    min_alphanumeric_ratio: 0.5,
    max_control_ratio: 0.01,
    max_replacement_ratio: 0.005
  },
  pdf_limits: %{
    max_input_bytes: 25 * 1_024 * 1_024,
    max_pages: 500,
    ocr_wall_time_ms: 120_000,
    ocr_cpu_seconds: 90,
    ocr_memory_bytes: 1_073_741_824,
    ocr_jobs: 1,
    ocr_languages: "fra+nld"
  },
  coverage_processor: BrusselsWtf.Processors.RecordedCorpusCoverage,
  coverage_generation: %{
    mode: :recorded,
    backfill_enabled: false,
    backfill_max_batch_size: 10,
    monthly_budget_cents: nil
  },
  allow_synthetic_seeds: false,
  automatic_transcription: false,
  citizen_mailer: BrusselsWtf.Accounts.Mail.Memory,
  citizen_token_signing_secret: String.duplicate("dev-only-citizen-token-secret-", 3),
  citizen_session: [idle_days: 30, absolute_days: 90],
  session_cookie_secure: false,
  review_auth: [
    actor_id: "rico",
    username: nil,
    password: nil,
    session_ttl_seconds: 28_800
  ],
  suggestions: [
    enabled: false,
    rate_limit_secret: nil,
    trusted_proxies: [],
    rate_limit_window_seconds: 3_600,
    rate_limit_max_submissions: 5,
    body_min_length: 10,
    body_max_bytes: 10_000,
    body_retention_days: 365,
    contact_retention_days: 90,
    decided_contact_retention_days: 30,
    anti_abuse_retention_seconds: 172_800,
    fingerprint_retention_days: 730,
    decision_note_retention_days: 365,
    purge_batch_size: 100,
    purge_max_batches_per_job: 10
  ]

config :brussels_wtf, Oban,
  repo: BrusselsWtf.Repo,
  notifier: Oban.Notifiers.Postgres,
  peer: Oban.Peers.Database,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 */6 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "ixelles", kind: "scheduled"}},
       {"15 */6 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "uccle", kind: "scheduled"}},
       {"30 */6 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "forest", kind: "scheduled"}},
       {"45 */6 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "city-of-brussels", kind: "scheduled"}},
       {"5 1 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "ixelles", kind: "scheduled", scope: "previous-year"}},
       {"20 1 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "uccle", kind: "scheduled", scope: "previous-year"}},
       {"35 1 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{commune_slug: "forest", kind: "scheduled", scope: "previous-year"}},
       {"50 1 * * *", BrusselsWtf.Workers.PollCommune,
        args: %{
          commune_slug: "city-of-brussels",
          kind: "scheduled",
          scope: "previous-year"
        }},
       {"30 2 * * *", BrusselsWtf.Workers.PurgeSuggestions, args: %{}},
       {"*/15 * * * *", BrusselsWtf.Workers.PurgeExpiredMagicLinks, args: %{}}
     ]}
  ],
  queues: [
    poll: 1,
    corpus: 1,
    fetch: 2,
    extract: 1,
    ocr: 1,
    normalize: 1,
    enrich: 1,
    publish: 1,
    maintenance: 1
  ]

# Configure the endpoint
config :brussels_wtf, BrusselsWtfWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BrusselsWtfWeb.ErrorHTML, json: BrusselsWtfWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BrusselsWtf.PubSub,
  live_view: [signing_salt: "4Mcxxy15"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  brussels_wtf: [
    args:
      ~w(js/app.js js/personal_feed_entry.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  brussels_wtf: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :poll_run_id,
    :retrieval_observation_id,
    :source_locator_id,
    :source_version_id,
    :review_case_id,
    :coverage_run_id,
    :coverage_reservation_id,
    :commune_id,
    :commune_slug,
    :status,
    :classification,
    :attempt,
    :sha256
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["email", "token", "management_secret", "citizen_session"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :ash_authentication, return_error_on_invalid_magic_link_token?: true
