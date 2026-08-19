defmodule BrusselsWtf.Council.CoverageExecution do
  @moduledoc "Executes one coverage processor call and records its immutable outcome."

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.PublicationInput
  alias BrusselsWtf.Processors.Coverage

  def canonical(page, input, metadata) do
    execute(
      page,
      "fr",
      :canonical_generation,
      nil,
      input,
      metadata.canonical_method,
      metadata,
      fn -> Coverage.generate_fr(input) end
    )
  end

  def translation(page, canonical_run, canonical_output, locale, metadata)
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
      fn -> Coverage.translate(canonical_output, locale) end
    )
  end

  defp execute(page, locale, operation, parent_run_id, input, method, metadata, fun) do
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
          duration_ms,
          classify_failure(reason)
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
          duration_ms,
          classify_failure(reason)
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
          duration_ms,
          "invalid_processor_response"
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

    {:ok, output, run}
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
         duration_ms,
         classification
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
        classification
      )

    {:error,
     {:coverage_processor_failure,
      %{run_id: run.id, classification: classification, locale: locale}}}
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
         classification
       ) do
    failure = %{"classification" => classification}

    Council.record_coverage_run!(%{
      meeting_page_id: page.id,
      parent_run_id: parent_run_id,
      operation: operation,
      locale: locale,
      input_hash: PublicationInput.hash(input),
      output_hash: PublicationInput.hash(failure),
      processor_name: metadata.processor_name,
      processor_version: metadata.processor_version,
      config_hash: metadata.config_hash,
      provider_category: metadata.provider_category,
      model: metadata.model,
      method: method,
      status: :failed,
      input: input,
      output: %{},
      usage: usage,
      duration_ms: duration,
      failure_details: failure
    })
  end

  defp classify_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_failure({kind, _details}) when is_atom(kind), do: Atom.to_string(kind)
  defp classify_failure(_reason), do: "coverage_processor_failure"
end
