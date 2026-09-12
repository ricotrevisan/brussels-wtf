defmodule BrusselsWtf.Repo.Migrations.Issue45GazetteManagementFacts do
  @moduledoc """
  Trusted Gazette management-fact verifier for issue #45.

  Isolated fixture verification only. Live e-Justice retrieval remains blocked.
  """

  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE OR REPLACE FUNCTION enforce_sourced_fact_verification_transition()

        RETURNS trigger AS $$
        DECLARE
          trusted_verifier text;
          transition_run_id uuid;
          transition_artifact_id uuid;
          transition_processor_version text;
          transition_ruleset_version text;
          transition_config_sha256 text;
          transition_generation text;
        BEGIN
          IF TG_OP = 'INSERT' THEN
            IF NEW.verification_status <> 'unreviewed'
               OR NEW.verified_by IS NOT NULL
               OR NEW.verified_at IS NOT NULL
               OR NEW.verification_processor_version IS NOT NULL
               OR NEW.verification_ruleset_version IS NOT NULL
               OR NEW.verification_config_sha256 IS NOT NULL
               OR NEW.verification_generation IS NOT NULL
               OR NEW.verification_processing_run_id IS NOT NULL
               OR NEW.verification_artifact_id IS NOT NULL THEN
              RAISE EXCEPTION 'sourced facts must be inserted as unreviewed candidates';
            END IF;

            RETURN NEW;
          END IF;

          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'sourced fact audit history is immutable';
          END IF;

          IF NEW IS NOT DISTINCT FROM OLD THEN
            RETURN NEW;
          END IF;

          trusted_verifier := current_setting('brussels_wtf.trusted_relationship_verifier', true);

          IF current_setting('brussels_wtf.trusted_relationship_verifier', true)
             NOT IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v2', 'belgian_official_gazette_management_v1') THEN
            RAISE EXCEPTION 'sourced fact transitions require a trusted relationship verifier';
          END IF;

          IF OLD.subject_type IS DISTINCT FROM NEW.subject_type
             OR OLD.subject_id IS DISTINCT FROM NEW.subject_id
             OR OLD.object_type IS DISTINCT FROM NEW.object_type
             OR OLD.object_id IS DISTINCT FROM NEW.object_id
             OR OLD.object_label IS DISTINCT FROM NEW.object_label
             OR OLD.kind IS DISTINCT FROM NEW.kind
             OR OLD.effective_from IS DISTINCT FROM NEW.effective_from
             OR OLD.effective_to IS DISTINCT FROM NEW.effective_to
             OR OLD.source_version_id IS DISTINCT FROM NEW.source_version_id
             OR OLD.authoritative_url IS DISTINCT FROM NEW.authoritative_url
             OR OLD.source_authority IS DISTINCT FROM NEW.source_authority
             OR OLD.evidence_kind IS DISTINCT FROM NEW.evidence_kind
             OR OLD.evidence_excerpt IS DISTINCT FROM NEW.evidence_excerpt
             OR OLD.mandate_declaration IS DISTINCT FROM NEW.mandate_declaration
             OR OLD.evidence_location IS DISTINCT FROM NEW.evidence_location
             OR OLD.supersedes_id IS DISTINCT FROM NEW.supersedes_id
             OR OLD.inserted_at IS DISTINCT FROM NEW.inserted_at THEN
            RAISE EXCEPTION 'sourced fact semantics and evidence are immutable';
          END IF;

          transition_run_id := nullif(current_setting('brussels_wtf.verification_processing_run_id', true), '')::uuid;
          transition_artifact_id := nullif(current_setting('brussels_wtf.verification_artifact_id', true), '')::uuid;
          transition_processor_version := current_setting('brussels_wtf.verification_processor_version', true);
          transition_ruleset_version := current_setting('brussels_wtf.verification_ruleset_version', true);
          transition_config_sha256 := current_setting('brussels_wtf.verification_config_sha256', true);
          transition_generation := current_setting('brussels_wtf.verification_generation', true);

          IF OLD.verification_status = 'unreviewed' AND NEW.verification_status = 'verified' THEN
            IF NEW.verified_by <> trusted_verifier
               OR NEW.verification_processing_run_id IS DISTINCT FROM transition_run_id
               OR NEW.verification_artifact_id IS DISTINCT FROM transition_artifact_id
               OR NEW.verification_processor_version IS DISTINCT FROM transition_processor_version
               OR NEW.verification_ruleset_version IS DISTINCT FROM transition_ruleset_version
               OR NEW.verification_config_sha256 IS DISTINCT FROM transition_config_sha256
               OR NEW.verification_generation IS DISTINCT FROM transition_generation
               OR NEW.verified_at IS NULL THEN
              RAISE EXCEPTION 'trusted verification provenance does not match the server transition';
            END IF;

            IF NEW.verified_by IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v2') THEN
              IF NOT trusted_ixelles_public_mandate_fact(NEW)
                 OR NOT EXISTS (
                   SELECT 1
                     FROM people
                    WHERE people.id = NEW.subject_id
                      AND people.status = 'active'
                      AND (
                        SELECT count(*) FROM people AS names
                         WHERE names.status = 'active' AND names.legal_name = people.legal_name
                      ) = 1
                      AND (
                        SELECT count(*) FROM people AS identifiers
                         WHERE identifiers.status = 'active'
                           AND identifiers.explicit_identifier = people.explicit_identifier
                      ) = 1
                 ) THEN
                RAISE EXCEPTION 'trusted registry run, artifact, source, and identity contract is invalid';
              END IF;
            ELSIF NEW.verified_by = 'belgian_official_gazette_management_v1' THEN
              IF NOT trusted_gazette_management_fact(NEW) THEN
                RAISE EXCEPTION 'trusted registry run, artifact, source, and identity contract is invalid';
              END IF;
            ELSE
              RAISE EXCEPTION 'trusted registry run, artifact, source, and identity contract is invalid';
            END IF;
          ELSIF OLD.verification_status = 'verified' AND NEW.verification_status = 'superseded' THEN
            IF OLD.verified_by IS DISTINCT FROM NEW.verified_by
               OR OLD.verified_at IS DISTINCT FROM NEW.verified_at
               OR OLD.verification_processing_run_id IS DISTINCT FROM NEW.verification_processing_run_id
               OR OLD.verification_artifact_id IS DISTINCT FROM NEW.verification_artifact_id
               OR OLD.verification_processor_version IS DISTINCT FROM NEW.verification_processor_version
               OR OLD.verification_ruleset_version IS DISTINCT FROM NEW.verification_ruleset_version
               OR OLD.verification_config_sha256 IS DISTINCT FROM NEW.verification_config_sha256
               OR OLD.verification_generation IS DISTINCT FROM NEW.verification_generation THEN
              RAISE EXCEPTION 'supersession cannot rewrite original verification provenance';
            END IF;
          ELSE
            RAISE EXCEPTION 'invalid one-way sourced fact verification transition';
          END IF;

          INSERT INTO sourced_fact_verification_events
            (fact_id, from_status, to_status, verifier_id, processing_run_id, artifact_id,
             processor_version, ruleset_version, config_sha256, generation, occurred_at)
          VALUES
            (NEW.id, OLD.verification_status, NEW.verification_status, trusted_verifier,
             transition_run_id, transition_artifact_id, transition_processor_version,
             transition_ruleset_version, transition_config_sha256, transition_generation,
             clock_timestamp() AT TIME ZONE 'utc');

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
    """

    execute ~S"""
    CREATE OR REPLACE FUNCTION trusted_gazette_management_fact(f sourced_facts)
        RETURNS boolean
        LANGUAGE sql
        STABLE
        AS $fn$
          SELECT
            f.verification_status IN ('verified', 'superseded')
            AND f.verified_by = 'belgian_official_gazette_management_v1'
            AND f.verification_processor_version = '1.0.0'
            AND f.verification_ruleset_version = 'belgian-official-gazette-management-v1'
            AND f.verification_config_sha256 = 'sha256:8808a858e44fa00cc0b6ce5fa8ca3c6ef7efc73fb17dbd6acb74724ac0b61540'
            AND f.subject_type = 'person'
            AND f.object_type = 'legal_entity'
            AND f.object_id IS NOT NULL
            AND f.kind = 'management'
            AND f.source_authority = 'belgian_official_gazette'
            AND f.evidence_kind = 'official_act'
            AND f.effective_from IS NOT NULL
            AND f.verification_processing_run_id IS NOT NULL
            AND f.verification_artifact_id IS NOT NULL
            AND EXISTS (
              SELECT 1
                FROM processing_runs AS runs
                JOIN derived_artifacts AS artifacts
                  ON artifacts.id = f.verification_artifact_id
                JOIN processing_run_artifacts AS links
                  ON links.processing_run_id = runs.id
                 AND links.derived_artifact_id = artifacts.id
                 AND links.role = 'relationship_claim'
                JOIN processing_runs AS extraction_runs
                  ON extraction_runs.id::text = runs.inputs ->> 'extraction_run_id'
                JOIN derived_artifacts AS text_artifacts
                  ON text_artifacts.id::text = runs.inputs ->> 'text_artifact_id'
                JOIN processing_run_artifacts AS extraction_links
                  ON extraction_links.processing_run_id = extraction_runs.id
                 AND extraction_links.derived_artifact_id = text_artifacts.id
                 AND extraction_links.role = 'native_output'
                JOIN source_versions AS versions ON versions.id = runs.source_version_id
                JOIN source_records AS records ON records.id = versions.source_record_id
                JOIN communes ON communes.id = records.commune_id
                JOIN people ON people.id = f.subject_id
                JOIN legal_entities ON legal_entities.id = f.object_id
                JOIN source_locators AS locators
                  ON locators.commune_id = communes.id
                 AND locators.url = records.origin_url
                 AND locators.role = 'gazette_annex'
                 AND locators.parent_index_url = 'https://www.ejustice.just.fgov.be/tsv/tsvf2.htm'
                JOIN retrieval_observations AS observations
                  ON observations.source_locator_id = locators.id
                 AND observations.source_version_id = versions.id
                 AND observations.status IN ('success', 'unchanged')
                 AND observations.sha256 = versions.sha256
                 AND observations.final_url = records.origin_url
               WHERE runs.id = f.verification_processing_run_id
                 AND runs.source_version_id = f.source_version_id
                 AND runs.processor_role = 'relationship_verification'
                 AND runs.status = 'succeeded'
                 AND runs.processor_name = 'belgian-official-gazette-management'
                 AND runs.processor_version = '1.0.0'
                 AND runs.config_hash = 'sha256:8808a858e44fa00cc0b6ce5fa8ca3c6ef7efc73fb17dbd6acb74724ac0b61540'
                 AND runs.generation_key = f.verification_generation
                 AND runs.quality_measurements ->> 'accepted' = 'true'
                 AND runs.completed_at IS NOT NULL
                 AND artifacts.source_version_id = runs.source_version_id
                 AND artifacts.input_sha256 = versions.sha256
                 AND artifacts.processor_name = 'belgian-official-gazette-management'
                 AND artifacts.processor_version = '1.0.0'
                 AND artifacts.config_hash = 'sha256:8808a858e44fa00cc0b6ce5fa8ca3c6ef7efc73fb17dbd6acb74724ac0b61540'
                 AND artifacts.output_kind = 'relationship-claim-json'
                 AND artifacts.schema_version = 'belgian-official-gazette-management-v1'
                 AND artifacts.quality_measurements ->> 'accepted' = 'true'
                 AND extraction_runs.source_version_id = versions.id
                 AND extraction_runs.processor_role = 'native_extraction'
                 AND extraction_runs.status = 'succeeded'
                 AND extraction_runs.quality_measurements ->> 'accepted' = 'true'
                 AND extraction_runs.completed_at IS NOT NULL
                 AND text_artifacts.source_version_id = versions.id
                 AND text_artifacts.input_sha256 = versions.sha256
                 AND text_artifacts.processor_name = extraction_runs.processor_name
                 AND text_artifacts.processor_version = extraction_runs.processor_version
                 AND text_artifacts.config_hash = extraction_runs.config_hash
                 AND text_artifacts.output_kind = 'native-text'
                 AND text_artifacts.media_type = 'text/plain; charset=utf-8'
                 AND text_artifacts.quality_measurements ->> 'accepted' = 'true'
                 AND records.role = 'gazette_annex'
                 AND records.origin_url = f.authoritative_url
                 AND records.origin_url ~ '^https://www\.ejustice\.just\.fgov\.be/tsv/fr/[0-9]{4}-[0-9]{10}-(appointment|cessation)$'
                 AND communes.slug = 'belgian-official-gazette'
                 AND communes.name = 'Belgian Official Gazette'
                 AND communes.index_url = 'https://www.ejustice.just.fgov.be/tsv/tsvf2.htm'
                 AND people.status = 'active'
                 AND people.resolution_basis = 'corroborated_name'
                 AND people.corroborating_facts ->> 'enterprise_number' = legal_entities.enterprise_number
                 AND legal_entities.status = 'active'
                 AND (
                   SELECT count(*) FROM people AS names
                    WHERE names.status = 'active' AND names.legal_name = people.legal_name
                 ) = 1
            )
        $fn$;
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS trusted_gazette_management_fact(sourced_facts)"
  end
end
