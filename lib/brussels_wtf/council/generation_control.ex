defmodule BrusselsWtf.Council.GenerationControl do
  @moduledoc "Fail-closed runtime policy for coverage processor execution."

  require Logger

  @type mode :: :disabled | :recorded | :paid

  @spec runtime_config((String.t() -> String.t() | nil)) :: map()
  def runtime_config(get_env \\ &System.get_env/1) do
    mode = parse_mode(get_env.("COVERAGE_GENERATION_MODE"))
    backfill_enabled = parse_boolean(get_env.("BACKFILL_GENERATION_ENABLED"))

    backfill_max_batch_size =
      parse_positive_integer(
        get_env.("COVERAGE_BACKFILL_MAX_BATCH_SIZE"),
        "COVERAGE_BACKFILL_MAX_BATCH_SIZE",
        10
      )

    monthly_budget_cents = parse_budget(mode, get_env.("COVERAGE_MONTHLY_BUDGET_CENTS"))

    if mode == :disabled and backfill_enabled do
      raise ArgumentError,
            "BACKFILL_GENERATION_ENABLED cannot be true when coverage generation is disabled"
    end

    %{
      mode: mode,
      backfill_enabled: backfill_enabled,
      backfill_max_batch_size: backfill_max_batch_size,
      monthly_budget_cents: monthly_budget_cents
    }
  end

  @spec validate_configuration!() :: :ok
  def validate_configuration! do
    config = Application.fetch_env!(:brussels_wtf, :coverage_generation)

    case config.mode do
      :disabled ->
        :ok

      mode when mode in [:recorded, :paid] ->
        metadata = BrusselsWtf.Processors.Coverage.metadata()
        processor = Application.fetch_env!(:brussels_wtf, :coverage_processor)

        if permit?(metadata) and complete_processor_contract?(mode, processor, metadata, config) do
          :ok
        else
          raise "coverage processor is not permitted by COVERAGE_GENERATION_MODE or is incomplete"
        end

      _other ->
        raise "invalid coverage generation mode"
    end
  end

  defp complete_processor_contract?(:recorded, processor, metadata, _config) do
    complete_provenance?(processor, metadata) and
      get_in(metadata, [:usage, "network_calls"]) == 0
  end

  defp complete_processor_contract?(:paid, processor, metadata, config) do
    complete_provenance?(processor, metadata) and
      is_integer(config[:monthly_budget_cents]) and config.monthly_budget_cents > 0
  end

  defp complete_provenance?(processor, metadata) do
    Enum.all?(
      [:processor_name, :processor_version, :config_hash, :provider_category, :model],
      &(is_binary(metadata[&1]) and metadata[&1] != "")
    ) and
      metadata[:canonical_method] in [
        :ai_generation,
        :machine_translation,
        :deterministic,
        :human_edit
      ] and
      metadata[:translation_method] in [
        :ai_generation,
        :machine_translation,
        :deterministic,
        :human_edit
      ] and
      is_map(metadata[:usage]) and
      function_exported?(processor, :generate_fr, 1) and
      function_exported?(processor, :translate, 2) and
      function_exported?(processor, :maximum_cost, 2)
  end

  @spec mode() :: mode()
  def mode do
    :brussels_wtf
    |> Application.fetch_env!(:coverage_generation)
    |> Map.fetch!(:mode)
  end

  @spec enabled?() :: boolean()
  def enabled?, do: mode() != :disabled

  @spec permit?(map()) :: boolean()
  def permit?(metadata) when is_map(metadata) do
    case mode() do
      :disabled -> false
      :recorded -> metadata[:billing_mode] == :recorded and metadata[:network_access] == :none
      :paid -> metadata[:billing_mode] == :paid and metadata[:network_access] == :network
    end
  end

  def permit?(_metadata), do: false

  @spec preflight(:automatic | :backfill) :: :ok | {:defer, atom()}
  def preflight(generation_kind) do
    config = Application.fetch_env!(:brussels_wtf, :coverage_generation)

    cond do
      config.mode == :disabled -> {:defer, :coverage_disabled}
      generation_kind == :backfill and not config.backfill_enabled -> {:defer, :backfill_disabled}
      true -> :ok
    end
  end

  @spec before_call(map(), :automatic | :backfill) :: :ok | {:defer, atom()}
  def before_call(metadata, generation_kind \\ :automatic) do
    with :ok <- preflight(generation_kind) do
      if permit?(metadata), do: :ok, else: {:defer, :processor_not_permitted}
    end
  end

  @spec reserve_call(map(), atom(), String.t(), map(), map(), pos_integer()) ::
          {:ok, nil | BrusselsWtf.Council.CoverageReservation.t()}
          | {:defer, atom()}
          | {:error, atom()}
  def reserve_call(page, operation, locale, input, metadata, retry) do
    config = Application.fetch_env!(:brussels_wtf, :coverage_generation)

    case config.mode do
      :recorded ->
        {:ok, nil}

      :paid ->
        call_attrs = %{
          meeting_page_id: page.id,
          publication_input_hash: BrusselsWtf.Council.PublicationInput.hash(input),
          operation: operation,
          locale: locale,
          provider: metadata.provider_category,
          model: metadata.model,
          retry: retry,
          call_key: call_key(page, operation, locale, input, metadata, retry)
        }

        case BrusselsWtf.Council.CoverageBudget.unresolved_for_call(call_attrs) do
          {:ok, nil} ->
            with {:ok, estimate} when is_integer(estimate) and estimate > 0 <-
                   BrusselsWtf.Processors.Coverage.maximum_cost(operation, input) do
              call_attrs
              |> Map.put(:estimated_cost_cents, estimate)
              |> BrusselsWtf.Council.CoverageBudget.reserve_for_execution(
                config.monthly_budget_cents,
                BrusselsWtf.Clock.utc_now()
              )
              |> admit_reservation()
            else
              _error -> {:defer, :budget_unavailable}
            end

          {:ok, %{status: :reserved} = reserved} ->
            admit_reservation({:ok, reserved, :existing})

          {:ok, %{status: :reconciliation_pending} = pending} ->
            recover_pending_reconciliation(pending)

          {:ok, %{status: :executing}} ->
            {:defer, :call_already_reserved}

          {:error, _reason} ->
            {:defer, :budget_unavailable}
        end

      :disabled ->
        {:defer, :coverage_disabled}
    end
  end

  defp admit_reservation({:ok, reservation, _kind}) do
    case BrusselsWtf.Council.CoverageBudget.begin_execution(reservation.id) do
      {:ok, {:admit, executing}} ->
        {:ok, executing}

      {:ok, {:existing, %{status: :reconciliation_pending} = pending}} ->
        recover_pending_reconciliation(pending)

      {:ok, {:existing, _reservation}} ->
        {:defer, :call_already_reserved}

      {:error, :budget_exhausted} ->
        {:defer, :budget_exhausted}

      {:error, _reason} ->
        {:defer, :budget_unavailable}
    end
  end

  defp admit_reservation({:error, :budget_exhausted}), do: {:defer, :budget_exhausted}
  defp admit_reservation({:error, _reason}), do: {:defer, :budget_unavailable}

  defp recover_pending_reconciliation(pending) do
    usage = Map.merge(pending.input_usage || %{}, pending.output_usage || %{})

    case enqueue_reconciliation(pending.id, pending.coverage_run_id, usage) do
      :ok -> {:defer, :cost_reconciliation_pending}
      {:error, _reason} -> {:error, :cost_reconciliation_retry_unavailable}
    end
  end

  @spec reconcile_call(nil | BrusselsWtf.Council.CoverageReservation.t(), map(), map()) ::
          :ok | {:defer, atom()} | {:error, atom()}
  def reconcile_call(nil, _run, _usage), do: :ok

  def reconcile_call(reservation, run, usage) do
    final_cost = Map.get(usage, "cost_cents")

    attrs = %{
      coverage_run_id: run.id,
      input_usage: Map.take(usage, ["input_tokens", "input_units"]),
      output_usage: Map.take(usage, ["output_tokens", "output_units", "cost_cents"])
    }

    attrs =
      if is_integer(final_cost) and final_cost >= 0,
        do: Map.put(attrs, :final_cost_cents, final_cost),
        else: attrs

    with {:ok, pending} <-
           BrusselsWtf.Council.CoverageBudget.mark_reconciliation_pending(
             reservation.id,
             run.id,
             usage
           ) do
      reconcile_pending(pending, run, usage, attrs)
    else
      {:error, reason} ->
        log_reconciliation_failure(reservation.id, run.id, reason)
        {:error, :cost_reconciliation_state_unavailable}
    end
  end

  defp reconcile_pending(reservation, run, usage, attrs) do
    case BrusselsWtf.Council.CoverageBudget.reconcile(reservation.id, attrs) do
      {:ok, %{status: :settled}} ->
        :ok

      {:ok, %{status: :reconciliation_failed} = failed} ->
        log_reconciliation_failure(reservation.id, run.id, failed.reconciliation_failure)
        {:defer, :cost_reconciliation_failed}

      {:error, reason} ->
        log_reconciliation_failure(reservation.id, run.id, reason)

        case enqueue_reconciliation(reservation.id, run.id, usage) do
          :ok -> {:defer, :cost_reconciliation_failed}
          {:error, _insert_error} -> {:error, :cost_reconciliation_retry_unavailable}
        end
    end
  end

  defp log_reconciliation_failure(reservation_id, run_id, reason) do
    Logger.warning("coverage cost reconciliation failed",
      coverage_reservation_id: reservation_id,
      coverage_run_id: run_id,
      classification: reason
    )
  end

  defp enqueue_reconciliation(reservation_id, run_id, usage) do
    result =
      %{
        reservation_id: reservation_id,
        coverage_run_id: run_id,
        usage: usage
      }
      |> BrusselsWtf.Workers.ReconcileCoverageCost.new()
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("coverage cost reconciliation retry could not be queued",
          coverage_reservation_id: reservation_id,
          coverage_run_id: run_id
        )

        {:error, reason}
    end
  end

  defp call_key(page, operation, locale, input, metadata, retry) do
    BrusselsWtf.Council.PublicationInput.hash(%{
      "meeting_page_id" => page.id,
      "operation" => to_string(operation),
      "locale" => locale,
      "input_hash" => BrusselsWtf.Council.PublicationInput.hash(input),
      "processor" => metadata.processor_name,
      "processor_version" => metadata.processor_version,
      "config_hash" => metadata.config_hash,
      "retry" => retry
    })
  end

  defp parse_mode(value) when value in [nil, "", "recorded"], do: :recorded
  defp parse_mode("disabled"), do: :disabled
  defp parse_mode("paid"), do: :paid

  defp parse_mode(_value) do
    raise ArgumentError,
          "COVERAGE_GENERATION_MODE must be disabled, recorded, or paid"
  end

  defp parse_boolean(value) when value in [nil, "", "false", "0"], do: false
  defp parse_boolean(value) when value in ["true", "1"], do: true

  defp parse_boolean(_value) do
    raise ArgumentError, "BACKFILL_GENERATION_ENABLED must be true or false"
  end

  defp parse_positive_integer(value, _name, default) when value in [nil, ""], do: default

  defp parse_positive_integer(value, name, _default) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> raise ArgumentError, "#{name} must be a positive integer"
    end
  end

  defp parse_budget(:paid, value) do
    case Integer.parse(value || "") do
      {budget, ""} when budget > 0 ->
        budget

      _other ->
        raise ArgumentError,
              "COVERAGE_MONTHLY_BUDGET_CENTS must be a positive integer in paid mode"
    end
  end

  defp parse_budget(_mode, value) when value in [nil, ""], do: nil

  defp parse_budget(_mode, _value) do
    raise ArgumentError,
          "COVERAGE_MONTHLY_BUDGET_CENTS is accepted only when coverage generation mode is paid"
  end
end
