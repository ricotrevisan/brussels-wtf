defmodule BrusselsWtf.Processors.CoverageRuntimeTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.Processors.CoverageRuntime

  test "defaults preserve recorded publication without requiring a key" do
    assert %{processor: BrusselsWtf.Processors.RecordedCorpusCoverage, provider_config: []} =
             CoverageRuntime.load(fn _ -> nil end)
  end

  test "OpenCode selection requires both a key and bounded paid mode" do
    env = %{
      "COVERAGE_PROCESSOR" => "opencode",
      "COVERAGE_GENERATION_MODE" => "paid",
      "COVERAGE_MONTHLY_BUDGET_CENTS" => "500",
      "OPENCODE_API_KEY" => "test-key-not-real"
    }

    assert %{
             processor: BrusselsWtf.Processors.OpenCodeCoverage,
             generation: %{mode: :paid, monthly_budget_cents: 500},
             provider_config: [api_key: "test-key-not-real"]
           } = CoverageRuntime.load(&Map.get(env, &1))

    assert_raise ArgumentError, ~r/OPENCODE_API_KEY/, fn ->
      CoverageRuntime.load(&Map.get(Map.delete(env, "OPENCODE_API_KEY"), &1))
    end

    assert_raise ArgumentError, ~r/paid or disabled/, fn ->
      CoverageRuntime.load(
        &Map.get(
          Map.put(env, "COVERAGE_GENERATION_MODE", "recorded")
          |> Map.delete("COVERAGE_MONTHLY_BUDGET_CENTS"),
          &1
        )
      )
    end
  end

  test "malformed or unresolved keys fail without echoing the value" do
    for key <- [
          "",
          " padded ",
          "line\nbreak",
          "op://Dev/Opencode/brussels-wtf",
          String.duplicate("a", 513)
        ] do
      env = %{
        "COVERAGE_PROCESSOR" => "opencode",
        "COVERAGE_GENERATION_MODE" => "paid",
        "COVERAGE_MONTHLY_BUDGET_CENTS" => "100",
        "OPENCODE_API_KEY" => key
      }

      assert_raise ArgumentError, "OPENCODE_API_KEY is required for OpenCode coverage", fn ->
        CoverageRuntime.load(&Map.get(env, &1))
      end
    end
  end

  test "disabled OpenCode preserves emergency stop without a credential" do
    env = %{"COVERAGE_PROCESSOR" => "opencode", "COVERAGE_GENERATION_MODE" => "disabled"}

    assert %{generation: %{mode: :disabled}, provider_config: []} =
             CoverageRuntime.load(&Map.get(env, &1))
  end

  test "unknown processor and paid recorded processor fail without echoing values" do
    assert_raise ArgumentError, "COVERAGE_PROCESSOR must be recorded or opencode", fn ->
      CoverageRuntime.load(fn
        "COVERAGE_PROCESSOR" -> "secret-like-value"
        _ -> nil
      end)
    end

    env = %{"COVERAGE_GENERATION_MODE" => "paid", "COVERAGE_MONTHLY_BUDGET_CENTS" => "500"}

    assert_raise ArgumentError, ~r/requires opencode/, fn ->
      CoverageRuntime.load(&Map.get(env, &1))
    end
  end
end
