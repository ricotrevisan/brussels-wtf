defmodule BrusselsWtf.Identity.IxellesMandateDeclarationProcessor do
  @moduledoc """
  Source-specific processor for public-mandate declarations published by the
  Commune of Ixelles (the "Liste des mandats" transparency document).

  Automated retrieval, private evidentiary retention, and minimal public
  citation are permitted under written terms confirmed by the operator
  (issue #43, 2026-09-04). Remuneration data, fiscal sheets, national
  numbers, addresses, and signatures are never extracted, stored, or
  published.

  It creates only the deterministic semantic artifact consumed by the trusted
  verifier. It never accepts reviewer provenance or a human approval.
  """

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.TrustedVerifier
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Repo

  require Ash.Query

  @verifier :ixelles_mandate_declaration_v1
  @boilerplate_markers [
    "liste des mandats",
    "cellule transparence",
    "vade-mecum",
    "modele de formulaire",
    "declaration faite en execution",
    "arrete d'execution",
    "ordonnance conjointe",
    "y compris pour ceux",
    "compris pour ceux",
    "numero national",
    "nom :",
    "prenom",
    "adresse"
  ]

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
             fact.kind == :public_mandate and fact.source_authority == :municipal_decision and
             fact.evidence_kind == :official_decision and match?(%Date{}, fact.effective_from) and
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
    year = declaration_year!(version)
    commune = version.source_record.commune
    rows = mandate_rows(text)

    if rows == [] do
      open_document_review(version, :no_parseable_mandate_rows)
    end

    Enum.each(rows, fn row -> record_row_candidate(version, commune, row, year) end)

    :ok
  end

  defp record_row_candidate(version, commune, row, year) do
    case resolve_persons(row) do
      [person] -> record_fact!(version, commune, person, row, year)
      [] -> :ok
      _multiple -> open_ambiguity_review(version, row)
    end
  end

  defp record_fact!(version, commune, person, row, year) do
    if existing_candidate?(version, person, row) do
      :ok
    else
      {:ok, period_start} = Date.new(year, 1, 1)
      {:ok, period_end} = Date.new(year, 12, 31)

      fact =
        Identity.record_sourced_fact!(%{
          subject_type: :person,
          subject_id: person.id,
          object_type: :commune,
          object_id: commune.id,
          kind: :public_mandate,
          effective_from: period_start,
          effective_to: period_end,
          source_version_id: version.id,
          authoritative_url: version.source_record.origin_url,
          source_authority: :municipal_decision,
          evidence_kind: :official_decision,
          evidence_excerpt: row,
          evidence_location: "declaration #{year}"
        })

      enqueue_if_eligible!(fact)
      :ok
    end
  end

  defp existing_candidate?(version, person, row) do
    Identity.SourcedFact
    |> Ash.Query.filter(
      subject_id == ^person.id and source_version_id == ^version.id and
        evidence_excerpt == ^row and verification_status in [:unreviewed, :verified]
    )
    |> Ash.read!(authorize?: false, domain: Identity)
    |> Enum.any?()
  end

  defp resolve_persons(row) do
    result =
      Repo.query!(
        "SELECT id::text, legal_name FROM people WHERE status = 'active' AND resolution_basis = 'explicit_identifier'"
      )

    result.rows
    |> Enum.map(fn [id, legal_name] -> {Ecto.UUID.cast!(id), legal_name} end)
    |> Enum.filter(fn {_id, legal_name} ->
      TrustedVerifier.declaration_name_match?(row, legal_name)
    end)
    |> Enum.map(fn {id, _name} -> Identity.get_person!(id) end)
  end

  defp corroborated_person?(person_id, commune_id) do
    result =
      Repo.query!(
        """
        SELECT 1
          FROM sourced_facts
         WHERE subject_id = $1::text::uuid
           AND object_id = $2::text::uuid
           AND kind = 'public_mandate'
           AND trusted_ixelles_public_mandate_fact(sourced_facts)
         LIMIT 1
        """,
        [person_id, commune_id]
      )

    result.num_rows == 1
  rescue
    _ -> false
  end

  defp mandate_rows(text) do
    text
    |> String.split("\f")
    |> Enum.flat_map(&mandate_rows_for_page/1)
    |> Enum.uniq()
  end

  defp mandate_rows_for_page(page) do
    lines = String.split(page, ["\r\n", "\n"])

    with start when is_integer(start) <- find_header(lines, [:mandats], 0) do
      upper =
        case find_header(lines, [:fonctions, :derivees], start + 1) do
          nil -> length(lines)
          index -> index
        end

      lines
      |> Enum.slice((start + 1)..(upper - 1)//1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(boilerplate?(&1) or String.trim(&1) == ""))
      |> Enum.filter(&(String.length(&1) in 8..240))
    else
      _ -> []
    end
  end

  defp find_header(lines, kinds, from) do
    lines
    |> Enum.with_index()
    |> Enum.drop(from)
    |> Enum.find_value(fn {line, index} ->
      if header_kind(line) in kinds, do: index
    end)
  end

  defp header_kind(line) do
    norm = strip_letters(line)

    cond do
      norm == "mandats" -> :mandats
      norm == "fonctionsderivees" -> :derivees
      norm == "fonctions" -> :fonctions
      true -> nil
    end
  end

  defp boilerplate?(line) do
    lowered = String.downcase(line)

    String.length(String.trim(line)) < 4 or
      Enum.any?(@boilerplate_markers, &String.contains?(lowered, &1))
  end

  defp strip_letters(line) do
    line
    |> :unicode.characters_to_nfd_binary()
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
  end

  defp declaration_year!(version) do
    case Regex.run(~r/mandats-([0-9]{4})\.pdf/, version.source_record.origin_url) do
      [_, year] -> String.to_integer(year)
      _ -> raise ArgumentError, "declaration source has no recognizable reporting year"
    end
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
    metadata = BrusselsWtf.PDF.Processor.metadata()

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
        "relationship:ixelles-mandate-declaration-v1:#{fact.id}:#{text_artifact.output_sha256}"

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
        "claim_sha256" => artifact.output_sha256
      },
      quality_measurements: %{"accepted" => true},
      started_at: now,
      completed_at: now,
      duration_ms: 0
    })
  end

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

  defp open_ambiguity_review(version, row) do
    BrusselsWtf.Review.open_review_case!(%{
      kind: :evidence,
      affected_record_id: version.id,
      affected_record_type: "source_version",
      source_version_id: version.id,
      processing_generation: "ixelles-mandate-declaration:#{version.id}:ambiguous_person",
      urgency: :normal,
      summary: "Declaration row matches multiple active person identities",
      diagnostics: %{"row_sha256" => BrusselsWtf.Digest.sha256(row)}
    })

    :ok
  end
end
