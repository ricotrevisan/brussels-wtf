import Config
config :brussels_wtf, :allow_synthetic_seeds, true

config :brussels_wtf, :review_auth,
  actor_id: "rico",
  username: "rico",
  password: "review-secret",
  session_ttl_seconds: 28_800

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :brussels_wtf, BrusselsWtf.Repo,
  username: System.get_env("PGUSER", "brussels"),
  password: System.get_env("PGPASSWORD", "brussels"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5433")),
  database: "brussels_wtf_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :brussels_wtf,
  clock: BrusselsWtf.Clock.Controlled,
  http: BrusselsWtf.HTTP.Stub,
  archive: BrusselsWtf.Archive.Memory,
  processors: BrusselsWtf.Processors.Stub,
  pdf_processor: BrusselsWtf.PDF.Stub,
  coverage_processor: BrusselsWtf.Processors.Stub

config :brussels_wtf, Oban, testing: :manual, queues: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :brussels_wtf, BrusselsWtfWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ben/AdGVtuvLmP6BTbxmvIT9gfqEdn2+Onvnd68SO+S9z5AtwXNb6QkXpg3TkGWq",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
