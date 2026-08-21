defmodule BrusselsWtf.CBE do
  @moduledoc "External CBE Open Data lookup seam used by private enrichment jobs."

  @callback fetch_enterprise(String.t()) :: {:ok, map()} | {:error, term()}

  def fetch_enterprise(enterprise_number) do
    Application.fetch_env!(:brussels_wtf, :cbe_source).fetch_enterprise(enterprise_number)
  end
end
