defmodule BrusselsWtf.MunicipalInstallationTest do
  use BrusselsWtf.DataCase, async: false
  alias BrusselsWtf.{Identity, Ingestion}
  alias Identity.MunicipalInstallation
  alias MunicipalInstallation.Source

  setup tags do
    # Concurrent callers need a pool whose queue budget exceeds the independent
    # extraction transaction. Keep this override local to this one test.
    repo =
      if tags[:concurrent_publish] do
        repo = start_supervised!({Repo, name: nil, queue_target: 5_000})
        owner = Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: true)
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
        Repo.put_dynamic_repo(repo)
        repo
      else
        Repo
      end

    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    {:ok, repo: repo}
  end

  test "archived installation and independent native evidence publish bounded, dated profiles" do
    load!("forest")
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
    assert {:ok, [preview]} = MunicipalInstallation.preview(["forest"], actor: actor)
    assert preview.eligible == 3
    assert Identity.list_public_relationships!() == []

    assert {:ok, [first]} =
             MunicipalInstallation.publish(["forest"], actor: actor, max_facts_per_commune: 2)

    assert first.published_new == 2
    assert first.published_existing == 0

    assert {:ok, [second]} =
             MunicipalInstallation.publish(["forest"], actor: actor, max_facts_per_commune: 3)

    assert second.published_new == 1
    assert second.published_existing == 2

    assert {:ok, [again]} =
             MunicipalInstallation.publish(["forest"], actor: actor, max_facts_per_commune: 3)

    assert again.published_new == 0

    relationships = Identity.list_public_relationships!()
    assert length(relationships) == 3

    assert Enum.map(relationships, & &1.subject_name) |> Enum.sort() == [
             "Chloé Exemple",
             "Jean-Louis Test",
             "Zoé Autre"
           ]

    for relationship <- relationships do
      assert relationship.state == :documented
      assert relationship.effective_from == ~D[2024-12-01]
      assert relationship.effective_to == nil
      assert relationship.role_labels["en"] == "Municipal councillor"
      assert {:ok, profile} = Identity.get_public_person_profile(relationship.subject_id)
      refute inspect(profile) =~ "PRIVATE"
      assert Identity.get_person!(relationship.subject_id).explicit_identifier == nil
    end
  end

  test "all four communes admit multiple people and distinct municipal office labels" do
    for slug <- ~w(ixelles uccle forest city-of-brussels), do: load!(slug)

    assert {:ok, reports} =
             MunicipalInstallation.publish(~w(ixelles uccle forest city-of-brussels),
               actor: actor(),
               max_facts_per_commune: 2
             )

    assert Enum.map(reports, & &1.published_new) == [2, 2, 2, 2], inspect(reports)
    roles = Identity.list_public_relationships!()
    assert length(roles) == 8
    assert Enum.any?(roles, &(&1.role_labels["en"] == "Council chair"))

    assert Enum.any?(
             roles,
             &(&1.role_labels == %{
                 "en" => "Alderperson",
                 "fr" => "Membre du collège communal",
                 "nl" => "Schepen"
               })
           )

    refute Enum.any?(roles, &String.contains?(&1.subject_name, "Remplaçant"))
  end

  test "separate offices for one uniquely corroborated person retain separate role-key facts" do
    load!("city-of-brussels", fn {installation, corroboration} ->
      {String.replace(installation, "Nora Autre", "Louis Test"), corroboration}
    end)

    assert {:ok, [%{published_new: 3, rejected: []}]} =
             MunicipalInstallation.publish(["city-of-brussels"],
               actor: actor(),
               max_facts_per_commune: 3
             )

    roles = Identity.list_public_relationships!()
    louis = Enum.filter(roles, &(&1.subject_name == "Louis Test"))
    assert length(louis) == 2
    assert length(Enum.uniq_by(louis, & &1.subject_id)) == 1
    assert Enum.sort(Enum.map(louis, & &1.role_labels["en"])) == ["Alderperson", "Council chair"]

    assert {:ok, [%{published_new: 0, published_existing: 3}]} =
             MunicipalInstallation.publish(["city-of-brussels"],
               actor: actor(),
               max_facts_per_commune: 3
             )
  end

  test "only identifier-free person-compatible mentions from the proven sources are linked" do
    commune = load!("forest")
    other = load!("uccle")
    {:ok, contract} = Source.contract("forest")
    {:ok, other_contract} = Source.contract("uccle")
    [version] = Ingestion.source_history!(commune.id, contract.installation.url).versions

    [other_version] =
      Ingestion.source_history!(other.id, other_contract.installation.url).versions

    mentions =
      for {key, kind, identifier, source, text} <- [
            {"person", :person, nil, version, "Chloé Exemple"},
            {"unknown", :unknown, nil, version, "Chloé Exemple"},
            {"organization", :organization, nil, version, "Chloé Exemple"},
            {"cbe", :organization, "0123456749", version, "Chloé Exemple"},
            {"identified", :person, "unrelated-person-id", version, "Chloé Exemple"},
            {"unknown-identified", :unknown, "0123456749", version, "Chloé Exemple"},
            {"other-source", :person, nil, other_version, "Chloé Exemple"},
            {"different-name", :person, nil, version, "Chloe Exemple"},
            {"ambiguous", :person, nil, version, "Chloé Exemple"}
          ],
          into: %{} do
        mention =
          Identity.record_mention!(%{
            occurrence_key: key,
            kind: kind,
            explicit_identifier: identifier,
            source_version_id: source.id,
            text: text
          })

        if key == "ambiguous", do: Identity.mark_mention_ambiguous!(mention)
        {key, mention.id}
      end

    {:ok, [%{published_new: 1}]} =
      MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    [role] = Identity.list_public_relationships!()

    for {key, id} <- mentions do
      mention = Identity.get_mention!(id)

      if key in ["person", "unknown"] do
        assert mention.resolved_person_id == role.subject_id
        assert mention.resolution_status == :resolved
      else
        assert mention.resolved_person_id == nil

        assert mention.resolution_status ==
                 if(key == "ambiguous", do: :ambiguous, else: :unresolved)
      end
    end
  end

  test "unexpected processor failure bodies do not escape preview or publication reports" do
    commune = load!("forest")
    {:ok, contract} = Source.contract("forest")
    [version] = Ingestion.source_history!(commune.id, contract.installation.url).versions

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: {:error, "PRIVATE SOURCE BODY secret@example.invalid"}
    })

    assert {:ok, [%{error: :unexpected_evidence_result}]} =
             MunicipalInstallation.preview(["forest"], actor: actor())

    assert {:ok, [%{published_new: 0, error: :unexpected_evidence_result}]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    assert Identity.list_public_relationships!() == []
  end

  test "changed extracted text cannot inherit the accepted native artifact" do
    commune = load!("forest")
    {:ok, contract} = Source.contract("forest")
    [version] = Ingestion.source_history!(commune.id, contract.installation.url).versions

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{"text" => "2024-12-01 invented appointment"}
    })

    assert {:ok, [%{published_new: 0, error: _}]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 2)

    assert Identity.list_public_relationships!() == []
  end

  test "ambiguous existing full names stay private without blocking other proven events" do
    load!("forest")

    for _ <- 1..2 do
      Identity.record_person!(%{
        legal_name: "Chloé Exemple",
        resolution_basis: :corroborated_name,
        corroborating_facts: %{"municipality" => "forest"}
      })
    end

    assert {:ok, [%{published_new: 2, rejected: [%{reason: :ambiguous_person}]}]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 3)

    refute Enum.any?(Identity.list_public_relationships!(), &(&1.subject_name == "Chloé Exemple"))
  end

  test "same full name with conflicting commune evidence is not reused or linked" do
    load!("forest")

    person =
      Identity.record_person!(%{
        legal_name: "Chloé Exemple",
        resolution_basis: :corroborated_name,
        corroborating_facts: %{"municipality" => "uccle"}
      })

    assert {:ok, [%{published_new: 2, rejected: [_]}]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 3)

    assert {:error, :not_found} = Identity.get_public_person_profile(person.id)
  end

  test "unsupported cessation cannot reuse installation provenance and direct status writes fail" do
    load!("forest")

    assert {:ok, [_]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    [role] = Identity.list_public_relationships!()
    original = Identity.get_sourced_fact!(role.fact_id)

    attrs =
      Map.take(original, [
        :subject_type,
        :subject_id,
        :object_type,
        :object_id,
        :object_label,
        :kind,
        :effective_from,
        :source_version_id,
        :authoritative_url,
        :source_authority,
        :evidence_kind,
        :evidence_excerpt,
        :evidence_location
      ])

    cessation =
      Identity.record_fact!(
        Map.merge(attrs, %{effective_to: ~D[2025-01-01], supersedes_id: original.id})
      )

    assert_raise ArgumentError, fn ->
      Identity.verify_sourced_fact!(
        cessation.id,
        "municipal_installation_v1",
        original.verification_processing_run_id
      )
    end

    assert Identity.get_sourced_fact!(cessation.id).verification_status == :unreviewed
    assert length(Identity.list_public_relationships!()) == 1

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE sourced_facts SET verification_status = 'verified' WHERE id = $1::text::uuid",
        [cessation.id]
      )
    end
  end

  @tag :concurrent_publish
  test "concurrent bounded reruns converge on the same identities and audit transitions", %{
    repo: repo
  } do
    load!("forest")

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 2)
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, [_]}, &1))
    assert length(Identity.list_public_relationships!()) == 2

    assert Repo.query!(
             "SELECT count(*) FROM sourced_fact_verification_events WHERE verifier_id = 'municipal_installation_v1'"
           ).rows == [[2]]
  end

  test "wrong corroboration locator and raw archive corruption both fail closed" do
    commune = load!("forest")
    {:ok, contract} = Source.contract("forest")

    Repo.query!(
      "UPDATE source_locators SET parent_index_url = 'https://example.invalid/wrong' WHERE url = $1",
      [contract.corroboration.url]
    )

    assert {:ok, [%{published_new: 0, error: _}]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 2)

    Repo.query!("UPDATE source_locators SET parent_index_url = $2 WHERE url = $1", [
      contract.corroboration.url,
      contract.corroboration.parent_index_url
    ])

    [version] = Ingestion.source_history!(commune.id, contract.installation.url).versions

    Agent.update(
      BrusselsWtf.Archive.Memory,
      &Map.put(&1, version.object_key, "%PDF-1.7 CHANGED BYTES")
    )

    assert {:ok, [%{published_new: 0, error: _}]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 2)

    assert Identity.list_public_relationships!() == []
  end

  test "SQL forgery cannot reuse another fact's valid verifier run, even with transition GUCs" do
    load!("forest")

    {:ok, [_]} =
      MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    [role] = Identity.list_public_relationships!()
    prior = Identity.get_sourced_fact!(role.fact_id)

    forged =
      prior
      |> Map.take([
        :subject_type,
        :subject_id,
        :object_type,
        :object_id,
        :object_label,
        :kind,
        :effective_from,
        :source_version_id,
        :authoritative_url,
        :source_authority,
        :evidence_kind,
        :evidence_excerpt,
        :evidence_location
      ])
      |> Map.put(:evidence_excerpt, "A caller supplied invented appointment")
      |> Identity.record_fact!()

    for {key, value} <- [
          {"trusted_relationship_verifier", prior.verified_by},
          {"verification_processing_run_id", prior.verification_processing_run_id},
          {"verification_artifact_id", prior.verification_artifact_id},
          {"verification_processor_version", prior.verification_processor_version},
          {"verification_ruleset_version", prior.verification_ruleset_version},
          {"verification_config_sha256", prior.verification_config_sha256},
          {"verification_generation", prior.verification_generation}
        ] do
      Repo.query!("SELECT set_config($1, $2, true)", ["brussels_wtf." <> key, value])
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        """
        UPDATE sourced_facts f SET verification_status = 'verified', verified_by = p.verified_by,
          verified_at = now(), verification_processing_run_id = p.verification_processing_run_id,
          verification_artifact_id = p.verification_artifact_id,
          verification_processor_version = p.verification_processor_version,
          verification_ruleset_version = p.verification_ruleset_version,
          verification_config_sha256 = p.verification_config_sha256,
          verification_generation = p.verification_generation
        FROM sourced_facts p WHERE p.id = $1::text::uuid AND f.id = $2::text::uuid
        """,
        [prior.id, forged.id]
      )
    end
  end

  test "fresh caller-fabricated run and artifact cannot attest an invented claim through normal verification" do
    load!("forest")

    {:ok, [_]} =
      MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    [role] = Identity.list_public_relationships!()
    prior = Identity.get_sourced_fact!(role.fact_id)
    prior_run = Ingestion.get_processing_run!(prior.verification_processing_run_id)
    prior_artifact = Ingestion.get_derived_artifact!(prior.verification_artifact_id)

    forged =
      prior
      |> Map.take([
        :subject_type,
        :subject_id,
        :object_type,
        :object_id,
        :object_label,
        :kind,
        :effective_from,
        :source_version_id,
        :authoritative_url,
        :source_authority,
        :evidence_kind,
        :evidence_excerpt,
        :evidence_location
      ])
      |> Map.put(:evidence_excerpt, "PRIVATE invented completed appointment")
      |> Identity.record_fact!()

    payload =
      prior_run.inputs
      |> Map.put("fact_id", forged.id)
      |> put_in(["candidate", "evidence_excerpt"], forged.evidence_excerpt)

    bytes = Jason.encode!(payload)
    {:ok, archived} = BrusselsWtf.Archive.store(bytes, :derived)

    run =
      prior_run
      |> Map.take([
        :source_version_id,
        :processor_role,
        :processor_name,
        :processor_version,
        :config_hash,
        :quality_measurements,
        :completed_at
      ])
      |> Map.merge(%{
        generation_key: "municipal-installation-v1:#{forged.id}:#{archived.sha256}",
        status: :succeeded,
        inputs: payload,
        output: %{
          "schema_version" => "municipal-installation-v1",
          "claim_sha256" => archived.sha256
        }
      })
      |> Ingestion.record_processing_run!()

    artifact =
      prior_artifact
      |> Map.take([
        :source_version_id,
        :input_sha256,
        :processor_name,
        :processor_version,
        :config_hash,
        :output_kind,
        :media_type,
        :schema_version,
        :quality_measurements
      ])
      |> Map.merge(%{
        processing_run_id: run.id,
        output_sha256: archived.sha256,
        object_key: archived.object_key,
        byte_size: byte_size(bytes)
      })
      |> Ingestion.upsert_derived_artifact!()

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: run.id,
      derived_artifact_id: artifact.id,
      role: :relationship_claim
    })

    assert run.id != prior_run.id
    assert artifact.id != prior_artifact.id

    assert_raise ArgumentError,
                 "fact does not exactly match an independently parsed installation",
                 fn ->
                   Identity.verify_sourced_fact!(forged.id, "municipal_installation_v1", run.id)
                 end

    assert Identity.get_sourced_fact!(forged.id).verification_status == :unreviewed
    assert Enum.map(Identity.list_public_relationships!(), & &1.fact_id) == [prior.id]
  end

  test "processor configuration binds the complete source registry and parser policy" do
    inputs = %{
      contracts: Source.contracts(),
      parser_policy_version: Source.parser_policy_version()
    }

    expected =
      "sha256:" <> BrusselsWtf.Digest.sha256(:erlang.term_to_binary(inputs, [:deterministic]))

    assert MunicipalInstallation.Verifier.config_hash() == expected

    definition =
      Repo.query!(
        "SELECT pg_get_functiondef('trusted_municipal_installation_fact(sourced_facts)'::regprocedure)"
      ).rows

    assert [[sql]] = definition
    assert String.contains?(sql, expected)
    changed = put_in(inputs, [:parser_policy_version], "different-parser-policy")

    refute expected ==
             "sha256:" <>
               BrusselsWtf.Digest.sha256(:erlang.term_to_binary(changed, [:deterministic]))
  end

  test "database failures are classified without returning SQL detail or source bodies" do
    load!("forest")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION trusted_municipal_installation_document(slug text, sha text, url text, parent text, day date, meeting text, role text)
    RETURNS boolean LANGUAGE plpgsql AS $fn$ BEGIN
      RAISE EXCEPTION 'PRIVATE SOURCE BODY secret@example.invalid';
    END; $fn$;
    """)

    assert {:ok, [report]} =
             MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    assert report.published_new == 0

    assert Enum.map(report.rejected, & &1.reason) == [
             :database_error,
             :database_error,
             :database_error
           ]

    refute inspect(report) =~ "PRIVATE"
    assert Identity.list_public_relationships!() == []
  end

  test "changing current source context hides a previously verified fact" do
    load!("forest")

    {:ok, [_]} =
      MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 1)

    [role] = Identity.list_public_relationships!()
    {:ok, contract} = Source.contract("forest")

    Repo.query!("UPDATE source_locators SET scheduled_on = DATE '2024-12-02' WHERE url = $1", [
      contract.installation.url
    ])

    assert {:error, :not_found} = Identity.get_public_person_profile(role.subject_id)
  end

  test "no caller claims, provenance, or unbounded admission are accepted" do
    assert_raise ArgumentError, fn ->
      MunicipalInstallation.publish(["forest"], max_facts_per_commune: 2)
    end

    assert_raise ArgumentError, fn ->
      MunicipalInstallation.publish(["forest"], actor: actor(), max_facts_per_commune: 0)
    end

    assert_raise ArgumentError, fn ->
      MunicipalInstallation.preview(["forest"], actor: actor(), legal_name: "Someone Invented")
    end
  end

  defp actor, do: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

  defp load!(slug, transform \\ &Function.identity/1) do
    {:ok, contract} = Source.contract(slug)
    config = BrusselsWtf.Communes.configuration!(slug)

    commune =
      Ingestion.create_commune!(Map.take(config, [:name, :index_url]) |> Map.put(:slug, slug))

    {installation, corroboration} =
      transform.(BrusselsWtf.MunicipalInstallationFixture.pair(slug))

    for {kind, text} <- [installation: installation, corroboration: corroboration] do
      document = Map.fetch!(contract, kind)
      bytes = "%PDF-1.7 municipal-installation-fixture:#{slug}:#{kind}"
      {:ok, archived} = BrusselsWtf.Archive.store(bytes, :raw)
      # The test transaction substitutes only the two fixed synthetic raw hashes.
      Repo.query!(
        "SELECT pg_get_functiondef('trusted_municipal_installation_document(text,text,text,text,date,text,text)'::regprocedure)"
      )
      |> Map.fetch!(:rows)
      |> hd()
      |> hd()
      |> String.replace(document.sha256, archived.sha256)
      |> Repo.query!()

      locator =
        Ingestion.upsert_locator!(%{
          commune_id: commune.id,
          url: document.url,
          parent_index_url: document.parent_index_url,
          meeting_identifier: document.meeting_identifier,
          scheduled_on: document.date,
          role: document.role,
          language: :bilingual,
          observed_label: "Council record",
          discovered_at: ~U[2026-09-01 00:00:00Z]
        })

      record =
        Ingestion.upsert_source_record!(%{
          commune_id: commune.id,
          origin_url: document.url,
          role: document.role,
          original_language: :bilingual
        })

      version =
        Ingestion.upsert_source_version!(%{
          source_record_id: record.id,
          sha256: archived.sha256,
          byte_size: byte_size(bytes),
          media_type: "application/pdf",
          object_key: archived.object_key,
          first_retrieved_at: ~U[2026-09-01 00:00:00Z]
        })

      poll =
        Ingestion.start_poll_run!(%{
          commune_id: commune.id,
          started_at: ~U[2026-09-01 00:00:00Z],
          kind: :scheduled,
          requester_id: "system",
          target_type: :commune,
          target_id: commune.id,
          check_key: "installation:#{slug}:#{kind}",
          status: :completed
        })

      Ingestion.record_observation!(%{
        source_locator_id: locator.id,
        source_version_id: version.id,
        poll_run_id: poll.id,
        check_key: "installation:#{slug}:#{kind}",
        observed_at: ~U[2026-09-01 00:00:00Z],
        status: :success,
        http_status: 200,
        sha256: archived.sha256,
        final_url: document.url
      })

      pages =
        text
        |> String.split("\f")
        |> Enum.map(
          &(&1 <>
              "\n" <>
              String.duplicate(
                "Le conseil communal examine les documents de la séance publique. ",
                4
              ))
        )

      BrusselsWtf.Processors.Stub.put(version.sha256, %{extract: %{"page_texts" => pages}})
      :ok = Ingestion.Pipeline.extract(version.id)
    end

    commune
  end
end
