defmodule BrusselsWtf.Repo.Migrations.CorroborateInspectedIxellesDeclarant do
  use Ecto.Migration

  def up do
    execute """
    CREATE UNIQUE INDEX sourced_facts_one_current_declaration_index
      ON sourced_facts (subject_type, subject_id, object_type, object_id, kind, (mandate_declaration ->> 'key'))
      WHERE verification_status = 'verified'
        AND verified_by IN ('ixelles_mandate_declaration_v2', 'ixelles_mandate_declaration_v3')
    """

    execute "ALTER FUNCTION trusted_ixelles_public_mandate_fact(sourced_facts) RENAME TO trusted_ixelles_mandate_fact_before_v3"

    # Keep the public dispatch name available while creating the identity helper.
    execute """
    CREATE FUNCTION trusted_ixelles_public_mandate_fact(f sourced_facts)
    RETURNS boolean LANGUAGE sql STABLE AS 'SELECT trusted_ixelles_mandate_fact_before_v3(f)';
    """

    execute ~S"""

    CREATE FUNCTION trusted_ixelles_identity_source(v source_versions, r source_records)
    RETURNS boolean LANGUAGE sql STABLE AS $fn$
      SELECT coalesce(
        v.source_record_id = r.id
        AND v.sha256 = '4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5'
        AND v.byte_size = 1669707 AND v.media_type = 'application/pdf'
        AND r.origin_url = 'https://www.ixelles.be/uploads/conseil/pv/267.pdf'
        AND r.role = 'minutes'
        AND EXISTS (
          SELECT 1 FROM communes c
          JOIN source_locators l ON l.commune_id = c.id
          JOIN retrieval_observations o ON o.source_locator_id = l.id
          WHERE c.id = r.commune_id AND c.slug = 'ixelles' AND c.name = 'Ixelles'
            AND c.index_url = 'https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr'
            AND l.parent_index_url = c.index_url AND l.url = r.origin_url
            AND l.role = 'minutes' AND l.meeting_identifier = '267'
            AND l.scheduled_on = DATE '2026-06-11'
            AND o.source_version_id = v.id AND o.sha256 = v.sha256
            AND o.status IN ('success', 'unchanged') AND o.final_url = r.origin_url
        ), false);
    $fn$;

    """

    execute ~S"""
    CREATE FUNCTION trusted_ixelles_declarant_identity(p people, commune_id uuid)
    RETURNS boolean LANGUAGE sql STABLE AS $fn$
      SELECT coalesce(p.status = 'active'
        AND (SELECT count(*) FROM people names
             WHERE names.status = 'active'
               AND lower(regexp_replace(trim(names.legal_name), '\s+', ' ', 'g')) =
                   lower(regexp_replace(trim(p.legal_name), '\s+', ' ', 'g'))) = 1
        AND CASE p.resolution_basis
          WHEN 'explicit_identifier' THEN
            p.explicit_identifier IS NOT NULL AND p.explicit_identifier <> ''
            AND (SELECT count(*) FROM people ids WHERE ids.status = 'active'
                 AND ids.explicit_identifier = p.explicit_identifier) = 1
            AND EXISTS (
              SELECT 1 FROM sourced_facts prior
              WHERE prior.subject_id = p.id AND prior.object_id = commune_id
                AND CASE WHEN prior.verified_by = 'ixelles_municipal_minutes_public_mandate_v1'
                    THEN trusted_ixelles_public_mandate_fact(prior) ELSE false END
            )
          WHEN 'corroborated_name' THEN
            lower(regexp_replace(trim(p.legal_name), '\s+', ' ', 'g')) = 'gautier calomne'
            AND p.corroborating_facts ->> 'municipality' = 'ixelles'
            AND p.corroborating_facts ->> 'source_sha256' = '4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5'
            AND p.corroborating_facts ->> 'source_url' = 'https://www.ixelles.be/uploads/conseil/pv/267.pdf'
            AND p.corroborating_facts ->> 'location' = 'page 1'
            AND p.corroborating_facts ->> 'role' = 'Échevin'
            AND p.corroborating_facts ->> 'observed_on' = '2026-06-11'
            AND EXISTS (
              SELECT 1 FROM source_versions v JOIN source_records r ON r.id = v.source_record_id
              WHERE v.id::text = p.corroborating_facts ->> 'source_version_id'
                AND r.commune_id = commune_id AND trusted_ixelles_identity_source(v, r)
            )
          ELSE false END, false);
    $fn$;
    """

    execute ~S"""

    CREATE OR REPLACE FUNCTION trusted_ixelles_public_mandate_fact(f sourced_facts)
    RETURNS boolean LANGUAGE sql STABLE AS $fn$
      SELECT CASE WHEN f.verified_by = 'ixelles_mandate_declaration_v3' THEN coalesce((

        -- Mandate-declaration chain (issue #46).
        f.verification_status IN ('verified', 'superseded')
         AND f.verified_by = 'ixelles_mandate_declaration_v3'
         AND f.verification_processor_version = '1.0.0'
         AND f.verification_ruleset_version = 'ixelles-mandate-declaration-v3'
         AND f.verification_config_sha256 = 'sha256:45473bf93267f5a57466b934a414bea905ddef68433fdabe94d9ca95dde0ebc4'
         AND f.subject_type = 'person'
         AND f.object_type = 'commune'
         AND f.object_id IS NOT NULL
         AND f.kind = 'public_mandate'
         AND f.source_authority = 'municipal_declaration'
         AND f.evidence_kind = 'official_declaration'
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
              AND extraction_links.role = 'ocr_output'
             JOIN source_versions AS versions ON versions.id = runs.source_version_id
             JOIN source_records AS records ON records.id = versions.source_record_id
             JOIN communes ON communes.id = records.commune_id
             JOIN people ON people.id = f.subject_id
             JOIN source_locators AS locators
               ON locators.commune_id = communes.id
              AND locators.url = records.origin_url
              AND locators.role = 'mandate_declaration'
              AND locators.parent_index_url = 'https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr'
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
              AND runs.processor_name = 'ixelles-mandate-declarations'
              AND runs.processor_version = '1.0.0'
              AND runs.config_hash = 'sha256:45473bf93267f5a57466b934a414bea905ddef68433fdabe94d9ca95dde0ebc4'
              AND runs.generation_key = f.verification_generation
              AND runs.quality_measurements ->> 'accepted' = 'true'
              AND runs.completed_at IS NOT NULL
              AND artifacts.source_version_id = runs.source_version_id
              AND artifacts.input_sha256 = versions.sha256
              AND artifacts.processor_name = 'ixelles-mandate-declarations'
              AND artifacts.processor_version = '1.0.0'
              AND artifacts.config_hash = 'sha256:45473bf93267f5a57466b934a414bea905ddef68433fdabe94d9ca95dde0ebc4'
              AND artifacts.output_kind = 'relationship-claim-json'
              AND artifacts.schema_version = 'ixelles-mandate-declaration-v3'
              AND artifacts.quality_measurements ->> 'accepted' = 'true'
              AND extraction_runs.source_version_id = versions.id
              AND extraction_runs.processor_role = 'ocr'
              AND extraction_runs.status = 'succeeded'
              AND extraction_runs.quality_measurements ->> 'accepted' = 'true'
              AND extraction_runs.completed_at IS NOT NULL
              AND text_artifacts.source_version_id = versions.id
              AND text_artifacts.input_sha256 = versions.sha256
              AND text_artifacts.processor_name = extraction_runs.processor_name
              AND text_artifacts.processor_version = extraction_runs.processor_version
              AND text_artifacts.config_hash = extraction_runs.config_hash
              AND text_artifacts.output_kind = 'ocr-text'
              AND text_artifacts.media_type = 'text/plain; charset=utf-8'
              AND text_artifacts.quality_measurements ->> 'accepted' = 'true'
              AND records.role = 'mandate_declaration'
              AND records.origin_url = f.authoritative_url
              AND records.origin_url ~ '^https://www\.ixelles\.be/site/(fr|nl)/download/transparence/mandats-[0-9]{4}\.pdf$'
              AND communes.id = f.object_id
              AND communes.slug = 'ixelles'
              AND communes.name = 'Ixelles'
              AND trusted_ixelles_declarant_identity(people, communes.id)
              AND f.mandate_declaration IS NOT NULL
              AND jsonb_typeof(f.mandate_declaration) = 'object'
              AND f.mandate_declaration = runs.inputs -> 'mandate_declaration'
              AND f.mandate_declaration = runs.output -> 'mandate_declaration'
              AND f.mandate_declaration ->> 'section' = 'mandat'
              AND f.mandate_declaration ->> 'body' = 'Commune d''Ixelles'
              AND f.mandate_declaration ->> 'key' <> ''
              AND f.mandate_declaration ->> 'role' <> ''
              AND f.mandate_declaration ->> 'reporting_year' =
                    (regexp_match(records.origin_url, 'mandats-([0-9]{4})\.pdf'))[1]
              AND EXTRACT(YEAR FROM f.effective_from)::text = f.mandate_declaration ->> 'reporting_year'
              AND EXTRACT(YEAR FROM f.effective_to)::text = f.mandate_declaration ->> 'reporting_year'
              AND f.effective_from <= f.effective_to
              AND f.evidence_location = 'declaration ' || (f.mandate_declaration ->> 'reporting_year') ||
                    ' page ' || (f.mandate_declaration ->> 'page')

         )

      ), false) ELSE trusted_ixelles_mandate_fact_before_v3(f) END;
    $fn$;
    """

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
             NOT IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v2', 'ixelles_mandate_declaration_v3', 'belgian_official_gazette_management_v1') THEN
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

            IF NEW.verified_by = 'ixelles_mandate_declaration_v3' THEN
              IF NOT coalesce(trusted_ixelles_public_mandate_fact(NEW), false) THEN
                RAISE EXCEPTION 'trusted declaration identity and evidence contract is invalid';
              END IF;
            ELSIF NEW.verified_by IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v2', 'ixelles_mandate_declaration_v3') THEN
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
  end

  def down do
    execute "DROP INDEX sourced_facts_one_current_declaration_index"
    # Preserve all v3 facts and audits, but make them ineligible after rollback.
    execute """
    CREATE OR REPLACE FUNCTION trusted_ixelles_public_mandate_fact(f sourced_facts)
    RETURNS boolean LANGUAGE sql STABLE AS 'SELECT trusted_ixelles_mandate_fact_before_v3(f)';
    """

    execute "DROP FUNCTION trusted_ixelles_declarant_identity(people, uuid)"
    execute "DROP FUNCTION trusted_ixelles_identity_source(source_versions, source_records)"
    execute "DROP FUNCTION trusted_ixelles_public_mandate_fact(sourced_facts)"

    execute "ALTER FUNCTION trusted_ixelles_mandate_fact_before_v3(sourced_facts) RENAME TO trusted_ixelles_public_mandate_fact"

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
  end
end
