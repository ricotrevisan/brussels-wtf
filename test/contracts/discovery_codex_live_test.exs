defmodule BrusselsWtf.Contracts.DiscoveryCodexLiveTest do
  @moduledoc """
  Private real-source smoke, not a production activation or extraction benchmark.

      DISCOVERY_CODEX_LIVE=1 DISCOVERY_CODEX_COMMUNES=ixelles \\
        ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=_discovery_live \\
        timeout 600s mix test test/contracts/discovery_codex_live_test.exs --include external

  Requires local Poppler, discovery-codex:0.155.0 and owner-only ChatGPT auth at
  /home/rico/.codex/auth.json. Four calls maximum, no retries/fallback provider.
  Set DISCOVERY_CODEX_COMMUNES=ixelles or =uccle (comma-separated allowlist) to
  compile ONLY those commune tests; ExUnit include/exclude cannot expand it.
  Optional DISCOVERY_CODEX_CAPTURE_DIR retains parsed invalid input/results in
  fresh mode-0600 files under a private directory for offline diagnosis. Remove
  captures after review. Replay with python3 scripts/discovery_smoke_runner.py
  --replay /private/captures/ixelles-invalid.json (no inference).
  Each call has a 90-second execution cap plus bounded container cleanup. The
  sandbox rolls back private mentions; temporary input/results are mode 0600
  under a mode 0700 directory and removed on exit. No raw evidence is printed,
  including on failure. Ordinary tests exclude :external; even --include external
  cannot invoke this test without the separate environment opt-in. Do not combine
  --include external with commune exclusions: ExUnit inclusion takes precedence.

  Accumulated lab receipts (2026-09-20), gpt-5.6-sol, exact backend schema:
  - Ixelles final single-call verification: 25 mentions, 9805 input / 1814 output tokens.
  - Uccle preceding prompt revision: 20 mentions, 9607 input / 1248 output tokens.
  - Forest initial pass: 49 mentions, 9314 input / 1716 output tokens.
  - City of Brussels initial pass: 19 mentions, 9591 input / 803 output tokens.
  All four PDFs passed native quality; accepted paths left protected identity
  and publication counts unchanged. These receipts span different prompt
  revisions, not a simultaneous four-commune run or a recall benchmark.

  The private Ixelles diagnostic capture had 26 candidates and was rejected
  by the former text_in_line_ambiguous check at indexes 16 and 19. The agreed
  evidence rule requires exactly TWO unique spans: quote within line, text
  within quote. Repetition elsewhere in the line is immaterial. The unchanged
  capture now passes Python AND backend validation with all 26 candidates;
  the private capture file/directory were deleted after offline proof. A
  synthetic regression preserves this case without committing source text.
  (line_id, text) uniqueness, Unicode boundaries and UTF-8 byte caps remain.
  Minimum string lengths now use code points, matching JSON Schema and Python.

  Call accounting: five initial invocations (including the accidental excluded
  Ixelles call), two separately authorized diagnostic calls, and one final
  authorized Ixelles-only call. No further calls or deployment. See sanitized
  receipts in docs/specs/private-discovery.md. Offline tests do not authorize
  live calls, and these bounded smoke receipts are not production activation.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  require Ash.Query

  alias BrusselsWtf.{Archive, Clock, Council, Discovery, Identity, Ingestion, Repo}
  alias BrusselsWtf.Corpus.{Import, Manifest}

  @endpoint BrusselsWtfWeb.Endpoint
  @actor %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
  @moduletag :external
  @moduletag timeout: 140_000
  @moduletag skip: System.get_env("DISCOVERY_CODEX_LIVE") != "1"

  # One born-digital, hash-pinned source per commune. Native quality is never
  # overridden; a rejected source must be replaced, not sent through this smoke.
  @sources [
    {"ixelles", "ixelles-268", "primary"},
    {"uccle", "uccle-2026-04-23", "primary"},
    {"forest", "forest-2026-03-24", "primary"},
    {"city-of-brussels", "city-2026-06-08", "primary"}
  ]

  @selected_sources (case System.get_env("DISCOVERY_CODEX_COMMUNES") do
                       nil ->
                         @sources

                       value ->
                         names = String.split(value, ",", trim: true)
                         allowed = Enum.map(@sources, &elem(&1, 0))

                         if names == [] or Enum.any?(names, &(&1 not in allowed)) do
                           raise ArgumentError, "invalid discovery commune allowlist"
                         end

                         Enum.filter(@sources, &(elem(&1, 0) in names))
                     end)

  setup do
    assert System.get_env("MIX_TEST_PARTITION") == "_discovery_live"
    assert Repo.config()[:database] == "brussels_wtf_test_discovery_live"

    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo,
        shared: true,
        ownership_timeout: 160_000
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    keys = [:archive, :pdf_processor, :coverage_generation, :discovery_token_digest]
    previous = Map.new(keys, &{&1, Application.fetch_env(:brussels_wtf, &1)})
    previous_time = Clock.utc_now()
    previous_archive = Agent.get(Archive.Memory, & &1)
    directory = Path.join(System.tmp_dir!(), "discovery-live-#{Ash.UUID.generate()}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    on_exit(fn ->
      File.rm_rf!(directory)
      Agent.update(Archive.Memory, fn _ -> previous_archive end)
      Clock.Controlled.set(previous_time)

      for {key, value} <- previous do
        case value do
          {:ok, config} -> Application.put_env(:brussels_wtf, key, config)
          :error -> Application.delete_env(:brussels_wtf, key)
        end
      end
    end)

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Application.put_env(:brussels_wtf, :archive, Archive.Memory)
    Application.put_env(:brussels_wtf, :pdf_processor, BrusselsWtf.PDF.PopplerOcr)
    Application.put_env(:brussels_wtf, :coverage_generation, %{mode: :disabled})
    Application.put_env(:brussels_wtf, :discovery_token_digest, BrusselsWtf.Digest.sha256(token))
    Archive.Memory.reset()
    Clock.Controlled.set(DateTime.utc_now())
    {:ok, directory: directory, token: token}
  end

  for {commune, key, name} <- @selected_sources do
    @tag commune: commune
    test "#{commune} real PDF reaches validated private mentions through Codex and HTTP",
         context do
      commune = unquote(commune)

      # Never let ExUnit inspect private Ash errors, HTTP bodies or model output.
      try do
        phase("#{commune}:preflight")
        assert Application.get_env(:brussels_wtf, Oban)[:testing] == :manual
        assert Ash.count!(Discovery.Job, authorize?: false) == 0
        before_counts = protected_counts()
        before_mentions = Ash.count!(Identity.Mention)
        {^commune, run} = import_and_extract!({commune, unquote(key), unquote(name)})
        phase("#{commune}:enqueue")
        {:ok, batch} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
        assert length(batch.job_ids) in 1..8
        Clock.Controlled.set(DateTime.utc_now())
        claim = request("/internal/discovery/claim", %{}, context.token, 200)
        assert is_map(claim)
        assert claim["id"] in batch.job_ids

        # Send the exact backend schema (const/minLength included) to OpenAI.
        assert claim["schema"] == Discovery.Input.schema()
        phase("#{commune}:codex")

        {payload, usage} =
          try do
            infer!(claim, context.directory, commune)
          after
            assert protected_counts() == before_counts
            assert Ash.count!(Identity.Mention) == before_mentions
          end

        phase("#{commune}:submit")
        Clock.Controlled.set(DateTime.utc_now())
        path = "/internal/discovery/#{claim["id"]}/result"
        _ack = request(path, payload, context.token, 200)
        {:ok, status} = Discovery.status(batch.batch_id, actor: @actor)
        completed = Enum.filter(status.jobs, &(&1.state == :completed))
        assert length(completed) == 1
        job = hd(completed)
        assert job.id == claim["id"]
        assert job.attempts == 1
        assert job.mention_count > 0

        mentions =
          Identity.Mention
          |> Ash.read!()
          |> Enum.filter(&(&1.context["discovery_job_id"] == job.id))

        assert length(mentions) == job.mention_count
        assert Enum.all?(mentions, &(&1.resolution_status == :unresolved))
        assert Enum.all?(mentions, &(&1.context["extraction_run_id"] == run.id))
        assert Ash.count!(Identity.Mention) == before_mentions + job.mention_count
        assert protected_counts() == before_counts

        # No normalizer, publication or polling loop runs. Other chunks are
        # paused, then the entire per-source sandbox rolls back before the next
        # test (including on failure). Global pauses never leak across communes.
        {:ok, paused} = Discovery.pause(actor: @actor)
        assert paused.paused == length(batch.job_ids) - 1
        assert request("/internal/discovery/claim", %{}, context.token, 204) == nil
        receipt = %{commune: commune, jobs: 1, mentions: job.mention_count, usage: usage}
        IO.puts("DISCOVERY_CODEX_LIVE=" <> Jason.encode!(receipt))
      rescue
        error ->
          flunk(
            "private smoke failed at #{Process.get(:smoke_phase)} (#{inspect(error.__struct__)})"
          )
      end
    end
  end

  defp import_and_extract!({commune, key, name}) do
    phase("#{commune}:native_extraction")
    batch = Import.request!([key], @actor)
    assert Import.import_source(batch.id, key, name) == :ok
    batch = Council.get_corpus_import_batch!(batch.id)
    assert length(batch.source_version_ids) == 1
    version_id = hd(batch.source_version_ids)
    version = Ingestion.get_source_version!(version_id)
    source = Enum.find(Manifest.meeting!(key)["sources"], &(&1["name"] == name))
    assert version.sha256 == source["sha256"]
    {:ok, bytes} = Archive.get(version.object_key)
    assert BrusselsWtf.Digest.sha256(bytes) == source["sha256"]
    assert Ingestion.Pipeline.extract(version_id, 1, :backfill) == :ok

    runs =
      Ingestion.ProcessingRun
      |> Ash.Query.filter(
        source_version_id == ^version_id and processor_role == :native_extraction
      )
      |> Ash.read!()

    assert length(runs) == 1
    run = hd(runs)
    assert run.status == :succeeded
    assert run.processor_name == "poppler-native-text"
    assert run.quality_measurements["accepted"] == true
    {:ok, preview} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)
    assert preview.job_count in 1..8
    {commune, run}
  end

  defp infer!(claim, directory, commune) do
    job_path = Path.join(directory, "#{commune}-job.json")
    result_path = Path.join(directory, "#{commune}-result.json")
    File.write!(job_path, Jason.encode!(claim))
    File.chmod!(job_path, 0o600)

    capture_args =
      case System.get_env("DISCOVERY_CODEX_CAPTURE_DIR") do
        nil -> []
        path -> ["--capture-invalid", Path.join(path, "#{commune}-invalid.json")]
      end

    {output, code} =
      System.cmd(
        "python3",
        [
          "scripts/discovery_smoke_runner.py",
          "--job",
          job_path,
          "--result",
          result_path,
          "--auth",
          "/home/rico/.codex/auth.json",
          "--state",
          directory,
          "--model",
          "gpt-5.6-sol"
        ] ++ capture_args,
        stderr_to_stdout: true
      )

    usage =
      Regex.scan(
        ~r/\b(input_tokens|cached_input_tokens|output_tokens|reasoning_output_tokens)=(\d+)\b/,
        output
      )
      |> Map.new(fn [_, key, value] -> {key, String.to_integer(value)} end)

    if code != 0 do
      reason =
        case Regex.run(
               ~r/smoke_failure=(quota|unavailable|invalid_output|timeout|configuration_or_contract)\b/,
               output
             ) do
          [_, reason] -> reason
          _ -> "runner_exit"
        end

      diagnostic =
        case Regex.run(
               ~r/validation_failure code=([a-z_]{1,64}) index=(-?\d+) count=(\d+)/,
               output
             ) do
          [_, code, index, count] ->
            %{code: code, index: String.to_integer(index), count: String.to_integer(count)}

          _ ->
            nil
        end

      phase("#{commune}:codex:#{reason}")

      IO.puts(
        "DISCOVERY_CODEX_LIVE=" <>
          Jason.encode!(%{
            commune: commune,
            jobs: 1,
            mentions: 0,
            usage: usage,
            failure: reason,
            diagnostic: diagnostic
          })
      )
    end

    assert code == 0
    payload = result_path |> File.read!() |> Jason.decode!()
    File.rm!(job_path)
    File.rm!(result_path)

    assert is_integer(usage["input_tokens"]) and usage["input_tokens"] > 0
    assert is_integer(usage["output_tokens"]) and usage["output_tokens"] > 0
    {payload, usage}
  end

  defp request(path, body, token, expected) do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

    # No json_response/response assertion: they print the body on a mismatch.
    assert conn.status == expected
    if expected == 204, do: nil, else: Jason.decode!(conn.resp_body)
  end

  defp protected_counts do
    Map.new(
      [
        Identity.Person,
        Identity.LegalEntity,
        Identity.SourcedFact,
        Council.AgendaItem,
        Council.MeetingPage,
        Council.PublicationRevision,
        Council.CoverageRun
      ],
      &{&1, Ash.count!(&1)}
    )
  end

  defp phase(name), do: Process.put(:smoke_phase, name)
end
