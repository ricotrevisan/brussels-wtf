defmodule BrusselsWtf.Council.CoverageBudget do
  @moduledoc """
  The persisted hard spending limit for one UTC calendar month.

  Creating the month is idempotent only when the requested limit matches the
  stored limit. A restart cannot reset counters or silently change the limit.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  alias BrusselsWtf.Council
  alias BrusselsWtf.Repo
  require Ash.Query

  postgres do
    table "coverage_budgets"
    repo Repo
  end

  actions do
    defaults [:read]

    read :by_period do
      get? true
      argument :period_start, :date, allow_nil?: false
      filter expr(period_start == ^arg(:period_start))
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :period_start, :date, allow_nil?: false, public?: true

    attribute :hard_limit_cents, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :reserved_cents, :integer,
      allow_nil?: false,
      public?: true,
      default: 0,
      constraints: [min: 0]

    attribute :spent_cents, :integer,
      allow_nil?: false,
      public?: true,
      default: 0,
      constraints: [min: 0]

    attribute :poisoned_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    has_many :reservations, BrusselsWtf.Council.CoverageReservation
  end

  identities do
    identity :one_budget_per_month, [:period_start]
  end

  @type reservation_attrs :: %{
          required(:meeting_page_id) => Ecto.UUID.t(),
          required(:publication_input_hash) => String.t(),
          required(:operation) => :canonical_generation | :translation,
          required(:locale) => String.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:retry) => pos_integer(),
          required(:call_key) => String.t(),
          required(:estimated_cost_cents) => pos_integer()
        }

  @spec reserve(reservation_attrs(), pos_integer(), DateTime.t() | Date.t()) ::
          {:ok, BrusselsWtf.Council.CoverageReservation.t()}
          | {:error,
             :budget_exhausted
             | :budget_limit_mismatch
             | :reservation_conflict
             | :budget_unavailable}
  def reserve(attrs, monthly_limit_cents, now) do
    case reserve_for_execution(attrs, monthly_limit_cents, now) do
      {:ok, reservation, _disposition} -> {:ok, reservation}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reserve_for_execution(reservation_attrs(), pos_integer(), DateTime.t() | Date.t()) ::
          {:ok, BrusselsWtf.Council.CoverageReservation.t(), :new | :existing}
          | {:error,
             :budget_exhausted
             | :budget_limit_mismatch
             | :reservation_conflict
             | :budget_unavailable}
  def reserve_for_execution(attrs, monthly_limit_cents, now)
      when is_map(attrs) and is_integer(monthly_limit_cents) and monthly_limit_cents > 0 do
    estimated_cost_cents = Map.get(attrs, :estimated_cost_cents)

    if is_integer(estimated_cost_cents) and estimated_cost_cents > 0 do
      period_start = period_start(now)

      case Repo.transaction(fn ->
             budget = ensure_month_in_transaction(period_start, monthly_limit_cents)

             case Council.get_coverage_reservation_by_call_key(Map.fetch!(attrs, :call_key)) do
               {:ok, reservation} ->
                 if same_call?(reservation, attrs, budget.id) do
                   {reservation, [], :existing}
                 else
                   Repo.rollback(:reservation_conflict)
                 end

               _not_found ->
                 case reserve_cents(budget.id, estimated_cost_cents) do
                   :ok ->
                     {reservation, notifications} =
                       attrs
                       |> Map.put(:coverage_budget_id, budget.id)
                       |> Map.put(:reserved_cents, estimated_cost_cents)
                       |> Map.put(:status, :reserved)
                       |> then(
                         &Ash.create!(BrusselsWtf.Council.CoverageReservation, &1,
                           action: :reserve,
                           domain: Council,
                           return_notifications?: true
                         )
                       )

                     {reservation, notifications, :new}

                   :exhausted ->
                     Repo.rollback(:budget_exhausted)
                 end
             end
           end) do
        {:ok, {reservation, notifications, disposition}} ->
          Ash.Notifier.notify(notifications)
          {:ok, reservation, disposition}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :budget_unavailable}
    end
  rescue
    _exception -> {:error, :budget_unavailable}
  catch
    _kind, _reason -> {:error, :budget_unavailable}
  end

  def reserve_for_execution(_attrs, _monthly_limit_cents, _now),
    do: {:error, :budget_unavailable}

  @spec reconcile(Ecto.UUID.t(), map()) ::
          {:ok, BrusselsWtf.Council.CoverageReservation.t()}
          | {:error,
             :reservation_not_found
             | :final_cost_exceeds_reservation
             | :invalid_final_cost
             | :budget_unavailable}
  def reconcile(reservation_id, attrs) when is_binary(reservation_id) and is_map(attrs) do
    case Repo.transaction(fn -> reconcile_in_transaction(reservation_id, attrs) end) do
      {:ok, {reservation, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, reservation}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _exception -> {:error, :budget_unavailable}
  catch
    _kind, _reason -> {:error, :budget_unavailable}
  end

  def reconcile(_reservation_id, _attrs), do: {:error, :budget_unavailable}

  @spec ensure_month(pos_integer(), DateTime.t() | Date.t()) ::
          {:ok, t()} | {:error, :budget_limit_mismatch | :budget_unavailable}
  def ensure_month(limit_cents, now) when is_integer(limit_cents) and limit_cents > 0 do
    period_start = period_start(now)

    case Repo.transaction(fn -> ensure_month_in_transaction(period_start, limit_cents) end) do
      {:ok, budget} -> {:ok, budget}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :budget_unavailable}
  catch
    _kind, _reason -> {:error, :budget_unavailable}
  end

  def ensure_month(_limit_cents, _now), do: {:error, :budget_unavailable}

  @spec ensure_month!(pos_integer(), DateTime.t() | Date.t()) :: t()
  def ensure_month!(limit_cents, now) do
    case ensure_month(limit_cents, now) do
      {:ok, budget} -> budget
      {:error, reason} -> raise "coverage budget unavailable: #{reason}"
    end
  end

  defp ensure_month_in_transaction(period_start, limit_cents) do
    Repo.query!(
      """
      INSERT INTO coverage_budgets
        (period_start, hard_limit_cents, reserved_cents, spent_cents, inserted_at, updated_at)
      VALUES ($1, $2, 0, 0, timezone('utc', now()), timezone('utc', now()))
      ON CONFLICT (period_start) DO NOTHING
      """,
      [period_start, limit_cents]
    )

    budget = Council.get_coverage_budget_by_period!(period_start)

    if budget.hard_limit_cents == limit_cents do
      budget
    else
      Repo.rollback(:budget_limit_mismatch)
    end
  end

  defp same_call?(reservation, attrs, budget_id) do
    reservation.coverage_budget_id == budget_id and
      reservation.meeting_page_id == Map.get(attrs, :meeting_page_id) and
      reservation.publication_input_hash == Map.get(attrs, :publication_input_hash) and
      reservation.operation == Map.get(attrs, :operation) and
      reservation.locale == Map.get(attrs, :locale) and
      reservation.provider == Map.get(attrs, :provider) and
      reservation.model == Map.get(attrs, :model) and
      reservation.retry == Map.get(attrs, :retry) and
      reservation.estimated_cost_cents == Map.get(attrs, :estimated_cost_cents)
  end

  defp reconcile_in_transaction(reservation_id, attrs) do
    case lock_reservation(reservation_id) do
      :missing ->
        Repo.rollback(:reservation_not_found)

      :locked ->
        reservation =
          Ash.get!(BrusselsWtf.Council.CoverageReservation, reservation_id,
            domain: BrusselsWtf.Council
          )

        if reservation.status in [:settled, :reconciliation_failed] do
          {reservation, []}
        else
          final_cost_cents = Map.get(attrs, :final_cost_cents)

          cond do
            not (is_nil(final_cost_cents) or
                     (is_integer(final_cost_cents) and final_cost_cents >= 0)) ->
              Repo.rollback(:invalid_final_cost)

            is_integer(final_cost_cents) and final_cost_cents > reservation.reserved_cents ->
              poison_budget(reservation)

              Ash.update!(
                reservation,
                %{
                  coverage_run_id: Map.get(attrs, :coverage_run_id),
                  input_usage: Map.get(attrs, :input_usage, %{}),
                  output_usage: Map.get(attrs, :output_usage, %{}),
                  status: :reconciliation_failed,
                  reconciliation_failure: "final_cost_exceeds_reservation",
                  settled_at: Map.get(attrs, :settled_at, BrusselsWtf.Clock.utc_now())
                },
                action: :fail_reconciliation,
                domain: Council,
                return_notifications?: true
              )

            true ->
              charged_cents = final_cost_cents || reservation.reserved_cents
              settle_budget(reservation, charged_cents)

              settlement = %{
                coverage_run_id: Map.get(attrs, :coverage_run_id),
                final_cost_cents: final_cost_cents,
                charged_cents: charged_cents,
                input_usage: Map.get(attrs, :input_usage, %{}),
                output_usage: Map.get(attrs, :output_usage, %{}),
                status: :settled,
                settled_at: Map.get(attrs, :settled_at, BrusselsWtf.Clock.utc_now())
              }

              Ash.update!(reservation, settlement,
                action: :settle,
                domain: Council,
                return_notifications?: true
              )
          end
        end
    end
  end

  defp lock_reservation(reservation_id) do
    result =
      Repo.query!(
        "SELECT id FROM coverage_reservations WHERE id = $1 FOR UPDATE",
        [Ecto.UUID.dump!(reservation_id)]
      )

    if result.num_rows == 1, do: :locked, else: :missing
  end

  defp poison_budget(reservation) do
    result =
      Repo.query!(
        """
        UPDATE coverage_budgets
        SET reserved_cents = hard_limit_cents - spent_cents,
            poisoned_at = timezone('utc', now()),
            updated_at = timezone('utc', now())
        WHERE id = $1
          AND spent_cents <= hard_limit_cents
        """,
        [Ecto.UUID.dump!(reservation.coverage_budget_id)]
      )

    if result.num_rows != 1, do: Repo.rollback(:budget_unavailable)
  end

  defp settle_budget(reservation, charged_cents) do
    result =
      Repo.query!(
        """
        UPDATE coverage_budgets
        SET reserved_cents =
              CASE
                WHEN poisoned_at IS NULL THEN reserved_cents - $1
                ELSE hard_limit_cents - (spent_cents + $2)
              END,
            spent_cents = spent_cents + $2,
            updated_at = timezone('utc', now())
        WHERE id = $3
          AND reserved_cents >= $1
          AND spent_cents + $2 <= hard_limit_cents
        """,
        [
          reservation.reserved_cents,
          charged_cents,
          Ecto.UUID.dump!(reservation.coverage_budget_id)
        ]
      )

    if result.num_rows != 1, do: Repo.rollback(:budget_unavailable)
  end

  @spec unresolved_for_call(map()) ::
          {:ok, BrusselsWtf.Council.CoverageReservation.t() | nil} | {:error, term()}
  def unresolved_for_call(attrs) when is_map(attrs) do
    meeting_page_id_value = Map.get(attrs, :meeting_page_id)
    publication_input_hash_value = Map.get(attrs, :publication_input_hash)
    operation_value = Map.get(attrs, :operation)
    locale_value = Map.get(attrs, :locale)
    provider_value = Map.get(attrs, :provider)
    model_value = Map.get(attrs, :model)

    reservation =
      BrusselsWtf.Council.CoverageReservation
      |> Ash.Query.filter(
        status in [:reserved, :executing, :reconciliation_pending] and
          meeting_page_id == ^meeting_page_id_value and
          publication_input_hash == ^publication_input_hash_value and
          operation == ^operation_value and
          locale == ^locale_value and
          provider == ^provider_value and
          model == ^model_value
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(domain: Council)

    {:ok, reservation}
  rescue
    _error -> {:error, :budget_unavailable}
  catch
    :exit, _reason -> {:error, :budget_unavailable}
  end

  def unresolved_for_call(_attrs), do: {:error, :budget_unavailable}

  @spec begin_execution(Ecto.UUID.t()) ::
          {:ok, {:admit | :existing, BrusselsWtf.Council.CoverageReservation.t()}}
          | {:error, term()}
  def begin_execution(reservation_id) when is_binary(reservation_id) do
    reservation_transaction(reservation_id, fn reservation ->
      if reservation.status == :reserved do
        {updated, notifications} =
          Ash.update!(reservation, %{status: :executing},
            action: :begin_execution,
            domain: Council,
            return_notifications?: true
          )

        {{:admit, updated}, notifications}
      else
        {{:existing, reservation}, []}
      end
    end)
  end

  def begin_execution(_reservation_id), do: {:error, :budget_unavailable}

  @spec mark_reconciliation_pending(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, BrusselsWtf.Council.CoverageReservation.t()} | {:error, term()}
  def mark_reconciliation_pending(reservation_id, coverage_run_id, usage)
      when is_binary(reservation_id) and is_binary(coverage_run_id) and is_map(usage) do
    reservation_transaction(reservation_id, fn reservation ->
      if reservation.status in [:settled, :reconciliation_failed, :reconciliation_pending] do
        {reservation, []}
      else
        Ash.update!(
          reservation,
          %{
            coverage_run_id: coverage_run_id,
            input_usage: Map.take(usage, ["input_tokens", "input_units"]),
            output_usage: Map.take(usage, ["output_tokens", "output_units", "cost_cents"]),
            status: :reconciliation_pending
          },
          action: :mark_reconciliation_pending,
          domain: Council,
          return_notifications?: true
        )
      end
    end)
  end

  def mark_reconciliation_pending(_reservation_id, _coverage_run_id, _usage),
    do: {:error, :budget_unavailable}

  @spec fail_reconciliation(Ecto.UUID.t(), Ecto.UUID.t(), map(), term()) ::
          {:ok, BrusselsWtf.Council.CoverageReservation.t()} | {:error, term()}
  def fail_reconciliation(reservation_id, coverage_run_id, usage, reason)
      when is_binary(reservation_id) and is_binary(coverage_run_id) and is_map(usage) do
    result =
      Repo.transaction(fn ->
        case lock_reservation(reservation_id) do
          :missing ->
            Repo.rollback(:reservation_not_found)

          :locked ->
            reservation =
              Ash.get!(BrusselsWtf.Council.CoverageReservation, reservation_id,
                domain: BrusselsWtf.Council
              )

            if reservation.status in [:settled, :reconciliation_failed] do
              {reservation, []}
            else
              poison_budget(reservation)

              Ash.update!(
                reservation,
                %{
                  coverage_run_id: coverage_run_id,
                  input_usage: Map.take(usage, ["input_tokens", "input_units"]),
                  output_usage: Map.take(usage, ["output_tokens", "output_units", "cost_cents"]),
                  status: :reconciliation_failed,
                  reconciliation_failure: "retry_exhausted:" <> safe_reason(reason),
                  settled_at: BrusselsWtf.Clock.utc_now()
                },
                action: :fail_reconciliation,
                domain: Council,
                return_notifications?: true
              )
            end
        end
      end)

    case result do
      {:ok, {reservation, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, reservation}

      {:error, persistence_reason} ->
        {:error, persistence_reason}
    end
  rescue
    _error -> {:error, :budget_unavailable}
  catch
    :exit, _reason -> {:error, :budget_unavailable}
  end

  def fail_reconciliation(_reservation_id, _coverage_run_id, _usage, _reason),
    do: {:error, :budget_unavailable}

  defp reservation_transaction(reservation_id, fun) do
    result =
      Repo.transaction(fn ->
        case lock_reservation(reservation_id) do
          :missing ->
            Repo.rollback(:reservation_not_found)

          :locked ->
            reservation =
              Ash.get!(BrusselsWtf.Council.CoverageReservation, reservation_id,
                domain: BrusselsWtf.Council
              )

            fun.(reservation)
        end
      end)

    case result do
      {:ok, {value, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error -> {:error, :budget_unavailable}
  catch
    :exit, _reason -> {:error, :budget_unavailable}
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "budget_unavailable"

  defp reserve_cents(budget_id, estimated_cost_cents) do
    result =
      Repo.query!(
        """
        UPDATE coverage_budgets
        SET reserved_cents = reserved_cents + $1,
            updated_at = timezone('utc', now())
        WHERE id = $2
          AND poisoned_at IS NULL
          AND spent_cents + reserved_cents + $1 <= hard_limit_cents
        """,
        [estimated_cost_cents, Ecto.UUID.dump!(budget_id)]
      )

    if result.num_rows == 1, do: :ok, else: :exhausted
  end

  defp period_start(%DateTime{} = now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_date()
    |> Date.beginning_of_month()
  end

  defp period_start(%Date{} = date), do: Date.beginning_of_month(date)
end
