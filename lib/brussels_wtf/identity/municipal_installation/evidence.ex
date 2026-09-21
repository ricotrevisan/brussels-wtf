defmodule BrusselsWtf.Identity.MunicipalInstallation.Evidence do
  @moduledoc false
  alias BrusselsWtf.{Archive, Digest, Ingestion, Repo}
  alias BrusselsWtf.Identity.MunicipalInstallation.Source

  @test_contracts Application.compile_env(:brussels_wtf, :mandate_test_contracts, false)

  def load!(slug) do
    {:ok, contract} = Source.contract(slug)
    installation = chain!(contract, :installation)
    corroboration = chain!(contract, :corroboration)

    case Source.match_candidates(contract, installation.text, corroboration.text) do
      {:ok, parsed} ->
        Map.merge(parsed, %{
          contract: contract,
          installation: installation,
          corroboration: corroboration
        })

      {:error, reason} ->
        raise ArgumentError, "installation evidence rejected: #{reason}"
    end
  end

  def pin(chain) do
    %{
      "source_version_id" => chain.version.id,
      "source_sha256" => chain.version.sha256,
      "source_url" => chain.record.origin_url,
      "extraction_run_id" => chain.run.id,
      "text_artifact_id" => chain.artifact.id,
      "text_sha256" => chain.artifact.output_sha256
    }
  end

  defp chain!(contract, kind) do
    document = Map.fetch!(contract, kind)
    hashes = hashes(contract.slug, kind, document.sha256)

    rows =
      Repo.query!(
        """
        SELECT DISTINCT v.id::text FROM source_versions v
        JOIN source_records r ON r.id = v.source_record_id
        JOIN communes c ON c.id = r.commune_id
        JOIN source_locators l ON l.commune_id = c.id AND l.url = r.origin_url
        JOIN retrieval_observations o ON o.source_locator_id = l.id AND o.source_version_id = v.id
        LEFT JOIN council_meetings m ON m.id = r.council_meeting_id
        WHERE c.slug = $1 AND r.origin_url = $2 AND v.sha256 = ANY($3::text[])
          AND r.role = $4 AND l.role = $4 AND l.parent_index_url = $5
          AND l.scheduled_on = $6 AND l.meeting_identifier = $7
          AND (r.council_meeting_id IS NULL OR (m.commune_id = c.id AND m.scheduled_on = $6))
          AND o.status IN ('success', 'unchanged') AND o.sha256 = v.sha256 AND o.final_url = r.origin_url
          AND v.media_type = 'application/pdf'
        """,
        [
          contract.slug,
          document.url,
          hashes,
          to_string(document.role),
          document.parent_index_url,
          document.date,
          document.meeting_identifier
        ]
      ).rows

    version =
      case rows do
        [[id]] -> Ingestion.get_source_version!(id) |> Ash.load!(source_record: :commune)
        _ -> raise ArgumentError, "missing or ambiguous approved #{kind} source"
      end

    record = version.source_record
    configured = BrusselsWtf.Communes.configuration!(contract.slug)

    ensure!(
      record.commune.name == configured.name and record.commune.index_url == configured.index_url
    )

    {run, artifact} = native_input!(version)
    raw = bytes!(version)

    {:ok, rerun} =
      BrusselsWtf.PDF.Processor.native(
        %{sha256: version.sha256, media_type: version.media_type},
        raw
      )

    text = bytes!(artifact)

    ensure!(
      rerun.text == text and rerun.quality_measurements == artifact.quality_measurements and
        rerun.quality_measurements == run.quality_measurements and
        rerun.quality_measurements["accepted"] == true
    )

    %{
      version: version,
      record: record,
      commune: record.commune,
      run: run,
      artifact: artifact,
      text: text
    }
  end

  defp native_input!(version) do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    rows =
      Repo.query!(
        """
        SELECT r.id::text, a.id::text FROM processing_runs r
        JOIN processing_run_artifacts l ON l.processing_run_id = r.id AND l.role = 'native_output'
        JOIN derived_artifacts a ON a.id = l.derived_artifact_id
        WHERE r.source_version_id = $1::text::uuid AND r.processor_role = 'native_extraction'
          AND r.status = 'succeeded' AND r.completed_at IS NOT NULL
          AND r.processor_name = $2 AND r.processor_version = $3 AND r.config_hash = $4
          AND r.quality_measurements ->> 'accepted' = 'true'
          AND a.source_version_id = r.source_version_id AND a.input_sha256 = $5
          AND a.processor_name = r.processor_name AND a.processor_version = r.processor_version
          AND a.config_hash = r.config_hash AND a.output_kind = 'native-text'
          AND a.media_type = 'text/plain; charset=utf-8' AND a.quality_measurements = r.quality_measurements
        ORDER BY r.completed_at DESC, r.id DESC
        """,
        [
          version.id,
          metadata.native_processor_name,
          metadata.native_processor_version,
          metadata.config_hash,
          version.sha256
        ]
      ).rows

    case rows do
      [[run, artifact] | _] ->
        {Ingestion.get_processing_run!(run), Ingestion.get_derived_artifact!(artifact)}

      _ ->
        raise ArgumentError, "accepted native extraction is required"
    end
  end

  def bytes!(record) do
    {:ok, bytes} = Archive.get(record.object_key)
    hash = Map.get(record, :sha256) || record.output_sha256
    ensure!(Digest.sha256(bytes) == hash and byte_size(bytes) == record.byte_size)
    bytes
  end

  defp hashes(slug, kind, sha) do
    if @test_contracts do
      [sha, Digest.sha256("%PDF-1.7 municipal-installation-fixture:#{slug}:#{kind}")]
    else
      [sha]
    end
  end

  defp ensure!(true), do: :ok
  defp ensure!(_), do: raise(ArgumentError, "municipal installation evidence chain mismatch")
end
