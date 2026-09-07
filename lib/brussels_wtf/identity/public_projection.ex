defmodule BrusselsWtf.Identity.PublicProjection do
  @moduledoc false

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.PublicRelationship
  alias BrusselsWtf.Identity.SourcedFact

  @allowed_filters [:subject_type, :subject_id, :object_type, :object_id]
  @verifier "ixelles_municipal_minutes_public_mandate_v1"

  def list!(filter) when is_map(filter) do
    reject_unknown_filters!(filter)

    SourcedFact
    |> Ash.Query.filter(verification_status == :verified)
    |> maybe_filter(:subject_type, filter)
    |> maybe_filter(:subject_id, filter)
    |> maybe_filter(:object_type, filter)
    |> maybe_filter(:object_id, filter)
    |> Ash.read!(authorize?: false, domain: Identity)
    |> Enum.flat_map(&project/1)
  end

  def history!(filter) do
    reject_unknown_filters!(filter)

    SourcedFact
    |> Ash.Query.filter(
      verification_status == :superseded and verified_by == "ixelles_mandate_declaration_v2"
    )
    |> maybe_filter(:subject_type, filter)
    |> maybe_filter(:subject_id, filter)
    |> maybe_filter(:object_type, filter)
    |> maybe_filter(:object_id, filter)
    |> Ash.read!(authorize?: false, domain: Identity)
    |> Enum.flat_map(&project/1)
  end

  def ever_public_person?(person_id) do
    SourcedFact
    |> Ash.Query.filter(
      subject_type == :person and subject_id == ^person_id and
        verification_status in [:verified, :superseded]
    )
    |> Ash.read!(authorize?: false, domain: Identity)
    |> Enum.any?(&historically_safe_person_fact?(&1, person_id))
  end

  defp project(fact) do
    fact = Ash.load!(fact, source_version: [source_record: [:commune]])
    version = fact.source_version
    record = version.source_record
    commune = record.commune

    with true <- safe_verified_fact?(fact, record, commune),
         {:ok, person} <- Identity.get_person(fact.subject_id),
         true <- person.status == :active,
         true <- safe_declaration?(fact, person, version) do
      [
        %PublicRelationship{
          fact_id: fact.id,
          subject_type: :person,
          subject_id: person.id,
          subject_name: person.legal_name,
          object_type: :commune,
          object_id: commune.id,
          object_name: commune.name,
          kind: :public_mandate,
          effective_from: fact.effective_from,
          effective_to: fact.effective_to,
          source_authority: fact.source_authority,
          authoritative_url: record.origin_url,
          evidence_location: fact.evidence_location,
          source_retrieved_at: version.first_retrieved_at,
          verified_at: fact.verified_at,
          mandate_declaration: public_declaration(fact.mandate_declaration, version),
          state: fact_state(fact)
        }
      ]
    else
      _ -> []
    end
  end

  defp safe_declaration?(%{verified_by: "ixelles_mandate_declaration_v2"} = fact, person, version) do
    with {:ok, document} <- Identity.MandateDeclaration.contract(version.sha256) do
      Identity.MandateDeclaration.matches?(fact, person, document) and
        Identity.MandateDeclaration.unique_person?(person)
    else
      _ -> false
    end
  end

  defp safe_declaration?(fact, _person, _version), do: fact.mandate_declaration == nil

  defp public_declaration(nil, _version), do: nil

  defp public_declaration(value, version) do
    {:ok, document} = Identity.MandateDeclaration.contract(version.sha256)

    value
    |> Map.take(["role", "body", "section", "reporting_year", "page"])
    |> Map.put("role_labels", document.role_labels)
  end

  defp fact_state(%{verification_status: :superseded}), do: :superseded

  defp fact_state(%{effective_to: %Date{} = date}) do
    if Date.compare(date, DateTime.to_date(BrusselsWtf.Clock.utc_now())) == :lt,
      do: :ended,
      else: :current
  end

  defp fact_state(_), do: :current

  defp historically_safe_person_fact?(fact, person_id) do
    with %{source_version: version} <-
           Ash.load!(fact, source_version: [source_record: [:commune]]),
         %{source_record: record} when not is_nil(record) <- version,
         %{commune: commune} when not is_nil(commune) <- record do
      fact.subject_id == person_id and safe_verified_fact?(fact, record, commune) and
        safe_declaration?(fact, Identity.get_person!(person_id), version)
    else
      _ -> false
    end
  rescue
    Ash.Error.Invalid -> false
  end

  defp safe_verified_fact?(fact, record, commune) do
    configured = BrusselsWtf.Communes.configuration!("ixelles")

    trusted_current_or_prior_fact?(fact) and fact.subject_type == :person and
      fact.object_type == :commune and
      fact.object_id == commune.id and
      fact.kind == :public_mandate and
      safe_evidence_kind?(fact) and
      is_binary(fact.evidence_location) and
      safe_location?(fact) and
      match?(%Date{}, fact.effective_from) and
      match?(%DateTime{}, fact.verified_at) and
      not is_nil(fact.verification_processing_run_id) and
      not is_nil(fact.verification_artifact_id) and
      record.origin_url == fact.authoritative_url and
      commune.slug == "ixelles" and
      commune.name == configured.name and
      commune.index_url == configured.index_url and
      safe_source_record?(fact.verified_by, record)
  end

  defp safe_evidence_kind?(%{verified_by: @verifier} = fact),
    do: fact.source_authority == :municipal_decision and fact.evidence_kind == :official_decision

  defp safe_evidence_kind?(%{verified_by: "ixelles_mandate_declaration_v2"} = fact),
    do:
      fact.source_authority == :municipal_declaration and
        fact.evidence_kind == :official_declaration

  defp safe_evidence_kind?(_), do: false

  defp safe_location?(%{verified_by: @verifier} = fact) do
    Regex.match?(~r/\Adecision [0-9]+(?:[.-][0-9A-Za-z]+)*\z/, fact.evidence_location)
  end

  defp safe_location?(%{verified_by: "ixelles_mandate_declaration_v2"} = fact) do
    Regex.match?(~r/\Adeclaration [0-9]{4} page [1-9][0-9]*\z/, fact.evidence_location)
  end

  defp safe_location?(_fact), do: false

  defp safe_source_record?(@verifier, record), do: record.role == :minutes

  defp safe_source_record?("ixelles_mandate_declaration_v2", record) do
    record.role == :mandate_declaration and
      record.origin_url != nil and
      Regex.match?(
        ~r<\Ahttps://www\.ixelles\.be/site/(?:fr|nl)/download/transparence/mandats-[0-9]{4}\.pdf\z>,
        record.origin_url
      )
  end

  defp safe_source_record?(_verifier, _record), do: false

  defp trusted_current_or_prior_fact?(%{verification_status: status} = fact)
       when status in [:verified, :superseded],
       do: Identity.TrustedVerifier.trusted_fact?(fact)

  defp trusted_current_or_prior_fact?(_fact), do: false

  defp reject_unknown_filters!(filter) do
    unknown = Map.keys(filter) -- @allowed_filters

    if unknown != [] do
      raise ArgumentError, "unsupported public relationship filters: #{inspect(unknown)}"
    end
  end

  defp maybe_filter(query, key, filter) do
    case Map.fetch(filter, key) do
      {:ok, value} -> Ash.Query.filter_input(query, %{key => value})
      :error -> query
    end
  end
end
