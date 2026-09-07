defmodule BrusselsWtf.IdentityRelationshipVerificationTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.SourcedFact
  alias BrusselsWtf.Ingestion

  @verifier :ixelles_municipal_minutes_public_mandate_v1
  @processor_name "ixelles-municipal-minutes-public-mandates"
  @processor_version "1.0.0"
  @config_hash "sha256:1c6728b5044d402bddbad85e63cf51570f465836aeba70fc6e2d50fc24da12f1"
  @ruleset "ixelles-public-mandate-v1"
  @origin_url "https://www.ixelles.be/uploads/conseil/pv/267.pdf"

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

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: @origin_url,
        parent_index_url: configured.index_url,
        meeting_identifier: "267",
        scheduled_on: ~D[2026-08-19],
        role: :minutes,
        language: :bilingual,
        observed_label: "Procès-verbal",
        discovered_at: ~U[2026-08-19 11:59:00Z]
      })

    source_bytes = "%PDF-1.7 official Ixelles minutes fixture"
    {:ok, archived_source} = BrusselsWtf.Archive.store(source_bytes, :raw)

    source_record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: @origin_url,
        role: :minutes,
        original_language: :bilingual
      })

    source_version =
      Ingestion.upsert_source_version!(%{
        source_record_id: source_record.id,
        sha256: archived_source.sha256,
        byte_size: byte_size(source_bytes),
        media_type: "application/pdf",
        object_key: archived_source.object_key,
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
      source_locator_id: locator.id,
      source_version_id: source_version.id,
      poll_run_id: poll_run.id,
      check_key: "fetch:ixelles-267",
      observed_at: ~U[2026-08-19 12:00:00Z],
      status: :success,
      http_status: 200,
      sha256: archived_source.sha256,
      final_url: @origin_url
    })

    person =
      Identity.record_person!(%{
        legal_name: "Alex Example",
        explicit_identifier: "municipal-mandate-42",
        resolution_basis: :explicit_identifier,
        corroborating_facts: %{"private_address" => "DO NOT PUBLISH"}
      })

    {:ok, commune: commune, source_version: source_version, person: person}
  end

  test "eligible candidates automatically queue and process idempotently without human provenance",
       %{commune: commune, source_version: source_version, person: person} do
    excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."

    record_accepted_text!(source_version, "Official minutes\n#{excerpt}\n", "automatic")

    fact =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        evidence_excerpt: excerpt
      })

    assert_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesPublicMandate,
      args: %{fact_id: fact.id}
    )

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: fact.id})

    verified = Identity.get_sourced_fact!(fact.id)
    assert verified.verification_status == :verified
    assert verified.verified_by == Atom.to_string(@verifier)
    refute verified.verified_by =~ "human"

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: fact.id})

    relationship_runs =
      source_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.filter(&(&1.processor_role == :relationship_verification))

    assert length(relationship_runs) == 1

    assert [["ixelles_municipal_minutes_public_mandate_v1", nil]] =
             Repo.query!(
               "SELECT verifier_id, details ->> 'human_reviewed' FROM sourced_fact_verification_events WHERE fact_id = $1::text::uuid AND to_status = 'verified'",
               [fact.id]
             ).rows
  end

  test "automatic processing retries until extraction exists and then verifies once",
       %{commune: commune, source_version: source_version, person: person} do
    excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] is elected to the Ixelles municipal council."

    fact =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        evidence_excerpt: excerpt
      })

    assert {:error, :extraction_not_ready} =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: fact.id})

    record_accepted_text!(source_version, "Official minutes\n#{excerpt}\n", "retry")

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: fact.id})

    assert Identity.get_sourced_fact!(fact.id).verification_status == :verified
  end

  test "name-only and unresolved candidates never publish automatically",
       %{commune: commune, source_version: source_version, person: person} do
    mention = "2024-12-01 Alex Example [municipal-mandate-42] attended the council meeting."
    record_accepted_text!(source_version, "Official minutes\n#{mention}\n", "mention-only")

    name_only =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        evidence_excerpt: mention
      })

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: name_only.id})

    assert Identity.get_sourced_fact!(name_only.id).verification_status == :unreviewed
    assert Identity.list_public_relationships!(%{subject_id: person.id}) == []

    unresolved =
      Identity.record_sourced_fact!(%{
        subject_type: :person,
        subject_id: Ecto.UUID.generate(),
        object_type: :commune,
        object_id: commune.id,
        kind: :public_mandate,
        effective_from: ~D[2026-01-01],
        source_version_id: source_version.id,
        authoritative_url: @origin_url,
        source_authority: :municipal_decision,
        evidence_kind: :official_decision,
        evidence_excerpt: "Unknown Person is appointed to the council.",
        evidence_location: "decision 267"
      })

    refute_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesPublicMandate,
      args: %{fact_id: unresolved.id}
    )

    assert unresolved.verification_status == :unreviewed
  end

  test "bounded semantics reject another appointee, duplicate names, wrong context, and arbitrary corroboration",
       %{commune: commune, source_version: source_version, person: person} do
    other_person_excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] attended; Jane Other [jane-1] is appointed to the Ixelles municipal council."

    record_accepted_text!(
      source_version,
      "Official minutes\n#{other_person_excerpt}\n",
      "wrong-person"
    )

    wrong_person =
      record_mandate!(person, commune, source_version, %{
        evidence_excerpt: other_person_excerpt
      })

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{
               fact_id: wrong_person.id
             })

    assert Identity.get_sourced_fact!(wrong_person.id).verification_status == :unreviewed

    wrong_location =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 999"
      })

    {wrong_location_run, _} =
      record_verifier_output!(wrong_location, person, commune, source_version)

    assert_raise ArgumentError, ~r/official text must directly and unambiguously bind/, fn ->
      Identity.verify_sourced_fact!(wrong_location.id, @verifier, wrong_location_run.id)
    end

    wrong_date =
      record_mandate!(person, commune, source_version, %{
        evidence_excerpt:
          "2024-12-02 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."
      })

    {wrong_date_run, _} = record_verifier_output!(wrong_date, person, commune, source_version)

    assert_raise ArgumentError, ~r/official text must directly and unambiguously bind/, fn ->
      Identity.verify_sourced_fact!(wrong_date.id, @verifier, wrong_date_run.id)
    end

    detached_date =
      record_mandate!(person, commune, source_version, %{
        evidence_excerpt:
          "2024-12-01 minutes opened. Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."
      })

    {detached_date_run, _} =
      record_verifier_output!(detached_date, person, commune, source_version)

    assert_raise ArgumentError, ~r/official text must directly and unambiguously bind/, fn ->
      Identity.verify_sourced_fact!(detached_date.id, @verifier, detached_date_run.id)
    end

    Identity.record_person!(%{
      legal_name: "Alex Example",
      explicit_identifier: "duplicate-alex",
      resolution_basis: :explicit_identifier,
      corroborating_facts: %{}
    })

    duplicate_name_fact =
      record_mandate!(person, commune, source_version, %{
        effective_from: ~D[2024-12-03]
      })

    {duplicate_run, _} =
      record_verifier_output!(duplicate_name_fact, person, commune, source_version)

    assert_raise ArgumentError, ~r/unambiguously bind/, fn ->
      Identity.verify_sourced_fact!(duplicate_name_fact.id, @verifier, duplicate_run.id)
    end

    assert Identity.get_sourced_fact!(wrong_location.id).verification_status == :unreviewed

    other_commune =
      Ingestion.create_commune!(%{
        slug: "uccle",
        name: "Uccle",
        index_url: BrusselsWtf.Communes.configuration!("uccle").index_url
      })

    wrong_commune =
      record_mandate!(person, other_commune, source_version, %{
        evidence_excerpt:
          "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Uccle municipal council."
      })

    wrong_office =
      Identity.record_sourced_fact!(%{
        subject_type: :person,
        subject_id: person.id,
        object_type: :office,
        object_id: Ecto.UUID.generate(),
        kind: :public_mandate,
        effective_from: ~D[2024-12-01],
        source_version_id: source_version.id,
        authoritative_url: @origin_url,
        source_authority: :municipal_decision,
        evidence_kind: :official_decision,
        evidence_excerpt:
          "2024-12-01 Alex Example [municipal-mandate-42] is appointed to an unrelated office.",
        evidence_location: "decision 267"
      })

    for candidate <- [wrong_date, wrong_commune, wrong_office] do
      assert Identity.get_sourced_fact!(candidate.id).verification_status == :unreviewed
    end

    refute_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesPublicMandate,
      args: %{fact_id: wrong_commune.id}
    )

    refute_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesPublicMandate,
      args: %{fact_id: wrong_office.id}
    )

    corroborated =
      Identity.record_person!(%{
        legal_name: "Corroborated Example",
        resolution_basis: :corroborated_name,
        corroborating_facts: %{"arbitrary" => "caller supplied"}
      })

    corroborated_fact =
      record_mandate!(corroborated, commune, source_version, %{
        evidence_excerpt:
          "2024-12-01 Corroborated Example is appointed to the Ixelles municipal council."
      })

    refute_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesPublicMandate,
      args: %{fact_id: corroborated_fact.id}
    )

    assert corroborated_fact.verification_status == :unreviewed
  end

  test "raw GUC provenance forgery and later run tampering never become trusted or public",
       %{commune: commune, source_version: source_version, person: person} do
    excerpt =
      "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."

    {extraction_run, extraction_artifact} =
      record_accepted_text!(source_version, "Official minutes\n#{excerpt}\n", "raw-forgery")

    forged =
      record_mandate!(person, commune, source_version, %{
        evidence_excerpt: excerpt
      })

    assert_raise Postgrex.Error,
                 ~r/trusted registry run, artifact, source, and identity contract/,
                 fn ->
                   Repo.transaction(fn ->
                     for {key, value} <- [
                           {"brussels_wtf.trusted_relationship_verifier",
                            "ixelles_municipal_minutes_public_mandate_v1"},
                           {"brussels_wtf.verification_processing_run_id", extraction_run.id},
                           {"brussels_wtf.verification_artifact_id", extraction_artifact.id},
                           {"brussels_wtf.verification_processor_version",
                            extraction_run.processor_version},
                           {"brussels_wtf.verification_ruleset_version", @ruleset},
                           {"brussels_wtf.verification_config_sha256",
                            extraction_run.config_hash},
                           {"brussels_wtf.verification_generation", extraction_run.generation_key}
                         ] do
                       Repo.query!("SELECT set_config($1, $2, true)", [key, value])
                     end

                     Repo.query!(
                       """
                       UPDATE sourced_facts
                          SET verification_status = 'verified',
                              verified_by = 'ixelles_municipal_minutes_public_mandate_v1',
                              verification_processor_version = $2,
                              verification_ruleset_version = $3,
                              verification_config_sha256 = $4,
                              verification_generation = $5,
                              verification_processing_run_id = $6::text::uuid,
                              verification_artifact_id = $7::text::uuid,
                              verified_at = clock_timestamp() AT TIME ZONE 'utc'
                        WHERE id = $1::text::uuid
                       """,
                       [
                         forged.id,
                         extraction_run.processor_version,
                         @ruleset,
                         extraction_run.config_hash,
                         extraction_run.generation_key,
                         extraction_run.id,
                         extraction_artifact.id
                       ]
                     )
                   end)
                 end

    assert Identity.get_sourced_fact!(forged.id).verification_status == :unreviewed

    claim_bytes =
      Jason.encode!(%{
        "schema_version" => @ruleset,
        "subject" => %{"type" => "person", "id" => person.id}
      })

    {:ok, archived_claim} = BrusselsWtf.Archive.store(claim_bytes, :derived)

    empty_input_run =
      Ingestion.record_processing_run!(%{
        source_version_id: source_version.id,
        generation_key: "relationship:empty-inputs:#{forged.id}",
        processor_role: :relationship_verification,
        inputs: %{},
        processor_name: @processor_name,
        processor_version: @processor_version,
        config_hash: @config_hash,
        status: :succeeded,
        output: %{"schema_version" => @ruleset, "claim_sha256" => archived_claim.sha256},
        quality_measurements: %{"accepted" => true},
        completed_at: ~U[2026-08-19 12:01:00Z]
      })

    empty_input_artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: source_version.id,
        processing_run_id: empty_input_run.id,
        input_sha256: source_version.sha256,
        output_sha256: archived_claim.sha256,
        processor_name: @processor_name,
        processor_version: @processor_version,
        config_hash: @config_hash,
        output_kind: "relationship-claim-json",
        object_key: archived_claim.object_key,
        media_type: "application/json",
        byte_size: byte_size(claim_bytes),
        schema_version: @ruleset,
        quality_measurements: %{"accepted" => true}
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: empty_input_run.id,
      derived_artifact_id: empty_input_artifact.id,
      role: :relationship_claim
    })

    assert_raise Postgrex.Error,
                 ~r/trusted registry run, artifact, source, and identity contract/,
                 fn ->
                   Repo.transaction(fn ->
                     for {key, value} <- [
                           {"brussels_wtf.trusted_relationship_verifier",
                            "ixelles_municipal_minutes_public_mandate_v1"},
                           {"brussels_wtf.verification_processing_run_id", empty_input_run.id},
                           {"brussels_wtf.verification_artifact_id", empty_input_artifact.id},
                           {"brussels_wtf.verification_processor_version",
                            empty_input_run.processor_version},
                           {"brussels_wtf.verification_ruleset_version", @ruleset},
                           {"brussels_wtf.verification_config_sha256",
                            empty_input_run.config_hash},
                           {"brussels_wtf.verification_generation",
                            empty_input_run.generation_key}
                         ] do
                       Repo.query!("SELECT set_config($1, $2, true)", [key, value])
                     end

                     Repo.query!(
                       """
                       UPDATE sourced_facts
                          SET verification_status = 'verified',
                              verified_by = 'ixelles_municipal_minutes_public_mandate_v1',
                              verification_processor_version = $2,
                              verification_ruleset_version = $3,
                              verification_config_sha256 = $4,
                              verification_generation = $5,
                              verification_processing_run_id = $6::text::uuid,
                              verification_artifact_id = $7::text::uuid,
                              verified_at = clock_timestamp() AT TIME ZONE 'utc'
                        WHERE id = $1::text::uuid
                       """,
                       [
                         forged.id,
                         empty_input_run.processor_version,
                         @ruleset,
                         empty_input_run.config_hash,
                         empty_input_run.generation_key,
                         empty_input_run.id,
                         empty_input_artifact.id
                       ]
                     )
                   end)
                 end

    assert Identity.get_sourced_fact!(forged.id).verification_status == :unreviewed

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: forged.id})

    verified = Identity.get_sourced_fact!(forged.id)
    assert BrusselsWtf.Identity.TrustedVerifier.trusted_fact?(verified)

    Repo.query!(
      "UPDATE processing_runs SET config_hash = 'sha256:tampered' WHERE id = $1::text::uuid",
      [verified.verification_processing_run_id]
    )

    tampered = Identity.get_sourced_fact!(forged.id)
    refute BrusselsWtf.Identity.TrustedVerifier.trusted_fact?(tampered)
    assert Identity.list_public_relationships!(%{subject_id: person.id}) == []
  end

  test "terminal extraction failure opens private evidence review and later extraction re-enqueues",
       %{commune: commune, source_version: source_version, person: person} do
    fact = record_mandate!(person, commune, source_version, %{})

    assert :ok =
             BrusselsWtf.Workers.VerifyIxellesPublicMandate.perform(%Oban.Job{
               args: %{"fact_id" => fact.id},
               attempt: 5,
               max_attempts: 5
             })

    assert [%{kind: :evidence, affected_record_id: affected_id}] =
             BrusselsWtf.Review.Case
             |> Ash.read!(authorize?: false, domain: BrusselsWtf.Review)

    assert affected_id == fact.id
    assert Identity.get_sourced_fact!(fact.id).verification_status == :unreviewed

    Repo.query!(
      "UPDATE oban_jobs SET state = 'discarded' WHERE worker = $1 AND args ->> 'fact_id' = $2",
      ["BrusselsWtf.Workers.VerifyIxellesPublicMandate", fact.id]
    )

    record_accepted_text!(
      source_version,
      "Official minutes\n#{fact.evidence_excerpt}\n",
      "late-extraction"
    )

    available =
      Repo.query!(
        "SELECT count(*) FROM oban_jobs WHERE worker = $1 AND args ->> 'fact_id' = $2 AND state = 'available'",
        ["BrusselsWtf.Workers.VerifyIxellesPublicMandate", fact.id]
      ).rows

    assert available == [[1]]

    assert :ok =
             perform_job(BrusselsWtf.Workers.VerifyIxellesPublicMandate, %{fact_id: fact.id})

    assert Identity.get_sourced_fact!(fact.id).verification_status == :verified

    open_cases =
      BrusselsWtf.Review.Case
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Review)
      |> Enum.filter(&(&1.status == :open and &1.affected_record_id == fact.id))

    assert open_cases == []
  end

  test "an allowlisted Ixelles minutes claim verifies from its exact archived semantic artifact",
       %{commune: commune, source_version: source_version, person: person} do
    fact = record_mandate!(person, commune, source_version, %{evidence_location: "decision 267"})
    {run, artifact} = record_verifier_output!(fact, person, commune, source_version)

    verified = Identity.verify_sourced_fact!(fact.id, @verifier, run.id)

    assert verified.verification_status == :verified
    assert verified.verified_by == Atom.to_string(@verifier)
    assert verified.verification_processor_version == @processor_version
    assert verified.verification_ruleset_version == @ruleset
    assert verified.verification_config_sha256 == @config_hash
    assert verified.verification_generation == run.generation_key
    assert verified.verification_processing_run_id == run.id
    assert verified.verification_artifact_id == artifact.id
    assert %DateTime{} = verified.verified_at

    assert [%BrusselsWtf.Identity.PublicRelationship{} = relationship] =
             Identity.list_public_relationships!(%{subject_id: person.id})

    assert relationship.subject_name == "Alex Example"
    assert relationship.object_name == "Ixelles"
    assert relationship.authoritative_url == @origin_url
    assert relationship.source_retrieved_at == source_version.first_retrieved_at

    rendered = inspect(relationship)
    refute rendered =~ "DO NOT PUBLISH"
    refute rendered =~ run.generation_key
    refute rendered =~ artifact.object_key
  end

  test "verification rejects a payload that is not the exact candidate semantics",
       %{commune: commune, source_version: source_version, person: person} do
    fact = record_mandate!(person, commune, source_version, %{evidence_location: "decision 267"})

    {run, _artifact} =
      record_verifier_output!(fact, person, commune, source_version, fn claim ->
        put_in(claim, ["relationship", "kind"], "ownership")
      end)

    assert_raise ArgumentError, ~r/semantic payload does not exactly match/, fn ->
      Identity.verify_sourced_fact!(fact.id, @verifier, run.id)
    end

    assert Identity.get_sourced_fact!(fact.id).verification_status == :unreviewed
  end

  test "verification requires official discovery, retrieval, archive, succeeded run, and artifact",
       %{commune: commune, source_version: source_version, person: person} do
    fact = record_mandate!(person, commune, source_version, %{evidence_location: "decision 267"})
    {run, artifact} = record_verifier_output!(fact, person, commune, source_version)

    BrusselsWtf.Archive.Memory.reset()

    assert_raise ArgumentError, ~r/archived source bytes/, fn ->
      Identity.verify_sourced_fact!(fact.id, @verifier, run.id)
    end

    assert Identity.get_sourced_fact!(fact.id).verification_status == :unreviewed
    assert artifact.processing_run_id == run.id
  end

  test "caller-supplied verification provenance and generic Ash updates stay unavailable",
       %{commune: commune, source_version: source_version, person: person} do
    assert_raise Ash.Error.Invalid, ~r/No such input `verification_status`/, fn ->
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        verification_status: :verified,
        verified_by: Atom.to_string(@verifier),
        verified_at: ~U[2026-08-29 09:30:00Z]
      })
    end

    fact = record_mandate!(person, commune, source_version, %{evidence_location: "decision 267"})
    assert Ash.Resource.Info.action(SourcedFact, :verify) == nil
    assert Ash.Resource.Info.action(SourcedFact, :mark_superseded) == nil

    assert_raise RuntimeError, ~r/Required primary update action/, fn ->
      Ash.update!(fact, %{verification_status: :verified})
    end
  end

  test "supersession is an atomic one-way transition and keeps both audit events",
       %{commune: commune, source_version: source_version, person: person} do
    prior = record_mandate!(person, commune, source_version, %{evidence_location: "decision 267"})
    {prior_run, _} = record_verifier_output!(prior, person, commune, source_version)
    Identity.verify_sourced_fact!(prior.id, @verifier, prior_run.id)

    successor =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        effective_from: ~D[2025-01-01],
        supersedes_id: prior.id
      })

    {successor_run, _} = record_verifier_output!(successor, person, commune, source_version)
    Identity.verify_sourced_fact!(successor.id, @verifier, successor_run.id)

    assert Identity.get_sourced_fact!(prior.id).verification_status == :superseded
    assert Identity.get_sourced_fact!(successor.id).verification_status == :verified

    statuses =
      Repo.query!(
        "SELECT from_status, to_status FROM sourced_fact_verification_events WHERE fact_id IN ($1::text::uuid, $2::text::uuid) ORDER BY inserted_at, id",
        [prior.id, successor.id]
      ).rows

    assert ["unreviewed", "verified"] in statuses
    assert ["verified", "superseded"] in statuses

    competing =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        effective_from: ~D[2025-02-01],
        supersedes_id: prior.id
      })

    {competing_run, _} = record_verifier_output!(competing, person, commune, source_version)

    assert_raise ArgumentError, ~r/current verified fact/, fn ->
      Identity.verify_sourced_fact!(competing.id, @verifier, competing_run.id)
    end

    assert Identity.get_sourced_fact!(prior.id).verification_status == :superseded
    assert Identity.get_sourced_fact!(successor.id).verification_status == :verified
    assert Identity.get_sourced_fact!(competing.id).verification_status == :unreviewed
  end

  test "self-attested JSON cannot replace direct extracted appointment evidence",
       %{commune: commune, source_version: source_version, person: person} do
    absent =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        evidence_excerpt:
          "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council."
      })

    {absent_run, _} =
      record_verifier_output!(
        absent,
        person,
        commune,
        source_version,
        & &1,
        "Official minutes contain no matching decision."
      )

    assert_raise ArgumentError,
                 ~r/directly and unambiguously bind/,
                 fn ->
                   Identity.verify_sourced_fact!(absent.id, @verifier, absent_run.id)
                 end

    mention_only =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        evidence_excerpt:
          "2024-12-01 Alex Example [municipal-mandate-42] attended the council meeting."
      })

    {mention_run, _} =
      record_verifier_output!(mention_only, person, commune, source_version)

    assert_raise ArgumentError,
                 ~r/directly and unambiguously bind/,
                 fn ->
                   Identity.verify_sourced_fact!(mention_only.id, @verifier, mention_run.id)
                 end

    assert Identity.get_sourced_fact!(absent.id).verification_status == :unreviewed
    assert Identity.get_sourced_fact!(mention_only.id).verification_status == :unreviewed
  end

  test "generic extraction success and an arbitrary HTTPS citation never verify",
       %{commune: commune, source_version: source_version, person: person} do
    fact =
      record_mandate!(person, commune, source_version, %{
        evidence_location: "decision 267",
        authoritative_url: "https://example.test/looks-official.pdf"
      })

    extraction_run =
      Ingestion.record_processing_run!(%{
        source_version_id: source_version.id,
        generation_key: "native:not-a-relationship-verifier",
        processor_role: :native_extraction,
        processor_name: "poppler-native-text",
        processor_version: "fixture-v1",
        config_hash: "sha256:not-a-relationship-config",
        status: :succeeded,
        output: %{"classification" => "accepted native text"},
        completed_at: ~U[2026-08-19 12:01:00Z]
      })

    assert_raise ArgumentError, ~r/exactly one relationship artifact/, fn ->
      Identity.verify_sourced_fact!(fact.id, @verifier, extraction_run.id)
    end

    {relationship_run, _} =
      record_verifier_output!(fact, person, commune, source_version)

    assert_raise ArgumentError, ~r/official discovered Ixelles minutes source/, fn ->
      Identity.verify_sourced_fact!(fact.id, @verifier, relationship_run.id)
    end

    assert Identity.get_sourced_fact!(fact.id).verification_status == :unreviewed
  end

  test "unknown verifiers and non-persisted runs fail closed",
       %{commune: commune, source_version: source_version, person: person} do
    fact = record_mandate!(person, commune, source_version, %{evidence_location: "decision 267"})

    assert_raise ArgumentError, ~r/persisted processing run/, fn ->
      Identity.verify_sourced_fact!(fact.id, @verifier, "not-a-run-id")
    end

    assert_raise ArgumentError, ~r/untrusted relationship verifier/, fn ->
      Identity.verify_sourced_fact!(fact.id, :generic_official_source, Ecto.UUID.generate())
    end
  end

  test "public citation URLs reject credentials, queries, fragments, and non-HTTPS schemes" do
    assert :ok = BrusselsWtf.Identity.TrustedVerifier.validate_public_url!(@origin_url)

    for unsafe <- [
          "http://www.ixelles.be/minutes.pdf",
          "https://user:secret@www.ixelles.be/minutes.pdf",
          "https://www.ixelles.be/minutes.pdf?token=secret",
          "https://www.ixelles.be/minutes.pdf#private",
          "https://www.ixelles.be:444/minutes.pdf"
        ] do
      assert_raise ArgumentError, ~r/safe public HTTPS URL/, fn ->
        BrusselsWtf.Identity.TrustedVerifier.validate_public_url!(unsafe)
      end
    end
  end

  defp record_mandate!(person, commune, source_version, overrides) do
    effective_from = Map.get(overrides, :effective_from, ~D[2024-12-01])

    attrs = %{
      subject_type: :person,
      subject_id: person.id,
      object_type: :commune,
      object_id: commune.id,
      object_label: "DO NOT PUBLISH object label",
      kind: :public_mandate,
      effective_from: effective_from,
      source_version_id: source_version.id,
      authoritative_url: @origin_url,
      source_authority: :municipal_decision,
      evidence_kind: :official_decision,
      evidence_excerpt:
        "#{Date.to_iso8601(effective_from)} #{person.legal_name} [#{person.explicit_identifier}] is appointed to the Ixelles municipal council.",
      evidence_location: "decision 267"
    }

    Identity.record_sourced_fact!(Map.merge(attrs, overrides))
  end

  defp record_accepted_text!(source_version, text, _generation) do
    BrusselsWtf.Processors.Stub.put(source_version.sha256, %{
      extract: %{"text" => text}
    })

    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(source_version.id)

    run =
      source_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :native_extraction and &1.status == :succeeded))

    artifact =
      run
      |> Ash.load!(:derived_artifacts)
      |> Map.fetch!(:derived_artifacts)
      |> Enum.find(&(&1.output_kind == "native-text"))

    {run, artifact}
  end

  defp record_verifier_output!(
         fact,
         person,
         commune,
         source_version,
         mutate \\ & &1,
         extracted_text \\ nil
       ) do
    claim =
      %{
        "schema_version" => @ruleset,
        "subject" => %{
          "type" => "person",
          "id" => person.id,
          "legal_name" => person.legal_name,
          "resolution_basis" => Atom.to_string(person.resolution_basis)
        },
        "object" => %{
          "type" => "commune",
          "id" => commune.id,
          "slug" => commune.slug,
          "name" => commune.name
        },
        "relationship" => %{
          "kind" => Atom.to_string(fact.kind),
          "effective_from" => Date.to_iso8601(fact.effective_from),
          "effective_to" => date_string(fact.effective_to)
        },
        "evidence" => %{
          "source_version_id" => source_version.id,
          "source_sha256" => source_version.sha256,
          "authoritative_url" => @origin_url,
          "source_authority" => Atom.to_string(fact.source_authority),
          "kind" => Atom.to_string(fact.evidence_kind),
          "excerpt" => fact.evidence_excerpt,
          "location" => fact.evidence_location
        }
      }
      |> mutate.()

    extracted_text =
      extracted_text || "Official Ixelles minutes\n#{fact.evidence_excerpt}\n"

    BrusselsWtf.Processors.Stub.put(source_version.sha256, %{
      extract: %{"text" => extracted_text}
    })

    {:ok, raw_source} = BrusselsWtf.Archive.get(source_version.object_key)

    {:ok, rerun} =
      BrusselsWtf.PDF.Processor.native(
        %{sha256: source_version.sha256, media_type: source_version.media_type},
        raw_source
      )

    {:ok, archived_text} = BrusselsWtf.Archive.store(extracted_text, :derived)

    text_run =
      Ingestion.record_processing_run!(%{
        source_version_id: source_version.id,
        generation_key: "native:relationship-input:#{fact.id}",
        processor_role: :native_extraction,
        inputs: %{"source_sha256" => source_version.sha256},
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
        source_version_id: source_version.id,
        processing_run_id: text_run.id,
        input_sha256: source_version.sha256,
        output_sha256: archived_text.sha256,
        processor_name: text_run.processor_name,
        processor_version: text_run.processor_version,
        config_hash: text_run.config_hash,
        output_kind: "native-text",
        object_key: archived_text.object_key,
        media_type: "text/plain; charset=utf-8",
        byte_size: byte_size(extracted_text),
        schema_version: "derived-artifact-v1",
        quality_measurements: rerun.quality_measurements
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: text_run.id,
      derived_artifact_id: text_artifact.id,
      role: :native_output
    })

    bytes = Jason.encode!(claim)
    {:ok, archived} = BrusselsWtf.Archive.store(bytes, :derived)

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: source_version.id,
        generation_key: "relationship:#{fact.id}",
        processor_role: :relationship_verification,
        inputs: %{
          "source_version_sha256" => source_version.sha256,
          "ruleset_version" => @ruleset,
          "extraction_run_id" => text_run.id,
          "text_artifact_id" => text_artifact.id
        },
        processor_name: @processor_name,
        processor_version: @processor_version,
        config_hash: @config_hash,
        status: :succeeded,
        output: %{
          "schema_version" => @ruleset,
          "claim_sha256" => archived.sha256
        },
        quality_measurements: %{"accepted" => true},
        completed_at: ~U[2026-08-19 12:01:00Z]
      })

    artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: source_version.id,
        processing_run_id: run.id,
        input_sha256: source_version.sha256,
        output_sha256: archived.sha256,
        processor_name: @processor_name,
        processor_version: @processor_version,
        config_hash: @config_hash,
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

    {run, artifact}
  end

  defp date_string(nil), do: nil
  defp date_string(date), do: Date.to_iso8601(date)
end
