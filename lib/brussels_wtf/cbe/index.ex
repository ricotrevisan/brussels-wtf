defmodule BrusselsWtf.CBE.Index do
  @moduledoc """
  Private, release-pinned CBE index. Importing never selects a release or writes
  public identities. Checkpoints count logical CSV data rows, excluding headers.

  Import options: `batch_size` (1..1000), `max_record_bytes` (1..1 MiB),
  `max_batch_bytes` (record limit..16 MiB), and `max_batches` (positive integer
  or `:infinity`). Each batch and its checkpoint commit together. A competing
  importer returns `:concurrent_import`; retrying resumes the committed prefix.

  `max_batches` is an invocation-wide budget across files, not a per-file limit
  or a recommendation to repeatedly import one microbatch. Every invocation
  rehashes the source files and replays/verifies the current incomplete file's
  logical-row prefix once before appending. Batches share that single CSV stream;
  completed files are not reparsed. Sealing revalidates the source hashes.
  Production bounded runs should use sizeable budgets to amortize hashing and
  prefix replay. Tiny budgets are intended for interruption tests or samples.
  """
  use Ash.Domain, otp_app: :brussels_wtf
  require Ash.Query

  alias BrusselsWtf.CBE.Index.{Entry, Manifest, Release}
  alias BrusselsWtf.CBE.Source
  alias BrusselsWtf.Repo

  @projection_version 1

  resources do
    resource Release
    resource Entry
  end

  def import_release(directory, expected_manifest, opts \\ []) do
    safely(fn ->
      limits = limits!(opts)
      Manifest.validate!(directory, expected_manifest)
      release = stage!(expected_manifest)

      if release.state == :ready do
        {:ok, summary(release)}
      else
        {release, _batches} =
          Enum.reduce_while(Source.files(), {release, 0}, fn file, {release, batches} ->
            cond do
              file in release.completed_files ->
                {:cont, {release, batches}}

              batches == limits.max_batches ->
                {:halt, {release, batches}}

              true ->
                result = import_file(directory, file, release, batches, limits)
                {:cont, result}
            end
          end)

        release =
          if Enum.sort(release.completed_files) == Enum.sort(Source.files()) do
            # Do not seal bytes changed during the import invocation.
            Manifest.validate!(directory, expected_manifest)

            case Source.validate_metadata(read_rows(release.id, "meta.csv"), release.sha256) do
              :ok -> advance!(release, %{state: :ready})
              {:error, reason} -> throw({:index_error, reason})
            end
          else
            release
          end

        {:ok, summary(release)}
      end
    end)
  end

  def status(sha256) do
    safely(fn ->
      with :ok <- valid_selector(sha256), %Release{} = release <- find_release(sha256) do
        {:ok, summary(release)}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def ready?(sha256) do
    case status(sha256) do
      {:ok, %{state: :ready, projection_version: @projection_version}} -> :ok
      {:error, :invalid_release_sha256} = error -> error
      {:error, :cbe_index_unavailable} = error -> error
      _ -> {:error, :cbe_index_not_ready}
    end
  end

  def fetch_enterprise(sha256, enterprise_number) do
    safely(fn ->
      with {:ok, number} <- Source.normalize_number(enterprise_number),
           :ok <- valid_selector(sha256),
           %Release{state: :ready, projection_version: @projection_version} = release <-
             find_release(sha256) do
        enterprise = read_rows(release.id, "enterprise.csv", [number], 1)
        units = read_rows(release.id, "establishment.csv", [number])

        numbers = [
          number | Enum.map(units, &Source.normalize_number_value(&1["EstablishmentNumber"]))
        ]

        Source.project(
          %{
            meta: read_rows(release.id, "meta.csv"),
            code: read_rows(release.id, "code.csv"),
            enterprise: enterprise,
            establishment: units,
            denomination: read_rows(release.id, "denomination.csv", Enum.uniq(numbers))
          },
          sha256,
          number
        )
      else
        {:error, _} = error -> error
        _ -> {:error, :cbe_index_not_ready}
      end
    end)
  end

  defp stage!(manifest) do
    transaction!(fn ->
      Release
      |> Ash.Changeset.for_create(:stage, %{
        sha256: manifest["sha256"],
        manifest: manifest,
        projection_version: @projection_version
      })
      |> Ash.create!(return_notifications?: true)

      release = find_release(manifest["sha256"], true)

      unless release.manifest == manifest and release.projection_version == @projection_version,
        do: throw({:index_error, :release_manifest_conflict})

      release
    end)
  end

  defp import_file(directory, file, release, batches, limits) do
    checkpoint = Map.get(release.progress, file, 0)

    result =
      directory
      |> Path.join(file)
      |> Source.rows(file, limits.max_record_bytes, release.manifest["files"][file])
      |> Stream.with_index(1)
      |> verify_prefix(checkpoint, release.progress_hashes[file])
      |> bounded_batches(limits)
      |> Enum.reduce_while({release, batches, false}, fn rows, {release, batches, _} ->
        release = append!(release, file, rows)
        batches = batches + 1

        if batches == limits.max_batches,
          do: {:halt, {release, batches, true}},
          else: {:cont, {release, batches, false}}
      end)

    case result do
      {release, batches, true} ->
        {release, batches}

      {release, batches, false} ->
        {advance!(release, %{completed_files: release.completed_files ++ [file]}), batches}
    end
  end

  # A restored file must match the prefix actually committed, not just the
  # manifest checked before parsing began. This also detects a file replaced
  # during a prior interrupted invocation. Only bounded hash state is retained.
  defp verify_prefix(rows, checkpoint, expected_hash) do
    Stream.transform(
      rows,
      fn -> {<<0::256>>, 0} end,
      fn {row, ordinal}, {previous, _} ->
        hash = :crypto.hash(:sha256, [previous, :erlang.term_to_binary(row, [:deterministic])])
        encoded = Base.encode16(hash, case: :lower)

        if ordinal == checkpoint and encoded != expected_hash,
          do: throw({:index_error, :checkpoint_mismatch})

        emitted = if ordinal > checkpoint, do: [{row, ordinal, encoded}], else: []
        {emitted, {hash, ordinal}}
      end,
      fn {_, count} = state ->
        if count < checkpoint, do: throw({:index_error, :checkpoint_mismatch})
        {[], state}
      end,
      fn _ -> :ok end
    )
  end

  defp bounded_batches(rows, limits) do
    Stream.chunk_while(
      rows,
      {[], 0, 0},
      fn {row, _, _} = item, {batch, count, bytes} ->
        size = :erlang.external_size(row) + 128
        if size > limits.max_batch_bytes, do: throw({:index_error, :record_too_large})

        if count > 0 and (count == limits.batch_size or bytes + size > limits.max_batch_bytes) do
          {:cont, Enum.reverse(batch), {[item], 1, size}}
        else
          {:cont, {[item | batch], count + 1, bytes + size}}
        end
      end,
      fn
        {[], _, _} = acc -> {:cont, acc}
        {batch, _, _} -> {:cont, Enum.reverse(batch), {[], 0, 0}}
      end
    )
  end

  defp append!(release, file, rows) do
    transaction!(fn ->
      current = check_checkpoint!(release)

      inputs =
        Enum.map(rows, fn {data, ordinal, _hash} ->
          %{
            release_id: release.id,
            file: file,
            ordinal: ordinal,
            number: lookup_number(file, data),
            data: data
          }
        end)

      result =
        Ash.bulk_create(inputs, Entry, :append,
          batch_size: 1000,
          max_concurrency: 1,
          transaction: :all,
          return_records?: false,
          return_errors?: false,
          stop_on_error?: true
        )

      if result.status != :success, do: throw({:index_error, :batch_failed})
      {_, ordinal, hash} = List.last(rows)

      update_release!(current, %{
        progress: Map.put(current.progress, file, ordinal),
        progress_hashes: Map.put(current.progress_hashes, file, hash)
      })
    end)
  end

  defp advance!(release, attrs) do
    transaction!(fn -> release |> check_checkpoint!() |> update_release!(attrs) end)
  end

  defp check_checkpoint!(expected) do
    current = find_release(expected.sha256, true)

    unless current.state == :staging and current.progress == expected.progress and
             current.completed_files == expected.completed_files and
             current.progress_hashes == expected.progress_hashes do
      throw({:index_error, :concurrent_import})
    end

    current
  end

  defp update_release!(release, attrs),
    do:
      release
      |> Ash.Changeset.for_update(:advance, attrs)
      |> Ash.update!(return_notifications?: true)
      |> elem(0)

  defp find_release(sha256, lock? \\ false) do
    query = Release |> Ash.Query.filter(sha256 == ^sha256)
    query = if lock?, do: Ash.Query.lock(query, :for_update), else: query
    Ash.read_one!(query)
  end

  defp read_rows(release_id, file, numbers \\ nil, limit \\ nil) do
    query =
      Entry
      |> Ash.Query.filter(release_id == ^release_id and file == ^file)
      |> Ash.Query.sort(ordinal: :asc)

    query = if numbers, do: Ash.Query.filter(query, number in ^numbers), else: query
    query = if limit, do: Ash.Query.limit(query, limit), else: query
    query |> Ash.read!() |> Enum.map(& &1.data)
  end

  defp lookup_number("enterprise.csv", row),
    do: Source.normalize_number_value(row["EnterpriseNumber"])

  defp lookup_number("establishment.csv", row),
    do: Source.normalize_number_value(row["EnterpriseNumber"])

  defp lookup_number("denomination.csv", row),
    do: Source.normalize_number_value(row["EntityNumber"])

  defp lookup_number(_, _), do: ""

  defp summary(release) do
    %{
      sha256: release.sha256,
      state: release.state,
      projection_version: release.projection_version,
      progress: release.progress,
      completed_files: release.completed_files,
      rows: release.progress |> Map.values() |> Enum.sum()
    }
  end

  defp valid_selector(sha256) do
    if Manifest.valid_sha?(sha256), do: :ok, else: {:error, :invalid_release_sha256}
  end

  defp limits!(opts) do
    defaults = [
      batch_size: 1000,
      max_record_bytes: 1_048_576,
      max_batch_bytes: 4_194_304,
      max_batches: :infinity
    ]

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- Keyword.keys(defaults) == [],
      do: throw({:index_error, :invalid_limits})

    limits = defaults |> Keyword.merge(opts) |> Map.new()

    unless is_integer(limits.batch_size) and limits.batch_size in 1..1000 and
             is_integer(limits.max_record_bytes) and limits.max_record_bytes in 1..1_048_576 and
             is_integer(limits.max_batch_bytes) and
             limits.max_batch_bytes in limits.max_record_bytes..16_777_216 and
             (limits.max_batches == :infinity or
                (is_integer(limits.max_batches) and limits.max_batches > 0)) do
      throw({:index_error, :invalid_limits})
    end

    limits
  end

  defp transaction!(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, _} -> throw({:index_error, :batch_failed})
    end
  end

  # Never interpolate source bytes, paths, SQL parameters, or Ash exceptions into
  # operational output. Repo.default_options also covers bulk insert_all calls.
  defp safely(fun) do
    previous = Process.put(:brussels_wtf_private_cbe_index, true)

    try do
      fun.()
    rescue
      _ in File.Error -> {:error, :cbe_source_unavailable}
      _ -> {:error, :cbe_index_unavailable}
    catch
      {:index_error, reason} -> {:error, reason}
      {:source_error, reason} -> {:error, {:invalid_cbe_open_data_release, reason}}
    after
      if previous,
        do: Process.put(:brussels_wtf_private_cbe_index, previous),
        else: Process.delete(:brussels_wtf_private_cbe_index)
    end
  end
end
