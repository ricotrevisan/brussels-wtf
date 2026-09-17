defmodule BrusselsWtf.Contracts.OpenRouterLiveTest do
  use ExUnit.Case, async: false

  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Council

  alias BrusselsWtf.Council.{
    CoverageBudget,
    CoverageExecution,
    CoverageReservation,
    GenerationContract,
    PublicationInput
  }

  alias BrusselsWtf.Processors.OpenRouterCoverage

  @moduletag :external
  @moduletag timeout: 240_000

  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(BrusselsWtf.Repo,
        shared: true,
        ownership_timeout: 300_000
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    keys = [:coverage_generation, :coverage_processor, OpenRouterCoverage]
    previous = Map.new(keys, &{&1, Application.fetch_env(:brussels_wtf, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, config} -> Application.put_env(:brussels_wtf, key, config)
          :error -> Application.delete_env(:brussels_wtf, key)
        end
      end
    end)

    :ok
  end

  test "three bounded live calls validate real Ixelles 269 coverage without publishing" do
    key = System.get_env("OPENROUTER_API_KEY")

    assert is_binary(key) and String.trim(key) != "",
           "OPENROUTER_API_KEY is required for this opt-in test"

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    # Only the private test page/reservation owner comes from the fixture.
    # Every byte sent to the provider below comes from the real current manifest.
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert Council.list_coverage_runs!(page.id) == []

    input = real_publication_input()
    assert input["meeting_identifier"] == "269"
    assert Enum.map(input["items"], & &1["key"]) == ~w(38 39)
    assert :ok = PublicationInput.validate(input)
    assert {:ok, _recorded_reference} = Manifest.recorded_bundle(input, "fr")

    Application.put_env(:brussels_wtf, :coverage_processor, OpenRouterCoverage)
    Application.put_env(:brussels_wtf, OpenRouterCoverage, api_key: key)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 100
    })

    metadata = OpenRouterCoverage.metadata()

    try do
      # No retry loop: stop on the first failure, at most three adapter requests.
      assert {:ok, canonical, canonical_run} =
               CoverageExecution.canonical(page, input, metadata, :automatic, 1)

      assert :ok = GenerationContract.validate_bundle(input, canonical, "fr")

      for locale <- ~w(nl en) do
        assert {:ok, translated, _run} =
                 CoverageExecution.translation(
                   page,
                   canonical_run,
                   canonical,
                   locale,
                   metadata,
                   :automatic,
                   1
                 )

        assert :ok = GenerationContract.validate_bundle(input, translated, locale)
      end

      runs = Council.list_coverage_runs!(page.id)
      assert length(runs) == 3
      assert Enum.all?(runs, &(&1.status == :succeeded and &1.model in metadata.allowed_models))
      assert Enum.all?(Ash.read!(CoverageReservation, domain: Council), &(&1.status == :settled))
      assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
      assert budget.spent_cents <= 100
      assert budget.reserved_cents == 0
      assert Council.get_meeting_page!(page.id).publication_status == :draft
      assert Council.list_publication_revisions!(page.id) == []

      print_receipts(page)
      Process.put(:openrouter_live_receipts_printed, true)
    after
      # Print only allowlisted receipts; never credentials, headers, or provider bodies.
      unless Process.get(:openrouter_live_receipts_printed) do
        try do
          print_receipts(page)
        rescue
          _ -> IO.puts("OPENROUTER_LIVE_RECEIPTS_ERROR=unavailable")
        end
      end
    end
  end

  defp print_receipts(page) do
    receipts =
      Enum.map(Council.list_coverage_runs!(page.id), fn run ->
        %{
          locale: run.locale,
          model: run.usage["model"],
          status: run.status,
          cost_cents: run.usage["cost_cents"],
          input_tokens: run.usage["input_tokens"],
          output_tokens: run.usage["output_tokens"],
          network_calls: run.usage["network_calls"],
          failure: run.failure_details["classification"],
          http_status: run.failure_details["http_status"]
        }
      end)

    IO.puts("OPENROUTER_LIVE_RECEIPTS=" <> Jason.encode!(receipts))
  end

  defp real_publication_input do
    manifest = Manifest.load!("current-20260911")
    meeting = Enum.find(manifest["meetings"], &(&1["key"] == "ixelles-269"))

    %{
      "commune_slug" => meeting["commune"],
      "meeting_identifier" => meeting["municipal_identifier"],
      "scheduled_on" => meeting["scheduled_on"],
      "items" =>
        Enum.map(meeting["items"], fn item ->
          source = Enum.find(meeting["sources"], &(&1["name"] == item["source"]))
          proposal = item["proposal"]

          %{
            "key" => item["key"],
            "item_number" => item["item_number"],
            "procedural_state" => item["state"],
            "outcome" => item["outcome"],
            "source_wording" => item["source_wording"],
            "claims" => [
              %{
                "key" => "proposal:#{item["key"]}:#{source["sha256"]}",
                "kind" => "proposal",
                "text" => proposal["text"],
                "evidence" => [
                  %{
                    "citation_url" => source["url"],
                    "source_origin_url" => source["url"],
                    "source_sha256" => source["sha256"],
                    "retrieved_at" => source["captured_at"],
                    "excerpt" => proposal["excerpt"],
                    "location" => proposal["location"],
                    "synthetic" => false
                  }
                ]
              }
            ]
          }
        end)
    }
  end
end
