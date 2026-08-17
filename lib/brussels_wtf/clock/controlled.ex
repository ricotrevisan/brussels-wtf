defmodule BrusselsWtf.Clock.Controlled do
  @moduledoc false
  @behaviour BrusselsWtf.Clock

  use Agent

  def start_link(initial \\ DateTime.utc_now()) do
    Agent.start_link(fn -> DateTime.truncate(initial, :microsecond) end, name: __MODULE__)
  end

  def set(%DateTime{} = datetime) do
    Agent.update(__MODULE__, fn _ -> DateTime.truncate(datetime, :microsecond) end)
  end

  @impl true
  def utc_now, do: Agent.get(__MODULE__, & &1)
end
