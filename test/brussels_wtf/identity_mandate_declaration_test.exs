defmodule BrusselsWtf.IdentityMandateDeclarationTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Ingestion

  @verifier :ixelles_mandate_declaration_v1
  @minutes_verifier :ixelles_municipal_minutes_public_mandate_v1
  @minutes_url "https://www.ixelles.be/uploads/conseil/pv/267.pdf"
  @declaration_url "https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf"
  @transparency_index "https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr"
  @declaration_row "Alex Example Premier Echevin, Officier de l'Etat Civil"
  @fiscal_page "FISCAL 281.10 tranche 12 345,67 EUR numero national 85.07.23-123.45"

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    configured = BrusselsWtf.Communes.configuration!("ixelles")

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: configured.name,
        index_url: configured.index_url
      })

    minutes_locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: @minutes_url,
        parent_index_url: configured.index_url,
        meeting_identifier: "267",
        scheduled_on: ~D[2026-08-19],
        role: :minutes,
        language: :bilingual,
        observed_label: "Proces-verbal",
        discovered_at: ~U[2026-08-19 11:59:00Z]
      })

    minutes_bytes = "%PDF-1.7 official Ixelles minutes fixture"
    {:ok, archived_minutes} = BrusselsWtf.Archive.store(minutes_bytes, :raw)

    minutes_record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: @minutes_url,
        role: :minutes,
        original_language: :bilingual
      })

    minutes_version =
      Ingestion.upsert_source_version!(%{
        source_record_id: minutes_record.id,
        sha256: archived_minutes.sha256,
        byte_size: byte_size(minutes_bytes),
        media_type: "application/pdf",
        object_key: archived_minutes.object_key,
        first_retrieved_at: ~U[2026-08-19 12:00:00Z]
      })

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: ~U[2026-08-19 11:58:00Z],
        kind: :scheduled,
        requester_id: "system",
        target_type: :commune,
        target_id: commune.id,
        check_key: "poll:ixelles-267",
        status: :completed
      })

    Ingestion.record_observation!(%{
      source_locator_id: minutes_locator.id,
      source_version_id: minutes_version.id,
      poll_run_id: poll_run.id,
      check_key: "fetch:ixelles-267",
      observed_at: ~U[2026-08-19 12:00:00Z],
      status: :success,
      http_status: 200,
      sha256: archived_minutes.sha256,
      final_url: @minutes_url
    })

    declaration_locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: @declaration_url,
        parent_index_url: @transparency_index,
        meeting_identifier: "mandats-2024",
        role: :mandate_declaration,
        language: :fr,
        observed_label: "Liste des mandats 2024",
        discovered_at: ~U[2026-09-03 09:00:00Z]
      })

    declaration_bytes = "%PDF-1.7 scanned Ixelles mandate declarations"
    {:ok, archived_declaration} = BrusselsWtf.Archive.store(declaration_bytes, :raw)

    declaration_record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: @declaration_url,
        role: :mandate_declaration,
        original_language: :fr
      })

    declaration_version =
      Ingestion.upsert_source_version!(%{
        source_record_id: declaration_record.id,
        sha256: archived_declaration.sha256,
        byte_size: byte_size(declaration_bytes),
        media_type: "application/pdf",
        object_key: archived_declaration.object_key,
        first_retrieved_at: ~U[2026-09-03 09:00:10Z]
      })

    Ingestion.record_observation!(%{
      source_locator_id: declaration_locator.id,
      source_version_id: declaration_version.id,
      poll_run_id: poll_run.id,
      check_key: "fetch:ixelles-mandats-2024",
      observed_at: ~U[2026-09-03 09:00:10Z],
      status: :success,
      http_status: 200,
      sha256: archived_declaration.sha256,
      final_url: @declaration_url
    })

    person =
      Identity.record_person!(%{
        legal_name: "Alex Example",
        explicit_identifier: "municipal-mandate-42",
        resolution_basis: :explicit_identifier
      })

    %{
      commune: commune,
      person: person,
      minutes_version: minutes_version,
      declaration_version: declaration_version
    }
  end

  test "minutes corroboration, declaration OCR, and trusted verification flow end to end",
       %{
         commune: commune,
         person: person,
         minutes_version: minutes_version,
         declaration_version: declaration_version
       } do
    # Corroborating fact: a trusted minutes-sourced council mandate.
    minutes_excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."

    minutes_fact = record_minutes_mandate!(person, minutes_version, minutes_excerpt, commune)
    verify_minutes!(minutes_fact)

    assert Identity.get_sourced_fact!(minutes_fact.id).verification_status == :verified

    # Declaration document via the OCR pipeline hook.
    declaration_page =
      "Cellule transparence\nMANDATS\n#{@declaration_row}\nFONCTIONS\n#{@fiscal_page}"

    stub_ocr(declaration_version, declaration_page)

    assert :ok = Ingestion.Pipeline.extract(declaration_version.id)

    ocr_run =
      declaration_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :ocr))

    assert :ok = Ingestion.Pipeline.ocr(ocr_run.id, 1)

    facts =
      Identity.SourcedFact
      |> Ash.Query.filter(
        subject_id == ^person.id and source_version_id == ^declaration_version.id
      )
      |> Ash.read!(authorize?: false, domain: Identity)

    assert [%{verification_status: :unreviewed} = fact] = facts
    assert fact.evidence_excerpt == @declaration_row
    assert fact.evidence_location == "declaration 2024"
    assert fact.effective_from == ~D[2024-01-01]
    assert fact.effective_to == ~D[2024-12-31]

    assert_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesMandateDeclaration,
      args: %{fact_id: fact.id}
    )

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesMandateDeclaration, %{fact_id: fact.id})

    verified = Identity.get_sourced_fact!(fact.id)
    assert verified.verification_status == :verified
    assert verified.verified_by == Atom.to_string(@verifier)

    IO.inspect(
      BrusselsWtf.Repo.query!(
        "SELECT verifier_id, to_status, processing_run_id = $1::uuid, artifact_id = $2::uuid FROM sourced_fact_verification_events WHERE fact_id = $3::uuid",
        Enum.map(
          [
            verified.verification_processing_run_id,
            verified.verification_artifact_id,
            verified.id
          ],
          fn value -> elem(Ecto.UUID.dump(value), 1) end
        )
      ).rows,
      label: "EVENTS"
    )

    IO.inspect(
      BrusselsWtf.Repo.query!(
        "SELECT trusted_ixelles_public_mandate_fact(f) FROM sourced_facts f WHERE f.id = $1::text::uuid",
        [verified.id]
      ).rows,
      label: "TRUSTED FN"
    )

    assert BrusselsWtf.Identity.TrustedVerifier.trusted_fact?(verified)

    assert [declaration] =
             Identity.list_public_relationships!(%{subject_id: person.id})
             |> Enum.filter(&(&1.authoritative_url == @declaration_url))

    assert declaration.evidence_location == "declaration 2024"
    assert declaration.effective_from == ~D[2024-01-01]

    # Fiscal content never becomes a fact.
    fiscal_facts =
      Identity.SourcedFact
      |> Ash.Query.filter(
        source_version_id == ^declaration_version.id and evidence_excerpt == ^@fiscal_page
      )
      |> Ash.read!(authorize?: false, domain: Identity)

    assert fiscal_facts == []

    # Idempotent: rerunning the OCR hook does not duplicate candidates.
    assert :ok = Ingestion.Pipeline.ocr(ocr_run.id, 1)

    facts_after =
      Identity.SourcedFact
      |> Ash.Query.filter(
        subject_id == ^person.id and source_version_id == ^declaration_version.id
      )
      |> Ash.read!(authorize?: false, domain: Identity)

    assert length(facts_after) == 1
  end

  test "unverified minutes corroboration never makes declaration facts eligible",
       %{person: person, declaration_version: declaration_version} do
    stub_ocr(declaration_version, "MANDATS\n#{@declaration_row}\nFONCTIONS")

    assert :ok = Ingestion.Pipeline.extract(declaration_version.id)

    ocr_run =
      declaration_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :ocr))

    assert :ok = Ingestion.Pipeline.ocr(ocr_run.id, 1)

    facts =
      Identity.SourcedFact
      |> Ash.Query.filter(
        subject_id == ^person.id and source_version_id == ^declaration_version.id
      )
      |> Ash.read!(authorize?: false, domain: Identity)

    assert [%{verification_status: :unreviewed} = fact] = facts

    refute_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesMandateDeclaration,
      args: %{fact_id: fact.id}
    )

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesMandateDeclaration, %{fact_id: fact.id})

    assert Identity.get_sourced_fact!(fact.id).verification_status == :unreviewed
    assert Identity.list_public_relationships!(%{subject_id: person.id}) == []
  end

  test "forbidden declaration content fails closed into a review case",
       %{
         commune: commune,
         person: person,
         minutes_version: minutes_version,
         declaration_version: declaration_version
       } do
    minutes_excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."

    minutes_fact = record_minutes_mandate!(person, minutes_version, minutes_excerpt, commune)
    verify_minutes!(minutes_fact)

    tainted_row = "#{@declaration_row} 2 345,67 EUR"

    stub_ocr(declaration_version, "MANDATS\n#{tainted_row}\nFONCTIONS")

    assert :ok = Ingestion.Pipeline.extract(declaration_version.id)

    ocr_run =
      declaration_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :ocr))

    assert :ok = Ingestion.Pipeline.ocr(ocr_run.id, 1)

    facts =
      Identity.SourcedFact
      |> Ash.Query.filter(
        subject_id == ^person.id and source_version_id == ^declaration_version.id
      )
      |> Ash.read!(authorize?: false, domain: Identity)

    assert [%{verification_status: :unreviewed} = fact] = facts

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesMandateDeclaration, %{fact_id: fact.id})

    assert Identity.get_sourced_fact!(fact.id).verification_status == :unreviewed

    assert Identity.list_public_relationships!(%{subject_id: person.id})
           |> Enum.filter(&(&1.authoritative_url == @declaration_url)) == []

    cases =
      BrusselsWtf.Review.Case
      |> Ash.Query.filter(affected_record_id == ^fact.id)
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Review)

    assert Enum.any?(cases, &String.contains?(&1.summary || "", "failed closed"))
  end

  test "ambiguous declarant names open a review case without recording a fact",
       %{
         commune: commune,
         person: person,
         minutes_version: minutes_version,
         declaration_version: declaration_version
       } do
    minutes_excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."

    minutes_fact = record_minutes_mandate!(person, minutes_version, minutes_excerpt, commune)
    verify_minutes!(minutes_fact)

    Identity.record_person!(%{
      legal_name: "Alex Example",
      explicit_identifier: "municipal-mandate-43",
      resolution_basis: :explicit_identifier
    })

    stub_ocr(declaration_version, "MANDATS\n#{@declaration_row}\nFONCTIONS")

    assert :ok = Ingestion.Pipeline.extract(declaration_version.id)

    ocr_run =
      declaration_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :ocr))

    assert :ok = Ingestion.Pipeline.ocr(ocr_run.id, 1)

    facts =
      Identity.SourcedFact
      |> Ash.Query.filter(source_version_id == ^declaration_version.id)
      |> Ash.read!(authorize?: false, domain: Identity)

    assert facts == []

    cases =
      BrusselsWtf.Review.Case
      |> Ash.Query.filter(source_version_id == ^declaration_version.id)
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Review)

    assert Enum.any?(cases, &String.contains?(&1.summary || "", "multiple active person"))
  end

  ## Helpers

  defp record_minutes_mandate!(person, source_version, excerpt, commune) do
    Identity.record_sourced_fact!(%{
      subject_type: :person,
      subject_id: person.id,
      object_type: :commune,
      object_id: commune.id,
      kind: :public_mandate,
      effective_from: ~D[2024-12-01],
      source_version_id: source_version.id,
      authoritative_url: @minutes_url,
      source_authority: :municipal_decision,
      evidence_kind: :official_decision,
      evidence_excerpt: excerpt,
      evidence_location: "decision 267"
    })
  end

  defp verify_minutes!(fact) do
    version =
      Ingestion.get_source_version!(fact.source_version_id)
      |> Ash.load!(source_record: [:commune])

    minutes_text = "Official minutes\n#{fact.evidence_excerpt}\n"

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{"text" => minutes_text}
    })

    {:ok, raw_source} = BrusselsWtf.Archive.get(version.object_key)

    {:ok, rerun} =
      BrusselsWtf.PDF.Processor.native(
        %{sha256: version.sha256, media_type: version.media_type},
        raw_source
      )

    {:ok, archived_text} = BrusselsWtf.Archive.store(minutes_text, :derived)

    text_run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        generation_key: "native:relationship-input:#{fact.id}",
        processor_role: :native_extraction,
        inputs: %{"source_sha256" => version.sha256},
        processor_name: "poppler-native-text",
        processor_version: "fixture-poppler-24.02",
        config_hash: "sha256:fixture-pdf-quality-v1",
        status: :succeeded,
        output: %{"classification" => "accepted native text"},
        quality_measurements: rerun.quality_measurements,
        completed_at: ~U[2026-08-19 12:00:30Z]
      })

    text_artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: version.id,
        processing_run_id: text_run.id,
        input_sha256: version.sha256,
        output_sha256: archived_text.sha256,
        processor_name: text_run.processor_name,
        processor_version: text_run.processor_version,
        config_hash: text_run.config_hash,
        output_kind: "native-text",
        object_key: archived_text.object_key,
        media_type: "text/plain; charset=utf-8",
        byte_size: byte_size(minutes_text),
        schema_version: "derived-artifact-v1",
        quality_measurements: rerun.quality_measurements
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: text_run.id,
      derived_artifact_id: text_artifact.id,
      role: :native_output
    })

    contract = BrusselsWtf.Identity.TrustedVerifier.ixelles_contract()
    person = Identity.get_person!(fact.subject_id)
    commune = version.source_record.commune

    claim =
      BrusselsWtf.Identity.TrustedVerifier.ixelles_semantic_payload(
        fact,
        person,
        commune,
        version
      )

    claim_bytes = Jason.encode!(claim)
    {:ok, archived} = BrusselsWtf.Archive.store(claim_bytes, :derived)

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        generation_key: "relationship:#{fact.id}",
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

    run =
      Ingestion.complete_processing_run!(run, %{
        status: :succeeded,
        output: %{
          "schema_version" => contract.ruleset_version,
          "claim_sha256" => artifact.output_sha256
        },
        quality_measurements: %{"accepted" => true},
        started_at: ~U[2026-08-19 12:01:00Z],
        completed_at: ~U[2026-08-19 12:01:00Z],
        duration_ms: 0
      })

    BrusselsWtf.Identity.TrustedVerifier.verify!(fact.id, @minutes_verifier, run.id)
  end

  defp stub_ocr(source_version, page_text) do
    BrusselsWtf.Processors.Stub.put(source_version.sha256, %{
      extract: %{"text" => "", "page_texts" => [""]},
      ocr: %{
        "page_texts" => [page_text],
        "searchable_pdf" => "%PDF recorded searchable declaration"
      }
    })
  end
end
