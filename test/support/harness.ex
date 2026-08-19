defmodule BrusselsWtf.Test.Harness do
  @moduledoc """
  Loads versioned municipal evidence scenarios and drives the principal seam.
  """

  alias BrusselsWtf.Ingestion

  @fixtures Path.expand("fixtures", __DIR__)
  @queues [:poll, :fetch, :extract, :ocr, :normalize, :publish]

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

        outputs = maybe_put_ocr(outputs, processor_dir)

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
      fixture_dir: dir,
      scenario: scenario,
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

  def advance(stage_name) when is_binary(stage_name) do
    loaded = Application.fetch_env!(:brussels_wtf, :loaded_test_scenario)
    stage = get_in(loaded.scenario, ["stages", stage_name]) || raise "unknown fixture stage"
    index = File.read!(Path.join(loaded.fixture_dir, stage["index_fixture_path"]))

    if BrusselsWtf.Digest.sha256(index) != stage["index_fixture_sha256"] do
      raise "captured stage index hash does not match scenario manifest"
    end

    {:ok, observed_at, _} = DateTime.from_iso8601(stage["observed_at"])
    BrusselsWtf.Clock.Controlled.set(observed_at)

    BrusselsWtf.HTTP.Stub.put(loaded.index_url, %{
      body: index,
      headers: stage["index_response"]["headers"]
    })

    coverage =
      loaded.fixture_dir
      |> Path.join(stage["coverage_fixture_path"])
      |> File.read!()
      |> Jason.decode!()

    BrusselsWtf.Processors.Stub.put_locales(loaded.scenario["meeting_identifier"], coverage)

    Enum.each(List.wrap(stage["source_changes"]), fn change ->
      name = String.to_existing_atom(change["name"])
      bytes = File.read!(Path.join(loaded.fixture_dir, change["fixture_path"]))
      processor_dir = Path.join(loaded.fixture_dir, change["processor_path"])

      outputs = %{
        extract: read_json(Path.join(processor_dir, "extract.json")),
        normalize: read_json(Path.join(processor_dir, "normalize.json")),
        locales: read_json(Path.join(processor_dir, "locales.json"))
      }

      outputs = maybe_put_ocr(outputs, processor_dir)

      respond_with_changed_source(name, bytes, outputs)
    end)

    :ok
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
    from = Keyword.get(opts, :from, :poll)
    until_queue = Keyword.get(opts, :until, List.last(@queues))

    queues =
      @queues
      |> Enum.drop_while(&(&1 != from))
      |> Enum.take_while(&(&1 != until_queue))
      |> Kernel.++([until_queue])

    Enum.each(queues, &drain_queue!/1)
    :ok
  end

  defp drain_queue!(queue) do
    result = Oban.drain_queue(queue: queue, with_safety: false)

    if result.failure > 0 or result.discard > 0 do
      raise "pipeline queue #{queue} failed: #{inspect(result)}"
    end

    if result.success > 0, do: drain_queue!(queue), else: :ok
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

  defp maybe_put_ocr(outputs, processor_dir) do
    path = Path.join(processor_dir, "ocr.json")
    if File.exists?(path), do: Map.put(outputs, :ocr, read_json(path)), else: outputs
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp atomize_keys(map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)

  defp commune_name("ixelles"), do: "Ixelles"
  defp commune_name("uccle"), do: "Uccle"
  defp commune_name("forest"), do: "Forest"
  defp commune_name("city-of-brussels"), do: "City of Brussels"
end
