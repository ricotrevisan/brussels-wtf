defmodule BrusselsWtf.ProcessRole do
  @moduledoc "Queue isolation contract for lightweight and OCR release roles."

  def oban(:app) do
    [queues: [poll: 1, fetch: 2, extract: 1, normalize: 1, publish: 1]]
  end

  def oban(:ocr), do: [plugins: false, queues: [ocr: 1]]
end
