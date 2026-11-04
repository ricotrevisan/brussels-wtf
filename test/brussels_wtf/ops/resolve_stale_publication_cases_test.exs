defmodule BrusselsWtf.Ops.ResolveStalePublicationCasesTest do
  @moduledoc """
  Guards the issue 146 backfill the way an operator runs it. Only a case opened
  before the page's current published revision is stale; a later case is a live signal.
  """

  use BrusselsWtf.DataCase, async: false

  import ExUnit.CaptureIO

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.PublicationLifecycle
  alias BrusselsWtf.Review

  @script "priv/ops/resolve_stale_publication_cases_20261103.exs"
  @actor %Review.Actor{id: "rico", role: :reviewer}

  setup do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    BrusselsWtf.Processors.Stub.put_locales("268", scenario.coverage)
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    page =
      Council.get_ingested_meeting!("ixelles", "268")
      |> Ash.load!(:meeting_page)
      |> Map.fetch!(:meeting_page)

    assert page.publication_status == :published
    %{page: page}
  end

  test "the default run lists stale cases, explains what stays open, and changes nothing", %{
    page: page
  } do
    stale = open_case!(page.id, "stale", -86_400)
    live = open_case!(page.id, "live", 86_400)

    {output, result} = run_script([])

    assert result.applied == false
    assert result.stale_case_ids == [stale.id]
    assert [%{id: live_id, reason: "opened_after_current_revision"}] = result.left_open
    assert live_id == live.id
    assert output =~ stale.id
    assert output =~ "read_only: true"
    refute output =~ "normalized_content"

    for review_case <- [stale, live] do
      current = Review.get_review_case!(review_case.id, actor: @actor)
      assert current.status == :open
      assert current.actions == []
    end
  end

  test "apply resolves exactly the expected stale cases through the audited path", %{page: page} do
    stale_one = open_case!(page.id, "stale-one", -86_400)
    stale_two = open_case!(page.id, "stale-two:config", -3_600)
    live = open_case!(page.id, "live", 86_400)
    other_kind = open_case!(page.id, "other-kind", -86_400, :acquisition)

    {_output, result} =
      run_script(apply?: true, expected_case_ids: [stale_one.id, stale_two.id])

    assert result.applied == true
    assert Enum.sort(result.resolved_case_ids) == Enum.sort([stale_one.id, stale_two.id])

    for %{id: id} <- [stale_one, stale_two] do
      resolved = Review.get_review_case!(id, actor: @actor)
      assert resolved.status == :resolved
      assert resolved.disposition == :superseded_by_publication
      assert [audit] = resolved.actions
      assert audit.actor_id == "system:publication"
      assert audit.details["trigger"] == "backfill"
      assert audit.details["publication_revision_id"] == page.current_revision_id
    end

    assert Review.get_review_case!(live.id, actor: @actor).status == :open
    assert Review.get_review_case!(other_kind.id, actor: @actor).status == :open

    {_output, again} = run_script([])
    assert again.stale_case_ids == []
  end

  test "apply fails closed unless the expected ids match the candidates exactly", %{page: page} do
    stale = open_case!(page.id, "stale", -86_400)
    surprise = open_case!(page.id, "surprise", -86_400)

    assert_raise RuntimeError, ~r/expected_case_ids is required/, fn ->
      run_script(apply?: true)
    end

    assert_raise RuntimeError, ~r/does not match/, fn ->
      run_script(apply?: true, expected_case_ids: [stale.id])
    end

    for %{id: id} <- [stale, surprise] do
      assert Review.get_review_case!(id, actor: @actor).status == :open
    end
  end

  test "a withdrawn page keeps its cases open", %{page: page} do
    stale = open_case!(page.id, "stale", -86_400)

    PublicationLifecycle.withdraw!(page.id, %{"en" => "x", "fr" => "x", "nl" => "x"}, @actor)

    {_output, result} = run_script([])

    assert result.stale_case_ids == []
    assert [%{id: id, reason: "page_not_published"}] = result.left_open
    assert id == stale.id
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

  # Timestamps are placed relative to the published revision because the test clock
  # is controlled while Ash stamps `inserted_at` from the system clock.
  defp open_case!(page_id, generation, offset_seconds, kind \\ :publication) do
    review_case =
      Review.open_review_case!(%{
        kind: kind,
        affected_record_id: page_id,
        affected_record_type: "meeting_page",
        processing_generation: generation,
        summary: "Issue 146 backfill fixture"
      })

    BrusselsWtf.Repo.query!(
      """
      UPDATE review_cases r
      SET inserted_at = mp.revision_published_at + make_interval(secs => $2)
      FROM meeting_pages mp
      WHERE r.id = $1::text::uuid AND mp.id = $3::text::uuid
      """,
      [review_case.id, offset_seconds, page_id]
    )

    review_case
  end
end
