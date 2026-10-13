defmodule BrusselsWtf.Ingestion.OcrRecoveryBudget do
  @moduledoc "One finite OCR allowance per immutable audited document generation. Unknown spending is never refunded."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ocr_recovery_budgets"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :open do
      accept [:processing_run_id]
      upsert? true
      upsert_identity :one_generation
      upsert_fields []
    end

    update :reserve do
      require_atomic? false
      accept []
      argument :page_run_id, :uuid, allow_nil?: false
      argument :token, :uuid, allow_nil?: false
      change {BrusselsWtf.Ingestion.OcrRecoveryBudget.Change, operation: :reserve}
    end

    update :reserve_assembly do
      require_atomic? false
      accept []
      argument :token, :uuid, allow_nil?: false
      change {BrusselsWtf.Ingestion.OcrRecoveryBudget.Change, operation: :reserve_assembly}
    end

    update :settle do
      require_atomic? false
      accept []
      argument :token, :uuid, allow_nil?: false
      argument :cpu_ms, :integer, allow_nil?: false, constraints: [min: 0]
      argument :wall_ms, :integer, allow_nil?: false, constraints: [min: 0]
      argument :output_bytes, :integer, allow_nil?: false, constraints: [min: 0]
      change {BrusselsWtf.Ingestion.OcrRecoveryBudget.Change, operation: :settle}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :cpu_ms, :integer, allow_nil?: false, default: 0, constraints: [min: 0, max: 90_000]

    attribute :wall_ms, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0, max: 120_000]

    attribute :output_bytes, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0, max: 134_217_728]

    attribute :reservations, :map, allow_nil?: false, default: %{}
    timestamps()
  end

  relationships do
    belongs_to :processing_run, BrusselsWtf.Ingestion.ProcessingRun, allow_nil?: false
  end

  identities do
    identity :one_generation, [:processing_run_id]
  end
end

defmodule BrusselsWtf.Ingestion.OcrRecoveryBudget.Change do
  @moduledoc false
  use Ash.Resource.Change
  require Ash.Query
  alias BrusselsWtf.Ingestion.{OcrRecoveryBudget, ProcessingRun}

  def change(changeset, opts, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      id = changeset.data.id

      budget =
        OcrRecoveryBudget
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!()

      apply_operation(%{changeset | data: budget}, budget, opts[:operation])
    end)
  end

  defp apply_operation(cs, budget, :reserve) do
    page_id = Ash.Changeset.get_argument(cs, :page_run_id)
    token = Ash.Changeset.get_argument(cs, :token)
    page = Ash.get!(ProcessingRun, page_id)
    parent = Ash.get!(ProcessingRun, budget.processing_run_id)
    attempts = Enum.count(budget.reservations, fn {_, r} -> r["page_run_id"] == page_id end)
    cpu = div(90_000 - budget.cpu_ms, 1000) * 1000
    wall = 120_000 - budget.wall_ms

    if page.inputs["parent_run_id"] == parent.id and page.status == :queued and
         parent.status == :queued and parent.inputs["operation"] == "ocr_large_pages" and
         parent.inputs["extraction_only"] == true and
         cpu >= 1000 and wall > 0 and attempts < 3 and
         not Map.has_key?(budget.reservations, token) do
      reservation = %{
        "page_run_id" => page_id,
        "attempt" => attempts + 1,
        "cpu_ms" => cpu,
        "wall_ms" => wall,
        "settled" => false
      }

      cs
      |> Ash.Changeset.force_change_attribute(:cpu_ms, budget.cpu_ms + cpu)
      |> Ash.Changeset.force_change_attribute(:wall_ms, budget.wall_ms + wall)
      |> Ash.Changeset.force_change_attribute(
        :reservations,
        Map.put(budget.reservations, token, reservation)
      )
    else
      Ash.Changeset.add_error(cs,
        field: :reservations,
        message: "finite OCR allowance exhausted or invalid claim"
      )
    end
  end

  defp apply_operation(cs, budget, :reserve_assembly) do
    parent = Ash.get!(ProcessingRun, budget.processing_run_id)
    token = Ash.Changeset.get_argument(cs, :token)

    chunks =
      ProcessingRun |> Ash.Query.filter(inputs[:parent_run_id] == ^parent.id) |> Ash.read!()

    pages = chunks |> Enum.flat_map(& &1.inputs["original_pages"]) |> Enum.sort()

    if parent.status == :queued and parent.inputs["extraction_only"] == true and
         parent.inputs["operation"] == "ocr_large_pages" and
         pages == parent.inputs["original_pages"] and
         Enum.all?(chunks, &(&1.status == :succeeded)) and budget.wall_ms < 120_000 and
         not Enum.any?(budget.reservations, fn {_, r} -> r["phase"] == "assembly" end) and
         not Map.has_key?(budget.reservations, token) do
      r = %{
        "phase" => "assembly",
        "cpu_ms" => 0,
        "wall_ms" => 120_000 - budget.wall_ms,
        "settled" => false
      }

      cs
      |> Ash.Changeset.force_change_attribute(:wall_ms, 120_000)
      |> Ash.Changeset.force_change_attribute(
        :reservations,
        Map.put(budget.reservations, token, r)
      )
    else
      Ash.Changeset.add_error(cs,
        field: :reservations,
        message: "finite assembly allowance exhausted or already claimed"
      )
    end
  end

  defp apply_operation(cs, budget, :settle) do
    token = Ash.Changeset.get_argument(cs, :token)
    cpu = Ash.Changeset.get_argument(cs, :cpu_ms)
    wall = Ash.Changeset.get_argument(cs, :wall_ms)
    bytes = Ash.Changeset.get_argument(cs, :output_bytes)

    case budget.reservations[token] do
      %{"settled" => true} ->
        cs

      %{"cpu_ms" => rcpu, "wall_ms" => rwall} = reservation when cpu <= rcpu and wall <= rwall ->
        if budget.output_bytes + bytes <= 134_217_728 do
          settled =
            Map.merge(reservation, %{
              "settled" => true,
              "used_cpu_ms" => cpu,
              "used_wall_ms" => wall,
              "output_bytes" => bytes
            })

          cs
          |> Ash.Changeset.force_change_attribute(:cpu_ms, budget.cpu_ms - rcpu + cpu)
          |> Ash.Changeset.force_change_attribute(:wall_ms, budget.wall_ms - rwall + wall)
          |> Ash.Changeset.force_change_attribute(:output_bytes, budget.output_bytes + bytes)
          |> Ash.Changeset.force_change_attribute(
            :reservations,
            Map.put(budget.reservations, token, settled)
          )
        else
          Ash.Changeset.add_error(cs, field: :output_bytes, message: "document OCR output limit")
        end

      _ ->
        Ash.Changeset.add_error(cs,
          field: :reservations,
          message: "invalid or unmeasured spending; retain full reservation"
        )
    end
  end
end
