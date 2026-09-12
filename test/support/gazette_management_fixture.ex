defmodule BrusselsWtf.Test.GazetteManagementFixture do
  @moduledoc false

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Test.PublicProfileFixture

  @index_url "https://www.ejustice.just.fgov.be/tsv/tsvf2.htm"
  @appointment_url "https://www.ejustice.just.fgov.be/tsv/fr/2026-0123456749-appointment"
  @cessation_url "https://www.ejustice.just.fgov.be/tsv/fr/2026-0123456749-cessation"
  @enterprise_number "0123456749"
  @person_name "Alex Public"
  @role "administrateur"

  def index_url, do: @index_url
  def appointment_url, do: @appointment_url
  def cessation_url, do: @cessation_url
  def enterprise_number, do: @enterprise_number
  def person_name, do: @person_name
  def role, do: @role

  def appointment_excerpt do
    "2026-01-15 #{@person_name} est nommé #{@role} de Public Example ASBL (#{@enterprise_number})."
  end

  def cessation_excerpt do
    "2026-03-15 #{@person_name} n'est plus #{@role} de Public Example ASBL (#{@enterprise_number})."
  end

  def publisher! do
    Ingestion.create_commune!(%{
      slug: "belgian-official-gazette",
      name: "Belgian Official Gazette",
      index_url: @index_url
    })
  end

  def company!(attrs \\ %{}) do
    PublicProfileFixture.company!(attrs)
  end

  def person!(overrides \\ %{}) do
    Identity.record_person!(
      Map.merge(
        %{
          legal_name: @person_name,
          resolution_basis: :corroborated_name,
          corroborating_facts: %{
            "enterprise_number" => @enterprise_number,
            "private_address" => "PRIVATE HOME ADDRESS",
            "family" => "PRIVATE FAMILY"
          }
        },
        overrides
      )
    )
  end

  def source!(publisher, :appointment), do: source!(publisher, @appointment_url, "appointment")
  def source!(publisher, :cessation), do: source!(publisher, @cessation_url, "cessation")

  def source!(publisher, origin_url, act) do
    source_bytes = "%PDF-1.7 gazette #{act} fixture"
    {:ok, archived} = BrusselsWtf.Archive.store(source_bytes, :raw)

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: publisher.id,
        url: origin_url,
        parent_index_url: @index_url,
        meeting_identifier: "2026-#{@enterprise_number}-#{act}",
        scheduled_on: ~D[2026-01-20],
        role: :gazette_annex,
        language: :bilingual,
        observed_label: "Annexes personnes morales",
        discovered_at: ~U[2026-01-20 09:00:00Z]
      })

    source_record =
      Ingestion.upsert_source_record!(%{
        commune_id: publisher.id,
        origin_url: origin_url,
        role: :gazette_annex,
        original_language: :bilingual
      })

    source_version =
      Ingestion.upsert_source_version!(%{
        source_record_id: source_record.id,
        sha256: archived.sha256,
        byte_size: byte_size(source_bytes),
        media_type: "application/pdf",
        object_key: archived.object_key,
        first_retrieved_at: ~U[2026-01-20 09:05:00Z]
      })

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: publisher.id,
        started_at: ~U[2026-01-20 09:00:00Z],
        kind: :scheduled,
        requester_id: "system",
        target_type: :commune,
        target_id: publisher.id,
        check_key: "poll:gazette-#{act}",
        status: :completed
      })

    Ingestion.record_observation!(%{
      source_locator_id: locator.id,
      source_version_id: source_version.id,
      poll_run_id: poll_run.id,
      check_key: "fetch:gazette-#{act}",
      observed_at: ~U[2026-01-20 09:05:00Z],
      status: :success,
      http_status: 200,
      sha256: archived.sha256,
      final_url: origin_url
    })

    %{locator: locator, source_record: source_record, source_version: source_version}
  end

  def extract!(source_version, text) do
    BrusselsWtf.Processors.Stub.put(source_version.sha256, %{
      extract: %{"text" => text}
    })

    :ok = BrusselsWtf.Ingestion.Pipeline.extract(source_version.id)
    :ok
  end

  def record_appointment!(person, company, source_version, overrides \\ %{}) do
    Identity.record_sourced_fact!(
      Map.merge(
        %{
          subject_type: :person,
          subject_id: person.id,
          object_type: :legal_entity,
          object_id: company.id,
          object_label: @role,
          kind: :management,
          effective_from: ~D[2026-01-15],
          source_version_id: source_version.id,
          authoritative_url:
            source_version |> Ash.load!(:source_record) |> then(& &1.source_record.origin_url),
          source_authority: :belgian_official_gazette,
          evidence_kind: :official_act,
          evidence_excerpt: appointment_excerpt(),
          evidence_location: "publication 2026-#{@enterprise_number}-appointment"
        },
        overrides
      )
    )
  end

  def record_cessation!(person, company, source_version, supersedes_id, overrides \\ %{}) do
    Identity.record_sourced_fact!(
      Map.merge(
        %{
          subject_type: :person,
          subject_id: person.id,
          object_type: :legal_entity,
          object_id: company.id,
          object_label: @role,
          kind: :management,
          effective_from: ~D[2026-03-15],
          source_version_id: source_version.id,
          authoritative_url:
            source_version |> Ash.load!(:source_record) |> then(& &1.source_record.origin_url),
          source_authority: :belgian_official_gazette,
          evidence_kind: :official_act,
          evidence_excerpt: cessation_excerpt(),
          evidence_location: "publication 2026-#{@enterprise_number}-cessation",
          supersedes_id: supersedes_id
        },
        overrides
      )
    )
  end
end
