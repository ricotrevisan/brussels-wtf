defmodule BrusselsWtf.Test.Harness do
  @moduledoc """
  Loads a municipal fixture scenario and drives the principal acceptance seam.
  """

  alias BrusselsWtf.Ingestion

  @fixtures Path.expand("fixtures", __DIR__)
  @queues [:poll, :fetch, :extract, :normalize, :publish]

  def load(name) do
    dir = Path.join(@fixtures, name)
    scenario = read_json(Path.join(dir, "scenario.json"))
    index = File.read!(Path.join(dir, "index.html"))
    source = File.read!(Path.join(dir, scenario["source_path"]))
    sha256 = BrusselsWtf.Digest.sha256(source)
    {:ok, observed_at, _} = DateTime.from_iso8601(scenario["observed_at"])

    reset_adapters()
    BrusselsWtf.Clock.Controlled.set(observed_at)
    BrusselsWtf.HTTP.Stub.put(scenario["index_url"], %{body: index})
    BrusselsWtf.HTTP.Stub.put(scenario["source_url"], %{body: source})

    BrusselsWtf.Processors.Stub.put(sha256, %{
      extract: read_json(Path.join(dir, "processors/extract.json")),
      normalize: read_json(Path.join(dir, "processors/normalize.json")),
      locales: read_json(Path.join(dir, "processors/locales.json"))
    })

    commune =
      Ingestion.create_commune!(%{
        slug: scenario["commune"],
        name: commune_name(scenario["commune"]),
        index_url: scenario["index_url"]
      })

    %{
      commune: commune,
      sha256: sha256,
      expected: %{
        path: scenario["expected"]["path"],
        title_en: scenario["expected"]["title_en"],
        citation_url: scenario["source_url"]
      }
    }
  end

  def drain_pipeline do
    Enum.each(@queues, fn queue ->
      result = Oban.drain_queue(queue: queue, with_safety: false)

      if result.failure > 0 or result.discard > 0 do
        raise "pipeline queue #{queue} failed: #{inspect(result)}"
      end
    end)

    :ok
  end

  defp reset_adapters do
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
  end

  defp read_json(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp commune_name("ixelles"), do: "Ixelles"
  defp commune_name("uccle"), do: "Uccle"
  defp commune_name("forest"), do: "Forest"
  defp commune_name("city-of-brussels"), do: "City of Brussels"
end
