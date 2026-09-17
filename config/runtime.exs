import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/brussels_wtf start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :brussels_wtf, BrusselsWtfWeb.Endpoint, server: true
end

config :brussels_wtf, BrusselsWtfWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :brussels_wtf, BrusselsWtfWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        Regex.compile!(to_string("priv/static/(?!uploads/).*\\.(js|css|png|jpeg|jpg|gif|svg)$")),
        # Gettext translations
        Regex.compile!(to_string("priv/gettext/.*\\.po$")),
        # Router, Controllers, LiveViews and LiveComponents
        Regex.compile!(to_string("lib/brussels_wtf_web/router\\.ex$")),
        Regex.compile!(
          to_string("lib/brussels_wtf_web/(controllers|live|components|pages)/.*\\.(ex|heex)$")
        )
      ]
    ]
end

# Tests select faithful processors explicitly and never consume operator API keys.
if config_env() in [:dev, :prod] do
  coverage = BrusselsWtf.Processors.CoverageRuntime.load()
  config :brussels_wtf, :coverage_generation, coverage.generation
  config :brussels_wtf, :coverage_processor, coverage.processor
  config :brussels_wtf, BrusselsWtf.Processors.OpenRouterCoverage, coverage.provider_config
end

if config_env() == :prod do
  # The release carries its build identity; stale Coolify runtime variables cannot relabel it.
  release_sha =
    case File.read(Application.app_dir(:brussels_wtf, "priv/source_commit")) do
      {:ok, value} -> String.trim(value)
      {:error, :enoent} -> System.get_env("RELEASE_SHA", "unknown")
      {:error, reason} -> raise "cannot read release identity: #{inspect(reason)}"
    end

  unless Regex.match?(~r/\A(?:unknown|[0-9a-f]{7,40})\z/, release_sha) do
    raise "RELEASE_SHA must be a Git commit hash or unknown"
  end

  config :brussels_wtf, :release_sha, release_sha

  process_role = System.get_env("PROCESS_ROLE", "app")

  role =
    case process_role do
      "app" -> :app
      "ocr" -> :ocr
      _ -> raise "PROCESS_ROLE must be app or ocr"
    end

  if role == :ocr do
    config :brussels_wtf, BrusselsWtfWeb.Endpoint, server: false
  end

  # BrusselsWtf.Application applies this role as one exact Oban child config,
  # avoiding recursive keyword-list leakage from the build configuration.
  config :brussels_wtf, :process_role, role

  cbe_open_data_directory = System.get_env("CBE_OPEN_DATA_DIRECTORY")
  cbe_open_data_sha256 = System.get_env("CBE_OPEN_DATA_SHA256")

  case {cbe_open_data_directory, cbe_open_data_sha256} do
    {directory, sha256} when directory not in [nil, ""] and sha256 not in [nil, ""] ->
      config :brussels_wtf, :cbe_source, BrusselsWtf.CBE.OpenData

      config :brussels_wtf, BrusselsWtf.CBE.OpenData,
        directory: directory,
        release_sha256: sha256

    {directory, sha256} when directory in [nil, ""] and sha256 in [nil, ""] ->
      :ok

    _ ->
      raise "CBE Open Data requires both CBE_OPEN_DATA_DIRECTORY and CBE_OPEN_DATA_SHA256"
  end

  config :brussels_wtf, :pdf_limits, %{
    max_input_bytes: String.to_integer(System.get_env("PDF_MAX_INPUT_BYTES", "26214400")),
    max_pages: String.to_integer(System.get_env("PDF_MAX_PAGES", "500")),
    ocr_wall_time_ms: String.to_integer(System.get_env("PDF_OCR_WALL_TIME_MS", "120000")),
    ocr_cpu_seconds: String.to_integer(System.get_env("PDF_OCR_CPU_SECONDS", "90")),
    ocr_memory_bytes: String.to_integer(System.get_env("PDF_OCR_MEMORY_BYTES", "1073741824")),
    ocr_jobs: 1,
    ocr_languages: "fra+nld"
  }

  review_username =
    System.get_env("REVIEW_USERNAME") ||
      raise "environment variable REVIEW_USERNAME is missing"

  review_password =
    System.get_env("REVIEW_PASSWORD") ||
      raise "environment variable REVIEW_PASSWORD is missing"

  if byte_size(review_password) < 16 do
    raise "environment variable REVIEW_PASSWORD must contain at least 16 characters"
  end

  config :brussels_wtf, :review_auth,
    actor_id: "rico",
    username: review_username,
    password: review_password,
    session_ttl_seconds: 28_800

  archive_environment = %{
    access_key_id: "SOURCE_ARCHIVE_S3_ACCESS_KEY_ID",
    secret_access_key: "SOURCE_ARCHIVE_S3_SECRET_ACCESS_KEY",
    region: "SOURCE_ARCHIVE_S3_REGION",
    endpoint_url: "SOURCE_ARCHIVE_S3_ENDPOINT",
    bucket: "SOURCE_ARCHIVE_S3_BUCKET"
  }

  archive_config =
    Map.new(archive_environment, fn {key, name} -> {key, System.get_env(name)} end)

  missing_archive_environment =
    archive_environment
    |> Enum.filter(fn {key, _name} -> archive_config[key] in [nil, ""] end)
    |> Enum.map(fn {_key, name} -> name end)

  cond do
    missing_archive_environment == [] ->
      config :brussels_wtf, :archive, BrusselsWtf.Archive.S3

      config :brussels_wtf, BrusselsWtf.Archive.S3,
        bucket: archive_config.bucket,
        validation_prefix: "_validation/brussels-wtf",
        req_options: [
          aws_endpoint_url_s3: archive_config.endpoint_url,
          aws_sigv4: [
            access_key_id: archive_config.access_key_id,
            secret_access_key: archive_config.secret_access_key,
            region: archive_config.region
          ]
        ]

    length(missing_archive_environment) == map_size(archive_environment) ->
      :ok

    true ->
      raise "incomplete source archive configuration; missing #{Enum.join(missing_archive_environment, ", ")}"
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :brussels_wtf, BrusselsWtf.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  suggestions_enabled =
    case System.get_env("SUGGESTIONS_ENABLED", "true") do
      "true" -> true
      "false" -> false
      _ -> raise "SUGGESTIONS_ENABLED must be true or false"
    end

  suggestion_hmac_key =
    System.get_env("SUGGESTION_RATE_LIMIT_SECRET") ||
      :crypto.mac(
        :hmac,
        :sha256,
        secret_key_base,
        "brussels-wtf:suggestion-rate-limit:v1"
      )

  trusted_proxies =
    System.get_env("SUGGESTION_TRUSTED_PROXIES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :brussels_wtf, :suggestions,
    enabled: suggestions_enabled,
    rate_limit_secret: suggestion_hmac_key,
    trusted_proxies: trusted_proxies

  host = System.get_env("PHX_HOST") || "example.com"

  config :brussels_wtf, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :brussels_wtf, BrusselsWtfWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :brussels_wtf, BrusselsWtfWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :brussels_wtf, BrusselsWtfWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
