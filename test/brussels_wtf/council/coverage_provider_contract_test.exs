defmodule BrusselsWtf.Council.CoverageProviderContractTest do
  use BrusselsWtfWeb.ConnCase, async: false

  defmodule AlternateRecordedProvider do
    @behaviour BrusselsWtf.Processors
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    defdelegate extract(meta, bytes), to: BrusselsWtf.Processors.Stub

    @impl true
    defdelegate normalize(extracted), to: BrusselsWtf.Processors.Stub

    @impl true
    defdelegate generate_fr(normalized), to: BrusselsWtf.Processors.Stub

    @impl true
    defdelegate translate(canonical, locale), to: BrusselsWtf.Processors.Stub

    @impl true
    def maximum_cost(_operation, _input), do: {:ok, 0}

    @impl true
    def metadata do
      %{
        processor_name: "alternate-recorded-generator",
        processor_version: "2026-08",
        config_hash: "sha256:alternate-recorded-contract",
        provider_category: "recorded_fixture",
        billing_mode: :recorded,
        network_access: :none,
        model: "alternate-fixture",
        canonical_method: :ai_generation,
        translation_method: :machine_translation,
        usage: %{"fixture" => true, "network_calls" => 0}
      }
    end
  end

  test "provider replacement preserves the domain contract and public copy", %{conn: conn} do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)
    previous_coverage = Application.fetch_env!(:brussels_wtf, :coverage_processor)
    Application.put_env(:brussels_wtf, :processors, AlternateRecordedProvider)
    Application.put_env(:brussels_wtf, :coverage_processor, AlternateRecordedProvider)

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous_processors)
      Application.put_env(:brussels_wtf, :coverage_processor, previous_coverage)
    end)

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    page_id = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page) |> Map.fetch!(:id)
    page = BrusselsWtf.Council.get_meeting_page!(page_id)

    assert page.publication_status == :published

    assert BrusselsWtf.Council.list_coverage_runs!(page.id)
           |> Enum.all?(&(&1.processor_name == "alternate-recorded-generator"))

    html = conn |> get("/meetings/ixelles/268?lang=en") |> html_response(200)
    assert html =~ scenario.expected.title_en
    assert html =~ scenario.expected.proposal_text
  end

  test "production recorded coverage satisfies the publication contract", %{conn: conn} do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    previous = Application.fetch_env!(:brussels_wtf, :coverage_processor)

    Application.put_env(
      :brussels_wtf,
      :coverage_processor,
      BrusselsWtf.Processors.RecordedCoverage
    )

    on_exit(fn -> Application.put_env(:brussels_wtf, :coverage_processor, previous) end)

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")

    for queue <- [:poll, :fetch, :extract, :normalize] do
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: queue, with_safety: false)
    end

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    input = BrusselsWtf.Council.Publication.generation_input(meeting.id)
    assert {:ok, canonical} = BrusselsWtf.Processors.RecordedCoverage.generate_fr(input)
    assert {:ok, nl} = BrusselsWtf.Processors.RecordedCoverage.translate(canonical, "nl")
    assert :ok = BrusselsWtf.Council.GenerationContract.validate_bundle(input, canonical, "fr")
    assert :ok = BrusselsWtf.Council.GenerationContract.validate_bundle(input, nl, "nl")
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :publish, with_safety: false)
    page_id = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page) |> Map.fetch!(:id)
    page = BrusselsWtf.Council.get_meeting_page!(page_id)

    assert page.publication_status == :published

    assert BrusselsWtf.Council.list_coverage_runs!(page.id)
           |> Enum.all?(&(&1.processor_name == "recorded-ixelles-coverage"))

    html = conn |> get("/meetings/ixelles/268?lang=nl") |> html_response(200)
    assert html =~ "Voorgestelde subsidie voor een vertoning"
    assert html =~ scenario.expected.proposal_text
  end
end
