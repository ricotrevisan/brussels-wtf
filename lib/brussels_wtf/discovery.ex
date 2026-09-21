defmodule BrusselsWtf.Discovery do
  @moduledoc """
  Bounded private municipal mention discovery. No identity resolution or publication.

  `preview/2` and `enqueue/2` require explicit extraction IDs, `actor: reviewer`
  and `max_jobs: 1..100` (at most 20 runs, eight chunks per run per request).
  Optional `chunk_offset: 0..100_000` selects an absolute chunk window for each
  run; its measurements return `next_chunk_offset` (nil at the end) and `has_more`.
  `status/2` takes a returned batch UUID. `pause/1` stops all unfinished jobs;
  `resume/1` explicitly releases paused jobs without resetting execution counts.
  Failures live here, not in publication-blocking Review cases.
  """
  use Ash.Domain, otp_app: :brussels_wtf
  require Ash.Query
  alias BrusselsWtf.Discovery.{Input, Job, Sweep}
  alias BrusselsWtf.{Clock, Digest, Identity, Ingestion, Repo}

  resources do
    resource Job
    resource BrusselsWtf.Discovery.SweepState
    resource BrusselsWtf.Discovery.SweepRun
    resource BrusselsWtf.Discovery.SweepEvent
  end

  @doc "Explicit reviewer opt-in; limits can only be lowered from the hard ceilings. Never clears a hold."
  def enable_sweep(opts \\ []), do: Sweep.enable(opts)

  @doc "Safe private progress, recent audit receipts and durable failures; run pages use cursor."
  def sweep_status(opts \\ []), do: Sweep.status(opts)

  @doc false
  def sweep_tick, do: Sweep.tick()

  @doc """
  Lists extraction candidates, not eligibility decisions; use `preview/2` next.

  Requires `actor: reviewer` and `limit: 1..20`. Optional `commune` is one of
  the four municipal slugs; pass the previous page's `next_cursor` as `cursor`.
  Returns safe summaries in ascending run-ID order. Each call scans at most
  `limit` runs plus one lookahead; rejected quality can leave a short/empty page.
  A non-nil cursor advances the scan even when the candidate page is empty.
  """
  def candidates(opts \\ []) do
    quiet(fn ->
      with :ok <- reviewer(opts),
           :ok <- candidate_options(opts) do
        query =
          Ingestion.ProcessingRun
          |> Ash.Query.filter(
            status == :succeeded and processor_role in [:native_extraction, :ocr] and
              source_version.source_record.commune.slug in ^~w(ixelles uccle forest city-of-brussels)
          )
          |> Ash.Query.select([:id, :source_version_id, :quality_measurements])
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.limit(opts[:limit] + 1)
          |> Ash.Query.load(source_version: [source_record: :commune])

        query =
          if opts[:commune],
            do:
              Ash.Query.filter(
                query,
                source_version.source_record.commune.slug == ^opts[:commune]
              ),
            else: query

        query = if opts[:cursor], do: Ash.Query.filter(query, id > ^opts[:cursor]), else: query
        rows = Ash.read!(query)
        page = Enum.take(rows, opts[:limit])

        summaries =
          page
          |> Enum.filter(&(&1.quality_measurements["accepted"] == true))
          |> Enum.map(fn run ->
            record = run.source_version.source_record

            %{
              run_id: run.id,
              source_version_id: run.source_version_id,
              commune: record.commune.slug,
              source_role: record.role,
              origin_url: record.origin_url
            }
          end)

        {:ok,
         %{
           candidates: summaries,
           next_cursor: if(length(rows) > opts[:limit], do: List.last(page).id)
         }}
      end
    end)
  end

  defp candidate_options(opts) do
    cond do
      not is_integer(opts[:limit]) or opts[:limit] not in 1..20 ->
        {:error, :invalid_limit}

      opts[:commune] not in [nil | ~w(ixelles uccle forest city-of-brussels)] ->
        {:error, :invalid_commune}

      not is_nil(opts[:cursor]) and not match?({:ok, _}, Ecto.UUID.cast(opts[:cursor])) ->
        {:error, :invalid_cursor}

      true ->
        :ok
    end
  end

  def preview(run_ids, opts \\ []) do
    quiet(fn ->
      with :ok <- reviewer(opts), :ok <- bounds(run_ids, opts) do
        prepared =
          Enum.map(Enum.uniq(run_ids), fn id ->
            {id, Input.prepare(id, Keyword.get(opts, :chunk_offset, 0))}
          end)

        jobs =
          Enum.flat_map(prepared, fn
            {_, {:ok, input}} -> input.jobs
            _ -> []
          end)

        if length(jobs) > opts[:max_jobs] do
          {:error, :batch_cap_exceeded}
        else
          {:ok,
           %{
             job_count: length(jobs),
             jobs: jobs,
             runs:
               Enum.map(prepared, fn
                 {id, {:ok, input}} ->
                   %{extraction_run_id: id, measurements: input.measurements, eligible: true}

                 {id, {:error, reason}} ->
                   %{extraction_run_id: id, eligible: false, reason: reason}
               end)
           }}
        end
      end
    end)
  end

  def enqueue(run_ids, opts \\ []) do
    with {:ok, preview} <- preview(run_ids, opts) do
      if Enum.any?(preview.runs, &(not &1.eligible)) or preview.job_count == 0 do
        {:error, :ineligible_or_empty_batch}
      else
        serialized(fn ->
          batch_id = Ash.UUID.generate()

          {jobs, new_count} = Sweep.admit!(preview.jobs, batch_id, opts[:actor].id)

          Sweep.record("enqueue", opts[:actor].id, %{
            batch_id: batch_id,
            new_jobs: new_count,
            existing_jobs: length(jobs) - new_count
          })

          %{batch_id: batch_id, job_ids: Enum.map(jobs, & &1.id), runs: preview.runs}
        end)
      end
    end
  end

  def status(batch_id, opts \\ []) do
    quiet(fn ->
      with :ok <- reviewer(opts), {:ok, id} <- Ecto.UUID.cast(batch_id) do
        jobs =
          Job
          |> Ash.Query.filter(^id in batch_ids)
          |> Ash.Query.sort(inserted_at: :asc, chunk: :asc)
          |> read_jobs()

        {:ok,
         %{
           batch_id: id,
           jobs:
             Enum.map(
               jobs,
               &Map.take(&1, [
                 :id,
                 :state,
                 :attempts,
                 :failure_reason,
                 :mention_count,
                 :extraction_run_id,
                 :derived_artifact_id,
                 :source_version_id,
                 :chunk,
                 :contract,
                 :input_hash,
                 :result_hash,
                 :processor,
                 :measurements,
                 :lease_expires_at,
                 :available_at,
                 :completed_at
               ])
             )
         }}
      else
        :error -> {:error, :invalid_batch_id}
        error -> error
      end
    end)
  end

  def pause(opts \\ []) do
    with :ok <- reviewer(opts) do
      serialized(fn ->
        Sweep.hold("operator_pause", opts[:actor].id)
        pause_jobs("operator_pause")
      end)
    end
  end

  def resume(opts \\ []) do
    with :ok <- reviewer(opts) do
      serialized(fn ->
        Sweep.release(opts[:actor].id)
        jobs = Job |> Ash.Query.filter(state == :paused) |> read_jobs()

        Enum.each(jobs, fn job ->
          transition(job, %{
            state: if(job.attempts < 3, do: :queued, else: :failed),
            available_at: now()
          })
        end)

        %{resumed: length(jobs)}
      end)
    end
  end

  @doc false
  def authorized_token?(token) when is_binary(token) do
    digest = Application.get_env(:brussels_wtf, :discovery_token_digest)

    is_binary(digest) and byte_size(digest) == 64 and
      Plug.Crypto.secure_compare(Digest.sha256(token), digest)
  end

  def authorized_token?(_), do: false

  @doc false
  def enabled? do
    case Application.get_env(:brussels_wtf, :discovery_token_digest) do
      value when is_binary(value) -> Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
      _ -> false
    end
  end

  @doc false
  def claim(token) do
    with :ok <- machine(token) do
      serialized(fn ->
        reap()

        busy =
          Job
          |> Ash.Query.filter(state in [:leased, :paused])
          |> Ash.Query.limit(1)
          |> read_jobs()

        if Sweep.paused?() or busy != [] do
          nil
        else
          job =
            Job
            |> Ash.Query.filter(
              state == :queued and attempts < 3 and
                (is_nil(available_at) or available_at <= ^now())
            )
            |> Ash.Query.sort(inserted_at: :asc, id: :asc)
            |> Ash.Query.limit(1)
            |> read_jobs()
            |> List.first()

          if job do
            lease = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
            expires = DateTime.add(now(), 900)

            job =
              transition(job, %{
                state: :leased,
                attempts: job.attempts + 1,
                lease_digest: Digest.sha256(lease),
                lease_expires_at: expires,
                failure_reason: nil
              })

            %{
              id: job.id,
              lease_token: lease,
              lease_expires_at: DateTime.to_iso8601(expires),
              input: %{schema_version: job.contract, input_hash: job.input_hash, lines: job.lines},
              schema: Input.schema()
            }
          end
        end
      end)
    end
  end

  @doc false
  def submit(id, payload, token) do
    with :ok <- machine(token),
         {:ok, id} <- uuid(id),
         true <- Input.exact_keys?(payload, ~w(lease_token result processor)) do
      serialized(fn ->
        job = get(id)

        cond do
          is_nil(job) ->
            Repo.rollback(:not_found)

          not Input.valid_result?(job, payload["result"], payload["processor"]) ->
            Repo.rollback(:invalid_result)

          job.state == :completed ->
            replay(job, payload)

          not live_lease?(job, payload["lease_token"]) ->
            Repo.rollback(:stale_lease)

          true ->
            result_hash =
              Input.hash(%{"result" => payload["result"], "processor" => payload["processor"]})

            Enum.each(payload["result"]["mentions"], fn mention ->
              context =
                Map.merge(job.source_context, %{
                  "discovery_job_id" => job.id,
                  "extraction_run_id" => job.extraction_run_id,
                  "derived_artifact_id" => job.derived_artifact_id,
                  "input_hash" => job.input_hash,
                  "contract" => job.contract,
                  "result_hash" => result_hash,
                  "processor" => payload["processor"],
                  "line_id" => mention["line_id"],
                  "quote" => mention["quote"]
                })

              Identity.record_mention!(%{
                occurrence_key:
                  "discovery:" <>
                    Input.hash(
                      {job.source_version_id, job.source_context["artifact_sha256"],
                       mention["line_id"], mention["text"]}
                    ),
                source_version_id: job.source_version_id,
                agenda_item_id: job.source_context["agenda_item_id"],
                kind: if(mention["kind"] == "person", do: :person, else: :organization),
                text: mention["text"],
                context: context
              })
            end)

            job =
              transition(job, %{
                state: :completed,
                processor: payload["processor"],
                result: payload["result"],
                result_hash: result_hash,
                mention_count: length(payload["result"]["mentions"]),
                completed_at: now()
              })

            Sweep.record("complete", "machine", %{
              job_id: job.id,
              mention_count: job.mention_count
            })

            acknowledgment(job)
        end
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @doc false
  def fail(id, payload, token) do
    with :ok <- machine(token),
         {:ok, id} <- uuid(id),
         true <-
           Input.exact_keys?(payload, ~w(lease_token reason)) and
             payload["reason"] in ~w(quota unavailable invalid_output timeout) do
      serialized(fn ->
        job = get(id)

        cond do
          is_nil(job) ->
            Repo.rollback(:not_found)

          receipt = failure_receipt(job, payload) ->
            receipt["ack"]

          not live_lease?(job, payload["lease_token"]) ->
            Repo.rollback(:stale_lease)

          true ->
            updated =
              if payload["reason"] == "quota" do
                Sweep.hold("quota", "machine")
                pause_jobs("quota")
                get(id)
              else
                retry(job, payload["reason"])
              end

            ack = updated |> acknowledgment() |> Jason.encode!() |> Jason.decode!()

            receipt = %{
              "attempt" => job.attempts,
              "lease_digest" => job.lease_digest,
              "request_hash" => Input.hash(payload),
              "ack" => ack
            }

            transition(updated, %{failure_receipts: job.failure_receipts ++ [receipt]})

            Sweep.record("failure", "machine", %{
              job_id: job.id,
              reason: payload["reason"],
              state: updated.state
            })

            ack
        end
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  # Receipts are bounded by the three execution attempts and survive later leases.
  # A replay is read-only: it must not retry, pause, or clear the current lease.
  defp failure_receipt(job, payload) do
    Enum.find(job.failure_receipts, fn receipt ->
      receipt["request_hash"] == Input.hash(payload) and
        lease_matches?(%{lease_digest: receipt["lease_digest"]}, payload["lease_token"])
    end)
  end

  defp replay(job, payload) do
    hash = Input.hash(%{"result" => payload["result"], "processor" => payload["processor"]})

    if lease_matches?(job, payload["lease_token"]) and hash == job.result_hash,
      do: acknowledgment(job),
      else: Repo.rollback(:conflicting_result)
  end

  defp acknowledgment(job), do: %{id: job.id, state: job.state, mention_count: job.mention_count}

  defp live_lease?(job, lease),
    do:
      job.state == :leased and lease_matches?(job, lease) and
        match?(%DateTime{}, job.lease_expires_at) and
        DateTime.compare(job.lease_expires_at, now()) == :gt

  defp lease_matches?(job, lease),
    do:
      is_binary(lease) and byte_size(lease) <= 100 and
        is_binary(job.lease_digest) and
        Plug.Crypto.secure_compare(Digest.sha256(lease), job.lease_digest)

  defp reap do
    Job
    |> Ash.Query.filter(state == :leased and lease_expires_at <= ^now())
    |> read_jobs()
    |> Enum.each(&retry(&1, "lease_expired"))
  end

  defp retry(job, reason) do
    transition(job, %{
      state: if(job.attempts >= 3, do: :failed, else: :queued),
      failure_reason: reason,
      available_at: DateTime.add(now(), 60 * job.attempts),
      lease_digest: nil,
      lease_expires_at: nil
    })
  end

  defp pause_jobs(reason) do
    jobs = Job |> Ash.Query.filter(state in [:queued, :leased]) |> read_jobs()

    Enum.each(
      jobs,
      &transition(&1, %{
        state: :paused,
        failure_reason: reason,
        lease_digest: nil,
        lease_expires_at: nil
      })
    )

    %{paused: length(jobs)}
  end

  defp bounds(ids, opts) do
    offset = Keyword.get(opts, :chunk_offset, 0)

    cond do
      not is_integer(offset) or offset not in 0..100_000 ->
        {:error, :invalid_chunk_offset}

      is_list(ids) and length(ids) in 1..20 and
        Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) and
        is_integer(opts[:max_jobs]) and opts[:max_jobs] in 1..100 ->
        :ok

      true ->
        {:error, :explicit_batch_cap_required}
    end
  end

  @doc false
  def reviewer(opts) do
    case opts[:actor] do
      %BrusselsWtf.Review.Actor{id: id, role: :reviewer} when is_binary(id) and id != "" -> :ok
      _ -> {:error, :reviewer_required}
    end
  end

  defp machine(token), do: if(authorized_token?(token), do: :ok, else: {:error, :unauthorized})

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp now, do: Clock.utc_now()
  defp read_jobs(query), do: Ash.read!(query, authorize?: false)
  defp get(id), do: Job |> Ash.Query.filter(id == ^id) |> read_jobs() |> List.first()

  defp transition(job, attrs),
    do: job |> Ash.Changeset.for_update(:transition, attrs) |> Ash.update!(authorize?: false)

  # All writers share one PostgreSQL lock; the partial unique index independently
  # prevents multiple active leases. No transport state or in-memory mutex owns it.
  @doc false
  def serialized(fun) do
    quiet(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(184321, 1)", [], log: false)
        fun.()
      end)
    end)
  end

  # SQL debug logging must not expose pinned evidence or model output either.
  defp quiet(fun) do
    level = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      if level,
        do: Logger.put_process_level(self(), level),
        else: Logger.delete_process_level(self())
    end
  end
end
