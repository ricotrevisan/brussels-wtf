defmodule BrusselsWtf.IdentityEnrichmentTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Ingestion

  setup do
    BrusselsWtf.CBE.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 03:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "uccle",
        name: "Uccle",
        index_url: "https://example.test/uccle"
      })

    source_record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: "https://example.test/uccle/minutes.pdf",
        role: :minutes,
        original_language: :bilingual
      })

    source_version =
      Ingestion.upsert_source_version!(%{
        source_record_id: source_record.id,
        sha256: String.duplicate("a", 64),
        byte_size: 100,
        media_type: "application/pdf",
        object_key: "raw/sha256/aa/fixture",
        first_retrieved_at: BrusselsWtf.Clock.utc_now()
      })

    {:ok,
     source_version: source_version, actor: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}}
  end

  test "an explicit enterprise number enriches one mention asynchronously", %{
    source_version: source_version
  } do
    mention =
      Identity.record_mention!(%{
        occurrence_key: "uccle-minutes:page-4:line-12",
        source_version_id: source_version.id,
        text: "Example Brussels ASBL",
        kind: :organization,
        explicit_identifier: "0123.456.749",
        context: %{"page" => 4, "line" => 12}
      })

    BrusselsWtf.CBE.Stub.put("0123456749", {
      :ok,
      %{
        release: %{
          release_key: "cbe-open-data-2026-08-21",
          published_on: ~D[2026-08-21],
          sha256: String.duplicate("b", 64)
        },
        entity: %{
          enterprise_number: "0123456749",
          entity_type: :legal_person,
          registered_name: "Example Brussels ASBL",
          status: :active
        },
        names: [
          %{
            name: "Example Brussels ASBL",
            kind: :registered,
            language: "fr",
            effective_from: ~D[2020-01-02]
          },
          %{name: "Example Brussels", kind: :trading, language: "en"}
        ],
        establishment_units: [
          %{
            unit_number: "2123456789",
            name: "Example Brussels office",
            status: :active,
            started_on: ~D[2020-02-03]
          }
        ]
      }
    })

    request = Identity.request_cbe_enrichment!(mention.id, "0123.456.749")
    assert request.status == :queued

    assert_enqueued(
      worker: BrusselsWtf.Workers.EnrichMention,
      args: %{request_id: request.id}
    )

    assert {:ok, legal_entity} =
             perform_job(BrusselsWtf.Workers.EnrichMention, %{request_id: request.id})

    assert legal_entity.enterprise_number == "0123456749"
    assert legal_entity.registered_name == "Example Brussels ASBL"

    legal_entity = Ash.load!(legal_entity, [:cbe_release, :names, :establishment_units])
    assert legal_entity.cbe_release.release_key == "cbe-open-data-2026-08-21"
    assert Enum.map(legal_entity.names, & &1.kind) |> Enum.sort() == [:registered, :trading]
    assert [%{unit_number: "2123456789"}] = legal_entity.establishment_units

    resolved = Identity.get_mention!(mention.id)
    assert resolved.resolution_status == :resolved
    assert resolved.resolved_legal_entity_id == legal_entity.id

    completed = Identity.get_enrichment_request!(request.id)
    assert completed.status == :succeeded
    assert completed.legal_entity_id == legal_entity.id

    assert_raise ArgumentError, ~r/explicit enterprise number/, fn ->
      name_only =
        Identity.record_mention!(%{
          occurrence_key: "uccle-minutes:page-5:line-1",
          source_version_id: source_version.id,
          text: "Example Brussels ASBL",
          kind: :organization
        })

      Identity.request_cbe_enrichment!(name_only.id, "0123.456.749")
    end
  end

  test "people require explicit or corroborated identity and merge or split history is retained",
       %{
         source_version: source_version,
         actor: actor
       } do
    mention =
      Identity.record_mention!(%{
        occurrence_key: "uccle-minutes:page-7:line-9",
        source_version_id: source_version.id,
        text: "Alex Example",
        kind: :person
      })

    assert_raise ArgumentError, ~r/exact name plus a corroborating fact/, fn ->
      Identity.resolve_person!(mention.id, %{legal_name: "Alex Example"})
    end

    person =
      Identity.resolve_person!(mention.id, %{
        legal_name: "Alex Example",
        corroborating_facts: %{"municipality" => "Uccle", "mandate_on" => "2026-06-01"}
      })

    assert person.resolution_basis == :corroborated_name

    ambiguous =
      Identity.record_mention!(%{
        occurrence_key: "uccle-minutes:page-8:line-2",
        source_version_id: source_version.id,
        text: "Sam Example",
        kind: :person
      })

    review_case =
      Identity.mark_person_ambiguous!(
        ambiguous.id,
        [%{"name" => "Sam Example", "municipality" => "Uccle"}],
        "resolver-v1"
      )

    assert review_case.affected_record_id == ambiguous.id
    assert Identity.get_mention!(ambiguous.id).resolution_status == :ambiguous

    target =
      Identity.record_person!(%{
        legal_name: "Alex Example",
        explicit_identifier: "official-id-2",
        resolution_basis: :explicit_identifier,
        corroborating_facts: %{}
      })

    merge_action = Identity.merge_people!(person.id, target.id, "Same person confirmed", actor)
    assert merge_action.action == :merge
    assert Identity.get_person!(person.id).retired_into_id == target.id

    split =
      Identity.split_person!(
        target.id,
        %{
          legal_name: "Alex Other",
          explicit_identifier: "official-id-3",
          resolution_basis: :explicit_identifier,
          corroborating_facts: %{}
        },
        "Two records were conflated",
        actor
      )

    assert split.id != target.id

    actions =
      Ash.read!(BrusselsWtf.Identity.IdentityAction,
        actor: actor,
        domain: Identity
      )

    assert Enum.map(actions, & &1.action) |> Enum.sort() == [:merge, :split]
  end

  test "typed sourced facts never infer ownership or awards", %{
    source_version: source_version
  } do
    subject_id = Ecto.UUID.generate()

    management =
      Identity.record_sourced_fact!(%{
        subject_type: :person,
        subject_id: subject_id,
        object_type: :legal_entity,
        object_id: Ecto.UUID.generate(),
        kind: :management,
        source_version_id: source_version.id,
        authoritative_url: "https://example.test/official-act",
        evidence_kind: :official_act,
        evidence_excerpt: "Appointed as director",
        evidence_location: "page 2",
        effective_from: ~D[2025-01-01]
      })

    assert management.kind == :management
    refute Identity.public_eligible?(management)

    assert_raise ArgumentError, ~r/cannot establish ownership/, fn ->
      Identity.record_sourced_fact!(%{
        subject_type: :person,
        subject_id: subject_id,
        object_type: :legal_entity,
        object_id: management.object_id,
        kind: :ownership,
        source_version_id: source_version.id,
        evidence_kind: :management_record,
        evidence_excerpt: "Listed as manager",
        evidence_location: "page 2"
      })
    end

    assert_raise ArgumentError, ~r/tender notice cannot establish/, fn ->
      Identity.record_sourced_fact!(%{
        subject_type: :legal_entity,
        subject_id: management.object_id,
        object_type: :contract,
        object_label: "Public works tender",
        kind: :contract,
        authoritative_url: "https://example.test/tender",
        evidence_kind: :tender_notice,
        evidence_excerpt: "Call for tenders",
        evidence_location: "notice 4"
      })
    end

    facts = Ash.read!(BrusselsWtf.Identity.SourcedFact, authorize?: false, domain: Identity)
    assert Enum.map(facts, & &1.kind) == [:management]
  end

  test "queued private enrichment does not block neutral meeting publication" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    assert :ok = Ingestion.poll_now(scenario.commune.slug)
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :normalize)

    history = Ingestion.source_history!(scenario.commune.id, scenario.sources.projects.url)
    [source_version] = history.versions

    mention =
      Identity.record_mention!(%{
        occurrence_key: "ixelles-268:item-4:organization-1",
        source_version_id: source_version.id,
        text: "Example Brussels ASBL",
        kind: :organization,
        explicit_identifier: "0123.456.749"
      })

    BrusselsWtf.CBE.Stub.put("0123456749", {
      :ok,
      %{
        release: %{
          release_key: "cbe-open-data-2026-08-21",
          published_on: ~D[2026-08-21],
          sha256: String.duplicate("c", 64)
        },
        entity: %{
          enterprise_number: "0123456749",
          entity_type: :legal_person,
          registered_name: "Example Brussels ASBL",
          status: :active
        },
        names: [],
        establishment_units: []
      }
    })

    request = Identity.request_cbe_enrichment!(mention.id, "0123.456.749")
    assert request.status == :queued
    assert Identity.get_mention!(mention.id).resolution_status == :unresolved

    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(from: :publish)

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert page.publication_status == :published

    revision_id = page.current_revision_id

    assert {:ok, _legal_entity} =
             perform_job(BrusselsWtf.Workers.EnrichMention, %{request_id: request.id})

    assert Identity.get_mention!(mention.id).resolution_status == :resolved
    assert BrusselsWtf.Council.get_meeting_page!(page.id).current_revision_id == revision_id
  end

  test "terminal CBE source failure becomes an evidence review case", %{
    source_version: source_version
  } do
    mention =
      Identity.record_mention!(%{
        occurrence_key: "uccle-minutes:page-10:line-3",
        source_version_id: source_version.id,
        text: "Unavailable CBE example",
        kind: :organization,
        explicit_identifier: "0123.456.749"
      })

    BrusselsWtf.CBE.Stub.put("0123456749", {:error, :temporary_unavailable})
    request = Identity.request_cbe_enrichment!(mention.id, "0123.456.749")

    assert {:error, :temporary_unavailable} =
             perform_job(
               BrusselsWtf.Workers.EnrichMention,
               %{request_id: request.id},
               attempt: 1
             )

    assert :ok =
             perform_job(
               BrusselsWtf.Workers.EnrichMention,
               %{request_id: request.id},
               attempt: 3
             )

    assert Identity.get_enrichment_request!(request.id).status == :failed

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(
               %{kind: :evidence, status: :open},
               authorize?: false
             )

    assert review_case.affected_record_id == mention.id
    assert review_case.processing_generation == "cbe:#{request.id}"
  end
end
