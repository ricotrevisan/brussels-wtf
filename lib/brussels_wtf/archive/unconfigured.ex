defmodule BrusselsWtf.Archive.Unconfigured do
  @moduledoc """
  Failing production-safe default used until a private object-store adapter is configured.

  There is deliberately no local-disk fallback for source evidence.
  """
  @behaviour BrusselsWtf.Archive

  def start_link(_opts) do
    {:error, :source_archive_not_configured}
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def put(_sha256, _bytes), do: {:error, :source_archive_not_configured}

  @impl true
  def get(_object_key), do: {:error, :source_archive_not_configured}

  @impl true
  def ready?, do: {:error, :source_archive_not_configured}
end
