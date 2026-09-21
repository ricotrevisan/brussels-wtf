defmodule BrusselsWtf.MunicipalInstallationArchiveFixture do
  @moduledoc false
  alias BrusselsWtf.{Ingestion, Repo}
  alias BrusselsWtf.Identity.MunicipalInstallation.Source

  def load!(slug) do
    {:ok, contract} = Source.contract(slug)
    config = BrusselsWtf.Communes.configuration!(slug)

    commune =
      Ingestion.create_commune!(Map.take(config, [:name, :index_url]) |> Map.put(:slug, slug))

    {installation, corroboration} = BrusselsWtf.MunicipalInstallationFixture.pair(slug)

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
