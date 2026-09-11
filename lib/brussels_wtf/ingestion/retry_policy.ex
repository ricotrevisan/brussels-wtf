defmodule BrusselsWtf.Ingestion.RetryPolicy do
  @moduledoc "Finite acquisition retry and terminal-review classification."

  @delays [30, 120, 600, 3_600, 21_600, 86_400]
  @transient_statuses [408, 425, 429]

  @type decision :: :complete | :disappeared | {:retry, pos_integer()} | {:review, atom()}

  @spec decision(term(), pos_integer(), keyword()) :: decision()
  def decision(result, attempt, opts \\ []) when is_integer(attempt) and attempt > 0 do
    case classify(result, opts) do
      :complete -> :complete
      :disappeared -> :disappeared
      {:review, classification} -> {:review, classification}
      {:transient, headers} -> retry_or_review(attempt, headers, opts)
    end
  end

  defp classify({:transport, {:body_too_large, _limit}}, _opts),
    do: {:review, :invalid_content}

  defp classify({:transport, :too_many_redirects}, _opts),
    do: {:review, :invalid_content}

  defp classify({:transport, %Req.HTTPError{reason: {:invalid_request_target, _target}}}, _opts),
    do: {:review, :invalid_content}

  defp classify({:transport, _reason}, _opts), do: {:transient, %{}}

  defp classify({:deterministic, classification}, _opts),
    do: {:review, classification}

  defp classify({:http, status, headers}, _opts)
       when status in @transient_statuses or status in 500..599,
       do: {:transient, headers}

  defp classify({:http, 404, headers}, opts) do
    if Keyword.get(opts, :newly_discovered?, false),
      do: {:transient, headers},
      else: :disappeared
  end

  defp classify({:http, status, _headers}, _opts) when status in [401, 403],
    do: {:review, :authentication_failure}

  defp classify({:http, 415, _headers}, _opts), do: {:review, :unsupported_media}

  defp classify({:http, status, _headers}, _opts) when status in 200..299 or status == 304,
    do: :complete

  defp classify({:http, status, _headers}, _opts) when status in 400..499,
    do: {:review, :invalid_content}

  defp classify(_result, _opts), do: {:review, :invalid_content}

  defp retry_or_review(attempt, headers, opts) when attempt <= length(@delays) do
    base_delay = Enum.at(@delays, attempt - 1)
    jittered_delay = jitter(base_delay, attempt, Keyword.get(opts, :jitter_key))
    retry_after = retry_after_seconds(headers, Keyword.get(opts, :now))
    {:retry, max(jittered_delay, retry_after || 0)}
  end

  defp retry_or_review(_attempt, _headers, _opts),
    do: {:review, :transient_retries_exhausted}

  defp jitter(delay, _attempt, nil), do: delay

  defp jitter(delay, attempt, key) do
    per_mille = 900 + :erlang.phash2({key, attempt}, 201)
    max(round(delay * per_mille / 1_000), 1)
  end

  defp retry_after_seconds(headers, now) do
    headers
    |> normalize_headers()
    |> Map.get("retry-after", [])
    |> List.first()
    |> parse_retry_after(now)
  end

  defp parse_retry_after(nil, _now), do: nil

  defp parse_retry_after(value, _now) when is_integer(value) and value >= 0, do: value

  defp parse_retry_after(value, now) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> parse_http_date(value, now)
    end
  end

  defp parse_retry_after(_value, _now), do: nil

  defp parse_http_date(_value, nil), do: nil

  defp parse_http_date(value, %DateTime{} = now) do
    with {{year, month, day}, {hour, minute, second}} <-
           :httpd_util.convert_request_date(String.to_charlist(value)),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, date} <- DateTime.from_naive(naive, "Etc/UTC") do
      max(DateTime.diff(date, now, :second), 0)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, values} ->
      {String.downcase(to_string(key)), List.wrap(values)}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, result ->
      Map.update(result, String.downcase(to_string(key)), [value], &(&1 ++ [value]))
    end)
  end

  defp normalize_headers(_headers), do: %{}
end
