defmodule BrusselsWtf.Repo.Migrations.Issue46TrustedMandateDeclarationFacts do
  @moduledoc """
  Extends trusted public-mandate verification to the Ixelles mandate
  declaration source (issue #46) while keeping the minutes chain unchanged.

  The transition trigger accepts both trusted verifier lanes, and the trusted
  fact function gains a second, equally strict declaration branch: official
  transparency locator, authorized retrieval observation, accepted OCR text
  chain, declaration relationship-verification run, corroborated resolved
  person, and reporting-year-bound fact.
  """

  use Ecto.Migration

  def up do
    # The one-current invariant becomes lane-scoped: the minutes lane and the
    # declaration lane are complementary sourced roles, so each keeps one
    # current verified fact per (subject, object, kind).
    execute "DROP INDEX IF EXISTS sourced_facts_one_current_semantic_fact_index"

    execute """
    CREATE UNIQUE INDEX sourced_facts_one_current_semantic_fact_index
      ON sourced_facts (subject_type, subject_id, object_type, object_id, kind, verified_by)
      NULLS NOT DISTINCT
      WHERE verification_status = 'verified'
    """

    execute """
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
         NOT IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v1') THEN
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

    execute """
    CREATE OR REPLACE FUNCTION trusted_ixelles_public_mandate_fact(f sourced_facts)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $fn$
      SELECT CASE f.verified_by
        WHEN 'ixelles_municipal_minutes_public_mandate_v1' THEN (
        -- Minutes chain (issue #30, unchanged).
        f.verification_status IN ('verified', 'superseded')
         AND f.verified_by = 'ixelles_municipal_minutes_public_mandate_v1'
         AND f.verification_processor_version = '1.0.0'
         AND f.verification_ruleset_version = 'ixelles-public-mandate-v1'
         AND f.verification_config_sha256 = 'sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1'
         AND f.subject_type = 'person'
         AND f.object_type = 'commune'
         AND f.object_id IS NOT NULL
         AND f.kind = 'public_mandate'
         AND f.source_authority = 'municipal_decision'
         AND f.evidence_kind = 'official_decision'
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
             JOIN source_locators AS locators
               ON locators.commune_id = communes.id
              AND locators.url = records.origin_url
              AND locators.role = 'minutes'
              AND locators.parent_index_url = 'https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr'
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
              AND runs.processor_name = 'ixelles-municipal-minutes-public-mandates'
              AND runs.processor_version = '1.0.0'
              AND runs.config_hash = 'sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1'
              AND runs.generation_key = f.verification_generation
              AND runs.quality_measurements ->> 'accepted' = 'true'
              AND runs.completed_at IS NOT NULL
              AND artifacts.source_version_id = runs.source_version_id
              AND artifacts.input_sha256 = versions.sha256
              AND artifacts.processor_name = 'ixelles-municipal-minutes-public-mandates'
              AND artifacts.processor_version = '1.0.0'
              AND artifacts.config_hash = 'sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1'
              AND artifacts.output_kind = 'relationship-claim-json'
              AND artifacts.schema_version = 'ixelles-public-mandate-v1'
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
              AND records.role = 'minutes'
              AND records.origin_url = f.authoritative_url
              AND records.origin_url ~ '^https://www\.ixelles\.be/uploads/conseil/pv/[0-9]+\.pdf$'
              AND communes.id = f.object_id
              AND communes.slug = 'ixelles'
              AND communes.name = 'Ixelles'
              AND communes.index_url = 'https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr'
              AND people.resolution_basis = 'explicit_identifier'
              AND people.explicit_identifier IS NOT NULL
              AND people.explicit_identifier <> ''
              AND position(people.explicit_identifier in f.evidence_excerpt) > 0
              AND position(f.effective_from::text in f.evidence_excerpt) > 0
              AND f.evidence_location = 'decision ' || locators.meeting_identifier
         )
      ) WHEN 'ixelles_mandate_declaration_v1' THEN (
        -- Mandate-declaration chain (issue #46).
        f.verification_status IN ('verified', 'superseded')
         AND f.verified_by = 'ixelles_mandate_declaration_v1'
         AND f.verification_processor_version = '1.0.0'
         AND f.verification_ruleset_version = 'ixelles-mandate-declaration-v1'
         AND f.verification_config_sha256 = 'sha256:9419244e4ca95f36bd739b5f1eb79d2f835cfbfdb5a4ff73ef63e2633dcc9858'
         AND f.subject_type = 'person'
         AND f.object_type = 'commune'
         AND f.object_id IS NOT NULL
         AND f.kind = 'public_mandate'
         AND f.source_authority = 'municipal_decision'
         AND f.evidence_kind = 'official_decision'
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
              AND runs.config_hash = 'sha256:9419244e4ca95f36bd739b5f1eb79d2f835cfbfdb5a4ff73ef63e2633dcc9858'
              AND runs.generation_key = f.verification_generation
              AND runs.quality_measurements ->> 'accepted' = 'true'
              AND runs.completed_at IS NOT NULL
              AND artifacts.source_version_id = runs.source_version_id
              AND artifacts.input_sha256 = versions.sha256
              AND artifacts.processor_name = 'ixelles-mandate-declarations'
              AND artifacts.processor_version = '1.0.0'
              AND artifacts.config_hash = 'sha256:9419244e4ca95f36bd739b5f1eb79d2f835cfbfdb5a4ff73ef63e2633dcc9858'
              AND artifacts.output_kind = 'relationship-claim-json'
              AND artifacts.schema_version = 'ixelles-mandate-declaration-v1'
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
              AND people.resolution_basis = 'explicit_identifier'
              AND people.explicit_identifier IS NOT NULL
              AND people.explicit_identifier <> ''
              AND f.effective_from = make_date(
                    (regexp_match(records.origin_url, 'mandats-([0-9]{4})\.pdf'))[1]::int, 1, 1)
              AND f.effective_to = make_date(
                    (regexp_match(records.origin_url, 'mandats-([0-9]{4})\.pdf'))[1]::int, 12, 31)
              AND f.evidence_location =
                    'declaration ' || (regexp_match(records.origin_url, 'mandats-([0-9]{4})\.pdf'))[1]
              AND EXISTS (
                SELECT 1
                  FROM sourced_facts AS prior
                 WHERE prior.subject_id = f.subject_id
                   AND prior.object_id = f.object_id
                   AND prior.kind = 'public_mandate'
                   AND prior.id <> f.id
                   AND CASE
                     WHEN prior.verified_by = 'ixelles_municipal_minutes_public_mandate_v1'
                     THEN trusted_ixelles_public_mandate_fact(prior)
                     ELSE false
                   END
              )
         )
      ) ELSE false END;
    $fn$;
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS sourced_facts_one_current_semantic_fact_index"

    execute """
    CREATE UNIQUE INDEX sourced_facts_one_current_semantic_fact_index
      ON sourced_facts (subject_type, subject_id, object_type, object_id, kind)
      NULLS NOT DISTINCT
      WHERE verification_status = 'verified'
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
          FROM sourced_fact_verification_events
         WHERE verifier_id NOT IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v1')
      ) THEN
        RAISE EXCEPTION 'cannot discard trusted sourced-fact verification audit history';
      END IF;
    END;
    $$;
    """

    execute "DROP TRIGGER IF EXISTS sourced_facts_verification_transition ON sourced_facts"

    execute """
    CREATE FUNCTION enforce_sourced_fact_verification_transition()

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

      IF trusted_verifier IS DISTINCT FROM 'ixelles_municipal_minutes_public_mandate_v1' THEN
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

    execute """
    CREATE TRIGGER sourced_facts_verification_transition
    BEFORE INSERT OR UPDATE OR DELETE ON sourced_facts
    FOR EACH ROW EXECUTE FUNCTION enforce_sourced_fact_verification_transition();
    """

    execute """
    CREATE FUNCTION trusted_ixelles_public_mandate_fact(f sourced_facts)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
      SELECT f.verification_status IN ('verified', 'superseded')
         AND f.verified_by = 'ixelles_municipal_minutes_public_mandate_v1'
         AND f.verification_processor_version = '1.0.0'
         AND f.verification_ruleset_version = 'ixelles-public-mandate-v1'
         AND f.verification_config_sha256 = 'sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1'
         AND f.subject_type = 'person'
         AND f.object_type = 'commune'
         AND f.object_id IS NOT NULL
         AND f.kind = 'public_mandate'
         AND f.source_authority = 'municipal_decision'
         AND f.evidence_kind = 'official_decision'
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
             JOIN source_locators AS locators
               ON locators.commune_id = communes.id
              AND locators.url = records.origin_url
              AND locators.role = 'minutes'
              AND locators.parent_index_url = 'https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr'
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
              AND runs.processor_name = 'ixelles-municipal-minutes-public-mandates'
              AND runs.processor_version = '1.0.0'
              AND runs.config_hash = 'sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1'
              AND runs.generation_key = f.verification_generation
              AND runs.quality_measurements ->> 'accepted' = 'true'
              AND runs.completed_at IS NOT NULL
              AND artifacts.source_version_id = runs.source_version_id
              AND artifacts.input_sha256 = versions.sha256
              AND artifacts.processor_name = 'ixelles-municipal-minutes-public-mandates'
              AND artifacts.processor_version = '1.0.0'
              AND artifacts.config_hash = 'sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1'
              AND artifacts.output_kind = 'relationship-claim-json'
              AND artifacts.schema_version = 'ixelles-public-mandate-v1'
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
              AND records.role = 'minutes'
              AND records.origin_url = f.authoritative_url
              AND records.origin_url ~ '^https://www\.ixelles\.be/uploads/conseil/pv/[0-9]+\.pdf$'
              AND communes.id = f.object_id
              AND communes.slug = 'ixelles'
              AND communes.name = 'Ixelles'
              AND communes.index_url = 'https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr'
              AND people.resolution_basis = 'explicit_identifier'
              AND people.explicit_identifier IS NOT NULL
              AND people.explicit_identifier <> ''
              AND position(people.explicit_identifier in f.evidence_excerpt) > 0
              AND position(f.effective_from::text in f.evidence_excerpt) > 0
              AND f.evidence_location = 'decision ' || locators.meeting_identifier
         );
    $$;
    """
  end
end
