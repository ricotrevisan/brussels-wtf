defmodule BrusselsWtf.CBE.Source.Records do
  @moduledoc false

  def stream(path, limit, expected \\ nil) do
    path
    |> File.stream!(65_536)
    |> verify_bytes(expected)
    |> Stream.transform(
      fn -> {[], 0, false} end,
      fn chunk, state -> split(chunk, state, [], limit) end,
      fn
        {[], 0, false} = state -> {[], state}
        {parts, _, false} = state -> {[parts |> Enum.reverse() |> IO.iodata_to_binary()], state}
        _ -> throw({:source_error, :malformed_csv})
      end,
      fn _ -> :ok end
    )
    # Match File.stream!'s original line-mode normalization, including CRLF
    # inside quoted fields. Hash and bound raw bytes first; normalize complete
    # records so a CRLF split across input chunks is still handled correctly.
    |> Stream.map(&String.replace(&1, "\r\n", "\n"))
  end

  defp verify_bytes(chunks, nil), do: chunks

  defp verify_bytes(chunks, expected) do
    Stream.transform(
      chunks,
      fn -> {:crypto.hash_init(:sha256), 0} end,
      fn chunk, {hash, bytes} ->
        {[chunk], {:crypto.hash_update(hash, chunk), bytes + byte_size(chunk)}}
      end,
      fn {hash, bytes} = state ->
        sha = Base.encode16(:crypto.hash_final(hash), case: :lower)

        unless sha == expected["sha256"] and bytes == expected["bytes"],
          do: throw({:source_error, :manifest_mismatch})

        {[], state}
      end,
      fn _ -> :ok end
    )
  end

  # Quote parity is sufficient to locate record boundaries, including doubled
  # quotes. NimbleCSV remains responsible for validating the CSV grammar.
  defp split(<<>>, state, records, _limit), do: {Enum.reverse(records), state}

  defp split(chunk, {parts, size, quoted}, records, limit) do
    case :binary.match(chunk, ["\"", "\n"]) do
      :nomatch ->
        check_size(size + byte_size(chunk), limit)
        {Enum.reverse(records), {[chunk | parts], size + byte_size(chunk), quoted}}

      {offset, 1} ->
        <<part::binary-size(offset), char, rest::binary>> = chunk
        size = size + offset + 1
        check_size(size, limit)
        parts = [<<char>>, part | parts]

        cond do
          char == ?\n and not quoted ->
            record = parts |> Enum.reverse() |> IO.iodata_to_binary()
            split(rest, {[], 0, false}, [record | records], limit)

          char == ?\" ->
            split(rest, {parts, size, not quoted}, records, limit)

          true ->
            split(rest, {parts, size, quoted}, records, limit)
        end
    end
  end

  defp check_size(size, limit) do
    if size > limit, do: throw({:source_error, :record_too_large})
  end
end
