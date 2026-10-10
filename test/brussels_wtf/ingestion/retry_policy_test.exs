defmodule BrusselsWtf.Ingestion.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Ingestion.RetryPolicy

  @now ~U[2026-08-20 12:00:00Z]

  test "transient transport and HTTP failures receive six finite retry delays" do
    expected = [30, 120, 600, 3_600, 21_600, 86_400]

    for {delay, attempt} <- Enum.with_index(expected, 1) do
      assert RetryPolicy.decision({:transport, :timeout}, attempt, now: @now) ==
               {:retry, delay}

      assert RetryPolicy.decision({:http, 500, %{}}, attempt, now: @now) ==
               {:retry, delay}
    end

    assert RetryPolicy.decision({:http, 503, %{}}, 7, now: @now) ==
             {:review, :transient_retries_exhausted}
  end

  test "Retry-After is a lower bound for 429 and transient response delays" do
    assert RetryPolicy.decision({:http, 429, %{"retry-after" => ["900"]}}, 1, now: @now) ==
             {:retry, 900}

    assert RetryPolicy.decision(
             {:http, 503, %{"retry-after" => ["Thu, 20 Aug 2026 12:20:00 GMT"]}},
             2,
             now: @now
           ) == {:retry, 1_200}
  end

  test "only newly discovered 404 responses retry" do
    assert RetryPolicy.decision({:http, 404, %{}}, 1, newly_discovered?: true, now: @now) ==
             {:retry, 30}

    assert RetryPolicy.decision({:http, 404, %{}}, 1,
             newly_discovered?: false,
             now: @now
           ) == :disappeared
  end

  test "deterministic failures become review work immediately" do
    for failure <- [
          :corruption,
          :authentication_failure,
          :invalid_content,
          :parser_ambiguity,
          :unsupported_media,
          :repeated_quality_failure
        ] do
      assert RetryPolicy.decision({:deterministic, failure}, 1, now: @now) ==
               {:review, failure}
    end

    assert RetryPolicy.decision({:http, 401, %{}}, 1, now: @now) ==
             {:review, :authentication_failure}

    assert RetryPolicy.decision({:http, 415, %{}}, 1, now: @now) ==
             {:review, :unsupported_media}
  end

  test "production retry delays are deterministically jittered around the finite schedule" do
    assert {:retry, delay} =
             RetryPolicy.decision({:transport, :timeout}, 3,
               now: @now,
               jitter_key: "poll-run:locator"
             )

    assert delay in 540..660
    refute delay == 600
  end

  test "invalid request targets become review work without consuming transient retries" do
    error = %Req.HTTPError{
      protocol: :http1,
      reason:
        {:invalid_request_target, "/show_documents/07-09-2026/07 09 2026 OJ point_punt (109)"}
    }

    for attempt <- [1, 7] do
      assert RetryPolicy.decision({:transport, error}, attempt, now: @now) ==
               {:review, :invalid_content}
    end

    assert RetryPolicy.decision({:transport, %Req.TransportError{reason: :timeout}}, 1, now: @now) ==
             {:retry, 30}
  end

  test "invalid downloaded content does not consume transient retries" do
    for reason <- [
          {:invalid_content, {:unexpected_success_status, 206}},
          {:unsupported_content_encoding, ["gzip"]}
        ] do
      assert RetryPolicy.decision({:transport, reason}, 1, now: @now) ==
               {:review, :invalid_content}
    end
  end

  test "deterministic HTTP adapter limits do not consume transport retries" do
    assert RetryPolicy.decision({:transport, {:body_too_large, 1_024}}, 1, now: @now) ==
             {:review, :invalid_content}

    assert RetryPolicy.decision({:transport, :too_many_redirects}, 1, now: @now) ==
             {:review, :invalid_content}
  end
end
