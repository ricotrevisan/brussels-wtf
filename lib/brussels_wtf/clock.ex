defmodule BrusselsWtf.Clock do
  @moduledoc """
  Process-wide clock used by ingestion so tests can freeze observation time.
  """

  @callback utc_now() :: DateTime.t()

  @spec utc_now() :: DateTime.t()
  def utc_now, do: impl().utc_now()

  defp impl, do: Application.fetch_env!(:brussels_wtf, :clock)
end
