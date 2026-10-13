defmodule BrusselsWtf.PDF.PageAssembly do
  @moduledoc "Bounded exact-original-page assembly; selected OCR text replaces only its authorized page."
  @max_text 67_108_864
  @max_page 262_144
  def assemble(native, replacements, output, expected) do
    with true <-
           is_map(replacements) and expected in 1..500 and
             Enum.all?(Map.keys(replacements), &(is_integer(&1) and &1 in 1..expected)),
         {:ok, out} <- File.open(output, [:write, :binary, :exclusive]) do
      try do
        {pending, count, _bytes} =
          File.stream!(native, [], 65_536)
          |> Enum.reduce({"", 0, 0}, fn chunk, {pending, count, bytes} ->
            parts = :binary.split(pending <> chunk, "\f", [:global])

            {count, bytes} =
              Enum.reduce(Enum.drop(parts, -1), {count, bytes}, fn page, {count, bytes} ->
                number = count + 1
                if number > expected or byte_size(page) > @max_page, do: throw(:page_completeness)

                text =
                  case Map.fetch(replacements, number) do
                    {:ok, path} ->
                      if File.stat!(path).size > @max_page + 1, do: throw(:page_bytes)

                      case :binary.split(File.read!(path), "\f", [:global]) do
                        [text, ""] when byte_size(text) <= @max_page -> text
                        _ -> throw(:page_completeness)
                      end

                    :error ->
                      page
                  end

                if bytes + byte_size(text) + 1 > @max_text, do: throw(:text_bytes)
                :ok = IO.binwrite(out, [text, "\f"])
                {number, bytes + byte_size(text) + 1}
              end)

            pending = List.last(parts)
            if byte_size(pending) > @max_page, do: throw(:page_bytes)
            {pending, count, bytes}
          end)

        if pending == "" and count == expected, do: :ok, else: {:error, :page_completeness}
      rescue
        _ -> {:error, :assembly_failed}
      catch
        _ -> {:error, :assembly_failed}
      after
        File.close(out)
      end
    else
      _ -> {:error, :page_completeness}
    end
  end
end
