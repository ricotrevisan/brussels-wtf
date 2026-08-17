defmodule BrusselsWtf.Clock.System do
  @moduledoc false
  @behaviour BrusselsWtf.Clock

  @impl true
  def utc_now, do: DateTime.utc_now()
end
