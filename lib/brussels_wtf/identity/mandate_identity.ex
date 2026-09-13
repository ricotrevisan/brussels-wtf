defmodule BrusselsWtf.Identity.MandateIdentity do
  @moduledoc """
  Independent identity evidence for the first inspected Ixelles declaration.

  Page 1 of the pinned June 2026 minutes names Gautier Calomne among the
  aldermen of Ixelles. This corroborates identity only: it neither creates a
  council appointment nor extends the December 2024 declaration's period.
  """

  alias BrusselsWtf.{Identity, Ingestion, Repo}
  alias Identity.MandateDeclaration
  require Ash.Query

  @sha "4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5"
  @origin "https://www.ixelles.be/uploads/conseil/pv/267.pdf"
  @name "gautier calomne"

  def source_sha, do: @sha
  def source_url, do: @origin

  def resolve(document, commune_id) do
    if MandateDeclaration.name(document) == @name do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "mandate-identity:#{@name}"
        ])

        people =
          Identity.Person
          |> Ash.Query.filter(status == :active)
          |> Ash.read!(authorize?: false)
          |> Enum.filter(&(MandateDeclaration.normalize(&1.legal_name) == @name))

        case people do
          [] ->
            with {:ok, version} <- source_version(commune_id),
                 :ok <- check_bytes(version) do
              {person, notifications} =
                Identity.record_person!(
                  %{
                    legal_name: "Gautier Calomne",
                    resolution_basis: :corroborated_name,
                    corroborating_facts: %{
                      "municipality" => "ixelles",
                      "source_version_id" => version.id,
                      "source_sha256" => @sha,
                      "source_url" => @origin,
                      "location" => "page 1",
                      "role" => "Échevin",
                      "observed_on" => "2026-06-11"
                    }
                  },
                  return_notifications?: true
                )

              {:created, person, notifications}
            end

          [person] ->
            if corroborated?(person, commune_id),
              do: {:ok, person},
              else: {:error, :uncorroborated_person}

          _ ->
            {:error, :ambiguous_person}
        end
      end)
      |> case do
        {:ok, {:created, person, notifications}} ->
          Ash.Notifier.notify(notifications)
          {:ok, person}

        {:ok, result} ->
          result

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unresolved_person}
    end
  end

  def corroborated?(person, commune_id) do
    Repo.query!(
      "SELECT trusted_ixelles_declarant_identity(people, $2::text::uuid) FROM people WHERE id = $1::text::uuid",
      [person.id, commune_id]
    ).rows == [[true]]
  end

  def verify_bytes(person, commune_id) do
    if person.resolution_basis == :corroborated_name do
      with true <- corroborated?(person, commune_id),
           {:ok, version} <- source_version(commune_id),
           true <- version.id == person.corroborating_facts["source_version_id"] do
        check_bytes(version)
      else
        _ -> {:error, :independent_identity_evidence_missing}
      end
    else
      :ok
    end
  end

  defp source_version(commune_id) do
    result =
      Repo.query!(
        """
        SELECT versions.id::text
          FROM source_versions versions
          JOIN source_records records ON records.id = versions.source_record_id
         WHERE versions.sha256 = $1 AND records.origin_url = $2
           AND records.commune_id = $3::text::uuid
           AND trusted_ixelles_identity_source(versions, records)
        """,
        [@sha, @origin, commune_id]
      )

    case result.rows do
      [[id]] -> {:ok, Ingestion.get_source_version!(id)}
      _ -> {:error, :independent_identity_evidence_missing}
    end
  end

  defp check_bytes(version) do
    with {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
         true <- BrusselsWtf.Digest.sha256(bytes) == @sha,
         true <- byte_size(bytes) == version.byte_size do
      :ok
    else
      _ -> {:error, :independent_identity_evidence_unavailable}
    end
  end
end
