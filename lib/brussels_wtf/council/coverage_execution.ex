defmodule BrusselsWtf.Council.CoverageExecution do
  @moduledoc "Executes one coverage processor call and records its immutable outcome."

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.PublicationInput
  alias BrusselsWtf.Processors.Coverage

  def canonical(page, input, metadata, generation_kind, retry) do
    execute(
      page,
      "fr",
      :canonical_generation,
      nil,
      input,
      metadata.canonical_method,
      metadata,
      generation_kind,
      retry,
      fn -> Coverage.generate_fr(input) end
    )
  end

  def translation(
        page,
        canonical_run,
        canonical_output,
        locale,
        metadata,
        generation_kind,
        retry
      )
      when locale in ["nl", "en"] do
    input = %{
      "canonical_output_hash" => canonical_run.output_hash,
      "canonical" => canonical_output,
      "locale" => locale
    }

    execute(
      page,
      locale,
      :translation,
      canonical_run.id,
      input,
      metadata.translation_method,
      metadata,
      generation_kind,
      retry,
      fn -> Coverage.translate(canonical_output, locale) end
    )
  end

  defp execute(
         page,
         locale,
         operation,
         parent_run_id,
         input,
         method,
         metadata,
         generation_kind,
         retry,
         fun
       ) do
    with :ok <- BrusselsWtf.Council.GenerationControl.before_call(metadata, generation_kind),
         {:ok, reservation} <-
           BrusselsWtf.Council.GenerationControl.reserve_call(
             page,
             operation,
             locale,
             input,
             metadata,
             retry
           ) do
      execute_permitted(
        page,
        locale,
        operation,
        parent_run_id,
        input,
        method,
        metadata,
        reservation,
        fun
      )
    else
      {:defer, reason} -> {:deferred, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_permitted(
         page,
         locale,
         operation,
         parent_run_id,
         input,
         method,
         metadata,
         reservation,
         fun
       ) do
    started_at = System.monotonic_time()
    result = safe_invoke(fun)

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    case result do
      {:ok, output} when is_map(output) ->
        succeed(
          page,
          locale,
          operation,
          parent_run_id,
          input,
          output,
          method,
          metadata,
          metadata.usage,
          reservation,
          duration_ms
        )

      {:ok, output, usage} when is_map(output) and is_map(usage) ->
        succeed(
          page,
          locale,
          operation,
          parent_run_id,
          input,
          output,
          method,
          metadata,
          usage,
          reservation,
          duration_ms
        )

      {:error, reason} ->
        fail(
          page,
          locale,
          operation,
          parent_run_id,
          input,
          method,
          metadata,
          metadata.usage,
          reservation,
          duration_ms,
          failure_details(reason)
        )

      {:error, reason, usage} when is_map(usage) ->
        fail(
          page,
          locale,
          operation,
          parent_run_id,
          input,
          method,
          metadata,
          usage,
          reservation,
          duration_ms,
          failure_details(reason)
        )

      _unexpected ->
        fail(
          page,
          locale,
          operation,
          parent_run_id,
          input,
          method,
          metadata,
          metadata.usage,
          reservation,
          duration_ms,
          %{"classification" => "invalid_processor_response"}
        )
    end
  end

  defp safe_invoke(fun) do
    fun.()
  rescue
    _exception -> {:error, :processor_exception}
  catch
    :exit, _reason -> {:error, :processor_exit}
    _kind, _reason -> {:error, :processor_throw}
  end

  defp succeed(
         page,
         locale,
         operation,
         parent_run_id,
         input,
         output,
         method,
         metadata,
         usage,
         reservation,
         duration_ms
       ) do
    run =
      record(
        page,
        locale,
        operation,
        parent_run_id,
        input,
        output,
        method,
        metadata,
        usage,
        duration_ms
      )

    case BrusselsWtf.Council.GenerationControl.reconcile_call(reservation, run, usage) do
      :ok -> {:ok, output, run}
      {:defer, reason} -> {:deferred, reason}
    end
  end

  defp fail(
         page,
         locale,
         operation,
         parent_run_id,
         input,
         method,
         metadata,
         usage,
         reservation,
         duration_ms,
         failure_details
       ) do
    run =
      record_failure(
        page,
        locale,
        operation,
        parent_run_id,
        input,
        method,
        metadata,
        usage,
        duration_ms,
        failure_details
      )

    case BrusselsWtf.Council.GenerationControl.reconcile_call(reservation, run, usage) do
      :ok ->
        {:error,
         {:coverage_processor_failure,
          %{
            run_id: run.id,
            classification: failure_details["classification"],
            locale: locale
          }}}

      {:defer, reason} ->
        {:deferred, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record(
         page,
         locale,
         operation,
         parent_run_id,
         input,
         output,
         method,
         metadata,
         usage,
         duration
       ) do
    Council.record_coverage_run!(%{
      meeting_page_id: page.id,
      parent_run_id: parent_run_id,
      operation: operation,
      locale: locale,
      input_hash: PublicationInput.hash(input),
      output_hash: PublicationInput.hash(output),
      processor_name: metadata.processor_name,
      processor_version: metadata.processor_version,
      config_hash: metadata.config_hash,
      provider_category: metadata.provider_category,
      model: metadata.model,
      method: method,
      carried_provenance: carried_provenance(metadata, operation),
      status: :succeeded,
      input: input,
      output: output,
      usage: usage,
      duration_ms: duration,
      failure_details: %{}
    })
  end

  defp record_failure(
         page,
         locale,
         operation,
         parent_run_id,
         input,
         method,
         metadata,
         usage,
         duration,
         failure_details
       ) do
    Council.record_coverage_run!(%{
      meeting_page_id: page.id,
      parent_run_id: parent_run_id,
      operation: operation,
      locale: locale,
      input_hash: PublicationInput.hash(input),
      output_hash: PublicationInput.hash(failure_details),
      processor_name: metadata.processor_name,
      processor_version: metadata.processor_version,
      config_hash: metadata.config_hash,
      provider_category: metadata.provider_category,
      model: metadata.model,
      method: method,
      carried_provenance: carried_provenance(metadata, operation),
      status: :failed,
      input: input,
      output: %{},
      usage: usage,
      duration_ms: duration,
      failure_details: failure_details
    })
  end

  defp carried_provenance(metadata, :canonical_generation),
    do: Map.get(metadata, :canonical_carried_provenance, [])

  defp carried_provenance(metadata, :translation),
    do: Map.get(metadata, :translation_carried_provenance, [])

  defp failure_details(reason) do
    classification = classify_failure(reason)

    safe_details =
      case reason do
        {_kind, details} when is_map(details) ->
          details
          |> Map.take([:retryable, "retryable", :http_status, "http_status", :stage, "stage"])
          |> Map.new(fn {key, value} -> {to_string(key), safe_detail(value)} end)

        _reason ->
          %{}
      end

    Map.put(safe_details, "classification", classification)
  end

  defp safe_detail(value) when is_boolean(value) or is_integer(value), do: value
  defp safe_detail(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_detail(_value), do: "redacted"

  defp classify_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_failure({kind, _details}) when is_atom(kind), do: Atom.to_string(kind)
  defp classify_failure(_reason), do: "coverage_processor_failure"
end
