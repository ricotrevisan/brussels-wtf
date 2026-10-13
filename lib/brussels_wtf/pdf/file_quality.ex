defmodule BrusselsWtf.PDF.FileQuality do
  @moduledoc "Exact unchanged Quality measurements while retaining only one text page."
  alias BrusselsWtf.PDF.Quality

  def assess(path, expected, limits) do
    deadline = Map.get(limits, :deadline_ms, System.monotonic_time(:millisecond) + 120_000)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:processor_limit, :wall_time}}
    else
      task =
        Task.async(fn ->
          try do
            do_assess(path, expected, limits)
          rescue
            _ -> {:error, {:invalid_pdf, :text_file}}
          end
        end)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, {:processor_limit, :wall_time}}
      end
    end
  end

  defp do_assess(path, expected, limits) do
    if expected <= 0 or expected > limits.max_pages do
      {:error, {:invalid_pdf, :page_completeness}}
    else
      try do
        if File.stat!(path).size > limits.max_output_bytes,
          do: throw({:processor_limit, :output_bytes})

        {pending, reversed, _bytes} =
          File.stream!(path, [], 65_536)
          |> Enum.reduce({"", [], 0}, fn chunk, {pending, pages, bytes} ->
            bytes = bytes + byte_size(chunk)
            if bytes > limits.max_output_bytes, do: throw({:processor_limit, :output_bytes})
            parts = :binary.split(pending <> chunk, "\f", [:global])
            completed = Enum.drop(parts, -1)

            pages =
              Enum.reduce(completed, pages, fn page, acc ->
                if length(acc) >= expected, do: throw({:invalid_pdf, :page_completeness})

                if byte_size(page) > limits.max_page_bytes,
                  do: throw({:processor_limit, :page_text_bytes})

                if not String.valid?(page), do: throw({:invalid_pdf, :invalid_utf8})
                measurement = Quality.assess([page])["pages"] |> hd()
                [Map.put(measurement, "page", length(acc) + 1) | acc]
              end)

            pending = List.last(parts)

            if byte_size(pending) > limits.max_page_bytes,
              do: throw({:processor_limit, :page_text_bytes})

            {pending, pages, bytes}
          end)

        if pending != "" or length(reversed) != expected do
          {:error, {:invalid_pdf, :page_completeness}}
        else
          pages = Enum.reverse(reversed)

          {:ok,
           %{
             "page_count" => expected,
             "pages" => pages,
             "accepted" => Enum.all?(pages, &(&1["decision"] == "accepted")),
             "rejected_pages" =>
               Enum.filter(pages, &(&1["decision"] != "accepted")) |> Enum.map(& &1["page"]),
             "thresholds" => Map.new(Quality.thresholds(), fn {k, v} -> {to_string(k), v} end)
           }}
        end
      catch
        reason -> {:error, reason}
      end
    end
  end
end
