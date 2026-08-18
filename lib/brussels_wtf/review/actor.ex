defmodule BrusselsWtf.Review.Actor do
  @moduledoc "The authenticated identity allowed to perform private editorial review."

  @enforce_keys [:id, :role]
  defstruct [:id, :role]
end
