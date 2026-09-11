defmodule BrusselsWtf.Ingestion.UccleCurrentPollingTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion

  @current_url "https://www.uccle.be/fr/ma-commune/le-conseil-communal"
  @archive_url "https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal"
  @actor %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

  setup do
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-11 12:00:00Z])

    # An already persisted production commune must not stay on its legacy archive root.
    commune =
      Ingestion.create_commune!(%{slug: "uccle", name: "Uccle", index_url: @archive_url})

    current = File.read!("test/support/fixtures/uccle/current-index-2026.html")
    archive = File.read!("test/support/fixtures/uccle/adapter-index.html")
    BrusselsWtf.HTTP.Stub.put(@current_url, %{status: 200, body: current})
    BrusselsWtf.HTTP.Stub.put(@archive_url, %{status: 200, body: archive})

    {:ok, commune: commune, current: current, archive: archive}
  end

  test "a current poll checks the current page and retains the separately archived index history",
       %{
         commune: commune,
         current: current,
         archive: archive
       } do
    Ingestion.request_backfill!(%{type: :commune, id: commune.id}, actor: @actor)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)
    old_locators = Ingestion.list_document_locators!(commune.id)

    current_poll =
      Ingestion.request_poll_now!(%{type: :commune, id: commune.id}, actor: @actor)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)

    september =
      commune.id
      |> Ingestion.list_document_locators!()
      |> Enum.filter(&(&1.scheduled_on == ~D[2026-09-10]))

    assert Enum.sort(Enum.map(september, & &1.role)) ==
             Enum.sort([
               :agenda,
               :complementary_agenda,
               :explanatory_note,
               :complementary_explanatory_note
             ])

    assert Enum.all?(september, &(&1.parent_index_url == @current_url))

    for locator <- september do
      assert_enqueued(
        worker: BrusselsWtf.Workers.FetchLocator,
        args: %{locator_id: locator.id, poll_run_id: current_poll.id}
      )
    end

    for locator <- old_locators do
      assert Ingestion.get_locator!(locator.id).parent_index_url == @archive_url
      assert Ingestion.list_observations!(locator.id) == []
    end

    for {url, bytes} <- [{@archive_url, archive}, {@current_url, current}] do
      history = Ingestion.source_history!(commune.id, url)
      assert [%{sha256: hash}] = history.versions
      assert hash == BrusselsWtf.Digest.sha256(bytes)
      assert [%{status: :success}] = history.observations
    end
  end

  test "previous-year polls and unchanged replays remain on the archive and preserve current context",
       %{
         commune: commune
       } do
    current_poll = Ingestion.request_scheduled_poll!("uccle")
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)

    previous_poll = Ingestion.request_scheduled_poll!("uccle", :previous_year)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)

    assert [_] = BrusselsWtf.HTTP.Stub.requests(@current_url)
    assert [_] = BrusselsWtf.HTTP.Stub.requests(@archive_url)

    assert_fetch_scope(commune, current_poll, 2026, @current_url)
    assert_fetch_scope(commune, previous_poll, 2025, @archive_url)

    BrusselsWtf.HTTP.Stub.put(@current_url, %{status: 304})
    BrusselsWtf.HTTP.Stub.put(@archive_url, %{status: 304})

    current_replay = Ingestion.request_scheduled_poll!("uccle")
    previous_replay = Ingestion.request_scheduled_poll!("uccle", :previous_year)
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :poll)

    assert_fetch_scope(commune, current_replay, 2026, @current_url)
    assert_fetch_scope(commune, previous_replay, 2025, @archive_url)

    for url <- [@current_url, @archive_url] do
      history = Ingestion.source_history!(commune.id, url)
      assert [_] = history.versions
      assert Enum.map(history.observations, & &1.status) == [:success, :unchanged]
    end

    for locator <- Ingestion.list_document_locators!(commune.id) do
      assert Ingestion.list_observations!(locator.id) == []
    end
  end

  test "removing a current link appends disappearance and index bytes without changing archive context",
       %{
         commune: commune,
         current: current
       } do
    Ingestion.request_scheduled_poll!("uccle", :previous_year)
    Ingestion.request_scheduled_poll!("uccle")
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :poll)

    removed =
      commune.id
      |> Ingestion.list_document_locators!()
      |> Enum.find(&(&1.scheduled_on == ~D[2026-09-10] and &1.role == :complementary_agenda))

    changed =
      Regex.replace(
        ~r/<a href="[^"]*CC-2026-09-10-ODJC-U1180_fr_nl.pdf"[^>]*>.*?<\/a>/s,
        current,
        ""
      )

    # These are separate observations; tied retrieval times have no chronological order.
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-11 12:00:01Z])
    BrusselsWtf.HTTP.Stub.put(@current_url, %{status: 200, body: changed})
    Ingestion.request_scheduled_poll!("uccle")
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)

    assert [%{status: :disappeared, final_url: url}] = Ingestion.list_observations!(removed.id)
    assert url == removed.url
    assert Ingestion.get_locator!(removed.id).parent_index_url == @current_url

    history = Ingestion.source_history!(commune.id, @current_url)
    [original_version, changed_version] = history.versions

    assert DateTime.compare(
             original_version.first_retrieved_at,
             changed_version.first_retrieved_at
           ) ==
             :lt

    assert Enum.map(history.versions, & &1.sha256) ==
             Enum.map([current, changed], &BrusselsWtf.Digest.sha256/1)

    for locator <- Ingestion.list_document_locators!(commune.id),
        locator.parent_index_url == @archive_url do
      assert Ingestion.list_observations!(locator.id) == []
    end
  end

  test "an unknown current role retains the rejected index and does not erase discovered locators",
       %{
         commune: commune,
         current: current
       } do
    Ingestion.request_scheduled_poll!("uccle")
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)
    locators = Ingestion.list_document_locators!(commune.id)

    ambiguous =
      String.replace(current, ">Ordre du jour</th>", ">Document inconnu</th>", global: false)

    BrusselsWtf.HTTP.Stub.put(@current_url, %{status: 200, body: ambiguous})
    poll = Ingestion.request_scheduled_poll!("uccle")
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :poll)

    assert Ingestion.get_poll_run!(poll.id).status == :failed
    assert Ingestion.list_document_locators!(commune.id) == locators
    history = Ingestion.source_history!(commune.id, @current_url)
    assert Enum.map(history.observations, & &1.status) == [:success, :failure]
    assert List.last(history.observations).error_kind == "parser_failure"
    assert length(history.versions) == 2

    for locator <- locators do
      assert Ingestion.list_observations!(locator.id) == []
    end
  end

  test "the native commune configuration upsert preserves identity, locator parents, and index history",
       %{
         commune: commune
       } do
    Ingestion.request_scheduled_poll!("uccle", :previous_year)
    Ingestion.request_scheduled_poll!("uccle")
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :poll)

    locators = Ingestion.list_locators!(commune.id)
    current_history = Ingestion.source_history!(commune.id, @current_url)
    archive_history = Ingestion.source_history!(commune.id, @archive_url)
    approved = Ingestion.get_commune_by_slug!("uccle")
    assert approved.id == commune.id
    assert approved.index_url == @archive_url

    updated =
      Ingestion.create_commune!(%{
        slug: approved.slug,
        name: approved.name,
        index_url: BrusselsWtf.Communes.configuration!("uccle").index_url
      })

    assert updated.id == commune.id
    assert updated.name == approved.name
    assert updated.index_url == @current_url
    assert Ingestion.list_locators!(commune.id) == locators
    assert Ingestion.source_history!(commune.id, @current_url) == current_history
    assert Ingestion.source_history!(commune.id, @archive_url) == archive_history

    public_commune =
      BrusselsWtf.CoverageStatus.snapshot(~D[2026-09-11]).communes
      |> Enum.find(&(&1["slug"] == "uccle"))

    assert public_commune["index_url"] == @current_url
  end

  defp assert_fetch_scope(commune, poll_run, year, parent_url) do
    ids =
      all_enqueued(worker: BrusselsWtf.Workers.FetchLocator)
      |> Enum.filter(&(&1.args["poll_run_id"] == poll_run.id))
      |> Enum.map(& &1.args["locator_id"])
      |> MapSet.new()

    assert MapSet.size(ids) > 0

    fetched =
      commune.id
      |> Ingestion.list_document_locators!()
      |> Enum.filter(&MapSet.member?(ids, &1.id))

    assert Enum.all?(fetched, fn locator ->
             locator.scheduled_on.year == year and locator.parent_index_url == parent_url
           end)
  end
end
