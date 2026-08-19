defmodule BrusselsWtf.Council.CoverageProviderContractTest do
  use BrusselsWtfWeb.ConnCase, async: false

  defmodule AlternateRecordedProvider do
    @behaviour BrusselsWtf.Processors

    @impl true
    defdelegate extract(meta, bytes), to: BrusselsWtf.Processors.Stub

    @impl true
    defdelegate normalize(extracted), to: BrusselsWtf.Processors.Stub

    @impl true
    defdelegate generate_fr(normalized), to: BrusselsWtf.Processors.Stub

    @impl true
    defdelegate translate(canonical, locale), to: BrusselsWtf.Processors.Stub

    @impl true
    def coverage_metadata do
      %{
        processor_name: "alternate-recorded-generator",
        processor_version: "2026-08",
        config_hash: "sha256:alternate-recorded-contract",
        provider_category: "recorded_fixture",
        model: "alternate-fixture",
        usage: %{"fixture" => true}
      }
    end
  end

  test "provider replacement preserves the domain contract and public copy", %{conn: conn} do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    previous = Application.fetch_env!(:brussels_wtf, :processors)
    Application.put_env(:brussels_wtf, :processors, AlternateRecordedProvider)
    on_exit(fn -> Application.put_env(:brussels_wtf, :processors, previous) end)

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    assert page.publication_status == :published

    assert BrusselsWtf.Council.list_coverage_runs!(page.id)
           |> Enum.all?(&(&1.processor_name == "alternate-recorded-generator"))

    html = conn |> get("/meetings/ixelles/268?lang=en") |> html_response(200)
    assert html =~ scenario.expected.title_en
    assert html =~ scenario.expected.proposal_text
  end
end
