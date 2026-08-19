defmodule BrusselsWtf.Test.Harness do
  @moduledoc """
  Loads versioned municipal evidence scenarios and drives the principal seam.
  """

  alias BrusselsWtf.Ingestion

  @fixtures Path.expand("fixtures", __DIR__)
  @queues [:poll, :fetch, :extract, :normalize, :publish]

  def load(name) do
    dir = Path.join(@fixtures, name)
    scenario = read_json(Path.join(dir, "scenario.json"))
    index = File.read!(Path.join(dir, "index.html"))

    if BrusselsWtf.Digest.sha256(index) != scenario["index_fixture_sha256"] do
      raise "captured index fixture hash does not match scenario manifest"
    end

    {:ok, observed_at, _} = DateTime.from_iso8601(scenario["observed_at"])

    reset_adapters()
    BrusselsWtf.Clock.Controlled.set(observed_at)

    BrusselsWtf.HTTP.Stub.put(scenario["index_url"], %{
      body: index,
      headers: scenario["index_response"]["headers"]
    })

    sources =
      scenario["sources"]
      |> Enum.map(fn source ->
        bytes = File.read!(Path.join(dir, source["fixture_path"]))
        sha256 = source["fixture_sha256"]

        if BrusselsWtf.Digest.sha256(bytes) != sha256 do
          raise "captured fixture hash does not match scenario manifest: #{source["name"]}"
        end

        processor_dir = Path.join(dir, source["processor_path"])

        outputs = %{
          extract: read_json(Path.join(processor_dir, "extract.json")),
          normalize: read_json(Path.join(processor_dir, "normalize.json")),
          locales: read_json(Path.join(processor_dir, "locales.json"))
        }

        BrusselsWtf.HTTP.Stub.put(source["url"], %{
          body: bytes,
          headers: source["headers"],
          final_url: source["final_url"],
          redirect_chain: source["redirect_chain"]
        })

        BrusselsWtf.Processors.Stub.put(sha256, outputs)

        {String.to_atom(source["name"]),
         %{
           name: String.to_atom(source["name"]),
           url: source["url"],
           bytes: bytes,
           sha256: sha256,
           outputs: outputs,
           headers: source["headers"],
           final_url: source["final_url"],
           redirect_chain: source["redirect_chain"]
         }}
      end)
      |> Map.new()

    coverage = File.read!(Path.join(dir, scenario["coverage_fixture_path"])) |> Jason.decode!()
    BrusselsWtf.Processors.Stub.put_locales(scenario["meeting_identifier"], coverage)

    commune =
      Ingestion.create_commune!(%{
        slug: scenario["commune"],
        name: commune_name(scenario["commune"]),
        index_url: scenario["index_url"]
      })

    loaded = %{
      commune: commune,
      index_url: scenario["index_url"],
      index_body: index,
      sources: sources,
      coverage: coverage,
      expected: atomize_keys(scenario["expected"])
    }

    Application.put_env(:brussels_wtf, :loaded_test_scenario, loaded)
    loaded
  end

  def respond_with_changed_source(name, bytes, outputs \\ nil) do
    source = source!(name)
    sha256 = BrusselsWtf.Digest.sha256(bytes)
    BrusselsWtf.Processors.Stub.put(sha256, outputs || source.outputs)

    BrusselsWtf.HTTP.Stub.put(source.url, %{
      body: bytes,
      headers: source.headers,
      final_url: source.final_url,
      redirect_chain: source.redirect_chain
    })
  end

  def fail_source(name, reason) do
    BrusselsWtf.HTTP.Stub.put_error(source!(name).url, reason)
  end

  def drain_pipeline(opts \\ []) do
    queues = Enum.drop_while(@queues, &(&1 != Keyword.get(opts, :from, :poll)))

    Enum.each(queues, fn queue ->
      result = Oban.drain_queue(queue: queue, with_safety: false)

      if result.failure > 0 or result.discard > 0 do
        raise "pipeline queue #{queue} failed: #{inspect(result)}"
      end
    end)

    :ok
  end

  defp source!(name) do
    :brussels_wtf
    |> Application.fetch_env!(:loaded_test_scenario)
    |> get_in([:sources, name])
  end

  defp reset_adapters do
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp atomize_keys(map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)

  defp commune_name("ixelles"), do: "Ixelles"
  defp commune_name("uccle"), do: "Uccle"
  defp commune_name("forest"), do: "Forest"
  defp commune_name("city-of-brussels"), do: "City of Brussels"
end
