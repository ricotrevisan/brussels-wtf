defmodule BrusselsWtf.Council.GenerationControlTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council

  defmodule MustNotRunCoverage do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    def generate_fr(_input), do: raise("disabled generation called the provider")

    @impl true
    def translate(_canonical, _locale), do: raise("disabled generation called the provider")

    @impl true
    def maximum_cost(_operation, _input), do: raise("disabled generation estimated provider cost")

    @impl true
    def metadata, do: raise("disabled generation inspected the provider")
  end

  defmodule PaidCoverage do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    def generate_fr(_input), do: raise("recorded mode called a paid provider")

    @impl true
    def translate(_canonical, _locale), do: raise("recorded mode called a paid provider")

    @impl true
    def maximum_cost(_operation, _input), do: {:ok, 1}

    @impl true
    def metadata do
      %{
        processor_name: "paid-test",
        processor_version: "1",
        config_hash: "sha256:paid-test",
        provider_category: "paid_api",
        billing_mode: :paid,
        network_access: :network,
        model: "paid-model",
        canonical_method: :ai_generation,
        translation_method: :machine_translation,
        usage: %{}
      }
    end
  end

  defmodule ShutoffAfterCanonical do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    def generate_fr(input) do
      Application.put_env(:brussels_wtf, :coverage_generation, %{
        mode: :disabled,
        backfill_enabled: false,
        monthly_budget_cents: nil
      })

      BrusselsWtf.Processors.Stub.generate_fr(input)
    end

    @impl true
    def translate(_canonical, _locale), do: raise("translation ran after emergency shutoff")

    @impl true
    def maximum_cost(_operation, _input), do: {:ok, 0}

    @impl true
    def metadata do
      %{
        processor_name: "shutoff-test",
        processor_version: "1",
        config_hash: "sha256:shutoff-test",
        provider_category: "recorded_fixture",
        billing_mode: :recorded,
        network_access: :none,
        model: "recorded",
        canonical_method: :ai_generation,
        translation_method: :machine_translation,
        usage: %{"network_calls" => 0}
      }
    end
  end

  defmodule PaidBudgetCoverage do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    def generate_fr(input) do
      {:ok, output} = BrusselsWtf.Processors.Stub.generate_fr(input)
      {:ok, output, %{"cost_cents" => 25, "input_tokens" => 100, "output_tokens" => 20}}
    end

    @impl true
    def translate(canonical, locale) do
      {:ok, output} = BrusselsWtf.Processors.Stub.translate(canonical, locale)
      {:ok, output, %{"cost_cents" => 25, "input_tokens" => 80, "output_tokens" => 20}}
    end

    @impl true
    def maximum_cost(_operation, _input), do: {:ok, 40}

    @impl true
    def metadata do
      %{
        processor_name: "paid-budget-test",
        processor_version: "1",
        config_hash: "sha256:paid-budget-test",
        provider_category: "paid_test",
        billing_mode: :paid,
        network_access: :network,
        model: "paid-model",
        canonical_method: :ai_generation,
        translation_method: :machine_translation,
        usage: %{}
      }
    end
  end

  defmodule OverMaximumCoverage do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    def generate_fr(input) do
      {:ok, output} = BrusselsWtf.Processors.Stub.generate_fr(input)
      {:ok, output, %{"cost_cents" => 45, "input_tokens" => 100, "output_tokens" => 20}}
    end

    @impl true
    def translate(_canonical, _locale),
      do: raise("translation ran after cost reconciliation failed")

    @impl true
    def maximum_cost(_operation, _input), do: {:ok, 40}

    @impl true
    def metadata do
      %{
        processor_name: "over-maximum-test",
        processor_version: "1",
        config_hash: "sha256:over-maximum-test",
        provider_category: "paid_test",
        billing_mode: :paid,
        network_access: :network,
        model: "paid-model",
        canonical_method: :ai_generation,
        translation_method: :machine_translation,
        usage: %{}
      }
    end
  end

  defmodule PartialPaidCoverage do
    def generate_fr(_normalized), do: raise("partial provider must not run")
    def translate(_canonical, _locale), do: raise("partial provider must not run")
    def maximum_cost(_operation, _input), do: {:ok, 1}

    def metadata do
      %{
        processor_name: "partial-paid-test",
        processor_version: "1",
        config_hash: "sha256:partial-paid-test",
        provider_category: "paid_test",
        billing_mode: :paid,
        network_access: :network,
        model: "paid-model",
        canonical_method: :bogus,
        translation_method: :machine_translation,
        usage: %{}
      }
    end
  end

  setup do
    previous_generation = Application.fetch_env!(:brussels_wtf, :coverage_generation)
    previous_processor = Application.fetch_env!(:brussels_wtf, :coverage_processor)

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :coverage_generation, previous_generation)
      Application.put_env(:brussels_wtf, :coverage_processor, previous_processor)
    end)

    :ok
  end

  test "disabled mode normalizes a meeting without making a coverage call or opening a case" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, MustNotRunCoverage)
    BrusselsWtf.Test.Harness.load("ixelles/proposal")

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    assert page.publication_status == :draft
    assert Council.list_coverage_runs!(page.id) == []

    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
    assert BrusselsWtf.Review.list_review_cases!(%{kind: :publication}, actor: actor) == []
  end

  test "recorded mode refuses a paid processor before provider execution" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, PaidCoverage)

    assert :ok = Council.generate_meeting_coverage!(meeting.id, 1, 3)
    assert Council.list_coverage_runs!(page.id) == []
    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "runtime configuration defaults to recorded mode with backfill generation off" do
    assert BrusselsWtf.Council.GenerationControl.runtime_config(fn _name -> nil end) == %{
             mode: :recorded,
             backfill_enabled: false,
             backfill_max_batch_size: 10,
             monthly_budget_cents: nil
           }
  end

  test "paid runtime configuration requires a positive hard budget" do
    env = fn
      "COVERAGE_GENERATION_MODE" -> "paid"
      "COVERAGE_MONTHLY_BUDGET_CENTS" -> nil
      "BACKFILL_GENERATION_ENABLED" -> nil
      _name -> nil
    end

    assert_raise ArgumentError, ~r/COVERAGE_MONTHLY_BUDGET_CENTS/, fn ->
      BrusselsWtf.Council.GenerationControl.runtime_config(env)
    end
  end

  test "invalid runtime configuration fails closed" do
    env = fn
      "COVERAGE_GENERATION_MODE" -> "surprise"
      _name -> nil
    end

    assert_raise ArgumentError, ~r/COVERAGE_GENERATION_MODE/, fn ->
      BrusselsWtf.Council.GenerationControl.runtime_config(env)
    end
  end

  test "an emergency shutoff between calls prevents queued translations" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, ShutoffAfterCanonical)

    assert :ok = Council.generate_meeting_coverage!(meeting.id, 1, 3)

    assert [%{locale: "fr", status: :succeeded}] = Council.list_coverage_runs!(page.id)
    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "a forged backfill job without a persisted allowlist makes no coverage call" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, MustNotRunCoverage)

    assert :ok =
             BrusselsWtf.Workers.PublishMeeting.perform(%Oban.Job{
               args: %{"meeting_id" => meeting.id, "generation_kind" => "backfill"},
               attempt: 1,
               max_attempts: 3
             })

    assert Council.list_coverage_runs!(page.id) == []

    assert {:error, _invalid_batch} =
             Council.generate_backfill_meeting_coverage(
               meeting.id,
               1,
               3,
               :backfill,
               Ecto.UUID.generate()
             )
  end

  test "an acquisition backfill propagates its scope and does not publish automatically" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, MustNotRunCoverage)

    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    BrusselsWtf.Ingestion.request_backfill!(%{type: :commune, id: scenario.commune.id},
      actor: actor
    )

    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    assert page.publication_status == :draft
    assert Council.list_coverage_runs!(page.id) == []
  end

  test "paid mode reserves before each call and stops when the hard budget is exhausted" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 60
    })

    Application.put_env(:brussels_wtf, :coverage_processor, PaidBudgetCoverage)

    assert :ok = Council.generate_meeting_coverage!(meeting.id, 1, 3)

    assert [%{locale: "fr", status: :succeeded, usage: %{"cost_cents" => 25}}] =
             Council.list_coverage_runs!(page.id)

    assert Council.get_meeting_page!(page.id).publication_status == :draft

    assert {:ok, budget} =
             BrusselsWtf.Council.CoverageBudget.ensure_month(
               60,
               BrusselsWtf.Clock.utc_now()
             )

    assert budget.spent_cents == 25
    assert budget.reserved_cents == 0
  end

  test "startup validation rejects a processor that does not match the selected mode" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, PaidCoverage)

    assert_raise RuntimeError, ~r/not permitted/, fn ->
      BrusselsWtf.Council.GenerationControl.validate_configuration!()
    end
  end

  test "the scheduled previous-year window acquires records without generating coverage" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, MustNotRunCoverage)
    BrusselsWtf.Test.Harness.load("uccle/end-to-end")

    BrusselsWtf.Ingestion.request_scheduled_poll!("uccle", :previous_year)
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("uccle", "2025-06-26")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    assert page.publication_status == :draft
    assert Council.list_coverage_runs!(page.id) == []
  end

  test "a provider charge above its declared maximum blocks publication and keeps the reservation" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 100
    })

    Application.put_env(:brussels_wtf, :coverage_processor, OverMaximumCoverage)

    assert :ok = Council.generate_meeting_coverage!(meeting.id, 1, 3)

    assert [%{locale: "fr", usage: %{"cost_cents" => 45}}] =
             Council.list_coverage_runs!(page.id)

    assert {:ok, budget} =
             BrusselsWtf.Council.CoverageBudget.ensure_month(
               100,
               BrusselsWtf.Clock.utc_now()
             )

    assert budget.reserved_cents == 100
    assert budget.spent_cents == 0

    assert [reservation] =
             Ash.read!(BrusselsWtf.Council.CoverageReservation, domain: Council)

    assert reservation.status == :reconciliation_failed
    assert reservation.reconciliation_failure == "final_cost_exceeds_reservation"
    assert reservation.coverage_run_id != nil
    assert reservation.output_usage["cost_cents"] == 45

    assert {:error, :budget_exhausted} =
             BrusselsWtf.Council.CoverageBudget.reserve(
               %{
                 meeting_page_id: page.id,
                 publication_input_hash: "sha256:later-input",
                 operation: :translation,
                 locale: "nl",
                 provider: "paid_test",
                 model: "paid-model",
                 retry: 1,
                 call_key: "later-call-after-poison",
                 estimated_cost_cents: 1
               },
               100,
               BrusselsWtf.Clock.utc_now()
             )

    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "a job queued before the emergency restart cannot call a provider after shutoff" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 100
    })

    Application.put_env(:brussels_wtf, :coverage_processor, PaidBudgetCoverage)
    %{meeting_id: meeting.id} |> BrusselsWtf.Workers.PublishMeeting.new() |> Oban.insert!()

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    Application.put_env(:brussels_wtf, :coverage_processor, MustNotRunCoverage)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :publish, with_safety: false)

    assert Council.list_coverage_runs!(page.id) == []
    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "an authenticated allowlisted batch can generate selected historical coverage" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :disabled,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      backfill_max_batch_size: 10,
      monthly_budget_cents: nil
    })

    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
    batch = Council.request_coverage_batch!([meeting.id], actor: actor)
    assert batch.meeting_ids == [meeting.id]
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :publish, with_safety: false)

    assert Council.get_meeting_page!(page.id).publication_status == :published
    assert length(Council.list_coverage_runs!(page.id)) == 3
  end

  test "startup rejects a paid processor with a partial cost contract" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 100
    })

    Application.put_env(:brussels_wtf, :coverage_processor, PartialPaidCoverage)

    assert_raise RuntimeError, ~r/incomplete/, fn ->
      BrusselsWtf.Council.GenerationControl.validate_configuration!()
    end
  end

  test "an Oban retry repairs pending reconciliation before any new paid call" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: 100
    })

    Application.put_env(:brussels_wtf, :coverage_processor, PaidBudgetCoverage)
    BrusselsWtf.Seeds.PublicTimeline.run!()
    meeting = Council.get_ingested_meeting!("ixelles", "demo-ixelles")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    input = %{"proposal" => "same paid input"}
    metadata = PaidBudgetCoverage.metadata()

    assert {:ok, reservation} =
             BrusselsWtf.Council.GenerationControl.reserve_call(
               page,
               :canonical_generation,
               "fr",
               input,
               metadata,
               1
             )

    assert {:defer, :call_already_reserved} =
             BrusselsWtf.Council.GenerationControl.reserve_call(
               page,
               :canonical_generation,
               "fr",
               input,
               metadata,
               2
             )

    assert [_executing_reservation] =
             Ash.read!(BrusselsWtf.Council.CoverageReservation, domain: Council)

    run =
      Council.record_coverage_run!(%{
        meeting_page_id: page.id,
        operation: :canonical_generation,
        locale: "fr",
        input_hash: "sha256:pending-input",
        output_hash: "sha256:pending-output",
        processor_name: metadata.processor_name,
        processor_version: metadata.processor_version,
        config_hash: metadata.config_hash,
        provider_category: metadata.provider_category,
        model: metadata.model,
        method: metadata.canonical_method,
        status: :succeeded,
        input: %{},
        output: %{},
        usage: %{"cost_cents" => 25}
      })

    assert {:ok, pending} =
             BrusselsWtf.Council.CoverageBudget.mark_reconciliation_pending(
               reservation.id,
               run.id,
               %{"cost_cents" => 25}
             )

    assert pending.status == :reconciliation_pending

    assert {:defer, :cost_reconciliation_pending} =
             BrusselsWtf.Council.GenerationControl.reserve_call(
               page,
               :canonical_generation,
               "fr",
               input,
               metadata,
               3
             )

    assert [_one_reservation] =
             Ash.read!(BrusselsWtf.Council.CoverageReservation, domain: Council)

    assert_enqueued worker: BrusselsWtf.Workers.ReconcileCoverageCost,
                    args: %{reservation_id: reservation.id, coverage_run_id: run.id}
  end
end
