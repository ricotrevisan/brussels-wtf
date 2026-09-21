defmodule BrusselsWtf.Identity.MunicipalInstallation.Resolver do
  @moduledoc false
  alias BrusselsWtf.{Identity, Repo}
  alias BrusselsWtf.Identity.MunicipalInstallation.Evidence
  require Ash.Query

  def normalize(name),
    do:
      name
      |> String.normalize(:nfc)
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.downcase()

  def context(bundle, candidate) do
    Evidence.pin(bundle.corroboration)
    |> Map.merge(%{
      "municipality" => bundle.contract.slug,
      "observed_on" => Date.to_iso8601(bundle.contract.corroboration.date),
      "identity_name" => candidate.legal_name
    })
  end

  def resolve!(bundle, candidate) do
    # A global name lock also excludes concurrent cross-commune identity creation.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "installation-person:" <> normalize(candidate.legal_name)
    ])

    case matching(candidate.legal_name) do
      [] ->
        Identity.record_person!(
          %{
            legal_name: candidate.legal_name,
            resolution_basis: :corroborated_name,
            corroborating_facts: context(bundle, candidate)
          },
          return_notifications?: true
        )

      [person] ->
        validate!(person, bundle, candidate)
        {person, []}

      _ ->
        raise ArgumentError, "ambiguous existing full name"
    end
  end

  def validate!(person, bundle, candidate) do
    expected = context(bundle, candidate)
    keys = ~w(municipality source_version_id source_sha256 source_url observed_on)

    unless person.status == :active and
             normalize(person.legal_name) == normalize(candidate.legal_name) and
             Map.take(person.corroborating_facts, keys) == Map.take(expected, keys) and
             Enum.map(matching(candidate.legal_name), & &1.id) == [person.id] do
      raise ArgumentError, "ambiguous or conflicting person context"
    end

    :ok
  end

  defp matching(name) do
    normalized = normalize(name)

    Identity.Person
    |> Ash.Query.filter(status == :active)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(normalize(&1.legal_name) == normalized))
  end

  def link_mentions!(person, bundle, candidate) do
    ids = [bundle.installation.version.id, bundle.corroboration.version.id]

    Identity.Mention
    |> Ash.Query.filter(
      source_version_id in ^ids and resolution_status == :unresolved and
        kind in [:person, :unknown] and is_nil(explicit_identifier) and
        is_nil(resolved_legal_entity_id) and is_nil(resolved_person_id)
    )
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.text == candidate.legal_name))
    |> Enum.flat_map(fn mention ->
      {_, notifications} =
        Identity.resolve_mention_to_person!(mention, %{resolved_person_id: person.id},
          return_notifications?: true
        )

      notifications
    end)
  end
end
