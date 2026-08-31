defmodule BrusselsWtf.Follow.Target do
  @moduledoc "Typed action seam for stable targets that pass their public-page gate."

  @enforce_keys [:type, :identifier]
  defstruct [:type, :identifier]

  @types [:dossier, :person, :legal_entity, :commune]

  def new(type, identifier) when type in @types and is_binary(identifier) and identifier != "" do
    {:ok, %__MODULE__{type: type, identifier: identifier}}
  end

  def new(_, _), do: {:error, :ineligible}
end

defmodule BrusselsWtf.Follow.TargetEligibility do
  @moduledoc "Fail-closed reuse of each target's public page lookup."

  alias BrusselsWtf.Follow.Target

  def eligible?(%Target{type: :person, identifier: id}) do
    match?(
      {:ok, %BrusselsWtf.Identity.PublicProfile.Person{}},
      BrusselsWtf.Identity.get_public_person_profile(id)
    )
  end

  def eligible?(%Target{type: :legal_entity, identifier: number}) do
    match?(
      {:ok, %BrusselsWtf.Identity.PublicProfile.Company{}},
      BrusselsWtf.Identity.get_public_company_profile(number)
    )
  end

  def eligible?(%Target{type: :dossier, identifier: slug}) do
    case BrusselsWtf.Council.get_dossier(slug) do
      {:ok, %{status: :active}} ->
        true

      {:ok, %{status: :retired, retired_into: target}} ->
        not is_nil(target) and not is_struct(target, Ash.NotLoaded)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def eligible?(%Target{type: :commune, identifier: slug}) do
    case BrusselsWtf.Ingestion.get_commune_by_slug(slug) do
      {:ok, commune} ->
        configured = BrusselsWtf.Communes.configuration!(slug)
        commune.name == configured.name and commune.index_url == configured.index_url

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
