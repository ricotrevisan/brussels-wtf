defmodule BrusselsWtf.Test.PublicProfileFixture do
  @moduledoc false

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Ingestion

  @origin_url "https://www.ixelles.be/uploads/conseil/pv/267.pdf"

  def load!(public_names \\ ["Alex Public", "Prior Public"]) do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/final-267")
    :ok = BrusselsWtf.Test.Harness.advance("final")
    minutes = scenario.sources.minutes

    appointment_lines =
      Enum.map_join(public_names, "\n", fn name ->
        "2025-01-01 #{name} [#{identifier(name)}] is appointed to the Ixelles municipal council."
      end)

    extract =
      Map.update!(minutes.outputs.extract, "page_texts", fn page_texts ->
        page_texts ++ [appointment_lines]
      end)

    BrusselsWtf.Processors.Stub.put(minutes.sha256, %{minutes.outputs | extract: extract})

    :ok = Ingestion.poll_now("ixelles")
    :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :extract)

    [source_version] =
      scenario.commune.id
      |> Ingestion.source_history!(@origin_url)
      |> Map.fetch!(:versions)

    %{scenario: scenario, commune: scenario.commune, source_version: source_version}
  end

  def publish_person!(fixture, name, _decision_number) do
    person =
      Identity.record_person!(%{
        legal_name: name,
        explicit_identifier: identifier(name),
        resolution_basis: :explicit_identifier,
        corroborating_facts: %{
          "private_address" => "PRIVATE HOME ADDRESS",
          "family" => "PRIVATE FAMILY"
        }
      })

    fact =
      Identity.record_sourced_fact!(%{
        subject_type: :person,
        subject_id: person.id,
        object_type: :commune,
        object_id: fixture.commune.id,
        object_label: "PRIVATE CANDIDATE LABEL",
        kind: :public_mandate,
        effective_from: ~D[2025-01-01],
        source_version_id: fixture.source_version.id,
        authoritative_url: @origin_url,
        source_authority: :municipal_decision,
        evidence_kind: :official_decision,
        evidence_excerpt:
          "2025-01-01 #{name} [#{identifier(name)}] is appointed to the Ixelles municipal council.",
        evidence_location: "decision 267"
      })

    :ok =
      BrusselsWtf.Workers.VerifyIxellesPublicMandate.perform(%Oban.Job{
        args: %{"fact_id" => fact.id}
      })

    %{person: Identity.get_person!(person.id), fact: Identity.get_sourced_fact!(fact.id)}
  end

  defp identifier(name) do
    "municipal-mandate-" <>
      (name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"))
  end

  def company!(attrs \\ %{}) do
    release =
      Identity.record_cbe_release!(%{
        release_key: Map.get(attrs, :release_key, "PRIVATE-CBE-RELEASE-KEY"),
        published_on: Map.get(attrs, :published_on, ~D[2026-08-29]),
        sha256: Map.get(attrs, :sha256, String.duplicate("b", 64)),
        source_kind: :open_data
      })

    Identity.upsert_legal_entity!(%{
      enterprise_number: Map.get(attrs, :enterprise_number, "0123456749"),
      registered_name: Map.get(attrs, :registered_name, "Public Example ASBL"),
      status: Map.get(attrs, :status, :active),
      cbe_release_id: release.id
    })
  end
end
