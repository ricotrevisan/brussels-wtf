defmodule BrusselsWtf.Repo.Migrations.VerifiedMunicipalInstallations do
  use Ecto.Migration

  def up do
    execute "DROP INDEX sourced_facts_one_current_semantic_fact_index"

    execute """
    CREATE UNIQUE INDEX sourced_facts_one_current_semantic_fact_index
    ON sourced_facts (subject_type, subject_id, object_type, object_id, kind, verified_by, (COALESCE(mandate_declaration ->> 'key', '')))
    NULLS NOT DISTINCT WHERE verification_status = 'verified' AND verified_by <> 'municipal_installation_v1'
    """

    execute """
    CREATE UNIQUE INDEX sourced_facts_one_current_installation_index
    ON sourced_facts (subject_id, object_id, kind, object_label)
    WHERE verification_status = 'verified' AND verified_by = 'municipal_installation_v1'
    """

    execute ~S"""
    CREATE FUNCTION trusted_municipal_installation_document(slug text, sha text, url text, parent text, day date, meeting text, role text)
    RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
      SELECT (slug, sha, url, parent, day, meeting, role) IN (
        ('ixelles', '57b4ca56118d46178cf9c80692c49c92d6ab62f0cef5580610e8fb816b7eac06', 'https://www.ixelles.be/uploads/conseil/pv/245.pdf', 'https://www.ixelles.be/site/page.php?numpage=11&annee=2024', DATE '2024-12-01', '245', 'minutes'),
        ('ixelles', '4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5', 'https://www.ixelles.be/uploads/conseil/pv/267.pdf', 'https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr', DATE '2026-06-11', '267', 'minutes'),
        ('uccle', '74bf6d25bb6800c66453b14ddae58be03d290b7554148170fa3e69b3ef137612', 'https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2024-12-01_REGISTRE_U1180_fr_nl.pdf', 'https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal', DATE '2024-12-01', '2024-12-01', 'register'),
        ('uccle', '3ea29d0bdf4e09f329cc73027fec8583f36b811f9999e671c37e86d7f71cc8f9', 'https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf', 'https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal', DATE '2025-06-26', '2025-06-26', 'register'),
        ('forest', '266bbbd6960ed51ff569b80f3e9e4f2b0a3f9c02df09ecf531a66d5c6e4fcf26', 'https://forest.brussels/sites/default/files/publications/registre/2025-01/PV%20%20conseil%20communal%20-%20gemeenteraad%2001122024_1.pdf', 'https://forest.brussels/fr/publications/conseil-communal-1', DATE '2024-12-01', '2024-12-01', 'minutes'),
        ('forest', '6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26', 'https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf', 'https://forest.brussels/fr/publications/conseil-communal-1', DATE '2026-03-24', '2026-03-24', 'minutes'),
        ('city-of-brussels', '51ff7ef8d38e0437c06ec3fefe50b0039cc08b1d35b5a529a97a342b1c09537c', 'https://www.brussels.be/sites/default/files/13.-%20Conseil%20communal%20du%2001decembre%202024.pdf', 'https://www.brussels.be/complete-reports-public-meetings-city-council?field_date_document_value=2024', DATE '2024-12-01', '2024-12-01', 'minutes'),
        ('city-of-brussels', 'f3133ec17d84044f54712b2c5dc09c38c688c71a7d9b89f042c774d7869d2582', 'https://www.brussels.be/sites/default/files/CRI20avril2026.pdf', 'https://www.brussels.be/complete-reports-public-meetings-city-council', DATE '2026-04-20', '2026-04-20', 'minutes')
      );
    $fn$;
    """

    execute ~S"""
    CREATE FUNCTION trusted_municipal_installation_chain(pin jsonb, slug text, commune uuid, installed boolean)
    RETURNS boolean LANGUAGE sql STABLE AS $fn$
      SELECT coalesce(EXISTS (
        SELECT 1 FROM source_versions v JOIN source_records r ON r.id = v.source_record_id
        JOIN communes c ON c.id = r.commune_id
        JOIN source_locators l ON l.commune_id = c.id AND l.url = r.origin_url
        JOIN retrieval_observations o ON o.source_locator_id = l.id AND o.source_version_id = v.id
        JOIN processing_runs x ON x.id::text = pin ->> 'extraction_run_id'
        JOIN derived_artifacts a ON a.id::text = pin ->> 'text_artifact_id'
        JOIN processing_run_artifacts link ON link.processing_run_id = x.id AND link.derived_artifact_id = a.id AND link.role = 'native_output'
        LEFT JOIN council_meetings m ON m.id = r.council_meeting_id
        WHERE v.id::text = pin ->> 'source_version_id' AND v.sha256 = pin ->> 'source_sha256'
          AND r.origin_url = pin ->> 'source_url' AND r.role = l.role
          AND c.slug = slug AND c.id = commune
          AND (r.council_meeting_id IS NULL OR (m.commune_id = c.id AND m.scheduled_on = l.scheduled_on))
          AND trusted_municipal_installation_document(c.slug, v.sha256, r.origin_url, l.parent_index_url, l.scheduled_on, l.meeting_identifier, l.role)
          AND (l.scheduled_on = DATE '2024-12-01') = installed
          AND v.media_type = 'application/pdf'
          AND o.status IN ('success', 'unchanged') AND o.sha256 = v.sha256 AND o.final_url = r.origin_url
          AND x.source_version_id = v.id AND x.status = 'succeeded' AND x.completed_at IS NOT NULL
          AND x.processor_role = 'native_extraction' AND x.processor_name = 'poppler-native-text'
          AND x.quality_measurements ->> 'accepted' = 'true'
          AND a.input_sha256 = v.sha256
          AND a.output_sha256 = pin ->> 'text_sha256'
          AND a.output_kind = 'native-text' AND a.media_type = 'text/plain; charset=utf-8'
          AND a.processor_name = x.processor_name AND a.processor_version = x.processor_version
          AND a.config_hash = x.config_hash AND a.quality_measurements = x.quality_measurements
      ), false);
    $fn$;
    """

    execute ~S"""
    -- Persisted-lineage/transition consistency, not attestation of Elixir execution.
    -- Archive reproduction and independent parsing belong to the normal verifier API.
    CREATE FUNCTION trusted_municipal_installation_fact(f sourced_facts)
    RETURNS boolean LANGUAGE sql STABLE AS $fn$
      SELECT coalesce(
        f.verification_status IN ('verified', 'superseded') AND f.verified_by = 'municipal_installation_v1'
        AND f.verification_processor_version = '1.0.0'
        AND f.verification_ruleset_version = 'municipal-installation-v1'
        AND f.verification_config_sha256 = 'sha256:d56524d8d037ecb2a864da8dd71d846c517e5006587202a32afdb911fe2df8d3'
        AND f.subject_type = 'person' AND f.object_type = 'commune' AND f.kind = 'public_mandate'
        AND f.source_authority = 'municipal_decision' AND f.evidence_kind = 'official_decision'
        AND f.effective_from = DATE '2024-12-01' AND f.effective_to IS NULL
        AND f.supersedes_id IS NULL AND f.mandate_declaration IS NULL
        AND EXISTS (
          SELECT 1 FROM processing_runs x
          JOIN derived_artifacts a ON a.id = f.verification_artifact_id
          JOIN processing_run_artifacts link ON link.processing_run_id = x.id AND link.derived_artifact_id = a.id AND link.role = 'relationship_claim'
          JOIN people p ON p.id = f.subject_id
          JOIN communes c ON c.id = f.object_id
          WHERE x.id = f.verification_processing_run_id AND x.source_version_id = f.source_version_id
            AND x.processor_role = 'relationship_verification' AND x.processor_name = 'municipal-installation'
            AND x.processor_version = f.verification_processor_version AND x.config_hash = f.verification_config_sha256
            AND x.status = 'succeeded' AND x.completed_at IS NOT NULL AND x.quality_measurements = '{"accepted":true}'::jsonb
            AND x.generation_key = f.verification_generation
            AND x.generation_key = 'municipal-installation-v1:' || f.id::text || ':' || a.output_sha256
            AND x.output = jsonb_build_object('schema_version', 'municipal-installation-v1', 'claim_sha256', a.output_sha256)
            AND a.processing_run_id = x.id AND a.source_version_id = f.source_version_id
            AND a.input_sha256 = x.inputs -> 'installation' ->> 'source_sha256'
            AND a.processor_name = x.processor_name AND a.processor_version = x.processor_version AND a.config_hash = x.config_hash
            AND a.output_kind = 'relationship-claim-json' AND a.media_type = 'application/json'
            AND a.schema_version = 'municipal-installation-v1' AND a.quality_measurements = x.quality_measurements
            AND x.inputs ->> 'schema_version' = 'municipal-installation-v1'
            AND x.inputs ->> 'policy_version' = '1'
            AND x.inputs ->> 'fact_id' = f.id::text AND x.inputs ->> 'person_id' = p.id::text
            AND x.inputs ->> 'legal_name' = p.legal_name
            AND x.inputs ->> 'commune_id' = c.id::text AND x.inputs ->> 'commune_slug' = c.slug
            AND x.inputs -> 'candidate' ->> 'role_key' = f.object_label
            AND ((c.slug = 'city-of-brussels' AND f.object_label IN ('alderman', 'council_chair'))
              OR (c.slug IN ('ixelles', 'uccle', 'forest') AND f.object_label = 'municipal_councillor'))
            AND lower(x.inputs -> 'candidate' ->> 'legal_name') = lower(p.legal_name)
            AND x.inputs -> 'candidate' ->> 'effective_from' = f.effective_from::text
            AND x.inputs -> 'candidate' -> 'effective_to' = 'null'::jsonb
            AND x.inputs -> 'candidate' ->> 'evidence_excerpt' = f.evidence_excerpt
            AND x.inputs -> 'candidate' ->> 'evidence_location' = f.evidence_location
            AND f.evidence_location = 'installation 2024-12-01 page ' || (x.inputs -> 'candidate' ->> 'page')
            AND x.inputs -> 'installation' ->> 'source_version_id' = f.source_version_id::text
            AND x.inputs -> 'installation' ->> 'source_url' = f.authoritative_url
            AND trusted_municipal_installation_chain(x.inputs -> 'installation', c.slug, c.id, true)
            AND trusted_municipal_installation_chain(x.inputs -> 'corroboration', c.slug, c.id, false)
            AND p.status = 'active' AND p.resolution_basis = 'corroborated_name'
            AND p.corroborating_facts ->> 'municipality' = c.slug
            AND p.corroborating_facts ->> 'source_version_id' = x.inputs -> 'corroboration' ->> 'source_version_id'
            AND p.corroborating_facts ->> 'source_sha256' = x.inputs -> 'corroboration' ->> 'source_sha256'
            AND p.corroborating_facts ->> 'source_url' = x.inputs -> 'corroboration' ->> 'source_url'
            AND (SELECT count(*) FROM people names WHERE names.status = 'active'
              AND lower(regexp_replace(trim(names.legal_name), '\s+', ' ', 'g')) = lower(regexp_replace(trim(p.legal_name), '\s+', ' ', 'g'))) = 1
        ), false);
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
             NOT IN ('ixelles_municipal_minutes_public_mandate_v1', 'ixelles_mandate_declaration_v2', 'ixelles_mandate_declaration_v3', 'belgian_official_gazette_management_v1', 'municipal_installation_v1') THEN
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

            IF NEW.verified_by = 'municipal_installation_v1' THEN
              IF NOT coalesce(trusted_municipal_installation_fact(NEW), false) THEN
                RAISE EXCEPTION 'trusted installation identity and evidence contract is invalid';
              END IF;
            ELSIF NEW.verified_by = 'ixelles_mandate_declaration_v3' THEN
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
            IF OLD.verified_by = 'municipal_installation_v1' THEN
              RAISE EXCEPTION 'installation v1 does not authorize cessation or correction';
            END IF;
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
    raise "Evidence-gated installation audit history cannot be rolled back destructively"
  end
end
