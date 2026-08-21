defmodule BrusselsWtf.Workers.ImportCorpusSource do
  @moduledoc false

  use Oban.Worker,
    queue: :corpus,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: args}) do
    BrusselsWtf.Corpus.Import.import_source(
      args["corpus_import_batch_id"],
      args["meeting_key"],
      args["source_name"]
    )
  end
end
