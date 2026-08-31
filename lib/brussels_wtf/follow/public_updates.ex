defmodule BrusselsWtf.Follow.PublicUpdates do
  @moduledoc "Public, publication-gated update read seam. It never stores caller identity or follows."
  alias BrusselsWtf.Follow.{Target, TargetEligibility}

  def list(targets, locale) when locale in ~w(fr nl en) and is_list(targets) do
    provider =
      Application.get_env(:brussels_wtf, :public_follow_update_provider, __MODULE__.Empty)

    targets
    |> Enum.flat_map(fn %{"type" => type, "id" => id} ->
      with {:ok, target} <- Target.new(parse_type(type), id),
           true <- TargetEligibility.eligible?(target) do
        provider.list(target, locale)
      else
        _ -> []
      end
    end)
  end

  def list(_, _), do: []

  defp parse_type(type) when type in ~w(dossier person legal_entity commune),
    do: String.to_existing_atom(type)

  defp parse_type(_), do: :invalid

  defmodule Empty do
    @moduledoc false
    def list(_, _), do: []
  end
end
