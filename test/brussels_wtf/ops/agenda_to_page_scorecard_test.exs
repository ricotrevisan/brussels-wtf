defmodule BrusselsWtf.Ops.AgendaToPageScorecardTest do
  @moduledoc """
  The scorecard must report only what retained rows prove. A publication counts as
  automatic only when its job was inserted inside this meeting's normalization job.
  """

  use BrusselsWtf.DataCase, async: false

  import ExUnit.CaptureIO

  alias BrusselsWtf.Council
  alias BrusselsWtf.Repo

  @script "priv/ops/agenda_to_page_scorecard.exs"
  @publish "BrusselsWtf.Workers.PublishMeeting"
  @normalize "BrusselsWtf.Workers.NormalizeSource"

  describe "with a published meeting" do
    setup do
      scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
      BrusselsWtf.Processors.Stub.put_locales("268", scenario.coverage)
      assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
      assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
      meeting = Council.get_ingested_meeting!("ixelles", "268")

      Repo.query!("DELETE FROM oban_jobs", [])

      Repo.query!(
        """
        UPDATE source_versions SET first_retrieved_at = '2026-10-01 10:00:00'
        WHERE source_record_id IN (SELECT id FROM source_records WHERE council_meeting_id = $1::text::uuid)
        """,
        [meeting.id]
      )

      Repo.query!(
        """
        UPDATE publication_revisions SET published_at = '2026-10-01 11:00:00'
        WHERE meeting_page_id IN (SELECT id FROM meeting_pages WHERE council_meeting_id = $1::text::uuid)
        """,
        [meeting.id]
      )

      %{meeting: meeting}
    end

    test "reports lag and item counts, and calls a job inside its normalization automatic",
         %{meeting: meeting} do
      run_id = processing_run_id!(meeting.id)

      normalize_id =
        job!(@normalize, %{processing_run_id: run_id}, "10:30:00", "10:30:05", "10:30:10")

      job!(
        @publish,
        %{meeting_id: meeting.id, generation_kind: "automatic"},
        "10:30:08",
        "10:59:00",
        "11:00:30"
      )

      row = ixelles_row!()

      assert row.meeting_identifier == "268"
      assert row.published == true
      assert row.agenda_retained_at == "2026-10-01T10:00:00"
      assert row.first_published_at == "2026-10-01T11:00:00"
      assert row.lag_seconds == 3_600
      assert row.hand_queued == "no"
      assert row.hand_queued_evidence == "inserted_inside_normalization_job:#{normalize_id}"
      assert row.normalized_items > 0
      assert row.published_items > 0
      assert row.normalized_items == row.published_items + row.other_items
    end

    test "an automatic-looking job without a normalization parent is hand-queued",
         %{meeting: meeting} do
      job!(
        @publish,
        %{meeting_id: meeting.id, generation_kind: "automatic"},
        "10:58:00",
        "10:59:00",
        "11:00:30"
      )

      row = ixelles_row!()

      assert row.hand_queued == "yes"
      assert row.hand_queued_evidence == "no_normalization_parent"
    end

    test "another meeting's concurrent normalization does not make a job automatic",
         %{meeting: meeting} do
      job!(
        @normalize,
        %{processing_run_id: Ash.UUID.generate()},
        "10:30:00",
        "10:30:05",
        "10:30:10"
      )

      job!(
        @publish,
        %{meeting_id: meeting.id, generation_kind: "automatic"},
        "10:30:08",
        "10:59:00",
        "11:00:30"
      )

      assert ixelles_row!().hand_queued == "yes"
    end

    test "a coverage batch job is hand-queued", %{meeting: meeting} do
      batch_id = Ash.UUID.generate()

      job!(
        @publish,
        %{meeting_id: meeting.id, generation_kind: "backfill", coverage_batch_id: batch_id},
        "10:58:00",
        "10:59:00",
        "11:00:30"
      )

      row = ixelles_row!()

      assert row.hand_queued == "yes"
      assert row.hand_queued_evidence == "coverage_batch:#{batch_id}"
    end

    test "with no retained publishing job the answer is unknown, never no" do
      row = ixelles_row!()

      assert row.hand_queued == "unknown"
      assert row.hand_queued_evidence == "publishing_job_not_found"
    end

    test "the script writes nothing, and reports each commune" do
      counts_before = table_counts()
      {output, rows} = run_script([])

      assert counts_before == table_counts()
      assert output =~ ~s("commune":"ixelles")
      assert Enum.map(rows, & &1.commune) == ~w(city-of-brussels forest ixelles uccle)

      for row <- rows, row.commune != "ixelles" do
        assert row.meeting_identifier == nil
        assert row.status == "no_retained_agenda"
      end
    end
  end

  test "a retained agenda that never published reports its wait and no lag" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :fetch)

    row = ixelles_row!()

    assert row.meeting_identifier == "268"
    assert row.published == false
    assert row.first_published_at == nil
    assert row.lag_seconds == nil
    assert is_integer(row.waiting_seconds)
    assert row.hand_queued == "not_published"
    assert row.normalized_items == 0
  end

  test "per_commune is bounded" do
    source = File.read!(@script)

    assert_raise RuntimeError, ~r/per_commune must be between 1 and 12/, fn ->
      Code.eval_string(source, per_commune: 0)
    end

    assert_raise RuntimeError, ~r/per_commune must be between 1 and 12/, fn ->
      Code.eval_string(source, per_commune: 13)
    end
  end

  defp ixelles_row! do
    {_output, rows} = run_script([])
    Enum.find(rows, &(&1.commune == "ixelles"))
  end

  defp run_script(bindings) do
    source = File.read!(@script)
    parent = self()

    output =
      capture_io(fn ->
        {result, _bindings} = Code.eval_string(source, bindings)
        send(parent, {:result, result})
      end)

    assert_received {:result, result}
    {output, result}
  end

  defp processing_run_id!(meeting_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        SELECT r.id::text FROM processing_runs r
        JOIN source_versions v ON v.id = r.source_version_id
        JOIN source_records s ON s.id = v.source_record_id
        WHERE s.council_meeting_id = $1::text::uuid LIMIT 1
        """,
        [meeting_id]
      )

    id
  end

  defp job!(worker, args, inserted, attempted, completed) do
    day = "2026-10-01 "

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO oban_jobs (state, queue, worker, args, inserted_at, scheduled_at, attempted_at, completed_at, attempt)
        VALUES ('completed', 'publish', $1, $2, $3::text::timestamp, $3::text::timestamp, $4::text::timestamp, $5::text::timestamp, 1)
        RETURNING id
        """,
        [worker, args, day <> inserted, day <> attempted, day <> completed]
      )

    id
  end

  defp table_counts do
    for table <- ~w(review_cases review_actions publication_revisions oban_jobs) do
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, count}
    end
  end
end
