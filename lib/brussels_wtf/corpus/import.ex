defmodule BrusselsWtf.Corpus.Import do
  @moduledoc "Authenticated, hash-pinned acquisition for the bounded real corpus."

  alias BrusselsWtf.{Archive, Council, Ingestion}
  require Ash.Query
  alias BrusselsWtf.Corpus.Manifest

  @roles %{
    "agenda" => :agenda,
    "explanatory_note" => :explanatory_note,
    "minutes" => :minutes,
    "register" => :register,
    "supplement" => :supplement
  }
  @languages %{"fr" => :fr, "nl" => :nl, "bilingual" => :bilingual}

  @spec request!([String.t()], BrusselsWtf.Review.Actor.t()) ::
          BrusselsWtf.Council.CorpusImportBatch.t()
  def request!(meeting_keys, %BrusselsWtf.Review.Actor{role: :reviewer} = actor)
      when is_list(meeting_keys) do
    selected = validate_allowlist!(meeting_keys)
    sources = Enum.flat_map(selected, & &1["sources"])

    case BrusselsWtf.Repo.transaction(fn ->
           {batch, create_notifications} =
             Ash.create!(
               BrusselsWtf.Council.CorpusImportBatch,
               %{
                 requester_id: actor.id,
                 manifest_sha256: Manifest.digest(),
                 meeting_keys: Enum.map(selected, & &1["key"]),
                 expected_documents: length(sources),
                 expected_bytes: Enum.sum(Enum.map(sources, & &1["byte_size"])),
                 status: :queued,
                 metrics: initial_metrics(selected, sources)
               },
               action: :record,
               domain: Council,
               return_notifications?: true
             )

           Enum.each(selected, fn meeting ->
             Enum.each(meeting["sources"], fn source ->
               %{
                 corpus_import_batch_id: batch.id,
                 meeting_key: meeting["key"],
                 source_name: source["name"]
               }
               |> BrusselsWtf.Workers.ImportCorpusSource.new()
               |> Oban.insert!()
             end)
           end)

           {batch, update_notifications} =
             Ash.update!(
               batch,
               %{started_at: BrusselsWtf.Clock.utc_now()},
               action: :mark_importing,
               domain: Council,
               return_notifications?: true
             )

           {batch, create_notifications ++ update_notifications}
         end) do
      {:ok, {batch, notifications}} ->
        Ash.Notifier.notify(notifications)
        batch

      {:error, reason} ->
        raise ArgumentError, "real corpus batch could not be queued: #{inspect(reason)}"
    end
  end

  def request!(_meeting_keys, _actor),
    do: raise(ArgumentError, "real corpus import requires an authenticated reviewer")

  @spec import_source(Ecto.UUID.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def import_source(batch_id, meeting_key, source_name) do
    batch = Council.get_corpus_import_batch!(batch_id)

    with :ok <- authorize_job(batch, meeting_key),
         meeting <- Manifest.meeting!(meeting_key),
         %{} = source <- Enum.find(meeting["sources"], &(&1["name"] == source_name)),
         {:ok, body} <- fetch(source),
         {:ok, persisted} <- persist_bundle(batch, meeting, source, body) do
      if persisted.matches_manifest? do
        record_source!(batch, persisted.meeting.id, persisted.version)
        enqueue_extraction(persisted.version.id)
        :ok
      else
        block_for_drift!(batch, persisted, source)
        :ok
      end
    else
      nil ->
        block_failure(batch, meeting_key, source_name, "source is not in the sealed manifest")

      {:error, reason} ->
        block_failure(batch, meeting_key, source_name, safe_failure(reason))
    end
  end

  @spec prepare_coverage!(Ecto.UUID.t(), BrusselsWtf.Review.Actor.t()) ::
          BrusselsWtf.Council.CorpusImportBatch.t()
  def prepare_coverage!(batch_id, %BrusselsWtf.Review.Actor{role: :reviewer} = actor) do
    batch = refresh!(batch_id, actor)
    contract = Manifest.load!()

    unless batch.manifest_sha256 == Manifest.digest() and batch.status == :ready_for_coverage and
             Enum.sort(batch.meeting_keys) ==
               Enum.sort(Enum.map(contract["meetings"], & &1["key"])) do
      raise ArgumentError,
            "coverage requires the complete normalized eight-meeting sealed corpus without open cases"
    end

    meetings = meetings_by_contract!(contract, batch.meeting_ids)
    reviewed_at = batch.content_reviewed_at || BrusselsWtf.Clock.utc_now()

    batch =
      update_batch!(
        batch,
        %{content_reviewed_by: actor.id, content_reviewed_at: reviewed_at},
        :record_preparation
      )

    {dossier, links} = upsert_recorded_dossier!(contract, meetings, batch, actor)

    content_review = %{
      actor_id: actor.id,
      reviewed_at: reviewed_at,
      manifest_sha256: batch.manifest_sha256
    }

    coverage_batch =
      case batch.coverage_batch_id do
        nil ->
          item_scopes =
            contract["meetings"]
            |> Enum.zip(meetings)
            |> Map.new(fn {meeting_contract, meeting} ->
              {meeting.id, Enum.map(meeting_contract["items"], & &1["key"])}
            end)

          Council.request_coverage_batch!(Enum.map(meetings, & &1.id),
            actor: actor,
            content_review: content_review,
            item_scopes: item_scopes
          )

        id ->
          Council.get_coverage_batch!(id)
      end

    update_batch!(
      batch,
      %{
        coverage_batch_id: coverage_batch.id,
        dossier_id: dossier.id,
        dossier_link_ids: Enum.map(links, & &1.id)
      },
      :record_preparation
    )
  end

  def prepare_coverage!(_batch_id, _actor),
    do: raise(ArgumentError, "real corpus coverage requires an authenticated reviewer")

  @spec refresh!(Ecto.UUID.t(), BrusselsWtf.Review.Actor.t()) ::
          BrusselsWtf.Council.CorpusImportBatch.t()
  def refresh!(batch_id, %BrusselsWtf.Review.Actor{role: :reviewer}) do
    batch = Council.get_corpus_import_batch!(batch_id)
    meeting_ids = Enum.uniq(batch.meeting_ids)
    source_version_ids = Enum.uniq(batch.source_version_ids)

    meetings =
      Enum.map(meeting_ids, fn id ->
        id |> Council.get_meeting!() |> Ash.load!([:commune, :meeting_page, :agenda_items])
      end)

    pages = Enum.map(meetings, & &1.meeting_page) |> Enum.reject(&is_nil/1)
    published_pages = Enum.count(pages, &(&1.publication_status == :published))

    normalized_items = Manifest.contract_item_count(meetings)

    processing_runs = processing_runs(source_version_ids)
    ocr_runs = Enum.filter(processing_runs, &(&1.processor_role == :ocr))
    coverage_runs = Enum.flat_map(pages, &Council.list_coverage_runs!(&1.id))
    review_cases = related_review_cases(meeting_ids, source_version_ids, processing_runs)

    metrics =
      batch.metrics
      |> Map.merge(%{
        "documents_downloaded" => length(source_version_ids),
        "stored_bytes" => stored_bytes(source_version_ids),
        "ocr_documents" =>
          ocr_runs |> Enum.map(& &1.source_version_id) |> Enum.uniq() |> length(),
        "ocr_duration_ms" => Enum.sum(Enum.map(ocr_runs, & &1.duration_ms)),
        "normalized_items" => normalized_items,
        "generation_calls" => length(coverage_runs),
        "generation_usage" => merge_usage(coverage_runs),
        "review_cases" => length(review_cases),
        "pages_published" => published_pages
      })

    status =
      cond do
        review_cases != [] ->
          :blocked

        batch.status == :ready_for_coverage and published_pages == 8 ->
          :completed

        batch.status == :normalizing and length(batch.meeting_keys) == 8 and
            normalized_items == 24 ->
          :ready_for_coverage

        true ->
          batch.status
      end

    attrs = %{
      metrics: metrics,
      processing_run_ids: Enum.map(processing_runs, & &1.id),
      coverage_run_ids: Enum.map(coverage_runs, & &1.id),
      review_case_ids: Enum.map(review_cases, & &1.id),
      meeting_page_ids: Enum.map(pages, & &1.id)
    }

    case status do
      :blocked ->
        update_batch!(batch, Map.put(attrs, :failure, "related_review_case"), :block)

      :completed ->
        update_batch!(
          batch,
          Map.put(attrs, :completed_at, BrusselsWtf.Clock.utc_now()),
          :mark_completed
        )

      :ready_for_coverage when batch.status == :normalizing ->
        update_batch!(batch, attrs, :mark_ready)

      _status ->
        update_batch!(batch, attrs, :refresh_report)
    end
  end

  def refresh!(_batch_id, _actor),
    do: raise(ArgumentError, "real corpus batch refresh requires an authenticated reviewer")

  defp validate_allowlist!(meeting_keys) do
    keys = meeting_keys |> Enum.map(&to_string/1) |> Enum.uniq()
    manifest = Manifest.load!()["meetings"]
    allowed = Map.new(manifest, &{&1["key"], &1})

    if keys == [] or length(keys) > 8 or length(keys) != length(meeting_keys) or
         Enum.any?(keys, &(not Map.has_key?(allowed, &1))) do
      raise ArgumentError,
            "real corpus import must be a unique subset of the sealed eight-meeting allowlist"
    end

    Enum.map(keys, &Map.fetch!(allowed, &1))
  end

  defp authorize_job(batch, meeting_key) do
    cond do
      batch.manifest_sha256 != Manifest.digest() -> {:error, :manifest_changed}
      meeting_key not in batch.meeting_keys -> {:error, :meeting_not_allowed}
      batch.status in [:completed, :blocked] -> {:error, :batch_closed}
      true -> :ok
    end
  end

  defp fetch(source) do
    try do
      path = Manifest.bundle_path!(source)
      loader = Application.get_env(:brussels_wtf, :corpus_source_loader, &File.read/1)

      with {:ok, stat} <- File.stat(path),
           true <- stat.size <= 2_000_000,
           {:ok, body} <- loader.(path),
           true <- byte_size(body) <= 2_000_000 do
        {:ok, body}
      else
        false -> {:error, :corpus_source_too_large}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _error -> {:error, :invalid_bundle_contract}
    end
  end

  defp persist_bundle(batch, meeting_contract, source, body) do
    commune = ensure_commune!(meeting_contract["commune"])
    {:ok, scheduled_on} = Date.from_iso8601(meeting_contract["scheduled_on"])

    meeting =
      Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: meeting_contract["municipal_identifier"],
        scheduled_on: scheduled_on
      })

    now = BrusselsWtf.Clock.utc_now()
    {:ok, captured_at, 0} = DateTime.from_iso8601(source["captured_at"])
    check_key = "corpus-bundle:#{batch.id}:#{meeting_contract["key"]}:#{source["name"]}"

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: now,
        kind: :backfill,
        requester_id: batch.requester_id,
        target_type: :meeting,
        target_id: meeting.id,
        check_key: check_key,
        scope: :backfill,
        status: :running
      })

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: source["url"],
        parent_index_url: source["parent_index_url"],
        meeting_identifier: meeting_contract["municipal_identifier"],
        scheduled_on: scheduled_on,
        role: Map.fetch!(@roles, source["role"]),
        language: Map.fetch!(@languages, source["language"]),
        observed_label: "Issue 33 sealed corpus source: #{source["name"]}",
        discovered_at: captured_at
      })

    with {:ok, archived} <- Archive.store(body) do
      record =
        Ingestion.upsert_source_record!(%{
          commune_id: commune.id,
          origin_url: source["url"],
          role: Map.fetch!(@roles, source["role"]),
          original_language: Map.fetch!(@languages, source["language"])
        })
        |> Ingestion.link_source_record_to_meeting!(%{council_meeting_id: meeting.id})

      version =
        Ingestion.upsert_source_version!(%{
          source_record_id: record.id,
          sha256: archived.sha256,
          byte_size: byte_size(body),
          media_type: source["media_type"],
          object_key: archived.object_key,
          first_retrieved_at: captured_at
        })

      observation =
        Ingestion.record_observation!(%{
          source_locator_id: locator.id,
          source_version_id: version.id,
          poll_run_id: poll_run.id,
          check_key: check_key,
          observed_at: now,
          status: :success,
          sha256: archived.sha256,
          response_headers: %{},
          redirect_chain: []
        })

      Ingestion.complete_poll_run!(poll_run, %{completed_at: now})

      {:ok,
       %{
         batch: batch,
         commune: commune,
         meeting: meeting,
         locator: locator,
         observation: observation,
         version: version,
         matches_manifest?:
           archived.sha256 == source["sha256"] and byte_size(body) == source["byte_size"]
       }}
    end
  end

  defp ensure_commune!(slug) do
    case Ingestion.get_commune_by_slug(slug) do
      {:ok, commune} ->
        commune

      {:error, _error} ->
        config = BrusselsWtf.Communes.configuration!(slug)
        Ingestion.create_commune!(%{slug: slug, name: config.name, index_url: config.index_url})
    end
  end

  defp record_source!(batch, meeting_id, version) do
    current = Council.get_corpus_import_batch!(batch.id)

    update_batch!(
      current,
      %{
        meeting_ids: Enum.uniq([meeting_id | current.meeting_ids]),
        source_version_ids: Enum.uniq([version.id | current.source_version_ids])
      },
      :record_source
    )
  end

  defp enqueue_extraction(source_version_id) do
    %{source_version_id: source_version_id, generation_kind: "backfill"}
    |> BrusselsWtf.Workers.ExtractSource.new()
    |> Oban.insert!()
  end

  defp block_for_drift!(batch, persisted, source) do
    BrusselsWtf.Review.open_review_case!(%{
      kind: :acquisition,
      commune_id: persisted.commune.id,
      affected_record_id: persisted.version.id,
      affected_record_type: "source_version",
      processing_generation: "corpus:#{batch.id}:#{source["name"]}",
      urgency: :high,
      summary: "Sealed real-corpus source bytes changed",
      diagnostics: %{
        "url" => source["url"],
        "expected_sha256" => source["sha256"],
        "observed_sha256" => persisted.version.sha256,
        "expected_bytes" => source["byte_size"],
        "observed_bytes" => persisted.version.byte_size
      }
    })

    update_batch!(
      batch,
      %{
        meeting_ids: Enum.uniq([persisted.meeting.id | batch.meeting_ids]),
        source_version_ids: Enum.uniq([persisted.version.id | batch.source_version_ids]),
        failure: "source_drift"
      },
      :block
    )
  end

  defp current_contract_source(meeting_key, source_name) do
    meeting = Enum.find(Manifest.load!()["meetings"], &(&1["key"] == meeting_key))
    source = meeting && Enum.find(meeting["sources"], &(&1["name"] == source_name))
    {meeting, source}
  rescue
    _error -> {nil, nil}
  end

  defp block_failure(batch, meeting_key, source_name, failure) do
    {meeting, source} = current_contract_source(meeting_key, source_name)
    commune = meeting && ensure_commune!(meeting["commune"])

    BrusselsWtf.Review.open_review_case!(%{
      kind: :acquisition,
      commune_id: commune && commune.id,
      affected_record_id: batch.id,
      affected_record_type: "corpus_import_batch",
      processing_generation: "corpus:#{batch.id}:#{meeting_key}:#{source_name}",
      urgency: :high,
      summary: "Sealed real-corpus source could not be acquired safely",
      diagnostics: %{
        "classification" => failure,
        "detail" => "The release-owned source failed its bounded acquisition contract"
      },
      related_evidence: %{
        "meeting_key" => meeting_key,
        "source_name" => source_name,
        "official_url" => source && source["url"]
      }
    })

    update_batch!(batch, %{failure: failure}, :block)
    :ok
  end

  defp update_batch!(batch, attrs, action) do
    Ash.update!(batch, attrs, action: action, domain: Council)
  end

  defp initial_metrics(meetings, sources) do
    %{
      "meetings_selected" => length(meetings),
      "documents_expected" => length(sources),
      "bytes_expected" => Enum.sum(Enum.map(sources, & &1["byte_size"])),
      "documents_downloaded" => 0,
      "stored_bytes" => 0,
      "ocr_documents" => 0,
      "ocr_duration_ms" => 0,
      "normalized_items" => 0,
      "generation_calls" => 0,
      "generation_usage" => %{"network_calls" => 0, "cost_cents" => 0},
      "review_cases" => 0,
      "pages_published" => 0
    }
  end

  defp processing_runs([]), do: []

  defp processing_runs(source_version_ids) do
    BrusselsWtf.Ingestion.ProcessingRun
    |> Ash.Query.filter(source_version_id in ^source_version_ids)
    |> Ash.read!(domain: Ingestion)
  end

  defp stored_bytes([]), do: 0

  defp stored_bytes(source_version_ids) do
    BrusselsWtf.Ingestion.SourceVersion
    |> Ash.Query.filter(id in ^source_version_ids)
    |> Ash.read!(domain: Ingestion)
    |> Enum.sum_by(& &1.byte_size)
  end

  defp related_review_cases(meeting_ids, source_version_ids, processing_runs) do
    ids = meeting_ids ++ source_version_ids ++ Enum.map(processing_runs, & &1.id)

    if ids == [] do
      []
    else
      BrusselsWtf.Review.Case
      |> Ash.Query.filter(affected_record_id in ^ids and status == :open)
      |> Ash.read!(domain: BrusselsWtf.Review, authorize?: false)
    end
  end

  defp merge_usage(runs) do
    Enum.reduce(runs, %{"network_calls" => 0, "cost_cents" => 0}, fn run, totals ->
      Map.merge(totals, run.usage || %{}, fn _key, left, right ->
        if is_number(left) and is_number(right), do: left + right, else: right
      end)
    end)
  end

  defp meetings_by_contract!(contract, allowed_ids) do
    Enum.map(contract["meetings"], fn meeting_contract ->
      meeting =
        allowed_ids
        |> Enum.map(&(Council.get_meeting!(&1) |> Ash.load!(:commune)))
        |> Enum.find(fn candidate ->
          candidate.commune.slug == meeting_contract["commune"] and
            candidate.municipal_identifier == meeting_contract["municipal_identifier"] and
            Date.to_iso8601(candidate.scheduled_on) == meeting_contract["scheduled_on"]
        end)

      meeting = meeting && Ash.load!(meeting, :agenda_items)
      expected = MapSet.new(Enum.map(meeting_contract["items"], & &1["key"]))

      actual =
        meeting && MapSet.new(Enum.map(meeting.agenda_items, & &1.authoritative_identifier))

      if meeting && MapSet.subset?(expected, actual),
        do: meeting,
        else: raise(ArgumentError, "normalized meeting does not match the sealed corpus contract")
    end)
  end

  defp upsert_recorded_dossier!(contract, meetings, batch, actor) do
    [dossier_contract] = contract["dossiers"]

    dossier =
      Council.upsert_dossier!(%{
        slug: dossier_contract["slug"],
        title: dossier_contract["title"],
        localized_titles: dossier_contract["titles"]
      })

    meetings_by_key =
      contract["meetings"]
      |> Enum.zip(meetings)
      |> Map.new(fn {meeting_contract, meeting} -> {meeting_contract["key"], meeting} end)

    links =
      Enum.map(dossier_contract["links"], fn link_contract ->
        meeting = Map.fetch!(meetings_by_key, link_contract["meeting"])

        item =
          Enum.find(meeting.agenda_items, &(&1.authoritative_identifier == link_contract["item"]))

        link =
          Council.upsert_dossier_link!(%{
            agenda_item_id: item.id,
            dossier_id: dossier.id,
            match_method: :authoritative_identifier,
            confidence: 1.0,
            matcher_name: "issue-33-editorial-verification",
            matcher_version: batch.manifest_sha256,
            match_features: %{
              "authoritative_identifier" => "OPP/2026/185",
              "basis" => dossier_contract["link_basis"]
            },
            processing_generation: "corpus:#{batch.id}",
            status: :active,
            disposition: :confirmed
          })

        if link.id not in batch.dossier_link_ids do
          Council.record_dossier_action!(
            %{
              subject_id: link.id,
              subject_type: "dossier_link",
              action: :confirm_link,
              note: dossier_contract["link_basis"],
              details: %{
                "corpus_import_batch_id" => batch.id,
                "manifest_sha256" => batch.manifest_sha256
              }
            },
            actor: actor
          )
        end

        link
      end)

    {dossier, links}
  end

  defp safe_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_failure(_reason), do: "import_failed"
end
