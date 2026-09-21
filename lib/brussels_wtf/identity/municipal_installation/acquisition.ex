defmodule BrusselsWtf.Identity.MunicipalInstallation.Acquisition do
  @moduledoc """
  Reviewer-authorized acquisition of the eight pinned installation/corroboration PDFs.

  `acquire(slugs, actor: reviewer)` synchronously checks/reuses private archived
  bytes, or retrieves only each approved parent and its exactly observed leaf.
  It returns safe counts and source-version/job IDs, never text or object keys.
  No corpus manifest or normalized meeting link is required. Existing retrieval
  timestamps and duplicate discovery contexts are preserved.

  `:reused` means size/checksum-verified bytes and accepted native text from the
  current processor name/version/configuration are ready;
  `:queued` means native extraction was requested (possibly already queued).
  Call again after the returned extract jobs finish to check accepted native
  artifacts. Do not drain general queues. Jobs use `generation_kind: backfill`,
  so ordinary normalization cannot authorize coverage generation. This module
  neither interprets roles nor verifies/publishes people.

  `:http` accepts an HTTP behaviour adapter for controlled external-I/O tests.
  The default transport rejects off-origin redirects before following them.
  Scope, hashes and parents cannot be overridden by callers.
  """

  alias BrusselsWtf.{Archive, Digest, Ingestion}
  alias BrusselsWtf.Identity.MunicipalInstallation.Source

  @max_bytes 25 * 1_024 * 1_024
  @timeout 30_000

  def acquire(slugs, opts \\ []) do
    with :ok <- authorize(Keyword.get(opts, :actor)),
         {:ok, contracts} <- select(slugs) do
      sources =
        Enum.flat_map(contracts, fn contract ->
          commune = ensure_commune(contract.slug)

          Enum.map([:installation, :corroboration], fn kind ->
            source = Map.fetch!(contract, kind)
            acquire_source(commune, source, kind, opts)
          end)
        end)

      {:ok,
       %{
         sources: sources,
         reused: Enum.count(sources, &(&1.status == :reused)),
         queued: Enum.count(sources, &(&1.status == :queued)),
         failures: Enum.count(sources, &(&1.status == :failed))
       }}
    end
  end

  defp authorize(%BrusselsWtf.Review.Actor{role: :reviewer, id: id})
       when is_binary(id) and byte_size(id) > 0,
       do: :ok

  defp authorize(_), do: {:error, :reviewer_required}

  defp select(slugs) when is_list(slugs) and length(slugs) in 1..4 do
    contracts = Source.contracts()

    if Enum.uniq(slugs) == slugs and
         Enum.all?(slugs, fn slug -> Enum.any?(contracts, &(&1.slug == slug)) end) do
      {:ok, Enum.map(slugs, fn slug -> Enum.find(contracts, &(&1.slug == slug)) end)}
    else
      {:error, :invalid_scope}
    end
  end

  defp select(_), do: {:error, :invalid_scope}

  defp ensure_commune(slug) do
    case Ingestion.get_commune_by_slug(slug) do
      {:ok, commune} ->
        commune

      {:error, _} ->
        config = BrusselsWtf.Communes.configuration!(slug)
        Ingestion.create_commune!(%{slug: slug, name: config.name, index_url: config.index_url})
    end
  end

  defp acquire_source(commune, source, kind, opts) do
    poll =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: BrusselsWtf.Clock.utc_now(),
        kind: :backfill,
        requester_id: Keyword.fetch!(opts, :actor).id,
        target_type: :index,
        target_id: source.parent_index_url,
        check_key: "municipal-installation:v1:#{kind}:#{source.sha256}:#{Ecto.UUID.generate()}",
        scope: :backfill,
        status: :running
      })

    result =
      with {:ok, version} <- obtain(commune, source, poll, opts),
           :ok <- verify_bytes(version, source),
           {:ok, state} <- native_state(version) do
        {:ok, Map.merge(state, %{source_version_id: version.id})}
      end

    summary = %{slug: commune.slug, kind: kind, poll_run_id: poll.id}

    case result do
      {:ok, state} ->
        Ingestion.complete_poll_run!(poll, %{completed_at: BrusselsWtf.Clock.utc_now()})
        Map.merge(summary, state)

      {:error, reason} ->
        Ingestion.fail_poll_run!(poll, %{
          completed_at: BrusselsWtf.Clock.utc_now(),
          error_summary: Atom.to_string(reason)
        })

        Map.merge(summary, %{status: :failed, reason: reason})
    end
  end

  defp obtain(commune, source, poll, opts) do
    with {:ok, record} <- Ingestion.get_source_record_by_origin(commune.id, source.url),
         true <- record.role == source.role,
         version when not is_nil(version) <-
           Enum.find(record.versions, &(&1.sha256 == source.sha256)),
         true <- observed?(commune.id, source, version) do
      {:ok, version}
    else
      _ -> discover_and_fetch(commune, source, poll, opts)
    end
  end

  defp observed?(commune_id, source, version) do
    commune_id
    |> Ingestion.locator_history!(source.url)
    |> Enum.any?(fn locator ->
      matches?(locator, source) and
        Enum.any?(locator.observations, fn observation ->
          observation.status in [:success, :unchanged] and
            observation.source_version_id == version.id and observation.sha256 == source.sha256 and
            observation.final_url == source.url and
            valid_origin?(observation.final_url, source.url) and
            valid_redirects?(observation.redirect_chain, source.url)
        end)
    end)
  end

  defp matches?(locator, source) do
    locator.url == source.url and locator.parent_index_url == source.parent_index_url and
      locator.meeting_identifier == source.meeting_identifier and
      locator.scheduled_on == source.date and locator.role == source.role
  end

  defp discover_and_fetch(commune, source, poll, opts) do
    now = BrusselsWtf.Clock.utc_now()

    parent =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: source.parent_index_url,
        parent_index_url: source.parent_index_url,
        meeting_identifier: "index",
        role: :index,
        language: :bilingual,
        observed_label: "Authoritative council index",
        discovered_at: now
      })

    with {:ok, _version, body} <- retrieve(parent, poll, opts),
         {:ok, adapter} <- BrusselsWtf.Communes.adapter(commune.slug),
         {:ok, discovered} <- discover(adapter, body, parent.url),
         {:ok, observed} <- match_discovered(discovered, source),
         locator <-
           Ingestion.upsert_locator!(
             Map.merge(observed, %{commune_id: commune.id, discovered_at: now})
           ),
         {:ok, version, _body} <- retrieve(locator, poll, opts) do
      {:ok, version}
    end
  end

  defp discover(adapter, body, url) do
    case adapter.discover(body, url) do
      {:ok, locators} -> {:ok, locators}
      _ -> {:error, :unrecognized_index}
    end
  rescue
    ArgumentError -> {:error, :unrecognized_index}
  end

  defp match_discovered(discovered, source) do
    case Enum.find(discovered, &matches?(&1, source)) do
      nil -> {:error, :source_not_observed}
      locator -> {:ok, locator}
    end
  end

  defp retrieve(locator, poll, opts) do
    http = Keyword.get(opts, :http, __MODULE__.Transport)
    result = http.get(locator.url, max_body_bytes: @max_bytes, receive_timeout: @timeout)

    case result do
      {:ok, response} ->
        with :ok <- validate_response(response, locator),
             {:ok, archived} <- store(response.body),
             record <-
               Ingestion.upsert_source_record!(%{
                 commune_id: locator.commune_id,
                 origin_url: locator.url,
                 role: locator.role,
                 original_language: locator.language
               }),
             true <- record.role == locator.role do
          version =
            Ingestion.upsert_source_version!(%{
              source_record_id: record.id,
              sha256: archived.sha256,
              byte_size: byte_size(response.body),
              object_key: archived.object_key,
              media_type: if(locator.role == :index, do: "text/html", else: "application/pdf"),
              first_retrieved_at: BrusselsWtf.Clock.utc_now()
            })

          observe(locator, poll, response, %{
            status: :success,
            source_version_id: version.id,
            sha256: version.sha256
          })

          {:ok, version, response.body}
        else
          false -> failed_retrieval(locator, poll, response, :source_role_conflict)
          {:error, reason} -> failed_retrieval(locator, poll, response, reason)
        end

      {:error, failure} ->
        response = %{
          status: nil,
          final_url: Map.get(failure, :final_url, locator.url),
          headers: Map.get(failure, :response_headers, %{}),
          redirect_chain: Map.get(failure, :redirect_chain, [])
        }

        failed_retrieval(locator, poll, response, :http_failure)
    end
  end

  defp validate_response(response, locator) do
    cond do
      not valid_origin?(response.final_url, locator.url) or
          not valid_redirects?(response.redirect_chain, locator.url) ->
        {:error, :redirect_origin_rejected}

      locator.role != :index and response.final_url != locator.url ->
        {:error, :source_redirect_rejected}

      response.status != 200 ->
        {:error, :http_status_rejected}

      byte_size(response.body) > @max_bytes ->
        {:error, :source_too_large}

      locator.role != :index and not String.starts_with?(response.body, "%PDF-") ->
        {:error, :not_pdf}

      true ->
        :ok
    end
  end

  defp valid_origin?(url, origin) when is_binary(url) do
    uri = URI.parse(url)
    expected = URI.parse(origin)

    uri.scheme == "https" and uri.host == expected.host and uri.port == 443 and
      is_nil(uri.userinfo)
  end

  defp valid_origin?(_, _), do: false

  defp valid_redirects?(chain, origin) do
    Enum.all?(chain || [], fn redirect ->
      valid_origin?(redirect["url"] || redirect[:url], origin) and
        valid_origin?(redirect["location"] || redirect[:location], origin)
    end)
  end

  defp store(body) do
    case Archive.store(body) do
      {:ok, archived} -> {:ok, archived}
      _ -> {:error, :archive_unavailable}
    end
  end

  defp failed_retrieval(locator, poll, response, reason) do
    observe(locator, poll, response, %{status: :failure, error_kind: Atom.to_string(reason)})
    {:error, reason}
  end

  defp observe(locator, poll, response, attrs) do
    Ingestion.record_observation!(
      Map.merge(
        %{
          source_locator_id: locator.id,
          poll_run_id: poll.id,
          check_key: poll.check_key,
          observed_at: BrusselsWtf.Clock.utc_now(),
          http_status: response.status,
          final_url: response.final_url,
          response_headers: response.headers,
          redirect_chain: response.redirect_chain
        },
        attrs
      )
    )
  end

  defp verify_bytes(version, source) do
    cond do
      version.sha256 != source.sha256 ->
        {:error, :source_hash_changed}

      version.media_type != "application/pdf" ->
        {:error, :not_pdf}

      true ->
        case Archive.get(version.object_key) do
          {:ok, bytes} ->
            if Digest.sha256(bytes) == source.sha256 and byte_size(bytes) == version.byte_size and
                 String.starts_with?(bytes, "%PDF-"),
               do: :ok,
               else: {:error, :archive_checksum_mismatch}

          _ ->
            {:error, :archive_unavailable}
        end
    end
  end

  defp native_state(version) do
    version = Ash.load!(version, processing_runs: [:derived_artifacts, :artifact_links])
    metadata = BrusselsWtf.PDF.Processor.metadata()

    native =
      Enum.filter(version.processing_runs, fn run ->
        run.processor_role == :native_extraction and
          run.processor_name == metadata.native_processor_name and
          run.processor_version == metadata.native_processor_version and
          run.config_hash == metadata.config_hash
      end)

    accepted =
      Enum.filter(
        native,
        &(&1.status == :succeeded and not is_nil(&1.completed_at) and
            &1.quality_measurements["accepted"] == true)
      )

    ready =
      Enum.find_value(accepted, fn run ->
        Enum.find_value(run.derived_artifacts, fn artifact ->
          with true <-
                 artifact.output_kind == "native-text" and artifact.input_sha256 == version.sha256 and
                   artifact.processor_name == run.processor_name and
                   artifact.processor_version == run.processor_version and
                   artifact.config_hash == run.config_hash and
                   artifact.media_type == "text/plain; charset=utf-8" and
                   artifact.quality_measurements == run.quality_measurements and
                   Enum.any?(
                     run.artifact_links,
                     &(&1.derived_artifact_id == artifact.id and &1.role == :native_output)
                   ),
               {:ok, bytes} <- Archive.get(artifact.object_key),
               true <-
                 Digest.sha256(bytes) == artifact.output_sha256 and
                   byte_size(bytes) == artifact.byte_size do
            run.id
          else
            _ -> nil
          end
        end)
      end)

    cond do
      ready ->
        {:ok, %{status: :reused, processing_run_id: ready}}

      accepted != [] ->
        {:error, :native_artifact_unavailable}

      Enum.any?(native, &(&1.status in [:failed, :succeeded])) ->
        {:error, :native_extraction_rejected}

      true ->
        job =
          %{source_version_id: version.id, generation_kind: "backfill"}
          |> BrusselsWtf.Workers.ExtractSource.new()
          |> Oban.insert!()

        {:ok, %{status: :queued, job_id: job.id}}
    end
  end
end

defmodule BrusselsWtf.Identity.MunicipalInstallation.Acquisition.Transport do
  @moduledoc false
  @behaviour BrusselsWtf.HTTP

  # HTTP.Req currently follows arbitrary redirects. Keep this bounded transport
  # here until that shared adapter can enforce an origin before each request.
  @impl true
  def get(url, opts), do: follow(url, URI.parse(url).host, opts, [], 3)

  defp follow(url, host, opts, chain, remaining) do
    limit = Keyword.fetch!(opts, :max_body_bytes)
    uri = URI.parse(url)

    if uri.scheme != "https" or uri.host != host or uri.port != 443 or uri.userinfo != nil or
         remaining < 0 do
      failure(:redirect_origin_rejected, url, chain)
    else
      result =
        Req.get(url,
          redirect: false,
          retry: false,
          decode_body: false,
          receive_timeout: Keyword.fetch!(opts, :receive_timeout),
          connect_options: [timeout: Keyword.fetch!(opts, :receive_timeout)],
          into: fn {:data, data}, {request, response} ->
            body = response.body || []

            if IO.iodata_length(body) + byte_size(data) > limit do
              {:halt, {request, %{response | body: :too_large}}}
            else
              {:cont, {request, %{response | body: [body, data]}}}
            end
          end
        )

      case result do
        {:ok, %{body: :too_large}} ->
          failure(:source_too_large, url, chain)

        {:ok, %{status: status, headers: headers}} when status in [301, 302, 303, 307, 308] ->
          case List.first(Map.get(headers, "location", [])) do
            nil ->
              failure(:invalid_redirect, url, chain)

            location ->
              next = url |> URI.merge(location) |> URI.to_string()

              redirect = %{
                "url" => url,
                "location" => next,
                "status" => status,
                "headers" => headers
              }

              follow(next, host, opts, chain ++ [redirect], remaining - 1)
          end

        {:ok, response} ->
          {:ok,
           %{
             status: response.status,
             headers: response.headers,
             body: IO.iodata_to_binary(response.body || []),
             final_url: url,
             redirect_chain: chain
           }}

        {:error, _} ->
          failure(:transport_failure, url, chain)
      end
    end
  end

  defp failure(reason, url, chain),
    do: {:error, %{reason: reason, final_url: url, response_headers: %{}, redirect_chain: chain}}
end
