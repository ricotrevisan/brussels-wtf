defmodule BrusselsWtf.Ingestion.ProcessorContextTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Processors.Council

  @ixelles_url "https://example.test/ixelles/268/agenda.pdf"

  defmodule CapturingProcessor do
    @moduledoc false
    @behaviour BrusselsWtf.Processors

    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    def inputs, do: Agent.get(__MODULE__, & &1)

    @impl true
    def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

    @impl true
    def normalize(input) do
      Agent.update(__MODULE__, &[input | &1])
      {:error, :processor_unimplemented}
    end
  end

  setup do
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)

    on_exit(fn -> Application.put_env(:brussels_wtf, :processors, previous_processors) end)

    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 02:30:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/ixelles"
      })

    {:ok, commune: commune}
  end

  test "the processor receives the explicit discovery context of a locator-bearing run", %{
    commune: commune
  } do
    {run, version} = locator_run(commune)
    start_supervised!({CapturingProcessor, []})
    Application.put_env(:brussels_wtf, :processors, CapturingProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @ixelles_url)

    assert [input] = CapturingProcessor.inputs()

    assert input["commune_slug"] == "ixelles"
    assert input["origin_url"] == @ixelles_url
    assert input["role"] == "agenda"
    assert input["language"] == "fr"
    assert input["meeting_identifier"] == "268"
    assert input["scheduled_on"] == "2026-07-02"
    assert input["item_identifier"] == "4"
    assert input["dossier_identifier"] == "OPP/2026/185"

    assert input["sha256"] == version.sha256
    assert input["quality_accepted"] == true
    assert is_integer(input["page_count"])
    assert is_binary(input["text"])
  end

  test "a run without a locator degrades to nil identifiers instead of failing", %{
    commune: commune
  } do
    {run, _version} = locator_run(commune, locator?: false)
    start_supervised!({CapturingProcessor, []})
    Application.put_env(:brussels_wtf, :processors, CapturingProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @ixelles_url)

    assert [input] = CapturingProcessor.inputs()

    assert input["commune_slug"] == "ixelles"
    assert input["origin_url"] == @ixelles_url
    assert input["meeting_identifier"] == nil
    assert input["scheduled_on"] == nil
    assert input["item_identifier"] == nil
    assert input["dossier_identifier"] == nil

    # The source record still carries the role and language observed at retrieval.
    assert input["role"] == "agenda"
    assert input["language"] == "fr"
  end

  test "an unseen Ixelles hash never reaches the commune branch as a silent success", %{
    commune: commune
  } do
    {run, version} = locator_run(commune)
    Application.put_env(:brussels_wtf, :processors, Council)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @ixelles_url)

    assert BrusselsWtf.Corpus.Manifest.normalize(%{
             "sha256" => version.sha256,
             "text" => accepted_text()
           }) == {:error, :processor_unimplemented}

    if commune_normalizer_loaded?() do
      # Once the commune normalizer lands it owns this hash. The pipeline contract is
      # unchanged: nothing publishes itself without passing through the existing
      # review fallbacks.
      refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
    else
      assert [review_case] =
               BrusselsWtf.Review.list_review_cases!(
                 %{kind: :normalization, status: :open},
                 authorize?: false
               )

      assert review_case.processing_generation == "normalization:#{run.id}"
      assert review_case.summary == "Automatic normalization is unavailable and requires review"
      refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
    end
  end

  defp locator_run(commune, opts \\ []) do
    now = BrusselsWtf.Clock.utc_now()

    if Keyword.get(opts, :locator?, true) do
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: @ixelles_url,
        parent_index_url: "https://example.test/ixelles/index",
        meeting_identifier: "268",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :fr,
        observed_label: "Ordre du jour du 2 juillet 2026",
        item_identifier: "4",
        dossier_identifier: "OPP/2026/185",
        discovered_at: now
      })
    end

    bytes = "%PDF recorded processor context fixture"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: @ixelles_url,
        role: :agenda,
        original_language: :fr
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archived.sha256,
        byte_size: byte_size(bytes),
        media_type: "application/pdf",
        object_key: archived.object_key,
        first_retrieved_at: now
      })

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{"text" => accepted_text(), "quality" => "accepted"}
    })

    assert :ok = Ingestion.Pipeline.extract(version.id)

    run =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :native_extraction))

    {run, version}
  end

  defp accepted_text do
    "Conseil communal d'Ixelles ordre du jour public avec contenu officiel suffisant"
  end

  defp commune_normalizer_loaded? do
    Code.ensure_loaded?(BrusselsWtf.Processors.IxellesCouncil) and
      function_exported?(BrusselsWtf.Processors.IxellesCouncil, :normalize, 1)
  end
end
