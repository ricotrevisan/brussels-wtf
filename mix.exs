defmodule BrusselsWtf.MixProject do
  use Mix.Project

  @github_assets [
    heroicons: [
      version: "v2.2.0",
      url: "https://github.com/tailwindlabs/heroicons/archive/refs/tags/v2.2.0.tar.gz",
      sha256: "42bd31001127631a20270e7bd87ac13647bfcd628dd533e2ff31497068b4f7af",
      tar_prefix: "heroicons-2.2.0/optimized/",
      dest_subpath: "optimized",
      check_path: "optimized/24/outline"
    ],
    daisyui: [
      version: "v5.5.20",
      url: "https://github.com/saadeghi/daisyui/archive/refs/tags/v5.5.20.tar.gz",
      sha256: "576ce735008b61d8e9e367456d5188b2b4353c07f9ca29fb27456b265e2d0796",
      tar_prefix: "daisyui-5.5.20/packages/bundle/",
      dest_subpath: "packages/bundle",
      check_path: "packages/bundle/daisyui.js"
    ]
  ]

  def project do
    [
      app: :brussels_wtf,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BrusselsWtf.Application, []},
      extra_applications: [:logger, :runtime_tools, :xmerl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.browser": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_postgres, "~> 2.0"},
      {:simple_sat, "~> 0.1.4"},
      {:oban, "~> 2.24"},
      {:nimble_csv, "~> 1.2"},
      {:req, "~> 0.7"},
      {:req_s3, "~> 0.2.5"},
      {:dstar, "~> 0.3.2"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:tzdata, "~> 1.1"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:tidewave, "~> 0.8", only: :dev},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:sourceror, "~> 1.8", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "test.browser": [
        "assets.setup",
        "assets.build",
        "test --include browser test/brussels_wtf_web/personal_feed_browser_test.exs test/brussels_wtf_web/citizen_auth_browser_test.exs test/brussels_wtf_web/registered_feed_browser_test.exs test/brussels_wtf_web/inactivity_retention_browser_test.exs test/brussels_wtf_web/private_collection_sharing_browser_test.exs test/brussels_wtf/identity_mandate_declaration_test.exs"
      ],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "assets.vendor --if-missing"
      ],
      "assets.build": [
        "compile",
        "assets.vendor --if-missing",
        "tailwind brussels_wtf",
        "esbuild brussels_wtf"
      ],
      "assets.deploy": [
        "assets.vendor --if-missing",
        "tailwind brussels_wtf --minify",
        "esbuild brussels_wtf --minify",
        "phx.digest"
      ],
      "assets.vendor": &install_github_assets/1,
      precommit: [
        "compile --warnings-as-errors",
        "ash.codegen --check",
        "deps.unlock --unused",
        "format",
        "test"
      ]
    ]
  end

  defp install_github_assets(args) do
    if_missing? = "--if-missing" in args

    for {name, spec} <- @github_assets do
      install_github_asset(name, spec, if_missing?)
    end
  end

  defp install_github_asset(name, spec, if_missing?) do
    dest = Path.expand("deps/#{name}", __DIR__)
    version = Keyword.fetch!(spec, :version)
    version_file = Path.join(dest, ".version")
    check_path = Path.join(dest, Keyword.fetch!(spec, :check_path))

    already_installed? =
      File.regular?(version_file) and
        String.trim(File.read!(version_file)) == version and
        File.exists?(check_path) and
        not File.exists?(Path.join(dest, ".git"))

    unless if_missing? and already_installed? do
      Mix.shell().info("Installing #{name} #{version} into #{dest}...")
      tarball = fetch_tarball!(Keyword.fetch!(spec, :url))

      actual_sha =
        :crypto.hash(:sha256, tarball)
        |> Base.encode16(case: :lower)

      expected_sha = Keyword.fetch!(spec, :sha256)

      if actual_sha != expected_sha do
        Mix.raise("""
        #{name} tarball checksum mismatch!
          expected: #{expected_sha}
          actual:   #{actual_sha}
        """)
      end

      prefix = Keyword.fetch!(spec, :tar_prefix)
      dest_subpath = Keyword.fetch!(spec, :dest_subpath)
      File.mkdir_p!(Path.dirname(dest))

      tmp_dir =
        Path.join(Path.dirname(dest), ".#{name}-tmp-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(tmp_dir)
        {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

        for {entry, content} <- files,
            path = List.to_string(entry),
            String.starts_with?(path, prefix),
            not String.ends_with?(path, "/") do
          rel = String.replace_prefix(path, prefix, "")

          if ".." in Path.split(rel) or Path.type(rel) != :relative do
            Mix.raise("Refusing to extract unsafe path from #{name} tarball: #{path}")
          end

          target = Path.join([tmp_dir, dest_subpath, rel])
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, content)
        end

        File.write!(Path.join(tmp_dir, ".version"), version <> "\n")
        File.rm_rf!(dest)
        File.rename!(tmp_dir, dest)
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  defp fetch_tarball!(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    http_opts = [
      autoredirect: true,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    headers = [{~c"user-agent", ~c"mix"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        body

      other ->
        Mix.raise("Failed to download #{url}: #{inspect(other)}")
    end
  end
end
