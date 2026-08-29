defmodule BrusselsWtf.Identity.IxellesPublicMandateProcessor do
  @moduledoc """
  Automatic source-specific processor for direct public-mandate decisions in
  official Ixelles minutes.

  It creates only the deterministic semantic artifact consumed by the trusted
  verifier. It never accepts reviewer provenance or a human approval.
  """

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.TrustedVerifier
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Repo

  require Ash.Query

  @verifier :ixelles_municipal_minutes_public_mandate_v1

  def enqueue_if_eligible!(fact) do
    if eligible?(fact) do
      %{fact_id: fact.id}
      |> BrusselsWtf.Workers.VerifyIxellesPublicMandate.new()
      |> Oban.insert!()
    end

    fact
  end

  def eligible?(fact) do
    fact = Ash.load!(fact, source_version: [source_record: [:commune]])

    with %{verification_status: :unreviewed, source_version: version} when not is_nil(version) <-
           fact,
         %{source_record: record} when not is_nil(record) <- version,
         %{commune: commune} when not is_nil(commune) <- record,
         {:ok, person} <- Identity.get_person(fact.subject_id),
         configured <- BrusselsWtf.Communes.configuration!("ixelles") do
      uri = URI.parse(record.origin_url)

      fact.subject_type == :person and person.status == :active and
        person.resolution_basis == :explicit_identifier and is_binary(person.explicit_identifier) and
        person.explicit_identifier != "" and
        fact.object_type == :commune and fact.object_id == commune.id and
        fact.kind == :public_mandate and fact.source_authority == :municipal_decision and
        fact.evidence_kind == :official_decision and match?(%Date{}, fact.effective_from) and
        public_evidence_location?(fact.evidence_location) and commune.slug == "ixelles" and
        commune.name == configured.name and commune.index_url == configured.index_url and
        record.role == :minutes and fact.authoritative_url == record.origin_url and
        official_minutes_url?(uri)
    else
      _ -> false
    end
  rescue
    Ash.Error.Invalid -> false
    Ash.Error.Query.NotFound -> false
  end

  def enqueue_waiting_for_source_version!(source_version_id) do
    BrusselsWtf.Identity.SourcedFact
    |> Ash.Query.filter(
      source_version_id == ^source_version_id and verification_status == :unreviewed
    )
    |> Ash.read!(authorize?: false, domain: Identity)
    |> Enum.each(&enqueue_if_eligible!/1)

    :ok
  end

  def process(fact_id) do
    case Identity.get_sourced_fact(fact_id) do
      {:ok, %{verification_status: :verified}} ->
        :ok

      {:ok, fact} ->
        if eligible?(fact), do: process_eligible(fact), else: :ok

      _ ->
        :ok
    end
  end

  def open_terminal_review(fact_id, reason) do
    case Identity.get_sourced_fact(fact_id) do
      {:ok, fact} ->
        BrusselsWtf.Review.open_review_case!(%{
          kind: :evidence,
          affected_record_id: fact.id,
          affected_record_type: "sourced_fact",
          source_version_id: fact.source_version_id,
          processing_generation: "ixelles-public-mandate:#{fact.id}:#{reason}",
          urgency: :normal,
          summary: "Automatic Ixelles public-mandate verification failed closed",
          diagnostics: %{"classification" => to_string(reason)}
        })

        :ok

      _ ->
        :ok
    end
  end

  defp process_eligible(fact) do
    fact = Ash.load!(fact, source_version: [source_record: [:commune]])
    person = Identity.get_person!(fact.subject_id)
    version = fact.source_version
    commune = version.source_record.commune

    with {:ok, locator} <- official_locator_context(version, commune),
         {:ok, text_run, text_artifact, text} <- accepted_text_input(version),
         true <-
           TrustedVerifier.direct_mandate_evidence?(text, fact, person, commune, locator) do
      persist_and_verify(fact, person, commune, version, text_run, text_artifact)
    else
      false ->
        open_terminal_review(fact.id, :direct_mandate_evidence_failed)
        :ok

      {:error, :official_locator_ambiguous} ->
        open_terminal_review(fact.id, :official_locator_ambiguous)
        :ok

      {:error, :extraction_not_ready} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp official_locator_context(version, commune) do
    record = version.source_record
    configured = BrusselsWtf.Communes.configuration!("ixelles")

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
           AND locators.role = 'minutes'
           AND observations.source_version_id = $4::text::uuid
           AND observations.status IN ('success', 'unchanged')
           AND observations.sha256 = $5
           AND observations.final_url = $2
        """,
        [commune.id, record.origin_url, configured.index_url, version.id, version.sha256]
      )

    case result.rows do
      [[meeting_identifier, scheduled_on]] ->
        {:ok, %{meeting_identifier: meeting_identifier, scheduled_on: scheduled_on}}

      _ ->
        {:error, :official_locator_ambiguous}
    end
  end

  defp accepted_text_input(version) do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    candidates =
      version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.flat_map(fn run -> accepted_run_artifact(run, version, metadata) end)
      |> Enum.sort_by(
        fn {run, _artifact} ->
          {DateTime.to_unix(run.completed_at, :microsecond), run.id}
        end,
        :desc
      )

    case candidates do
      [{run, artifact} | _] ->
        with {:ok, raw} <- BrusselsWtf.Archive.get(version.object_key),
             true <- BrusselsWtf.Digest.sha256(raw) == version.sha256,
             true <- byte_size(raw) == version.byte_size,
             {:ok, rerun} <-
               BrusselsWtf.PDF.Processor.native(
                 %{sha256: version.sha256, media_type: version.media_type},
                 raw
               ),
             true <- rerun.quality_measurements["accepted"] == true,
             {:ok, text} <- BrusselsWtf.Archive.get(artifact.object_key),
             true <- rerun.text == text,
             true <- rerun.quality_measurements == artifact.quality_measurements,
             true <- BrusselsWtf.Digest.sha256(text) == artifact.output_sha256,
             true <- byte_size(text) == artifact.byte_size do
          {:ok, run, artifact, text}
        else
          {:error, _reason} -> {:error, :archive_unavailable}
          false -> {:error, :extraction_rerun_mismatch}
        end

      [] ->
        {:error, :extraction_not_ready}
    end
  end

  defp accepted_run_artifact(run, version, metadata) do
    {kind, role, expected_processor} =
      case run.processor_role do
        :native_extraction ->
          {"native-text", :native_output,
           {metadata.native_processor_name, metadata.native_processor_version,
            metadata.config_hash}}

        _ ->
          {nil, nil, nil}
      end

    actual_processor = {run.processor_name, run.processor_version, run.config_hash}

    if run.source_version_id == version.id and run.status == :succeeded and
         run.quality_measurements["accepted"] == true and match?(%DateTime{}, run.completed_at) and
         actual_processor == expected_processor do
      run
      |> Ash.load!(:derived_artifacts)
      |> Map.fetch!(:derived_artifacts)
      |> Enum.filter(fn artifact ->
        artifact.source_version_id == version.id and artifact.input_sha256 == version.sha256 and
          artifact.output_kind == kind and artifact.quality_measurements["accepted"] == true and
          artifact.processor_name == run.processor_name and
          artifact.processor_version == run.processor_version and
          artifact.config_hash == run.config_hash and
          artifact.media_type == "text/plain; charset=utf-8" and
          linked?(run.id, artifact.id, role)
      end)
      |> case do
        [artifact] -> [{run, artifact}]
        _ -> []
      end
    else
      []
    end
  end

  defp linked?(run_id, artifact_id, role) do
    import Ash.Expr
    require Ash.Query

    BrusselsWtf.Ingestion.ProcessingRunArtifact
    |> Ash.Query.filter(
      expr(processing_run_id == ^run_id and derived_artifact_id == ^artifact_id and role == ^role)
    )
    |> Ash.read!(authorize?: false, domain: Ingestion)
    |> length() == 1
  end

  defp persist_and_verify(fact, person, commune, version, text_run, text_artifact) do
    contract = TrustedVerifier.ixelles_contract()
    claim = TrustedVerifier.ixelles_semantic_payload(fact, person, commune, version)
    claim_bytes = Jason.encode!(claim)

    with {:ok, archived} <- BrusselsWtf.Archive.store(claim_bytes, :derived) do
      generation_key =
        "relationship:ixelles-public-mandate-v1:#{fact.id}:#{text_artifact.output_sha256}"

      run =
        Ingestion.record_processing_run!(%{
          source_version_id: version.id,
          generation_key: generation_key,
          processor_role: :relationship_verification,
          inputs: %{
            "source_version_sha256" => version.sha256,
            "ruleset_version" => contract.ruleset_version,
            "extraction_run_id" => text_run.id,
            "text_artifact_id" => text_artifact.id
          },
          processor_name: contract.processor_name,
          processor_version: contract.processor_version,
          config_hash: contract.config_hash,
          status: :queued,
          output: %{}
        })

      artifact =
        Ingestion.upsert_derived_artifact!(%{
          source_version_id: version.id,
          processing_run_id: run.id,
          input_sha256: version.sha256,
          output_sha256: archived.sha256,
          processor_name: contract.processor_name,
          processor_version: contract.processor_version,
          config_hash: contract.config_hash,
          output_kind: contract.artifact_kind,
          object_key: archived.object_key,
          media_type: "application/json",
          byte_size: byte_size(claim_bytes),
          schema_version: contract.ruleset_version,
          quality_measurements: %{"accepted" => true}
        })

      Ingestion.link_processing_run_artifact!(%{
        processing_run_id: run.id,
        derived_artifact_id: artifact.id,
        role: :relationship_claim
      })

      run = complete_if_queued(run, artifact, contract)

      try do
        TrustedVerifier.verify!(fact.id, @verifier, run.id)
        resolve_terminal_review_cases!(fact.id)
        :ok
      rescue
        error in ArgumentError -> handle_verify_error(fact.id, error)
      end
    else
      {:error, _reason} -> {:error, :archive_unavailable}
    end
  end

  defp handle_verify_error(fact_id, error) do
    if String.contains?(error.message, "unavailable") or
         String.contains?(error.message, "rerun failed") do
      {:error, :verification_evidence_unavailable}
    else
      open_terminal_review(fact_id, :trusted_verifier_rejected)
      :ok
    end
  end

  defp resolve_terminal_review_cases!(fact_id) do
    prefix = "ixelles-public-mandate:#{fact_id}:"

    BrusselsWtf.Review.Case
    |> Ash.Query.filter(status == :open and kind == :evidence and affected_record_id == ^fact_id)
    |> Ash.read!(authorize?: false, domain: BrusselsWtf.Review)
    |> Enum.filter(&String.starts_with?(&1.processing_generation || "", prefix))
    |> Enum.each(fn review_case ->
      BrusselsWtf.Review.complete_retry!(review_case.id)
    end)
  end

  defp complete_if_queued(%{status: :succeeded} = run, _artifact, _contract), do: run

  defp complete_if_queued(%{status: :queued} = run, artifact, contract) do
    now = BrusselsWtf.Clock.utc_now()

    Ingestion.complete_processing_run!(run, %{
      status: :succeeded,
      output: %{
        "schema_version" => contract.ruleset_version,
        "claim_sha256" => artifact.output_sha256
      },
      quality_measurements: %{"accepted" => true},
      started_at: now,
      completed_at: now,
      duration_ms: 0
    })
  end

  defp complete_if_queued(run, _artifact, _contract), do: run

  defp public_evidence_location?(location) when is_binary(location) do
    Regex.match?(~r/\Adecision [0-9]+(?:[.-][0-9A-Za-z]+)*\z/, location)
  end

  defp public_evidence_location?(_location), do: false

  defp official_minutes_url?(uri) do
    uri.scheme == "https" and uri.port == 443 and uri.host == "www.ixelles.be" and
      is_nil(uri.userinfo) and
      uri.query in [nil, ""] and uri.fragment in [nil, ""] and
      Regex.match?(~r{\A/uploads/conseil/pv/[0-9]+\.pdf\z}, uri.path || "")
  end
end
