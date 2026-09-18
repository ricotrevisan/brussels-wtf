defmodule BrusselsWtf.Ops.RequeueNormalizationTest do
  @moduledoc """
  Guards the operator recovery script for issue 98. The script is evaluated the way
  an operator runs it, so a syntax slip or an invalid candidate query fails here
  instead of during recovery.
  """

  use BrusselsWtf.DataCase, async: false

  import ExUnit.CaptureIO

  @script "priv/ops/requeue_normalization_20260918.exs"

  test "the default invocation is read-only and reports its preflight" do
    output =
      capture_io(fn ->
        {result, _bindings} = Code.eval_file(@script)
        assert result == :ok
      end)

    assert output =~ "read-only: no normalization was requeued"
    assert output =~ ~s(generate: "issue-98-normalization-requeue")
    assert output =~ "read_only: true"
    assert output =~ "normalization_contract:"
  end

  test "operator bindings are accepted and still refuse to apply beyond the cap" do
    source = File.read!(@script)

    assert_raise RuntimeError, ~r/refusing to requeue more than 25/, fn ->
      Code.eval_string(source, apply?: true, limit: 26)
    end

    assert_raise RuntimeError, ~r/limit must be positive/, fn ->
      Code.eval_string(source, apply?: true, limit: 0)
    end

    assert_raise RuntimeError, ~r/cursor must be a run id string/, fn ->
      Code.eval_string(source, apply?: true, limit: 1, cursor: 42)
    end
  end

  test "the candidate query is one statement and never selects an already-reviewed run" do
    source = File.read!(@script)

    assert length(String.split(source, "SELECT DISTINCT ON (r.id)")) == 2

    assert source =~ "review_cases rc"
    assert source =~ "normalization:' || r.id::text"
    assert source =~ "r.id > $3"

    # The script never pauses, starts, or resumes an Oban queue on its own.
    refute source =~ "Oban.pause_queue"
    refute source =~ "Oban.resume_queue"
  end

  test "read-only evaluation with a role filter and cursor returns a preflight map" do
    source = File.read!(@script)

    output =
      capture_io(fn ->
        {result, _} =
          Code.eval_string(source,
            apply?: false,
            commune: "ixelles",
            role: "agenda",
            cursor: "00000000-0000-0000-0000-000000000000"
          )

        assert result == :ok
      end)

    assert output =~ "role: \"agenda\""
    assert output =~ "candidate_count:"
  end
end
