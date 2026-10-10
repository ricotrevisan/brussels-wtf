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

  test "failed download validators cannot replace an archived version's validators", context do
    %{server: server, commune: commune, actor: actor} = context
    url = server.base_url <> "/bounded.pdf"
    previous_limit = Application.fetch_env!(:brussels_wtf, :http_max_body_bytes)
    Application.put_env(:brussels_wtf, :http_max_body_bytes, 16)
    on_exit(fn -> Application.put_env(:brussels_wtf, :http_max_body_bytes, previous_limit) end)

    ControllableHTTPServer.put_sequence(server, "/bounded.pdf", [
      %{
        status: 200,
        headers: %{"etag" => "failed-first", "last-modified" => "Thu, 20 Aug 2026 10:00:00 GMT"},
        body: String.duplicate("x", 32)
      },
      %{
        status: 200,
        headers: %{"etag" => "archived", "last-modified" => "Thu, 20 Aug 2026 11:00:00 GMT"},
        body: "archived bytes"
      },
      %{
        status: 200,
        headers: %{"etag" => "failed-change", "last-modified" => "Thu, 20 Aug 2026 12:00:00 GMT"},
        body: String.duplicate("y", 32)
      },
      %{status: 304}
    ])

    locator = locator!(commune, url)

    for _check <- 1..4 do
      run = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: actor)

      assert :ok =
               perform_job(FetchLocator, %{
                 locator_id: locator.id,
                 poll_run_id: run.id,
                 check_key: run.check_key,
                 attempt: 1
               })
    end

    [first, second, third, fourth] = ControllableHTTPServer.requests(server, "/bounded.pdf")

    for request <- [first, second] do
      refute Map.has_key?(request.headers, "if-none-match")
      refute Map.has_key?(request.headers, "if-modified-since")
    end

    for request <- [third, fourth] do
      assert request.headers["if-none-match"] == "archived"
      assert request.headers["if-modified-since"] == "Thu, 20 Aug 2026 11:00:00 GMT"
    end

    history = Ingestion.source_history!(commune.id, url)

    assert Enum.map(history.observations, & &1.status) == [
             :failure,
             :success,
             :failure,
             :unchanged
           ]

    assert [version] = history.versions
    assert version.sha256 == BrusselsWtf.Digest.sha256("archived bytes")
    assert Enum.at(history.observations, 0).response_headers["etag"] == ["failed-first"]
    assert Enum.at(history.observations, 2).response_headers["etag"] == ["failed-change"]
    assert List.last(history.observations).source_version_id == version.id
  end

  test "index polling ignores validators from a rejected download", context do
    %{server: server, commune: commune, actor: actor} = context
    index = File.read!("test/support/fixtures/ixelles/proposal/index.html")
    previous_limit = Application.fetch_env!(:brussels_wtf, :http_max_body_bytes)
    Application.put_env(:brussels_wtf, :http_max_body_bytes, byte_size(index))
    on_exit(fn -> Application.put_env(:brussels_wtf, :http_max_body_bytes, previous_limit) end)

    ControllableHTTPServer.put_sequence(server, "/index", [
      %{status: 200, headers: %{"etag" => "rejected-index"}, body: index <> "too large"},
      %{status: 200, headers: %{"etag" => "archived-index"}, body: index},
      %{status: 304}
    ])

    for expected <- [{:review, :invalid_content}, :ok, :ok] do
      run = Ingestion.request_poll_now!(%{type: :commune, id: commune.id}, actor: actor)

      assert BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
               commune.id,
               run.id,
               run.check_key
             ) == expected
    end

    [first, second, third] = ControllableHTTPServer.requests(server, "/index")
    refute Map.has_key?(first.headers, "if-none-match")
    refute Map.has_key?(second.headers, "if-none-match")
    assert third.headers["if-none-match"] == "archived-index"

    history = Ingestion.source_history!(commune.id, commune.index_url)
    assert Enum.map(history.observations, & &1.status) == [:failure, :success, :unchanged]
    assert [_version] = history.versions
  end

  test "restored index and document bytes remain current across conditional checks", context do
    %{server: server, commune: commune, actor: actor} = context
    index_a = File.read!("test/support/fixtures/ixelles/proposal/index.html")

    for {path, bytes_a, bytes_b, target_type} <- [
          {"/restored.pdf", "document A", "document B", :locator},
          {"/index", index_a, index_a <> "<!-- changed -->", :commune}
        ] do
      url = server.base_url <> path
      target_id = if target_type == :locator, do: locator!(commune, url).id, else: commune.id

      ControllableHTTPServer.put_sequence(server, path, [
        %{status: 200, headers: %{"etag" => "version-a"}, body: bytes_a},
        %{status: 200, headers: %{"etag" => "version-b"}, body: bytes_b},
        %{status: 200, headers: %{"etag" => "restored-a"}, body: bytes_a},
        %{status: 304}
      ])

      for check <- 1..4 do
        BrusselsWtf.Clock.Controlled.set(DateTime.add(~U[2026-08-20 12:00:00Z], check, :second))
        run = Ingestion.request_poll_now!(%{type: target_type, id: target_id}, actor: actor)

        if target_type == :locator do
          assert :ok =
                   perform_job(FetchLocator, %{
                     locator_id: target_id,
                     poll_run_id: run.id,
                     check_key: run.check_key,
                     attempt: 1
                   })
        else
          assert :ok =
                   BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
                     commune.id,
                     run.id,
                     run.check_key
                   )
        end
      end

      assert List.last(ControllableHTTPServer.requests(server, path)).headers["if-none-match"] ==
               "restored-a"

      history = Ingestion.source_history!(commune.id, url)
      assert length(history.versions) == 2
      [first, _changed, restored, unchanged] = history.observations
      assert restored.source_version_id == first.source_version_id
      assert unchanged.source_version_id == first.source_version_id
      assert unchanged.sha256 == BrusselsWtf.Digest.sha256(bytes_a)
    end
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
