defmodule BrusselsWtf.Test.LegacyMandateFixture do
  @moduledoc "A persisted v2 declaration produced through the retained database verification gate."

  alias BrusselsWtf.{Identity, Ingestion, Repo}
  @verifier "ixelles_mandate_declaration_v2"
  @ruleset "ixelles-mandate-declaration-v2"
  @config "sha256:2393d3c8cf782b744bf43351da33cbb0e6dfc8e26c2ba85e41e8d66d6d73cff5"

  def verify!(fact) do
    version =
      Ingestion.get_source_version!(fact.source_version_id)
      |> Ash.load!([:processing_runs, source_record: [:commune]])

    extraction =
      Enum.find(version.processing_runs, &(&1.processor_role == :ocr and &1.status == :succeeded))

    text =
      Ash.load!(extraction, :derived_artifacts).derived_artifacts
      |> Enum.find(&(&1.output_kind == "ocr-text"))

    payload =
      Identity.TrustedVerifier.declaration_semantic_payload(
        fact,
        Identity.get_person!(fact.subject_id),
        version.source_record.commune,
        version
      )
      |> Map.delete("identity_evidence")
      |> Map.put("schema_version", @ruleset)

    bytes = Jason.encode!(payload)
    {:ok, archived} = BrusselsWtf.Archive.store(bytes, :derived)

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        generation_key: "legacy-declaration:#{fact.id}",
        processor_role: :relationship_verification,
        processor_name: "ixelles-mandate-declarations",
        processor_version: "1.0.0",
        config_hash: @config,
        status: :succeeded,
        inputs: %{
          "source_version_sha256" => version.sha256,
          "ruleset_version" => @ruleset,
          "extraction_run_id" => extraction.id,
          "text_artifact_id" => text.id,
          "mandate_declaration" => fact.mandate_declaration
        },
        output: %{
          "schema_version" => @ruleset,
          "claim_sha256" => archived.sha256,
          "mandate_declaration" => fact.mandate_declaration
        },
        quality_measurements: %{"accepted" => true},
        completed_at: BrusselsWtf.Clock.utc_now()
      })

    artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: version.id,
        processing_run_id: run.id,
        input_sha256: version.sha256,
        output_sha256: archived.sha256,
        processor_name: run.processor_name,
        processor_version: run.processor_version,
        config_hash: @config,
        output_kind: "relationship-claim-json",
        object_key: archived.object_key,
        media_type: "application/json",
        byte_size: byte_size(bytes),
        schema_version: @ruleset,
        quality_measurements: %{"accepted" => true}
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: run.id,
      derived_artifact_id: artifact.id,
      role: :relationship_claim
    })

    # Model a previous release's persisted transition without disabling triggers,
    # changing current verifier configuration, or rewriting immutable audit rows.
    {:ok, _} =
      Repo.transaction(fn ->
        for {key, value} <- [
              {"trusted_relationship_verifier", @verifier},
              {"verification_processing_run_id", run.id},
              {"verification_artifact_id", artifact.id},
              {"verification_processor_version", "1.0.0"},
              {"verification_ruleset_version", @ruleset},
              {"verification_config_sha256", @config},
              {"verification_generation", run.generation_key}
            ],
            do: Repo.query!("SELECT set_config($1, $2, true)", ["brussels_wtf." <> key, value])

        Repo.query!(
          """
          UPDATE sourced_facts SET verification_status = 'verified', verified_by = $2,
            verification_processor_version = '1.0.0', verification_ruleset_version = $3,
            verification_config_sha256 = $4, verification_generation = $5,
            verification_processing_run_id = $6::text::uuid,
            verification_artifact_id = $7::text::uuid,
            verified_at = clock_timestamp() AT TIME ZONE 'utc'
          WHERE id = $1::text::uuid AND verification_status = 'unreviewed'
          """,
          [fact.id, @verifier, @ruleset, @config, run.generation_key, run.id, artifact.id]
        )
      end)

    Identity.get_sourced_fact!(fact.id)
  end
end
