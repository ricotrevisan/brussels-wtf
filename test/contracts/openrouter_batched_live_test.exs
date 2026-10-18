defmodule BrusselsWtf.Contracts.OpenRouterBatchedLiveTest do
  use ExUnit.Case, async: false

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
  @moduletag timeout: 900_000

  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(BrusselsWtf.Repo,
        shared: true,
        ownership_timeout: 900_000
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

  # The input is a real meeting's publication input exported to a private local
  # file (see docs/operations/publication.md); it is never committed.
  test "one real multi-batch meeting generates valid FR/NL/EN coverage without publishing" do
    key = System.get_env("OPENROUTER_API_KEY")
    path = System.get_env("OPENROUTER_LIVE_INPUT")
    assert is_binary(key) and String.trim(key) != "", "OPENROUTER_API_KEY is required"
    assert is_binary(path) and File.regular?(path), "OPENROUTER_LIVE_INPUT must name a file"

    input = path |> File.read!() |> Jason.decode!()
    assert :ok = PublicationInput.validate(input)
    assert {:ok, [_, _ | _] = batches} = OpenRouterCoverage.batch_keys(input)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    # Only the private test page/reservation owner comes from the fixture.
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_processor, OpenRouterCoverage)
    Application.put_env(:brussels_wtf, OpenRouterCoverage, api_key: key)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 100
    })

    metadata = OpenRouterCoverage.metadata()

    try do
      # No operation retry loop: exactly one FR, one NL and one EN operation.
      assert {:ok, canonical, canonical_run} =
               CoverageExecution.canonical(page, input, metadata, :automatic, 1)

      assert :ok = GenerationContract.validate_bundle(input, canonical, "fr")
      File.write!(path <> ".fr.json", Jason.encode!(canonical, pretty: true))

      bundles =
        for locale <- ~w(nl en), into: %{"fr" => canonical} do
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
          {locale, translated}
        end

      File.write!(path <> ".coverage.json", Jason.encode!(bundles, pretty: true))

      runs = Council.list_coverage_runs!(page.id)
      assert length(runs) == 3
      assert Enum.all?(runs, &(&1.status == :succeeded))
      assert Enum.all?(Ash.read!(CoverageReservation, domain: Council), &(&1.status == :settled))
      assert {:ok, budget} = CoverageBudget.ensure_month(100, BrusselsWtf.Clock.utc_now())
      assert budget.reserved_cents == 0
      assert Council.get_meeting_page!(page.id).publication_status == :draft
      assert Council.list_publication_revisions!(page.id) == []
      IO.puts("OPENROUTER_LIVE_BATCHES=#{length(batches)}")
    after
      print_receipts(page)
    end
  end

  # Allowlisted receipts only; never credentials, headers, prompts or provider bodies.
  defp print_receipts(page) do
    receipts =
      Enum.map(Council.list_coverage_runs!(page.id), fn run ->
        %{
          locale: run.locale,
          status: run.status,
          model: run.model,
          duration_ms: run.duration_ms,
          failure: run.failure_details["classification"],
          usage: Map.drop(run.usage, ["calls"]),
          calls:
            Enum.map(run.usage["calls"] || [], fn call ->
              %{
                part: call["part"],
                stages:
                  Enum.map(
                    call["stages"],
                    &Map.take(&1, ~w(requested_model provider status http_status input_tokens
                      output_tokens cost_microusd cost_known duration_ms))
                  )
              }
            end)
        }
      end)

    IO.puts("OPENROUTER_LIVE_RECEIPTS=" <> Jason.encode!(receipts))
  rescue
    _ -> IO.puts("OPENROUTER_LIVE_RECEIPTS_ERROR=unavailable")
  end
end
