defmodule BrusselsWtf.Ingestion.Pipeline do
  @moduledoc """
  Commune ingestion boundary invoked by Oban workers.

  External I/O remains behind controllable HTTP, archive, and processor
  adapters; all durable transitions use named Ash actions.
  """

  alias BrusselsWtf.Council
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Workers

  @extract_processor "native-extraction"
  @processor_version "fixture-contract-1"
  @config_hash "sha256:fixture-contract-1"

  @spec discover_and_enqueue(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer()
        ) :: :ok | :disappeared | {:retry, pos_integer()} | {:review, atom()}
  def discover_and_enqueue(commune_id, poll_run_id, check_key, attempt \\ 1) do
    commune = Ingestion.get_commune!(commune_id)
    poll_run = Ingestion.get_poll_run!(poll_run_id)
    now = BrusselsWtf.Clock.utc_now()

    index_locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: commune.index_url,
        parent_index_url: commune.index_url,
        meeting_identifier: "index",
        role: :index,
        language: :fr,
        observed_label: "Authoritative council index",
        discovered_at: now
      })

    newly_discovered? = newly_discovered?(index_locator.id)

    case BrusselsWtf.HTTP.get(commune.index_url, conditional_options(index_locator.id)) do
      {:ok, %{status: 304} = response} ->
        case existing_record(commune.id, commune.index_url) |> latest_version() do
          nil ->
            record_observation(index_locator, poll_run.id, response, check_key,
              status: :failure,
              error_kind: "not_modified_without_version",
              error_message: "HTTP 304 was observed before any archived index version"
            )

            {:review, :invalid_content}

          version ->
            record_observation(index_locator, poll_run.id, response, check_key,
              status: :unchanged,
              sha256: version.sha256,
              source_version_id: version.id
            )

            enqueue_document_fetches(commune.id, poll_run, check_key)
            :ok
        end

      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        case archive_index(index_locator, response, body, now) do
          {:ok, version, observation_status} ->
            if observation_status == :success do
              BrusselsWtf.Ingestion.Observability.archive_stored(
                poll_run.id,
                index_locator.id,
                version.id,
                byte_size(body)
              )
            end

            case discover(commune, body) do
              {:ok, discovered} ->
                record_observation(index_locator, poll_run.id, response, check_key,
                  status: observation_status,
                  sha256: version.sha256,
                  source_version_id: version.id
                )

                known_urls =
                  commune.id
                  |> Ingestion.list_locators!()
                  |> MapSet.new(& &1.url)

                stored =
                  Enum.map(discovered, fn locator ->
                    new_locator? = not MapSet.member?(known_urls, locator.url)

                    Ingestion.upsert_locator!(%{
                      commune_id: commune.id,
                      url: locator.url,
                      parent_index_url: locator.parent_index_url,
                      meeting_identifier: locator.meeting_identifier,
                      scheduled_on: locator.scheduled_on,
                      role: locator.role,
                      language: locator.language,
                      observed_label: locator.observed_label,
                      item_identifier: locator.item_identifier,
                      discovered_at: now,
                      next_fetch_at:
                        initial_next_fetch_at(
                          locator,
                          now,
                          poll_run.kind,
                          poll_run.scope,
                          new_locator?
                        )
                    })
                  end)

                stored =
                  Enum.map(
                    stored,
                    &reactivate_if_rediscovered(&1, now, poll_run.kind, poll_run.scope)
                  )

                mark_disappeared(
                  commune.id,
                  poll_run.id,
                  check_key,
                  stored,
                  now,
                  poll_run.scope
                )

                fetchable = scope_discovered(stored, poll_run.scope, now)
                enqueue_document_fetches(commune.id, poll_run, check_key, fetchable)
                :ok

              {:error, reason} ->
                record_observation(index_locator, poll_run.id, response, check_key,
                  status: :failure,
                  sha256: version.sha256,
                  source_version_id: version.id,
                  error_kind: "parser_failure",
                  error_message: safe_error(reason)
                )

                {:review, :parser_ambiguity}
            end

          {:error, reason} ->
            record_observation(index_locator, poll_run.id, response, check_key,
              status: :failure,
              error_kind: "corruption",
              error_message: safe_error(reason)
            )

            {:review, :corruption}
        end

      {:ok, response} ->
        decision =
          BrusselsWtf.Ingestion.RetryPolicy.decision(
            {:http, response.status, Map.get(response, :headers, %{})},
            attempt,
            now: now,
            newly_discovered?: newly_discovered?,
            jitter_key: check_key
          )

        record_observation(index_locator, poll_run.id, response, check_key,
          status: if(decision == :disappeared, do: :disappeared, else: :failure),
          error_kind: http_error_kind(response.status, decision),
          error_message: "authoritative index returned HTTP #{response.status}"
        )

        decision

      {:error, failure} ->
        record_transport_failure(index_locator, poll_run.id, check_key, failure, now)

        BrusselsWtf.Ingestion.RetryPolicy.decision(
          {:transport, failure.reason},
          attempt,
          now: now,
          newly_discovered?: newly_discovered?,
          jitter_key: check_key
        )
    end
  end

  @spec retrieve(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), pos_integer()) ::
          :ok | :disappeared | {:retry, pos_integer()} | {:review, atom()}
  def retrieve(locator_id, poll_run_id, check_key, attempt \\ 1) do
    locator = Ingestion.get_locator!(locator_id)
    now = BrusselsWtf.Clock.utc_now()
    newly_discovered? = newly_discovered?(locator.id)

    result =
      case BrusselsWtf.HTTP.get(locator.url, conditional_options(locator.id)) do
        {:ok, %{status: 304} = response} ->
          case existing_record(locator.commune_id, locator.url) |> latest_version() do
            nil ->
              record_observation(locator, poll_run_id, response, check_key,
                status: :failure,
                error_kind: "not_modified_without_version",
                error_message: "HTTP 304 was observed before any archived source version"
              )

              {:review, :invalid_content}

            version ->
              record_observation(locator, poll_run_id, response, check_key,
                status: :unchanged,
                sha256: version.sha256,
                source_version_id: version.id
              )

              :ok
          end

        {:ok, %{status: status, body: body} = response} when status in 200..299 ->
          archive_success(locator, poll_run_id, check_key, response, body, now)

        {:ok, response} ->
          decision =
            BrusselsWtf.Ingestion.RetryPolicy.decision(
              {:http, response.status, Map.get(response, :headers, %{})},
              attempt,
              now: now,
              newly_discovered?: newly_discovered?,
              jitter_key: check_key
            )

          record_observation(locator, poll_run_id, response, check_key,
            status: if(decision == :disappeared, do: :disappeared, else: :failure),
            error_kind: http_error_kind(response.status, decision),
            error_message: "source locator returned HTTP #{response.status}"
          )

          decision

        {:error, failure} ->
          record_transport_failure(locator, poll_run_id, check_key, failure, now)

          BrusselsWtf.Ingestion.RetryPolicy.decision(
            {:transport, failure.reason},
            attempt,
            now: now,
            newly_discovered?: newly_discovered?,
            jitter_key: check_key
          )
      end

    checked_attrs = %{last_checked_at: now}

    checked_attrs =
      if result == :ok and changed_observation?(locator.id, check_key),
        do: Map.put(checked_attrs, :last_changed_at, now),
        else: checked_attrs

    Ingestion.schedule_locator_fetch!(locator, checked_attrs)
    result
  end

  @spec extract(Ecto.UUID.t()) :: :ok | {:error, term()}
  def extract(source_version_id) do
    version = Ash.load!(Ingestion.get_source_version!(source_version_id), :source_record)

    with {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
         actual when actual == version.sha256 <- BrusselsWtf.Digest.sha256(bytes),
         {:ok, extracted} <- BrusselsWtf.Processors.extract(%{sha256: version.sha256}, bytes) do
      run =
        Ingestion.record_processing_run!(%{
          source_version_id: version.id,
          processor_name: @extract_processor,
          processor_version: @processor_version,
          config_hash: @config_hash,
          status: :succeeded,
          output: Map.put(extracted, "sha256", version.sha256)
        })

      %{processing_run_id: run.id, locator_url: version.source_record.origin_url}
      |> Workers.NormalizeSource.new()
      |> Oban.insert!()

      :ok
    else
      actual when is_binary(actual) ->
        reason = {:archived_hash_mismatch, version.sha256, actual}
        record_extraction_failure(version, reason)
        {:error, reason}

      {:error, reason} ->
        record_extraction_failure(version, reason)
        {:error, reason}
    end
  end

  @spec retry_extraction(Ecto.UUID.t()) :: :ok | {:error, term()}
  def retry_extraction(processing_run_id) do
    run =
      Ash.load!(Ingestion.get_processing_run!(processing_run_id),
        source_version: [:source_record]
      )

    version = run.source_version

    result =
      with {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
           actual when actual == version.sha256 <- BrusselsWtf.Digest.sha256(bytes),
           {:ok, extracted} <-
             BrusselsWtf.Processors.extract(%{sha256: version.sha256}, bytes) do
        completed =
          Ingestion.complete_processing_run!(run, %{
            status: :succeeded,
            output:
              run.output
              |> Map.merge(extracted)
              |> Map.put("sha256", version.sha256)
          })

        if review_case_id = run.output["review_case_id"] do
          BrusselsWtf.Review.complete_retry!(review_case_id)
        end

        %{
          processing_run_id: completed.id,
          locator_url: version.source_record.origin_url
        }
        |> Workers.NormalizeSource.new()
        |> Oban.insert!()

        :ok
      else
        actual when is_binary(actual) ->
          {:error, {:archived_hash_mismatch, version.sha256, actual}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        Ingestion.complete_processing_run!(run, %{
          status: :failed,
          output: Map.put(run.output || %{}, "error", safe_error(reason))
        })

        error
    end
  end

  @spec normalize(Ecto.UUID.t(), String.t()) :: :ok
  def normalize(processing_run_id, citation_url) do
    run =
      Ash.load!(Ingestion.get_processing_run!(processing_run_id),
        source_version: [source_record: [:commune]]
      )

    version = run.source_version
    source_record = version.source_record
    {:ok, normalized} = BrusselsWtf.Processors.normalize(run.output)

    meeting =
      Council.upsert_meeting!(%{
        commune_id: source_record.commune_id,
        municipal_identifier: normalized["meeting_identifier"],
        scheduled_on: Date.from_iso8601!(normalized["scheduled_on"])
      })

    Ingestion.link_source_record_to_meeting!(source_record, %{council_meeting_id: meeting.id})
    agenda = record_agenda(normalized["agenda"], meeting, version)

    Enum.each(List.wrap(normalized["items"]), fn candidate ->
      item =
        Council.upsert_agenda_item!(%{
          council_meeting_id: meeting.id,
          item_number: candidate["item_number"],
          authoritative_identifier: candidate["authoritative_identifier"],
          source_wording: candidate["source_wording"],
          current_source_version_id: version.id,
          current_version_order: current_version_order(version),
          procedural_state: :unknown,
          outcome: :unknown
        })

      Council.record_agenda_item_version!(%{
        agenda_item_id: item.id,
        source_version_id: version.id,
        agenda_id: agenda && agenda.id,
        authoritative_identifier: candidate["authoritative_identifier"],
        source_wording: candidate["source_wording"]
      })

      if List.wrap(candidate["proposals"]) != [] do
        Council.mark_agenda_item_proposed!(item)
      end

      record_proposals(candidate["proposals"], item, version, citation_url)
    end)

    Council.upsert_meeting_page!(%{
      council_meeting_id: meeting.id,
      citation_url: citation_url,
      procedural_state: :unknown
    })

    %{meeting_id: meeting.id}
    |> Workers.PublishMeeting.new()
    |> Oban.insert!()

    :ok
  end

  defp discover(commune, body) do
    with {:ok, adapter} <- BrusselsWtf.Communes.adapter(commune.slug) do
      adapter.discover(body, commune.index_url)
    end
  end

  defp archive_index(locator, response, body, now) do
    existing = existing_record(locator.commune_id, locator.url)
    sha256 = BrusselsWtf.Digest.sha256(body)
    existed? = existing && Enum.any?(existing.versions, &(&1.sha256 == sha256))

    with {:ok, %{sha256: ^sha256, object_key: object_key}} <- BrusselsWtf.Archive.store(body) do
      source_record =
        Ingestion.upsert_source_record!(%{
          commune_id: locator.commune_id,
          origin_url: locator.url,
          role: :index,
          original_language: locator.language
        })

      version =
        Ingestion.upsert_source_version!(%{
          source_record_id: source_record.id,
          sha256: sha256,
          byte_size: byte_size(body),
          media_type: media_type(response, locator.url),
          object_key: object_key,
          first_retrieved_at: now
        })

      {:ok, version, if(existed?, do: :unchanged, else: :success)}
    end
  end

  defp enqueue_document_fetches(commune_id, poll_run, check_key, discovered \\ nil) do
    locators =
      case {poll_run.kind, poll_run.scope, discovered} do
        {:scheduled, :previous_year, nil} ->
          commune_id
          |> Ingestion.list_document_locators!()
          |> previous_year_locators(BrusselsWtf.Clock.utc_now())
          |> Enum.filter(&due_now?/1)

        {:scheduled, :previous_year, locators} ->
          Enum.filter(locators, &due_now?/1)

        {:scheduled, :current, nil} ->
          Ingestion.list_due_locators!(BrusselsWtf.Clock.utc_now())
          |> Enum.filter(&(&1.commune_id == commune_id))

        {:scheduled, :current, locators} ->
          Enum.filter(locators, &due_now?/1)

        {_manual_kind, _scope, nil} ->
          Ingestion.list_document_locators!(commune_id)

        {_manual_kind, _scope, locators} ->
          locators
      end

    locators =
      if is_nil(discovered), do: Enum.reject(locators, &disappeared?/1), else: locators

    locators
    |> Enum.filter(&(&1.role in [:agenda, :project, :supplement, :addendum, :minutes, :register]))
    |> Enum.each(fn locator ->
      %{
        locator_id: locator.id,
        poll_run_id: poll_run.id,
        check_key: check_key,
        attempt: 1
      }
      |> Workers.FetchLocator.new()
      |> Oban.insert!()
    end)
  end

  defp due_now?(%{next_fetch_at: nil}), do: false

  defp due_now?(%{next_fetch_at: next_fetch_at}) do
    DateTime.compare(next_fetch_at, BrusselsWtf.Clock.utc_now()) in [:lt, :eq]
  end

  defp scope_discovered(discovered, :previous_year, now),
    do: previous_year_locators(discovered, now)

  defp scope_discovered(discovered, _scope, _now), do: discovered

  defp previous_year_locators(locators, now) do
    previous_year = DateTime.to_date(now).year - 1

    Enum.filter(locators, fn
      %{scheduled_on: %Date{year: ^previous_year}} -> true
      _locator -> false
    end)
  end

  defp initial_next_fetch_at(_locator, now, :scheduled, :previous_year, true), do: now

  defp initial_next_fetch_at(locator, now, :scheduled, _scope, _new_locator?) do
    case BrusselsWtf.Ingestion.PollSchedule.next_fetch_at(locator, now) do
      :stop -> nil
      _next -> now
    end
  end

  defp initial_next_fetch_at(locator, now, :poll_now, _scope, true) do
    case BrusselsWtf.Ingestion.PollSchedule.next_fetch_at(locator, now) do
      :stop -> nil
      _next -> now
    end
  end

  defp initial_next_fetch_at(_locator, _now, _manual_kind, _scope, _new_locator?), do: nil

  defp reactivate_if_rediscovered(locator, _now, kind, _scope)
       when kind in [:poll_now, :backfill],
       do: locator

  defp reactivate_if_rediscovered(locator, now, :scheduled, scope) do
    latest_observation = locator.id |> Ingestion.list_observations!() |> List.last()

    cond do
      match?(%{status: :disappeared}, latest_observation) ->
        Ingestion.schedule_locator_fetch!(locator, %{next_fetch_at: now})

      is_nil(latest_observation) and scope == :previous_year ->
        Ingestion.schedule_locator_fetch!(locator, %{next_fetch_at: now})

      true ->
        locator
    end
  end

  defp disappeared?(locator) do
    case List.last(Ingestion.list_observations!(locator.id)) do
      %{status: :disappeared} -> true
      _ -> false
    end
  end

  defp archive_success(locator, poll_run_id, check_key, response, body, now) do
    existing = existing_record(locator.commune_id, locator.url)
    sha256 = BrusselsWtf.Digest.sha256(body)
    existed? = existing && Enum.any?(existing.versions, &(&1.sha256 == sha256))

    case BrusselsWtf.Archive.store(body) do
      {:ok, %{sha256: ^sha256, object_key: object_key}} ->
        source_record =
          Ingestion.upsert_source_record!(%{
            commune_id: locator.commune_id,
            origin_url: locator.url,
            role: locator.role,
            original_language: locator.language
          })

        version =
          Ingestion.upsert_source_version!(%{
            source_record_id: source_record.id,
            sha256: sha256,
            byte_size: byte_size(body),
            media_type: media_type(response, locator.url),
            object_key: object_key,
            first_retrieved_at: now
          })

        unless existed? do
          BrusselsWtf.Ingestion.Observability.archive_stored(
            poll_run_id,
            locator.id,
            version.id,
            byte_size(body)
          )
        end

        record_observation(locator, poll_run_id, response, check_key,
          status: if(existed?, do: :unchanged, else: :success),
          sha256: sha256,
          source_version_id: version.id
        )

        unless processed?(version) do
          %{source_version_id: version.id}
          |> Workers.ExtractSource.new()
          |> Oban.insert!()
        end

        :ok

      {:error, reason} ->
        record_observation(locator, poll_run_id, response, check_key,
          status: :failure,
          error_kind: "archive_verification_failed",
          error_message: safe_error(reason)
        )

        {:review, :corruption}
    end
  end

  defp record_agenda(nil, _meeting, _version), do: nil

  defp record_agenda(agenda, meeting, version) do
    Council.record_agenda!(%{
      council_meeting_id: meeting.id,
      source_version_id: version.id,
      kind: agenda_kind(agenda["kind"]),
      language: language(agenda["language"])
    })
  end

  defp record_proposals(proposals, item, version, citation_url) do
    Enum.each(List.wrap(proposals), fn candidate ->
      proposal =
        Council.record_proposal!(%{
          agenda_item_id: item.id,
          source_version_id: version.id,
          text: candidate["text"],
          status: :proposed
        })

      if evidence = candidate["evidence"] do
        Council.record_evidence!(%{
          proposal_id: proposal.id,
          source_version_id: version.id,
          claim: :proposal,
          excerpt: evidence["excerpt"],
          location: evidence["location"],
          citation_url: citation_url,
          retrieved_at: version.first_retrieved_at,
          applicable_from: parse_date(evidence["applicable_from"]),
          applicable_until: parse_date(evidence["applicable_until"])
        })
      end
    end)
  end

  defp mark_disappeared(commune_id, poll_run_id, check_key, discovered, now, scope) do
    discovered_ids = MapSet.new(Enum.map(discovered, & &1.id))

    commune_id
    |> Ingestion.list_document_locators!()
    |> scope_discovered(scope, now)
    |> Enum.reject(&MapSet.member?(discovered_ids, &1.id))
    |> Enum.each(fn locator ->
      observation =
        Ingestion.record_observation!(%{
          source_locator_id: locator.id,
          poll_run_id: poll_run_id,
          check_key: scheduled_check_key(check_key, locator.id),
          observed_at: now,
          status: :disappeared,
          final_url: locator.url,
          error_kind: "disappeared_from_index",
          error_message: "locator was absent from the authoritative index observation"
        })

      BrusselsWtf.Ingestion.Observability.retrieval(observation)
    end)
  end

  defp record_transport_failure(locator, poll_run_id, check_key, failure, now) do
    observation =
      Ingestion.record_observation!(%{
        source_locator_id: locator.id,
        poll_run_id: poll_run_id,
        check_key: check_key || scheduled_check_key(poll_run_id, locator.id),
        observed_at: now,
        status: :failure,
        final_url: Map.get(failure, :final_url, locator.url),
        response_headers: normalize_headers(Map.get(failure, :response_headers, %{})),
        redirect_chain: normalize_redirects(Map.get(failure, :redirect_chain, [])),
        error_kind: error_kind(failure.reason),
        error_message: safe_error(failure.reason)
      })

    BrusselsWtf.Ingestion.Observability.retrieval(observation)
    observation
  end

  defp record_observation(locator, poll_run_id, response, check_key, attrs) do
    observation =
      Ingestion.record_observation!(%{
        source_locator_id: locator.id,
        source_version_id: attrs[:source_version_id],
        poll_run_id: poll_run_id,
        check_key: check_key || scheduled_check_key(poll_run_id, locator.id),
        observed_at: BrusselsWtf.Clock.utc_now(),
        status: Keyword.fetch!(attrs, :status),
        http_status: response.status,
        sha256: attrs[:sha256],
        final_url: Map.get(response, :final_url, locator.url),
        response_headers: normalize_headers(Map.get(response, :headers, %{})),
        redirect_chain: normalize_redirects(Map.get(response, :redirect_chain, [])),
        error_kind: attrs[:error_kind],
        error_message: attrs[:error_message]
      })

    BrusselsWtf.Ingestion.Observability.retrieval(observation)
    observation
  end

  defp existing_record(commune_id, url) do
    case Ingestion.get_source_record_by_origin(commune_id, url) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp latest_version(nil), do: nil

  defp latest_version(record) do
    Enum.max_by(record.versions, &DateTime.to_unix(&1.first_retrieved_at, :microsecond), fn ->
      nil
    end)
  end

  defp processed?(version) do
    version |> Ash.load!(:processing_runs) |> Map.fetch!(:processing_runs) |> Enum.any?()
  end

  defp scheduled_check_key(check_key, locator_id), do: "#{check_key}:locator:#{locator_id}"

  defp conditional_options(locator_id) do
    observations = Ingestion.list_observations!(locator_id)

    headers =
      %{}
      |> put_conditional_header("if-none-match", latest_header(observations, "etag"))
      |> put_conditional_header(
        "if-modified-since",
        latest_header(observations, "last-modified")
      )

    [headers: headers]
  end

  defp latest_header(observations, name) do
    observations
    |> Enum.reverse()
    |> Enum.find_value(fn observation ->
      observation.response_headers |> Map.get(name, []) |> List.first()
    end)
  end

  defp put_conditional_header(headers, _name, nil), do: headers
  defp put_conditional_header(headers, name, value), do: Map.put(headers, name, [value])

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), List.wrap(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.group_by(fn {key, _} -> to_string(key) end, fn {_, value} -> value end)
  end

  defp normalize_redirects(redirects) do
    Enum.map(redirects, fn redirect ->
      Map.new(redirect, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp media_type(response, url) do
    response
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> Map.get("content-type", [])
    |> List.first()
    |> case do
      nil -> media_type_from_url(url)
      value -> value |> String.split(";", parts: 2) |> hd()
    end
  end

  defp media_type_from_url(url) do
    cond do
      String.ends_with?(url, ".pdf") -> "application/pdf"
      String.ends_with?(url, ".html") -> "text/html"
      true -> "application/octet-stream"
    end
  end

  defp newly_discovered?(locator_id) do
    locator_id
    |> Ingestion.list_observations!()
    |> Enum.all?(&(&1.status not in [:success, :unchanged]))
  end

  defp changed_observation?(locator_id, check_key) do
    locator_id
    |> Ingestion.list_observations!()
    |> Enum.any?(&(&1.check_key == check_key and &1.status == :success))
  end

  defp http_error_kind(_status, :disappeared), do: "disappeared"
  defp http_error_kind(_status, {:retry, _delay}), do: "transient_http_status"
  defp http_error_kind(_status, {:review, classification}), do: Atom.to_string(classification)
  defp http_error_kind(_status, _decision), do: "http_status"

  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind(_), do: "transport_error"

  defp safe_error(reason),
    do: reason |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 1_000)

  defp record_extraction_failure(version, reason) do
    classification = BrusselsWtf.Ingestion.ProcessingFailure.classify(reason)

    Ingestion.record_processing_run!(%{
      source_version_id: version.id,
      processor_name: @extract_processor,
      processor_version: @processor_version,
      config_hash: @config_hash,
      status: :failed,
      output: %{
        "classification" => Atom.to_string(classification),
        "error" => safe_error(reason)
      }
    })
  end

  defp current_version_order(version) do
    "#{DateTime.to_iso8601(version.first_retrieved_at)}:#{version.sha256}"
  end

  defp parse_date(nil), do: nil
  defp parse_date(value), do: Date.from_iso8601!(value)

  defp agenda_kind("complementary"), do: :complementary
  defp agenda_kind("supplement"), do: :supplement
  defp agenda_kind("addendum"), do: :addendum
  defp agenda_kind("corrected"), do: :corrected
  defp agenda_kind("final"), do: :final
  defp agenda_kind(_), do: :base

  defp language("fr"), do: :fr
  defp language("nl"), do: :nl
  defp language("en"), do: :en
  defp language(_), do: :bilingual
end
