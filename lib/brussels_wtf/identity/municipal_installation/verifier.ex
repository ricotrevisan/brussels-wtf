defmodule BrusselsWtf.Identity.MunicipalInstallation.Verifier do
  @moduledoc """
  Independently reproduces both native evidence chains and parses the claimed event.

  PostgreSQL predicates/GUC guards enforce persisted lineage and transition consistency;
  they are not proof that Elixir executed against the archive. Arbitrary database DML
  together with arbitrary transition GUCs remains inside the trusted operator boundary.
  Normal verification never treats a caller-created run/artifact as proof by itself.
  """
  alias BrusselsWtf.{Archive, Digest, Identity, Ingestion, Repo}
  alias Identity.MunicipalInstallation
  alias MunicipalInstallation.{Evidence, Resolver, Source}

  @id "municipal_installation_v1"
  @rules "municipal-installation-v1"
  @processor "municipal-installation"
  @config_inputs %{
    parser_policy_version: Source.parser_policy_version(),
    contracts: Source.contracts()
  }
  @config "sha256:" <> Digest.sha256(:erlang.term_to_binary(@config_inputs, [:deterministic]))
  def id, do: @id

  @doc false
  def config_hash, do: @config

  def persist!(fact, person, bundle, candidate) do
    payload = payload(fact, person, bundle, candidate)
    bytes = Jason.encode!(payload)
    {:ok, archived} = Archive.store(bytes, :derived)

    {run, run_notifications} =
      Ingestion.record_processing_run!(
        %{
          source_version_id: fact.source_version_id,
          generation_key: "#{@rules}:#{fact.id}:#{archived.sha256}",
          processor_role: :relationship_verification,
          processor_name: @processor,
          processor_version: "1.0.0",
          config_hash: @config,
          status: :queued,
          inputs: payload,
          output: %{}
        },
        return_notifications?: true
      )

    {artifact, artifact_notifications} =
      Ingestion.upsert_derived_artifact!(
        %{
          source_version_id: fact.source_version_id,
          processing_run_id: run.id,
          input_sha256: bundle.installation.version.sha256,
          output_sha256: archived.sha256,
          processor_name: @processor,
          processor_version: "1.0.0",
          config_hash: @config,
          output_kind: "relationship-claim-json",
          object_key: archived.object_key,
          media_type: "application/json",
          byte_size: byte_size(bytes),
          schema_version: @rules,
          quality_measurements: %{"accepted" => true}
        },
        return_notifications?: true
      )

    {_, link_notifications} =
      Ingestion.link_processing_run_artifact!(
        %{processing_run_id: run.id, derived_artifact_id: artifact.id, role: :relationship_claim},
        return_notifications?: true
      )

    {run, completion_notifications} =
      if run.status == :queued do
        Ingestion.complete_processing_run!(
          run,
          %{
            status: :succeeded,
            quality_measurements: %{"accepted" => true},
            started_at: BrusselsWtf.Clock.utc_now(),
            completed_at: BrusselsWtf.Clock.utc_now(),
            duration_ms: 0,
            output: %{"schema_version" => @rules, "claim_sha256" => archived.sha256}
          },
          return_notifications?: true
        )
      else
        {run, []}
      end

    {run,
     run_notifications ++ artifact_notifications ++ link_notifications ++ completion_notifications}
  end

  def verify!(fact_id, run_id) do
    {:ok, fact} =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT id FROM sourced_facts WHERE id = $1::text::uuid FOR UPDATE", [
            fact_id
          ])

          fact = Identity.get_sourced_fact!(fact_id)
          person = Identity.get_person!(fact.subject_id)

          version =
            Ingestion.get_source_version!(fact.source_version_id)
            |> Ash.load!(source_record: :commune)

          bundle = Evidence.load!(version.source_record.commune.slug)

          candidate =
            Enum.find(bundle.candidates, fn candidate ->
              attrs = MunicipalInstallation.fact_attributes(bundle, candidate, person)

              Map.take(fact, Map.keys(attrs)) == attrs and
                Resolver.normalize(candidate.legal_name) == Resolver.normalize(person.legal_name)
            end)

          unless candidate && fact.verification_status == :unreviewed &&
                   is_nil(fact.supersedes_id) && is_nil(fact.mandate_declaration),
                 do:
                   raise(
                     ArgumentError,
                     "fact does not exactly match an independently parsed installation"
                   )

          Resolver.validate!(person, bundle, candidate)
          run = Ingestion.get_processing_run!(run_id)
          artifact = artifact!(run.id)
          expected = payload(fact, person, bundle, candidate)

          unless run.source_version_id == fact.source_version_id and
                   run.processor_role == :relationship_verification and
                   run.processor_name == @processor and run.processor_version == "1.0.0" and
                   run.config_hash == @config and
                   run.status == :succeeded and not is_nil(run.completed_at) and
                   run.quality_measurements == %{"accepted" => true} and
                   run.inputs == expected and
                   run.output == %{
                     "schema_version" => @rules,
                     "claim_sha256" => artifact.output_sha256
                   } and
                   run.generation_key == "#{@rules}:#{fact.id}:#{artifact.output_sha256}" and
                   artifact.processing_run_id == run.id and
                   artifact.source_version_id == fact.source_version_id and
                   artifact.input_sha256 == version.sha256 and
                   artifact.processor_name == @processor and
                   artifact.processor_version == "1.0.0" and artifact.config_hash == @config and
                   artifact.output_kind == "relationship-claim-json" and
                   artifact.media_type == "application/json" and
                   artifact.schema_version == @rules and
                   artifact.quality_measurements == %{"accepted" => true} and
                   Jason.decode!(Evidence.bytes!(artifact)) == expected do
            raise ArgumentError, "installation verifier provenance mismatch"
          end

          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "#{@id}:#{person.id}:#{fact.object_id}:#{fact.object_label}"
          ])

          for {key, value} <- [
                {"trusted_relationship_verifier", @id},
                {"verification_processing_run_id", run.id},
                {"verification_artifact_id", artifact.id},
                {"verification_processor_version", "1.0.0"},
                {"verification_ruleset_version", @rules},
                {"verification_config_sha256", @config},
                {"verification_generation", run.generation_key}
              ] do
            Repo.query!("SELECT set_config($1, $2, true)", ["brussels_wtf." <> key, value])
          end

          Repo.query!(
            """
            UPDATE sourced_facts SET verification_status = 'verified', verified_by = $2,
              verification_processor_version = '1.0.0', verification_ruleset_version = $3,
              verification_config_sha256 = $4, verification_generation = $5,
              verification_processing_run_id = $6::text::uuid, verification_artifact_id = $7::text::uuid,
              verified_at = clock_timestamp() AT TIME ZONE 'utc'
            WHERE id = $1::text::uuid AND verification_status = 'unreviewed'
            """,
            [fact.id, @id, @rules, @config, run.generation_key, run.id, artifact.id]
          )

          Identity.get_sourced_fact!(fact.id)
        end,
        timeout: 120_000
      )

    fact
  end

  def trusted_fact?(fact) do
    Repo.query!(
      """
      SELECT 1 FROM sourced_facts f JOIN sourced_fact_verification_events e ON e.fact_id = f.id
        AND e.to_status = 'verified' AND e.verifier_id = f.verified_by
        AND e.processing_run_id = f.verification_processing_run_id AND e.artifact_id = f.verification_artifact_id
        AND e.processor_version = f.verification_processor_version AND e.ruleset_version = f.verification_ruleset_version
        AND e.config_sha256 = f.verification_config_sha256 AND e.generation = f.verification_generation
      WHERE f.id = $1::text::uuid AND trusted_municipal_installation_fact(f)
      """,
      [fact.id]
    ).num_rows == 1
  rescue
    _ -> false
  end

  defp payload(fact, person, bundle, candidate) do
    %{
      "schema_version" => @rules,
      "policy_version" => bundle.contract.policy_version,
      "fact_id" => fact.id,
      "person_id" => person.id,
      "legal_name" => person.legal_name,
      "commune_id" => bundle.installation.commune.id,
      "commune_slug" => bundle.contract.slug,
      "candidate" => candidate,
      "installation" => Evidence.pin(bundle.installation),
      "corroboration" => Evidence.pin(bundle.corroboration)
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp artifact!(run_id) do
    case Repo.query!(
           "SELECT derived_artifact_id::text FROM processing_run_artifacts WHERE processing_run_id = $1::text::uuid AND role = 'relationship_claim'",
           [run_id]
         ).rows do
      [[id]] -> Ingestion.get_derived_artifact!(id)
      _ -> raise ArgumentError, "exactly one relationship claim artifact required"
    end
  end
end
