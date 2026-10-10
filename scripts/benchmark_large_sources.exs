# Run with MIX_ENV=test and the RUSTFS_CONTRACT_* fixture environment.
# This opt-in benchmark uses a caller-owned temporary file and never queues coverage.
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:bandit)
alias BrusselsWtf.{Archive, HTTP, Digest}
alias BrusselsWtf.Archive.S3

Application.put_env(:brussels_wtf, :http, BrusselsWtf.HTTP.Req)
Application.put_env(:brussels_wtf, :archive, S3)

Application.put_env(:brussels_wtf, S3,
  bucket: System.fetch_env!("RUSTFS_CONTRACT_BUCKET"),
  req_options: [
    aws_endpoint_url_s3: System.fetch_env!("RUSTFS_CONTRACT_ENDPOINT"),
    aws_sigv4: [
      access_key_id: System.fetch_env!("RUSTFS_CONTRACT_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("RUSTFS_CONTRACT_SECRET_ACCESS_KEY"),
      region: System.fetch_env!("RUSTFS_CONTRACT_REGION")
    ]
  ]
)

inputs = for mib <- [26, 64, 160], do: {mib, nil}

inputs =
  case System.get_env("LARGE_SOURCE_BENCHMARK_URL") do
    nil -> inputs
    url -> inputs ++ [{nil, url}]
  end

chunk = :binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), 256)

plug = fn conn, _opts ->
  mib = conn.request_path |> String.trim_leading("/") |> String.to_integer()
  conn = Plug.Conn.send_chunked(conn, 200)

  Enum.reduce_while(1..(mib * 16), conn, fn _, conn ->
    case Plug.Conn.chunk(conn, chunk) do
      {:ok, conn} -> {:cont, conn}
      {:error, _} -> {:halt, conn}
    end
  end)
end

{:ok, server} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0)
{:ok, {_, port}} = ThousandIsland.listener_info(server)

rss = fn ->
  [_, value] = Regex.run(~r/^VmRSS:\s+(\d+)/m, File.read!("/proc/self/status"))
  String.to_integer(value) * 1024
end

try do
  for {mib, official_url} <- inputs do
    directory = Path.join(System.tmp_dir!(), "brussels-large-benchmark-#{Ecto.UUID.generate()}")
    File.mkdir!(directory)
    path = Path.join(directory, "source")
    parent = self()
    baseline_rss = rss.()
    baseline_beam = :erlang.memory(:total)
    {:ok, peaks} = Agent.start_link(fn -> %{rss: baseline_rss, beam: baseline_beam} end)

    sampler =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          receive do
            :stop -> :stop
          after
            25 ->
              Agent.update(peaks, fn state ->
                %{rss: max(state.rss, rss.()), beam: max(state.beam, :erlang.memory(:total))}
              end)

              :continue
          end
        end)
        |> Enum.reduce_while(nil, fn status, _ ->
          if status == :stop, do: {:halt, send(parent, :sample_stopped)}, else: {:cont, nil}
        end)
      end)

    try do
      {download_us, {:ok, %{status: 200, byte_size: size} = response}} =
        :timer.tc(fn ->
          HTTP.download(official_url || "http://127.0.0.1:#{port}/#{mib}", path,
            max_body_bytes: BrusselsWtf.Ingestion.SourceLimits.supporting_document_limit()
          )
        end)

      true = size > 0
      expected_size = if mib, do: mib * 1024 * 1024, else: size
      true = response.byte_size == expected_size
      {:ok, expected} = Digest.sha256_file(path)
      {archive_us, {:ok, archived}} = :timer.tc(fn -> Archive.store_file(path) end)
      true = archived.sha256 == expected.sha256 and archived.byte_size == expected_size
      {repeat_us, {:ok, ^archived}} = :timer.tc(fn -> Archive.store_file(path) end)
      send(sampler, :stop)

      receive do
        :sample_stopped -> :ok
      end

      peak = Agent.get(peaks, & &1)

      cgroup_peak =
        case File.read("/sys/fs/cgroup/memory.peak") do
          {:ok, value} -> String.trim(value) |> String.to_integer()
          _ -> nil
        end

      IO.puts(
        Jason.encode!(%{
          mib: mib,
          status: response.status,
          official_url: official_url,
          final_url: response.final_url,
          sha256: archived.sha256,
          byte_size: archived.byte_size,
          baseline_rss: baseline_rss,
          peak_rss: peak.rss,
          baseline_beam: baseline_beam,
          peak_beam: peak.beam,
          cgroup_peak: cgroup_peak,
          download_ms: div(download_us, 1000),
          archive_ms: div(archive_us, 1000),
          repeat_ms: div(repeat_us, 1000),
          temp_bytes: File.stat!(path).size
        })
      )
    after
      send(sampler, :stop)
      Agent.stop(peaks)
      File.rm_rf!(directory)
    end
  end
after
  Process.unlink(server)
  GenServer.stop(server)
end
