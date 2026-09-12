defmodule BrusselsWtf.Identity.TrustedVerifier do
  @moduledoc """
  Source-specific relationship verification gates.

  Each registry entry owns its processor contract, source lineage checks, exact
  semantic payload, audit provenance, and atomic status transition. Callers can
  choose only a persisted candidate and processing run; they cannot provide
  verifier provenance or time.
  """

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.MandateDeclaration
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Repo

  @ixelles_mandate %{
    id: :ixelles_municipal_minutes_public_mandate_v1,
    verifier_id: "ixelles_municipal_minutes_public_mandate_v1",
    commune_slug: "ixelles",
    processor_name: "ixelles-municipal-minutes-public-mandates",
    processor_version: "1.0.0",
    config_hash: "sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1",
    ruleset_version: "ixelles-public-mandate-v1",
    artifact_kind: "relationship-claim-json",
    kind: :public_mandate
  }

  # The mandate-declaration source policy. The declaration publication is a
  # transparency document, not meeting minutes: it is a scanned bundle, so its
  # trusted text input is the bounded OCR chain, and its locator hangs off the
  # transparency index instead of the meeting index.
  @declaration_parent_index_url "https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr"

  @declaration_config_inputs %{
    "ruleset" => "ixelles-mandate-declaration-v2",
    "sections" => ["mandats"],
    "signature_policy" => "inspected-immutable-version",
    "identity_policy" => "complete-name-and-independent-minutes",
    "origin_path" => "/site/fr/download/transparence/mandats-YYYY.pdf",
    "parent_index_url" => @declaration_parent_index_url,
    "forbidden_excerpt_markers" => [
      "numero national",
      "numero-national",
      "adresse",
      "signature",
      "tranche",
      "281.10"
    ]
  }

  @declaration_config_hash "sha256:" <>
                             BrusselsWtf.Digest.sha256(
                               :erlang.term_to_binary(@declaration_config_inputs, [:deterministic])
                             )

  @ixelles_declaration %{
    id: :ixelles_mandate_declaration_v2,
    verifier_id: "ixelles_mandate_declaration_v2",
    commune_slug: "ixelles",
    processor_name: "ixelles-mandate-declarations",
    processor_version: "1.0.0",
    config_hash: @declaration_config_hash,
    ruleset_version: "ixelles-mandate-declaration-v2",
    artifact_kind: "relationship-claim-json",
    kind: :public_mandate,
    source: %{
      label: "mandate declaration",
      source_authority: :municipal_declaration,
      evidence_kind: :official_declaration,
      evidence_location_regex: ~r/\Adeclaration [0-9]{4} page [1-9][0-9]*\z/,
      record_role: :mandate_declaration,
      locator_role: :mandate_declaration,
      parent_index_url: @declaration_parent_index_url,
      parent_index_source: :literal,
      origin_path_regex: ~r|\A/site/fr/download/transparence/mandats-[0-9]{4}\.pdf\z|,
      text_input: :ocr,
      evidence: :declaration_row
    }
  }

  @ixelles_minutes_source %{
    label: "minutes",
    source_authority: :municipal_decision,
    evidence_kind: :official_decision,
    evidence_location_regex: ~r/\Adecision [0-9]+(?:[.-][0-9A-Za-z]+)*\z/,
    record_role: :minutes,
    locator_role: :minutes,
    parent_index_url: nil,
    parent_index_source: :commune_index,
    origin_path_regex: ~r|\A/uploads/conseil/pv/[0-9]+\.pdf\z|,
    text_input: :native,
    evidence: :minutes_decision
  }

  @gazette_index_url "https://www.ejustice.just.fgov.be/tsv/tsvf2.htm"

  @gazette_config_inputs %{
    "ruleset" => "belgian-official-gazette-management-v1",
    "publisher" => "belgian-official-gazette",
    "host" => "www.ejustice.just.fgov.be",
    "index_url" => @gazette_index_url,
    "roles" => ["administrateur", "bestuurder", "directeur", "gérant", "zaakvoerder"]
  }

  @gazette_config_hash "sha256:" <>
                         BrusselsWtf.Digest.sha256(
                           :erlang.term_to_binary(@gazette_config_inputs, [:deterministic])
                         )

  @gazette_management %{
    id: :belgian_official_gazette_management_v1,
    verifier_id: "belgian_official_gazette_management_v1",
    processor_name: "belgian-official-gazette-management",
    processor_version: "1.0.0",
    config_hash: @gazette_config_hash,
    ruleset_version: "belgian-official-gazette-management-v1",
    artifact_kind: "relationship-claim-json",
    kind: :management,
    source: %{
      label: "gazette annex",
      source_authority: :belgian_official_gazette,
      evidence_kind: :official_act,
      evidence_location_regex: ~r/\Apublication [0-9]{4}-[0-9]{10}-(appointment|cessation)\z/,
      record_role: :gazette_annex,
      locator_role: :gazette_annex,
      parent_index_url: @gazette_index_url,
      parent_index_source: :literal,
      origin_path_regex: ~r/\A\/tsv\/fr\/[0-9]{4}-[0-9]{10}-(appointment|cessation)\z/,
      text_input: :native,
      evidence: :gazette_act,
      publisher_slug: "belgian-official-gazette",
      publisher_name: "Belgian Official Gazette",
      publisher_host: "www.ejustice.just.fgov.be"
    }
  }

  @ixelles_mandate Map.put(@ixelles_mandate, :source, @ixelles_minutes_source)

  @registry %{
    @ixelles_mandate.id => @ixelles_mandate,
    @ixelles_declaration.id => @ixelles_declaration,
    @gazette_management.id => @gazette_management
  }

  @doc false
  def ixelles_contract, do: @ixelles_mandate

  @doc false
  def declaration_contract, do: @ixelles_declaration

  @doc false
  def gazette_contract, do: @gazette_management

  def available?, do: map_size(@registry) > 0

  def available_for?(kind) when is_atom(kind) do
    Enum.any?(@registry, fn {_id, verifier} -> verifier.kind == kind end)
  end

  def trusted_fact?(fact)
      when fact.verification_status in [:verified, :superseded] and
             fact.kind == :management do
    result =
      Repo.query!(
        """
        SELECT 1
          FROM sourced_facts
          JOIN sourced_fact_verification_events AS events
            ON events.fact_id = sourced_facts.id
           AND events.to_status = 'verified'
           AND events.verifier_id = sourced_facts.verified_by
           AND events.processing_run_id = sourced_facts.verification_processing_run_id
           AND events.artifact_id = sourced_facts.verification_artifact_id
           AND events.processor_version = sourced_facts.verification_processor_version
           AND events.ruleset_version = sourced_facts.verification_ruleset_version
           AND events.config_sha256 = sourced_facts.verification_config_sha256
           AND events.generation = sourced_facts.verification_generation
         WHERE sourced_facts.id = $1::text::uuid
           AND trusted_gazette_management_fact(sourced_facts)
         LIMIT 1
        """,
        [fact.id]
      )

    result.num_rows == 1
  rescue
    _ -> false
  end

  def trusted_fact?(fact)
      when fact.verification_status in [:verified, :superseded] and
             fact.kind == :public_mandate do
    result =
      Repo.query!(
        """
        SELECT 1
          FROM sourced_facts
          JOIN sourced_fact_verification_events AS events
            ON events.fact_id = sourced_facts.id
           AND events.to_status = 'verified'
           AND events.verifier_id = sourced_facts.verified_by
           AND events.processing_run_id = sourced_facts.verification_processing_run_id
           AND events.artifact_id = sourced_facts.verification_artifact_id
           AND events.processor_version = sourced_facts.verification_processor_version
           AND events.ruleset_version = sourced_facts.verification_ruleset_version
           AND events.config_sha256 = sourced_facts.verification_config_sha256
           AND events.generation = sourced_facts.verification_generation
         WHERE sourced_facts.id = $1::text::uuid
           AND trusted_ixelles_public_mandate_fact(sourced_facts)
         LIMIT 1
        """,
        [fact.id]
      )

    result.num_rows == 1
  rescue
    _ -> false
  end

  def trusted_fact?(_fact), do: false

  @doc false
  def ixelles_semantic_payload(fact, person, commune, version) do
    semantic_payload(fact, person, commune, version, @ixelles_mandate)
  end

  @doc false
  def declaration_semantic_payload(fact, person, commune, version) do
    semantic_payload(fact, person, commune, version, @ixelles_declaration)
  end

  @doc false
  def gazette_semantic_payload(fact, person, commune, version) do
    semantic_payload(fact, person, commune, version, @gazette_management)
  end

  def verify!(fact_id, verifier_id, processing_run_id) do
    verifier = fetch!(verifier_id)

    case Repo.transaction(fn -> verify_in_transaction!(fact_id, processing_run_id, verifier) end) do
      {:ok, fact} -> fact
      {:error, error} -> raise error
    end
  end

  def validate_public_url!(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.port == 443 and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and uri.query in [nil, ""] and uri.fragment in [nil, ""] do
      :ok
    else
      raise ArgumentError, "relationship citations require a safe public HTTPS URL"
    end
  end

  def validate_public_url!(_url) do
    raise ArgumentError, "relationship citations require a safe public HTTPS URL"
  end

  defp verify_in_transaction!(fact_id, processing_run_id, verifier) do
    lock_candidate!(fact_id)

    fact =
      fact_id
      |> Identity.get_sourced_fact!()
      |> Ash.load!(source_version: [source_record: [:commune]])

    run = Ingestion.get_processing_run!(processing_run_id)
    artifact = relationship_artifact!(run.id)
    person = Identity.get_person!(fact.subject_id)
    version = fact.source_version
    record = version.source_record
    commune = record.commune

    policy = Map.fetch!(verifier, :source)

    validate_candidate!(fact, person, commune, policy)
    validate_official_source!(fact, version, record, commune, policy)
    locator = validate_retrieval!(version, record, commune, policy)
    {text_run, text_artifact} = trusted_text_input!(run.inputs, version, policy)
    validate_processing!(run, artifact, text_run, text_artifact, version, verifier)

    validate_archives!(
      version,
      artifact,
      text_run,
      text_artifact,
      fact,
      person,
      commune,
      locator,
      verifier,
      policy
    )

    lock_semantic_key!(fact, verifier)
    current = lock_current_fact(fact, verifier)
    validate_supersession!(fact, current)
    set_transition_context!(run, artifact, verifier)

    if fact.supersedes_id do
      %{num_rows: 1} =
        Repo.query!(
          "UPDATE sourced_facts SET verification_status = 'superseded' WHERE id = $1::text::uuid AND verification_status = 'verified'",
          [fact.supersedes_id]
        )
    end

    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE sourced_facts
           SET verification_status = 'verified',
               verified_by = $2,
               verification_processor_version = $3,
               verification_ruleset_version = $4,
               verification_config_sha256 = $5,
               verification_generation = $6,
               verification_processing_run_id = $7::text::uuid,
               verification_artifact_id = $8::text::uuid,
               verified_at = clock_timestamp() AT TIME ZONE 'utc'
         WHERE id = $1::text::uuid AND verification_status = 'unreviewed'
        """,
        [
          fact.id,
          verifier.verifier_id,
          run.processor_version,
          verifier.ruleset_version,
          run.config_hash,
          run.generation_key,
          run.id,
          artifact.id
        ]
      )

    Identity.get_sourced_fact!(fact.id)
  end

  defp lock_candidate!(fact_id) do
    case Repo.query!("SELECT id FROM sourced_facts WHERE id = $1::text::uuid FOR UPDATE", [
           fact_id
         ]).num_rows do
      1 -> :ok
      0 -> raise ArgumentError, "unknown sourced fact"
    end
  end

  defp validate_candidate!(fact, person, commune, policy) do
    if policy.evidence == :gazette_act do
      validate_gazette_candidate!(fact, person)
    else
      validate_mandate_candidate!(fact, person, commune, policy)
    end
  end

  defp validate_mandate_candidate!(fact, person, commune, policy) do
    unless fact.verification_status == :unreviewed do
      raise ArgumentError, "only an unreviewed sourced fact can be verified"
    end

    unless fact.subject_type == :person and fact.subject_id == person.id and
             person.status == :active and
             person.resolution_basis == :explicit_identifier and
             is_binary(person.explicit_identifier) and
             person.explicit_identifier != "" do
      raise ArgumentError, "verification requires a resolved active person identity"
    end

    unless fact.object_type == :commune and fact.object_id == commune.id and
             fact.kind == :public_mandate and fact.source_authority == policy.source_authority and
             fact.evidence_kind == policy.evidence_kind and
             is_binary(fact.evidence_location) and
             Regex.match?(policy.evidence_location_regex, fact.evidence_location) and
             match?(%Date{}, fact.effective_from) do
      raise ArgumentError, "unsupported Ixelles public-mandate semantics"
    end
  end

  defp validate_gazette_candidate!(fact, person) do
    entity = Identity.get_legal_entity!(fact.object_id)
    corroborator = person.corroborating_facts["enterprise_number"]
    allowlisted_role? = fact.object_label in @gazette_config_inputs["roles"]

    unless fact.verification_status == :unreviewed do
      raise ArgumentError, "only an unreviewed sourced fact can be verified"
    end

    unless fact.subject_type == :person and fact.subject_id == person.id and
             person.status == :active and
             person.resolution_basis == :corroborated_name and
             is_binary(corroborator) and corroborator == entity.enterprise_number do
      raise ArgumentError, "verification requires a corroborated person and matching CBE number"
    end

    unless fact.object_type == :legal_entity and fact.object_id == entity.id and
             entity.status == :active and
             fact.kind == :management and
             fact.source_authority == :belgian_official_gazette and
             fact.evidence_kind == :official_act and
             allowlisted_role? and
             is_binary(fact.evidence_location) and
             Regex.match?(
               @gazette_management.source.evidence_location_regex,
               fact.evidence_location
             ) and match?(%Date{}, fact.effective_from) do
      raise ArgumentError, "unsupported Gazette management semantics"
    end
  end

  defp validate_gazette_source!(fact, version, record, commune, policy) do
    uri = URI.parse(record.origin_url)

    valid_path? =
      uri.scheme == "https" and uri.port == 443 and uri.host == policy.publisher_host and
        Regex.match?(policy.origin_path_regex, uri.path || "") and
        is_nil(uri.userinfo) and uri.query in [nil, ""] and uri.fragment in [nil, ""]

    unless commune.slug == policy.publisher_slug and commune.name == policy.publisher_name and
             commune.index_url == policy.parent_index_url and record.commune_id == commune.id and
             record.role == policy.record_role and fact.source_version_id == version.id and
             fact.authoritative_url == record.origin_url and valid_path? do
      raise ArgumentError, "verification requires an official discovered Gazette annex source"
    end

    validate_public_url!(record.origin_url)
  end

  defp validate_official_source!(fact, version, record, commune, policy) do
    if policy.evidence == :gazette_act do
      validate_gazette_source!(fact, version, record, commune, policy)
    else
      validate_ixelles_source!(fact, version, record, commune, policy)
    end
  end

  defp validate_ixelles_source!(fact, version, record, commune, policy) do
    configured = BrusselsWtf.Communes.configuration!("ixelles")
    uri = URI.parse(record.origin_url)

    valid_path? =
      uri.scheme == "https" and uri.port == 443 and uri.host == "www.ixelles.be" and
        Regex.match?(policy.origin_path_regex, uri.path || "") and
        is_nil(uri.userinfo) and uri.query in [nil, ""] and uri.fragment in [nil, ""]

    unless commune.slug == "ixelles" and commune.name == configured.name and
             commune.index_url == configured.index_url and record.commune_id == commune.id and
             record.role == policy.record_role and fact.source_version_id == version.id and
             fact.authoritative_url == record.origin_url and valid_path? do
      raise ArgumentError,
            "verification requires an official discovered Ixelles #{policy.label} source"
    end

    validate_public_url!(record.origin_url)
  end

  defp validate_retrieval!(version, record, commune, policy) do
    configured = BrusselsWtf.Communes.configuration!("ixelles")

    parent_index_url =
      case policy.parent_index_source do
        :commune_index -> configured.index_url
        :literal -> policy.parent_index_url
      end

    result =
      Repo.query!(
        """
        SELECT locators.meeting_identifier, locators.scheduled_on
          FROM source_locators AS locators
          JOIN retrieval_observations AS observations
            ON observations.source_locator_id = locators.id
         WHERE locators.commune_id = $1::text::uuid
           AND locators.url = $2
           AND locators.parent_index_url = $3
           AND locators.role = $4
           AND observations.source_version_id = $5::text::uuid
           AND observations.status IN ('success', 'unchanged')
           AND observations.sha256 = $6
           AND observations.final_url = $2
         LIMIT 1
        """,
        [
          commune.id,
          record.origin_url,
          parent_index_url,
          Atom.to_string(policy.locator_role),
          version.id,
          version.sha256
        ]
      )

    case result.rows do
      [[meeting_identifier, scheduled_on]] ->
        %{meeting_identifier: meeting_identifier, scheduled_on: scheduled_on}

      _ ->
        raise ArgumentError, "verification requires one archived official retrieval observation"
    end
  end

  defp trusted_text_input!(inputs, version, policy) do
    with {:ok, run_id} <- Ecto.UUID.cast(inputs["extraction_run_id"]),
         {:ok, artifact_id} <- Ecto.UUID.cast(inputs["text_artifact_id"]) do
      run = Ingestion.get_processing_run!(run_id)
      artifact = Ingestion.get_derived_artifact!(artifact_id)

      metadata =
        if policy.text_input == :ocr,
          do: BrusselsWtf.PDF.Processor.metadata(%{ocr_profile: :scanned_declaration}),
          else: BrusselsWtf.PDF.Processor.metadata()

      if policy.text_input == :ocr and run.inputs["ocr_profile"] != "scanned_declaration",
        do: raise(ArgumentError, "declaration requires the inspected OCR profile")

      {output_kind, link_role, expected_processor} =
        case {policy.text_input, run.processor_role} do
          {:native, :native_extraction} ->
            {"native-text", "native_output",
             {metadata.native_processor_name, metadata.native_processor_version,
              metadata.config_hash}}

          {:ocr, :ocr} ->
            {"ocr-text", "ocr_output",
             {metadata.ocr_processor_name, metadata.ocr_processor_version, metadata.config_hash}}

          _ ->
            raise ArgumentError, "relationship verification requires an extraction text run"
        end

      linked =
        Repo.query!(
          """
          SELECT artifacts.id::text
            FROM processing_run_artifacts AS links
            JOIN derived_artifacts AS artifacts ON artifacts.id = links.derived_artifact_id
           WHERE links.processing_run_id = $1::text::uuid
             AND links.derived_artifact_id = $2::text::uuid
             AND links.role = $3
          """,
          [run.id, artifact.id, link_role]
        )

      actual_processor = {run.processor_name, run.processor_version, run.config_hash}

      unless linked.rows == [[artifact.id]] and run.source_version_id == version.id and
               run.status == :succeeded and run.quality_measurements["accepted"] == true and
               match?(%DateTime{}, run.completed_at) and actual_processor == expected_processor and
               artifact.source_version_id == version.id and
               artifact.input_sha256 == version.sha256 and
               artifact.processor_name == run.processor_name and
               artifact.processor_version == run.processor_version and
               artifact.config_hash == run.config_hash and
               artifact.quality_measurements["accepted"] == true and
               artifact.output_kind == output_kind and
               artifact.media_type == "text/plain; charset=utf-8" do
        raise ArgumentError,
              "relationship verification requires one accepted checksum-bound extraction artifact"
      end

      {run, artifact}
    else
      _ ->
        raise ArgumentError,
              "relationship verification requires persisted extraction provenance"
    end
  end

  defp validate_processing!(run, artifact, text_run, text_artifact, version, verifier) do
    expected_inputs = %{
      "source_version_sha256" => version.sha256,
      "ruleset_version" => verifier.ruleset_version,
      "extraction_run_id" => text_run.id,
      "text_artifact_id" => text_artifact.id
    }

    expected_output = %{
      "schema_version" => verifier.ruleset_version,
      "claim_sha256" => artifact.output_sha256
    }

    {expected_inputs, expected_output} =
      if verifier.id == :ixelles_mandate_declaration_v2 do
        {:ok, document} = MandateDeclaration.contract(version.sha256)
        declaration = MandateDeclaration.metadata(document)

        {Map.put(expected_inputs, "mandate_declaration", declaration),
         Map.put(expected_output, "mandate_declaration", declaration)}
      else
        {expected_inputs, expected_output}
      end

    unless run.source_version_id == version.id and run.status == :succeeded and
             run.processor_role == :relationship_verification and
             run.processor_name == verifier.processor_name and
             run.processor_version == verifier.processor_version and
             run.config_hash == verifier.config_hash and
             run.quality_measurements["accepted"] == true and
             match?(%DateTime{}, run.completed_at) and run.inputs == expected_inputs and
             run.output == expected_output do
      raise ArgumentError, "processing run does not match the trusted Ixelles verifier contract"
    end

    unless artifact.source_version_id == version.id and artifact.processing_run_id == run.id and
             artifact.input_sha256 == version.sha256 and
             artifact.processor_name == run.processor_name and
             artifact.processor_version == run.processor_version and
             artifact.config_hash == run.config_hash and
             artifact.output_kind == verifier.artifact_kind and
             artifact.quality_measurements["accepted"] == true and
             artifact.media_type == "application/json" and
             artifact.schema_version == verifier.ruleset_version do
      raise ArgumentError, "derived artifact does not match the trusted Ixelles verifier contract"
    end
  end

  defp validate_archives!(
         version,
         artifact,
         text_run,
         text_artifact,
         fact,
         person,
         commune,
         locator,
         verifier,
         policy
       ) do
    source_bytes = archive_bytes!(version.object_key, "archived source bytes")

    unless BrusselsWtf.Digest.sha256(source_bytes) == version.sha256 and
             byte_size(source_bytes) == version.byte_size do
      raise ArgumentError, "archived source bytes do not match the SourceVersion"
    end

    rerun =
      case policy.text_input do
        :native ->
          case BrusselsWtf.PDF.Processor.native(
                 %{sha256: version.sha256, media_type: version.media_type},
                 source_bytes
               ) do
            {:ok, result} -> result
            {:error, _reason} -> raise ArgumentError, "configured native extraction rerun failed"
          end

        :ocr ->
          case BrusselsWtf.PDF.Processor.ocr(
                 %{
                   sha256: version.sha256,
                   media_type: version.media_type,
                   ocr_profile: :scanned_declaration
                 },
                 source_bytes,
                 text_run.inputs["pages"]
               ) do
            {:ok, result} -> result
            {:error, _reason} -> raise ArgumentError, "configured OCR rerun failed"
          end
      end

    rerun =
      if policy.evidence == :declaration_row do
        rerun
        |> Map.put(:text, MandateDeclaration.safe_text(version.sha256, rerun.text))
        |> Map.update!(
          :quality_measurements,
          &MandateDeclaration.quality(version.sha256, &1, :ocr)
        )
      else
        rerun
      end

    text_bytes = archive_bytes!(text_artifact.object_key, "archived extracted text")

    unless rerun.quality_measurements["accepted"] == true and rerun.text == text_bytes and
             rerun.quality_measurements == text_artifact.quality_measurements and
             BrusselsWtf.Digest.sha256(rerun.text) == text_artifact.output_sha256 and
             byte_size(rerun.text) == text_artifact.byte_size do
      raise ArgumentError,
            "configured extraction rerun does not match the archived artifact"
    end

    unless direct_evidence?(policy.evidence, text_bytes, fact, person, commune, locator) do
      raise ArgumentError,
            "official text must directly and unambiguously bind the verified public-mandate evidence"
    end

    artifact_bytes = archive_bytes!(artifact.object_key, "archived relationship artifact")

    unless BrusselsWtf.Digest.sha256(artifact_bytes) == artifact.output_sha256 and
             byte_size(artifact_bytes) == artifact.byte_size do
      raise ArgumentError, "archived relationship artifact does not match its checksum"
    end

    decoded =
      case Jason.decode(artifact_bytes) do
        {:ok, payload} -> payload
        _ -> raise ArgumentError, "relationship artifact is not valid JSON"
      end

    expected = semantic_payload(fact, person, commune, version, verifier)

    unless decoded == expected do
      raise ArgumentError, "semantic payload does not exactly match the sourced fact"
    end
  end

  defp direct_evidence?(:minutes_decision, text, fact, person, commune, locator) do
    direct_mandate_evidence?(text, fact, person, commune, locator)
  end

  defp direct_evidence?(:declaration_row, text, fact, person, _commune, _locator) do
    direct_declaration_evidence?(text, fact, person)
  end

  defp direct_evidence?(:gazette_act, text, fact, person, _commune, locator) do
    direct_gazette_evidence?(text, fact, person, locator)
  end

  def direct_gazette_evidence?(text, fact, person, locator) when is_binary(text) do
    entity = Identity.get_legal_entity!(fact.object_id)
    corroborator = person.corroborating_facts["enterprise_number"]

    valid_identity? =
      person.resolution_basis == :corroborated_name and
        is_binary(corroborator) and corroborator == entity.enterprise_number and
        String.contains?(digits(fact.evidence_excerpt), entity.enterprise_number)

    location_ok? = fact.evidence_location == "publication #{locator.meeting_identifier}"

    bounded? =
      bounded_gazette_construction?(
        fact.evidence_excerpt,
        person.legal_name,
        fact.object_label,
        entity.registered_name,
        entity.enterprise_number,
        fact.effective_from,
        locator.meeting_identifier
      )

    valid_identity? and location_ok? and bounded? and
      String.contains?(text, fact.evidence_excerpt) and
      unique_active_name?(person)
  end

  defp bounded_gazette_construction?(
         excerpt,
         legal_name,
         role,
         company_name,
         enterprise_number,
         effective_from,
         meeting_identifier
       ) do
    date = Regex.escape(Date.to_iso8601(effective_from))
    name = Regex.escape(legal_name)
    role = Regex.escape(role)
    company = Regex.escape(company_name)
    number = Regex.escape(enterprise_number)
    act = meeting_identifier |> String.split("-") |> List.last()

    verb =
      case act do
        "appointment" ->
          "(?:est\\s+nomm(?:é|ée)|wordt\\s+benoemd|is\\s+appointed)"

        "cessation" ->
          "(?:n['’]est\\s+plus|is\\s+niet\\s+langer|is\\s+no\\s+longer)"

        _ ->
          nil
      end

    is_binary(verb) and
      Regex.match?(
        Regex.compile!(
          "#{date}\\s+#{name}\\s+#{verb}\\s+#{role}\\s+de\\s+#{company}\\s+\\(#{number}\\)",
          "isu"
        ),
        excerpt
      )
  end

  defp digits(value) when is_binary(value), do: String.replace(value, ~r/[^0-9]/, "")

  defp unique_active_name?(person) do
    name_count =
      Repo.query!(
        "SELECT count(*) FROM people WHERE status = 'active' AND legal_name = $1",
        [person.legal_name]
      )

    name_count.rows == [[1]]
  end

  @doc false
  def direct_declaration_evidence?(text, fact, person) when is_binary(text) do
    version = Ingestion.get_source_version!(fact.source_version_id)

    with {:ok, document} <-
           MandateDeclaration.parse(version.sha256, fact.authoritative_url, text),
         true <- MandateDeclaration.matches?(fact, person, document),
         true <- MandateDeclaration.unique_person?(person) do
      true
    else
      _ -> false
    end
  end

  @doc false
  def direct_mandate_evidence?(text, fact, person, commune, locator) do
    valid_identity? =
      person.resolution_basis == :explicit_identifier and
        is_binary(person.explicit_identifier) and person.explicit_identifier != "" and
        String.contains?(fact.evidence_excerpt, person.explicit_identifier)

    valid_context? =
      fact.evidence_location == "decision #{locator.meeting_identifier}" and
        bounded_mandate_construction?(
          fact.evidence_excerpt,
          person.legal_name,
          person.explicit_identifier,
          commune.name,
          fact.effective_from
        )

    valid_identity? and valid_context? and is_binary(text) and
      String.contains?(text, fact.evidence_excerpt) and unique_active_identity?(person)
  end

  defp bounded_mandate_construction?(
         excerpt,
         legal_name,
         identifier,
         commune_name,
         effective_from
       ) do
    date = Regex.escape(Date.to_iso8601(effective_from))
    name = Regex.escape(legal_name)
    identifier = Regex.escape(identifier)
    commune = Regex.escape(commune_name)
    boundary_date = "(?<![\\p{L}\\p{N}])#{date}(?![\\p{L}\\p{N}])"
    boundary_name = "(?<![\\p{L}\\p{N}])#{name}(?![\\p{L}\\p{N}])"

    verb =
      "(?:is\\s+appointed|was\\s+appointed|is\\s+elected|was\\s+elected|est\\s+nomm(?:é|ée)|est\\s+désign(?:é|ée)|est\\s+él(?:u|ue)|wordt\\s+benoemd|werd\\s+benoemd|is\\s+verkozen)"

    mandate =
      "(?:#{commune}\\s+(?:municipal|communal)\\s+council|conseil\\s+communal\\s+d['’]Ixelles|gemeenteraad\\s+van\\s+Elsene)"

    Regex.match?(
      Regex.compile!(
        "#{boundary_date}\\s+#{boundary_name}\\s+\\[#{identifier}\\]\\s+#{verb}\\s+(?:to\\s+the\\s+)?#{mandate}",
        "isu"
      ),
      excerpt
    )
  end

  defp unique_active_identity?(person) do
    name_count =
      Repo.query!(
        "SELECT count(*) FROM people WHERE status = 'active' AND legal_name = $1",
        [person.legal_name]
      )

    identifier_count =
      Repo.query!(
        "SELECT count(*) FROM people WHERE status = 'active' AND explicit_identifier = $1",
        [person.explicit_identifier]
      )

    name_count.rows == [[1]] and identifier_count.rows == [[1]]
  end

  defp archive_bytes!(object_key, label) do
    case BrusselsWtf.Archive.get(object_key) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> raise ArgumentError, "#{label} are unavailable"
    end
  end

  defp semantic_payload(fact, person, commune, version, verifier) do
    payload = %{
      "schema_version" => verifier.ruleset_version,
      "subject" => %{
        "type" => "person",
        "id" => person.id,
        "legal_name" => person.legal_name,
        "resolution_basis" => Atom.to_string(person.resolution_basis)
      },
      "object" => semantic_object(fact, commune),
      "relationship" => %{
        "kind" => Atom.to_string(fact.kind),
        "effective_from" => Date.to_iso8601(fact.effective_from),
        "effective_to" => date_string(fact.effective_to)
      },
      "evidence" => %{
        "source_version_id" => version.id,
        "source_sha256" => version.sha256,
        "authoritative_url" => version.source_record.origin_url,
        "source_authority" => Atom.to_string(fact.source_authority),
        "kind" => Atom.to_string(fact.evidence_kind),
        "excerpt" => fact.evidence_excerpt,
        "location" => fact.evidence_location
      }
    }

    payload =
      if verifier.id == :ixelles_mandate_declaration_v2,
        do: Map.put(payload, "mandate_declaration", fact.mandate_declaration),
        else: payload

    if verifier.id == :belgian_official_gazette_management_v1,
      do: put_in(payload, ["relationship", "role"], fact.object_label),
      else: payload
  end

  defp semantic_object(%{object_type: :legal_entity} = fact, _commune) do
    entity = Identity.get_legal_entity!(fact.object_id)

    %{
      "type" => "legal_entity",
      "id" => entity.id,
      "enterprise_number" => entity.enterprise_number,
      "registered_name" => entity.registered_name
    }
  end

  defp semantic_object(_fact, commune) do
    %{
      "type" => "commune",
      "id" => commune.id,
      "slug" => commune.slug,
      "name" => commune.name
    }
  end

  defp relationship_artifact!(run_id) do
    result =
      Repo.query!(
        """
        SELECT artifacts.id::text
          FROM processing_run_artifacts AS links
          JOIN derived_artifacts AS artifacts ON artifacts.id = links.derived_artifact_id
         WHERE links.processing_run_id = $1::text::uuid
           AND links.role = 'relationship_claim'
        """,
        [run_id]
      )

    case result.rows do
      [[artifact_id]] ->
        Ingestion.get_derived_artifact!(artifact_id)

      _ ->
        raise ArgumentError, "trusted processing run requires exactly one relationship artifact"
    end
  end

  # Each verifier lane owns one current fact per (subject, object, kind):
  # the minutes lane and the declaration lane are complementary sourced
  # roles, so a declaration fact never supersedes the council mandate.
  defp lock_semantic_key!(fact, verifier) do
    key =
      Enum.join(
        [
          fact.subject_type,
          fact.subject_id,
          fact.object_type,
          fact.object_id,
          fact.kind,
          verifier.verifier_id,
          declaration_key(fact)
        ],
        ":"
      )

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end

  defp declaration_key(fact), do: (fact.mandate_declaration || %{})["key"] || ""

  defp lock_current_fact(fact, verifier) do
    result =
      Repo.query!(
        """
        SELECT id::text, verification_status, subject_type, subject_id::text, object_type, object_id::text, kind,
               effective_from, effective_to
          FROM sourced_facts
         WHERE subject_type = $1
           AND subject_id = $2::text::uuid
           AND object_type = $3
           AND object_id = $4::text::uuid
           AND kind = $5
           AND verified_by = $6
           AND COALESCE(mandate_declaration ->> 'key', '') = $7
           AND verification_status = 'verified'
         FOR UPDATE
        """,
        [
          Atom.to_string(fact.subject_type),
          fact.subject_id,
          Atom.to_string(fact.object_type),
          fact.object_id,
          Atom.to_string(fact.kind),
          verifier.verifier_id,
          declaration_key(fact)
        ]
      )

    case result.rows do
      [] ->
        nil

      [[id, status, subject_type, subject_id, object_type, object_id, kind, from, to]] ->
        %{
          id: id,
          status: status,
          subject_type: subject_type,
          subject_id: subject_id,
          object_type: object_type,
          object_id: object_id,
          kind: kind,
          effective_from: from,
          effective_to: to
        }

      _ ->
        raise ArgumentError, "multiple current verified facts violate the semantic invariant"
    end
  end

  defp validate_supersession!(%{supersedes_id: nil}, nil), do: :ok

  defp validate_supersession!(%{supersedes_id: nil}, _current) do
    raise ArgumentError, "a current verified fact must be explicitly superseded"
  end

  defp validate_supersession!(fact, %{id: predecessor_id} = current)
       when predecessor_id == fact.supersedes_id do
    same_semantics? =
      current.status == "verified" and current.subject_type == Atom.to_string(fact.subject_type) and
        current.subject_id == fact.subject_id and
        current.object_type == Atom.to_string(fact.object_type) and
        current.object_id == fact.object_id and current.kind == Atom.to_string(fact.kind)

    ordered? =
      if fact.mandate_declaration do
        previous = Identity.get_sourced_fact!(current.id) |> Ash.load!(:source_version)
        incoming = Ingestion.get_source_version!(fact.source_version_id)

        previous.mandate_declaration != nil and
          previous.mandate_declaration["key"] == fact.mandate_declaration["key"] and
          previous.mandate_declaration["revision"] < fact.mandate_declaration["revision"] and
          DateTime.compare(
            incoming.first_retrieved_at,
            previous.source_version.first_retrieved_at
          ) == :gt
      else
        Date.compare(fact.effective_from, current.effective_from) in [:eq, :gt]
      end

    unless same_semantics? and ordered? do
      raise ArgumentError,
            "supersession requires the current verified fact with identical semantics"
    end
  end

  defp validate_supersession!(_fact, _current) do
    raise ArgumentError, "supersession requires the current verified fact"
  end

  defp set_transition_context!(run, artifact, verifier) do
    values = [
      {"brussels_wtf.trusted_relationship_verifier", verifier.verifier_id},
      {"brussels_wtf.verification_processing_run_id", run.id},
      {"brussels_wtf.verification_artifact_id", artifact.id},
      {"brussels_wtf.verification_processor_version", run.processor_version},
      {"brussels_wtf.verification_ruleset_version", verifier.ruleset_version},
      {"brussels_wtf.verification_config_sha256", run.config_hash},
      {"brussels_wtf.verification_generation", run.generation_key}
    ]

    Enum.each(values, fn {key, value} ->
      Repo.query!("SELECT set_config($1, $2, true)", [key, value])
    end)
  end

  defp date_string(nil), do: nil
  defp date_string(date), do: Date.to_iso8601(date)

  defp fetch!(id) when is_atom(id) do
    case Map.fetch(@registry, id) do
      {:ok, verifier} -> verifier
      :error -> raise ArgumentError, "untrusted relationship verifier: #{inspect(id)}"
    end
  end

  defp fetch!(verifier_id) when is_binary(verifier_id) do
    Enum.find(@registry, {:error, :unknown}, fn {_id, verifier} ->
      verifier.verifier_id == verifier_id
    end)
    |> case do
      {_id, verifier} -> verifier
      :error -> raise ArgumentError, "untrusted relationship verifier: #{verifier_id}"
    end
  end
end
