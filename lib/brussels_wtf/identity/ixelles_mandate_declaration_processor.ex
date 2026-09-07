defmodule BrusselsWtf.Identity.IxellesMandateDeclarationProcessor do
  @moduledoc """
  Source-specific processor for public-mandate declarations published by the
  Commune of Ixelles (the "Liste des mandats" transparency document).

  Automated retrieval, private evidentiary retention, and minimal public
  citation are permitted under written terms confirmed by the operator
  (issue #43, 2026-09-04). Full PDF snapshots remain private evidence. Derived
  text retains only validated declaration fields; remuneration data, fiscal
  sheets, national numbers, addresses and signature images are never projected.

  It creates only the deterministic semantic artifact consumed by the trusted
  verifier. It never accepts reviewer provenance or a human approval.
  """

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.MandateDeclaration
  alias BrusselsWtf.Identity.TrustedVerifier
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Repo

  require Ash.Query

  @verifier :ixelles_mandate_declaration_v2

  @doc "Acquire the single approved report through its official index and the normal immutable retrieval pipeline."
  def acquire(commune_id, poll_run_id) do
    commune = Ingestion.get_commune!(commune_id)
    if commune.slug != "ixelles", do: raise(ArgumentError, "unsupported declaring authority")
    now = BrusselsWtf.Clock.utc_now()

    index =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: MandateDeclaration.index(),
        parent_index_url: MandateDeclaration.index(),
        meeting_identifier: "mandate-index",
        role: :index,
        language: :fr,
        observed_label: "Liste des mandats",
        discovered_at: now
      })

    with :ok <- Ingestion.Pipeline.retrieve(index.id, poll_run_id, "mandate-index:#{poll_run_id}") do
      record =
        Ingestion.SourceRecord
        |> Ash.Query.filter(commune_id == ^commune.id and origin_url == ^index.url)
        |> Ash.read_one!(authorize?: false)
        |> Ash.load!(:versions)

      version = Enum.max_by(record.versions, & &1.first_retrieved_at, DateTime)
      {:ok, html} = BrusselsWtf.Archive.get(version.object_key)

      links =
        Regex.scan(~r/href\s*=\s*["']([^"']+)["']/i, html)
        |> Enum.map(fn [_, href] -> URI.merge(index.url, href) |> URI.to_string() end)

      if MandateDeclaration.origin() in links do
        locator =
          Ingestion.upsert_locator!(%{
            commune_id: commune.id,
            url: MandateDeclaration.origin(),
            parent_index_url: index.url,
            meeting_identifier: "mandats-2024",
            role: :mandate_declaration,
            language: :fr,
            observed_label: "Liste des mandats 2024",
            discovered_at: now
          })

        Ingestion.Pipeline.retrieve(locator.id, poll_run_id, "mandate-document:#{poll_run_id}")
      else
        open_document_review(version, :missing_official_declaration_link)
      end
    end
  end

  @doc """
  Parses accepted OCR text for declaration source versions and records
  candidate public-mandate facts for resolvable declarants.
  """
  def enqueue_waiting_for_source_version!(source_version_id) do
    version =
      Ingestion.get_source_version!(source_version_id)
      |> Ash.load!(source_record: [:commune])

    if declaration_version?(version) do
      case accepted_ocr_text(version) do
        {:ok, text} -> process_declaration_text(version, text)
        _ -> :ok
      end
    else
      :ok
    end
  end

  @doc false
  def declaration_version?(version) do
    version.source_record.role == :mandate_declaration and
      version.source_record.commune.slug == "ixelles"
  rescue
    _ -> false
  end

  def enqueue_if_eligible!(fact) do
    if eligible?(fact) do
      %{fact_id: fact.id}
      |> BrusselsWtf.Workers.VerifyIxellesMandateDeclaration.new()
      |> Oban.insert!()
    end

    fact
  end

  def eligible?(fact) do
    fact = Ash.load!(fact, source_version: [source_record: [:commune]])
    policy = TrustedVerifier.declaration_contract().source

    with %{verification_status: :unreviewed, source_version: version} when not is_nil(version) <-
           fact,
         %{source_record: record} when not is_nil(record) <- version,
         %{commune: commune} when not is_nil(commune) <- record,
         {:ok, person} <- Identity.get_person(fact.subject_id),
         true <-
           fact.subject_type == :person and person.status == :active and
             person.resolution_basis == :explicit_identifier and
             is_binary(person.explicit_identifier) and person.explicit_identifier != "" and
             fact.object_type == :commune and fact.object_id == commune.id and
             fact.kind == :public_mandate and fact.source_authority == :municipal_declaration and
             fact.evidence_kind == :official_declaration and match?(%Date{}, fact.effective_from) and
             record.role == policy.record_role and
             fact.authoritative_url == record.origin_url and
             commune.slug == "ixelles" and
             declaration_origin_url?(record.origin_url) and
             corroborated_person?(fact.subject_id, commune.id) do
      true
    else
      _ -> false
    end
  rescue
    Ash.Error.Invalid -> false
    Ash.Error.Query.NotFound -> false
  end

  def process(fact_id) do
    case Identity.get_sourced_fact(fact_id) do
      {:ok, %{verification_status: :verified}} ->
        :ok

      {:ok, fact} ->
        cond do
          not eligible?(fact) -> :ok
          predecessor_pending?(fact) -> {:error, :predecessor_pending}
          true -> process_eligible(fact)
        end

      _ ->
        :ok
    end
  end

  defp predecessor_pending?(%{supersedes_id: nil}), do: false

  defp predecessor_pending?(fact),
    do: Identity.get_sourced_fact!(fact.supersedes_id).verification_status == :unreviewed

  def open_terminal_review(fact_id, reason) do
    case Identity.get_sourced_fact(fact_id) do
      {:ok, fact} ->
        BrusselsWtf.Review.open_review_case!(%{
          kind: :evidence,
          affected_record_id: fact.id,
          affected_record_type: "sourced_fact",
          source_version_id: fact.source_version_id,
          processing_generation: "ixelles-mandate-declaration:#{fact.id}:#{reason}",
          urgency: :normal,
          summary: "Automatic Ixelles mandate-declaration verification failed closed",
          diagnostics: %{"classification" => to_string(reason)}
        })

        :ok

      _ ->
        :ok
    end
  end

  ## Parsing and candidate recording

  defp process_declaration_text(version, text) do
    with {:ok, document} <-
           MandateDeclaration.parse(version.sha256, version.source_record.origin_url, text) do
      people =
        Identity.Person
        |> Ash.Query.filter(status == :active)
        |> Ash.read!(authorize?: false, domain: Identity)
        |> Enum.filter(
          &(MandateDeclaration.normalize(&1.legal_name) == MandateDeclaration.name(document))
        )

      case people do
        [person] ->
          if corroborated_person?(person.id, version.source_record.commune_id) do
            record_fact!(version, person, document)
          else
            open_document_review(version, :uncorroborated_person)
          end

        [] ->
          open_document_review(version, :unresolved_person)

        _ ->
          open_document_review(version, :ambiguous_person)
      end
    else
      {:error, reason} -> open_document_review(version, reason)
    end
  end

  defp record_fact!(version, person, document) do
    # Serialize candidate discovery as well as verification. Oban uniqueness is
    # not the authority for at-least-once acquisition or correction delivery.
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "declaration-candidate:#{person.id}:#{document.key}"
      ])

      existing =
        Identity.SourcedFact
        |> Ash.Query.filter(subject_id == ^person.id and source_version_id == ^version.id)
        |> Ash.read!(authorize?: false, domain: Identity)
        |> Enum.find(&(&1.mandate_declaration == MandateDeclaration.metadata(document)))

      if existing do
        enqueue_if_eligible!(existing)
      else
        predecessor =
          Identity.SourcedFact
          |> Ash.Query.filter(
            subject_id == ^person.id and verification_status in [:unreviewed, :verified]
          )
          |> Ash.read!(authorize?: false, domain: Identity)
          |> Enum.filter(
            &(not is_nil(&1.mandate_declaration) and &1.mandate_declaration["key"] == document.key and
                &1.mandate_declaration["revision"] < document.revision)
          )
          |> Enum.max_by(& &1.mandate_declaration["revision"], fn -> nil end)

        Identity.record_sourced_fact!(%{
          subject_type: :person,
          subject_id: person.id,
          object_type: :commune,
          object_id: version.source_record.commune_id,
          kind: :public_mandate,
          effective_from: document.effective_from,
          effective_to: document.effective_to,
          source_version_id: version.id,
          authoritative_url: version.source_record.origin_url,
          source_authority: :municipal_declaration,
          evidence_kind: :official_declaration,
          evidence_excerpt: document.row,
          evidence_location: MandateDeclaration.location(document),
          mandate_declaration: MandateDeclaration.metadata(document),
          supersedes_id: predecessor && predecessor.id
        })
      end
    end)

    :ok
  end

  defp corroborated_person?(person_id, commune_id) do
    Repo.query!(
      """
      SELECT 1 FROM sourced_facts
      WHERE subject_id = $1::text::uuid AND object_id = $2::text::uuid
        AND verified_by = 'ixelles_municipal_minutes_public_mandate_v1'
        AND trusted_ixelles_public_mandate_fact(sourced_facts)
      LIMIT 1
      """,
      [person_id, commune_id]
    ).num_rows == 1
  end

  defp declaration_origin_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "www.ixelles.be", path: path} when is_binary(path) ->
        Regex.match?(~r<\A/site/(?:fr|nl)/download/transparence/mandats-[0-9]{4}\.pdf\z>, path)

      _ ->
        false
    end
  end

  defp accepted_ocr_text(version) do
    {:ok, _run, _artifact, text} = accepted_declaration_input(version)
    {:ok, text}
  rescue
    _ -> :error
  end

  ## Verification

  defp process_eligible(fact) do
    fact = Ash.load!(fact, source_version: [source_record: [:commune]])
    person = Identity.get_person!(fact.subject_id)
    version = fact.source_version

    with {:ok, text_run, text_artifact, text} <- accepted_declaration_input(version),
         true <- TrustedVerifier.direct_declaration_evidence?(text, fact, person) do
      persist_and_verify(fact, person, version, text_run, text_artifact)
    else
      false ->
        open_terminal_review(fact.id, :direct_declaration_evidence_failed)
        :ok

      {:error, :extraction_not_ready} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  # Discovery consumes the immutable accepted artifact. The trusted verifier
  # independently recomputes OCR in its isolated :ocr worker before publication.
  defp accepted_declaration_input(version) do
    metadata = BrusselsWtf.PDF.Processor.metadata(%{ocr_profile: :scanned_declaration})

    version
    |> Ash.load!(:processing_runs)
    |> Map.fetch!(:processing_runs)
    |> Enum.filter(
      &(&1.processor_role == :ocr and &1.status == :succeeded and
          &1.quality_measurements["accepted"] == true and
          &1.processor_name == metadata.ocr_processor_name and
          &1.processor_version == metadata.ocr_processor_version and
          &1.config_hash == metadata.config_hash)
    )
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
    |> Enum.flat_map(fn run ->
      run
      |> Ash.load!(:derived_artifacts)
      |> Map.fetch!(:derived_artifacts)
      |> Enum.filter(
        &(&1.output_kind == "ocr-text" and &1.quality_measurements["accepted"] == true)
      )
      |> Enum.map(&{run, &1})
    end)
    |> case do
      [{run, artifact} | _] ->
        with {:ok, raw} <- BrusselsWtf.Archive.get(version.object_key),
             true <- BrusselsWtf.Digest.sha256(raw) == version.sha256,
             true <- byte_size(raw) == version.byte_size,
             {:ok, text} <- BrusselsWtf.Archive.get(artifact.object_key),
             true <- BrusselsWtf.Digest.sha256(text) == artifact.output_sha256,
             true <- byte_size(text) == artifact.byte_size do
          {:ok, run, artifact, text}
        else
          {:error, reason} -> {:error, reason}
          false -> {:error, :extraction_artifact_mismatch}
        end

      [] ->
        {:error, :extraction_not_ready}
    end
  end

  defp persist_and_verify(fact, person, version, text_run, text_artifact) do
    contract = TrustedVerifier.declaration_contract()
    commune = version.source_record.commune
    claim = TrustedVerifier.declaration_semantic_payload(fact, person, commune, version)
    claim_bytes = Jason.encode!(claim)

    with {:ok, archived} <- BrusselsWtf.Archive.store(claim_bytes, :derived) do
      generation_key =
        "relationship:ixelles-mandate-declaration-v2:#{fact.id}:#{text_artifact.output_sha256}"

      run =
        Ingestion.record_processing_run!(%{
          source_version_id: version.id,
          generation_key: generation_key,
          processor_role: :relationship_verification,
          inputs: %{
            "source_version_sha256" => version.sha256,
            "ruleset_version" => contract.ruleset_version,
            "extraction_run_id" => text_run.id,
            "text_artifact_id" => text_artifact.id,
            "mandate_declaration" => fact.mandate_declaration
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
    prefix = "ixelles-mandate-declaration:#{fact_id}:"

    BrusselsWtf.Review.Case
    |> Ash.Query.filter(status == :open and kind == :evidence and affected_record_id == ^fact_id)
    |> Ash.read!(authorize?: false, domain: BrusselsWtf.Review)
    |> Enum.filter(&String.starts_with?(&1.processing_generation || "", prefix))
    |> Enum.each(&BrusselsWtf.Review.complete_retry!/1)
  end

  defp complete_if_queued(%{status: :succeeded} = run, _artifact, _contract), do: run

  defp complete_if_queued(%{status: :queued} = run, artifact, contract) do
    now = BrusselsWtf.Clock.utc_now()

    Ingestion.complete_processing_run!(run, %{
      status: :succeeded,
      output: %{
        "schema_version" => contract.ruleset_version,
        "claim_sha256" => artifact.output_sha256,
        "mandate_declaration" =>
          Ingestion.get_processing_run!(run.id).inputs["mandate_declaration"]
      },
      quality_measurements: %{"accepted" => true},
      started_at: now,
      completed_at: now,
      duration_ms: 0
    })
  end

  def review_document(version, reason), do: open_document_review(version, reason)

  defp open_document_review(version, reason) do
    BrusselsWtf.Review.open_review_case!(%{
      kind: :evidence,
      affected_record_id: version.id,
      affected_record_type: "source_version",
      source_version_id: version.id,
      processing_generation: "ixelles-mandate-declaration:#{version.id}:#{reason}",
      urgency: :normal,
      summary: "Ixelles mandate declaration could not be parsed deterministically",
      diagnostics: %{"classification" => to_string(reason)}
    })

    :ok
  end
end
