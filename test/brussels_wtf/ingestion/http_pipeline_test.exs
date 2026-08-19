defmodule BrusselsWtf.Ingestion.HTTPPipelineTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Test.ControllableHTTPServer
  alias BrusselsWtf.Workers.FetchLocator

  setup do
    server = ControllableHTTPServer.start()
    previous_http = Application.fetch_env!(:brussels_wtf, :http)
    Application.put_env(:brussels_wtf, :http, BrusselsWtf.HTTP.Req)
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :http, previous_http)
      ControllableHTTPServer.stop(server)
    end)

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: server.base_url <> "/index"
      })

    {:ok, server: server, commune: commune, actor: %Actor{id: "rico", role: :reviewer}}
  end

  test "a real changing URL appends immutable versions and later disappearance", context do
    %{server: server, commune: commune, actor: actor} = context
    url = server.base_url <> "/changing.pdf"

    ControllableHTTPServer.put_sequence(server, "/changing.pdf", [
      %{
        status: 200,
        headers: %{"content-type" => "application/pdf", "etag" => "one"},
        body: "first bytes"
      },
      %{
        status: 200,
        headers: %{"content-type" => "application/pdf", "etag" => "two"},
        body: "second bytes"
      },
      %{status: 404, body: "gone"}
    ])

    locator = locator!(commune, url)

    for _check <- 1..3 do
      run = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: actor)

      assert :ok =
               perform_job(FetchLocator, %{
                 locator_id: locator.id,
                 poll_run_id: run.id,
                 check_key: run.check_key,
                 attempt: 1
               })
    end

    history = Ingestion.source_history!(commune.id, url)
    assert Enum.map(history.observations, & &1.status) == [:success, :success, :disappeared]

    assert MapSet.new(Enum.map(history.versions, & &1.sha256)) ==
             MapSet.new([
               BrusselsWtf.Digest.sha256("first bytes"),
               BrusselsWtf.Digest.sha256("second bytes")
             ])

    assert length(ControllableHTTPServer.requests(server, "/changing.pdf")) == 3
  end

  test "a real transient server receives exactly seven finite attempts", context do
    %{server: server, commune: commune, actor: actor} = context
    url = server.base_url <> "/retry.pdf"

    ControllableHTTPServer.put(server, "/retry.pdf", %{
      status: 503,
      headers: %{"retry-after" => "0"},
      body: "temporarily unavailable"
    })

    locator = locator!(commune, url)
    run = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: actor)

    for attempt <- 1..7 do
      assert :ok =
               perform_job(FetchLocator, %{
                 locator_id: locator.id,
                 poll_run_id: run.id,
                 check_key: run.check_key,
                 attempt: attempt
               })
    end

    assert length(ControllableHTTPServer.requests(server, "/retry.pdf")) == 7
    assert length(Ingestion.list_observations!(locator.id)) == 7
    assert [_case] = Review.list_review_cases!(%{kind: :acquisition}, actor: actor)
  end

  defp locator!(commune, url) do
    Ingestion.upsert_locator!(%{
      commune_id: commune.id,
      url: url,
      parent_index_url: commune.index_url,
      meeting_identifier: Ecto.UUID.generate(),
      scheduled_on: ~D[2026-08-30],
      role: :agenda,
      language: :fr,
      discovered_at: ~U[2026-08-20 10:00:00Z]
    })
  end
end
