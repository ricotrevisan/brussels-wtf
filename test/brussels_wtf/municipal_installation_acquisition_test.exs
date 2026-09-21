defmodule BrusselsWtf.Identity.MunicipalInstallation.AcquisitionTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Identity.MunicipalInstallation.{Acquisition, Source}
  alias BrusselsWtf.{Ingestion, HTTP}

  @actor %BrusselsWtf.Review.Actor{id: "acquisition-test", role: :reviewer}

  setup do
    HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    :ok
  end

  test "rejects unauthorized or unbounded requests before acquisition" do
    assert {:error, :reviewer_required} = Acquisition.acquire(["ixelles"], actor: nil)
    assert {:error, :invalid_scope} = Acquisition.acquire([], actor: @actor)
    assert {:error, :invalid_scope} = Acquisition.acquire(["other"], actor: @actor)
    assert {:error, :invalid_scope} = Acquisition.acquire(["ixelles", "ixelles"], actor: @actor)
    assert Ingestion.list_poll_runs!() == []
  end

  test "retains observed City report index and changed PDF without queuing extraction" do
    {:ok, contract} = Source.contract("city-of-brussels")
    source = contract.installation
    body = "%PDF-1.7\nsynthetic changed report\n%%EOF"
    HTTP.Stub.put(source.parent_index_url, %{body: city_index(source)})
    HTTP.Stub.put(source.url, %{body: body, headers: %{"content-type" => "application/pdf"}})

    assert {:ok, report} = Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)
    assert report.queued == 0
    assert report.reused == 0
    assert report.failures == 2
    assert [%{kind: :installation, reason: :source_hash_changed}, _] = report.sources

    commune = Ingestion.get_commune_by_slug!(contract.slug)
    history = Ingestion.source_history!(commune.id, source.url)
    assert [version] = history.versions
    assert version.sha256 == BrusselsWtf.Digest.sha256(body)
    assert [%{status: :success, source_version_id: id}] = history.observations
    assert id == version.id

    assert [%{parent_index_url: parent, scheduled_on: ~D[2024-12-01], role: :minutes}] =
             Ingestion.locator_history!(commune.id, source.url)

    assert parent == source.parent_index_url
    assert history.processing_runs == []
    assert [index_version] = Ingestion.source_history!(commune.id, parent).versions
    assert {:ok, html} = BrusselsWtf.Archive.get(index_version.object_key)
    assert html == city_index(source)
  end

  test "Ixelles archive discovery uses the dated row and never invents adjacent leaves" do
    {:ok, contract} = Source.contract("ixelles")
    source = contract.installation

    html = """
    <h3>[2024]</h3><table><tr><td>01/12</td>
    <td><a href="../uploads/conseil/pv/245.pdf">Procès-verbal</a></td></tr></table>
    """

    HTTP.Stub.put(source.parent_index_url, %{body: html})
    HTTP.Stub.put(source.url, %{body: "%PDF-1.7 changed"})
    assert {:ok, report} = Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)
    assert [%{reason: :source_hash_changed}, _] = report.sources
    commune = Ingestion.get_commune_by_slug!(contract.slug)

    assert [%{observed_label: "Procès-verbal", meeting_identifier: "245"}] =
             Ingestion.locator_history!(commune.id, source.url)

    HTTP.Stub.reset()
    HTTP.Stub.put(source.parent_index_url, %{body: String.replace(html, "01/12", "02/12")})
    assert {:ok, report} = Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)
    assert [%{reason: :source_not_observed}, _] = report.sources
    assert HTTP.Stub.requests(source.url) == []
  end

  test "report row labels, exact leaf and restricted origin are required" do
    {:ok, contract} = Source.contract("city-of-brussels")
    source = contract.installation

    for html <- [
          String.replace(city_index(source), "01/12/2024", "02/12/2024"),
          String.replace(city_index(source), "202024.pdf", "202024-other.pdf"),
          String.replace(city_index(source), "views-row", "unrelated")
        ] do
      HTTP.Stub.reset()
      HTTP.Stub.put(source.parent_index_url, %{body: html})

      assert {:ok, %{queued: 0, failures: 2}} =
               Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

      assert HTTP.Stub.requests(source.url) == []
    end

    HTTP.Stub.put(source.parent_index_url, %{
      body: city_index(source),
      final_url: "https://example.org/index"
    })

    assert {:ok, %{sources: [%{reason: :redirect_origin_rejected}, _]}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    assert HTTP.Stub.requests(source.url) == []
  end

  test "invalid PDFs and transport failures retain failed observations without a version" do
    {:ok, contract} = Source.contract("city-of-brussels")
    source = contract.installation
    HTTP.Stub.put(source.parent_index_url, %{body: city_index(source)})
    HTTP.Stub.put(source.url, %{body: "<html>login page</html>"})

    assert {:ok, %{sources: [%{reason: :not_pdf}, _], queued: 0}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    commune = Ingestion.get_commune_by_slug!(contract.slug)

    assert [%{observations: [%{status: :failure, source_version_id: nil}]}] =
             Ingestion.locator_history!(commune.id, source.url)

    assert {:error, _} = Ingestion.get_source_record_by_origin(commune.id, source.url)
  end

  test "a same-origin PDF alias is a classified failure, never extraction or publication readiness" do
    {:ok, contract} = Source.contract("city-of-brussels")
    source = contract.installation
    redirected = "https://www.brussels.be/sites/default/files/alias.pdf"
    HTTP.Stub.put(source.parent_index_url, %{body: city_index(source)})

    HTTP.Stub.put(source.url, %{
      body: "%PDF-1.7 synthetic report",
      final_url: redirected,
      redirect_chain: [%{"url" => source.url, "location" => redirected, "status" => 302}]
    })

    assert {:ok, %{queued: 0, reused: 0, sources: [failure, _]}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    assert failure.reason == :source_redirect_rejected

    assert Oban.Testing.all_enqueued(
             worker: BrusselsWtf.Workers.ExtractSource,
             repo: BrusselsWtf.Repo
           ) == []

    commune = Ingestion.get_commune_by_slug!(contract.slug)

    assert [
             %{
               observations: [
                 %{
                   status: :failure,
                   error_kind: "source_redirect_rejected",
                   final_url: ^redirected
                 }
               ]
             }
           ] =
             Ingestion.locator_history!(commune.id, source.url)

    assert {:ok, [%{published_new: 0, error: _}]} =
             BrusselsWtf.Identity.MunicipalInstallation.publish([contract.slug],
               actor: @actor,
               max_facts_per_commune: 1
             )

    assert BrusselsWtf.Identity.list_public_relationships!() == []
  end

  test "default transport retains same-origin redirects and archives the actual parent response" do
    {:ok, contract} = Source.contract("city-of-brussels")
    source = contract.installation
    old = Req.default_options()
    on_exit(fn -> Req.default_options(old) end)
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/complete-reports-public-meetings-city-council" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/canonical-report-index")
          |> Plug.Conn.send_resp(302, "")

        "/canonical-report-index" ->
          Plug.Conn.send_resp(conn, 200, city_index(source))

        _ ->
          Plug.Conn.send_resp(conn, 200, "%PDF-1.7 changed")
      end
    end)

    assert {:ok, %{sources: [%{reason: :source_hash_changed}, _]}} =
             Acquisition.acquire([contract.slug], actor: @actor)

    commune = Ingestion.get_commune_by_slug!(contract.slug)

    assert [%{observations: [%{status: :success, final_url: final, redirect_chain: [redirect]}]}] =
             Ingestion.locator_history!(commune.id, source.parent_index_url)

    assert final == "https://www.brussels.be/canonical-report-index"
    assert redirect["url"] == source.parent_index_url
    assert redirect["location"] == final
  end

  test "default transport refuses off-origin redirects before issuing their request" do
    old = Req.default_options()
    on_exit(fn -> Req.default_options(old) end)
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "www.brussels.be"
      send(self(), {:requested, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("location", "https://unapproved.invalid/private")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:ok, %{failures: 2, queued: 0}} =
             Acquisition.acquire(["city-of-brussels"], actor: @actor)

    assert_received {:requested, "/complete-reports-public-meetings-city-council"}
    commune = Ingestion.get_commune_by_slug!("city-of-brussels")
    source = Source.contract("city-of-brussels") |> elem(1) |> Map.fetch!(:installation)

    assert [%{observations: [%{status: :failure, redirect_chain: [redirect]}]}] =
             Ingestion.locator_history!(commune.id, source.parent_index_url)

    assert redirect["location"] == "https://unapproved.invalid/private"
  end

  # Opt-in, offline acceptance against the locally retained audit PDFs. Never
  # commit those bytes, alter production pins, or make CI fetch private evidence.
  @tag :external
  test "pinned bytes queue native extraction and reuse accepted archive lineage without meeting links" do
    dir = System.fetch_env!("ISSUE104_SOURCE_DIR")
    BrusselsWtf.Processors.Stub.reset()

    for {slug, filename} <- [
          {"ixelles", "ixelles-install"},
          {"uccle", "uccle-install"},
          {"forest", "forest-install"},
          {"city-of-brussels", "city-install"}
        ] do
      {:ok, contract} = Source.contract(slug)
      source = contract.installation
      bytes = File.read!(Path.join(dir, filename))
      assert BrusselsWtf.Digest.sha256(bytes) == source.sha256
      HTTP.Stub.put(source.parent_index_url, %{body: installation_index(slug, source)})
      HTTP.Stub.put(source.url, %{body: bytes})

      BrusselsWtf.Processors.Stub.put(source.sha256, %{
        extract: %{
          "text" =>
            String.duplicate("Le conseil communal délibère sur les matières publiques. ", 20)
        }
      })

      assert {:ok, %{sources: [queued, _]}} =
               Acquisition.acquire([slug], actor: @actor, http: HTTP.Stub)

      assert queued.status == :queued, inspect(queued)

      assert {:ok, %{sources: [again, _]}} =
               Acquisition.acquire([slug], actor: @actor, http: HTTP.Stub)

      assert again.job_id == queued.job_id
      assert length(HTTP.Stub.requests(source.url)) == 1

      assert :ok =
               Oban.Testing.perform_job(
                 BrusselsWtf.Workers.ExtractSource,
                 %{
                   source_version_id: queued.source_version_id,
                   generation_kind: "backfill"
                 },
                 repo: BrusselsWtf.Repo
               )

      commune = Ingestion.get_commune_by_slug!(slug)
      history = Ingestion.source_history!(commune.id, source.url)
      assert history.source_record.council_meeting_id == nil
      assert [version] = history.versions
      assert [original] = Ingestion.locator_history!(commune.id, source.url)
      # An unrelated duplicate context must not veto the exact observation.
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: source.url,
        parent_index_url: commune.index_url <> "#old",
        meeting_identifier: "old-context",
        scheduled_on: ~D[2023-01-01],
        role: source.role,
        language: :bilingual,
        discovered_at: BrusselsWtf.Clock.utc_now()
      })

      HTTP.Stub.reset()

      assert {:ok, %{sources: [reused, _]}} =
               Acquisition.acquire([slug], actor: @actor, http: HTTP.Stub)

      assert reused.status == :reused
      assert reused.source_version_id == queued.source_version_id
      assert HTTP.Stub.requests(source.url) == []

      assert Ingestion.get_source_version!(version.id).first_retrieved_at ==
               version.first_retrieved_at

      assert Enum.map(Ingestion.list_observations!(original.id), &{&1.id, &1.observed_at}) ==
               Enum.map(original.observations, &{&1.id, &1.observed_at})

      # Missing/corrupt archived bytes fail closed; successful metadata is not enough.
      BrusselsWtf.Archive.Memory.reset()

      assert {:ok, %{sources: [%{reason: :archive_unavailable}, _]}} =
               Acquisition.acquire([slug], actor: @actor, http: HTTP.Stub)

      assert HTTP.Stub.requests(source.url) == []
    end
  end

  @tag :external
  test "redirected archived PDF lineage cannot report ready or publish until an exact leaf retrieval succeeds" do
    dir = System.fetch_env!("ISSUE104_SOURCE_DIR")
    {:ok, contract} = Source.contract("city-of-brussels")
    {installation, corroboration} = BrusselsWtf.MunicipalInstallationFixture.pair(contract.slug)
    BrusselsWtf.Processors.Stub.reset()

    for {source, filename, text} <- [
          {contract.installation, "city-install", installation},
          {contract.corroboration, "city-report", corroboration}
        ] do
      HTTP.Stub.put(source.parent_index_url, %{body: city_index(source)})
      HTTP.Stub.put(source.url, %{body: File.read!(Path.join(dir, filename))})

      pages =
        text
        |> String.split("\f")
        |> Enum.map(
          &(&1 <>
              "\n" <>
              String.duplicate(
                "Le conseil communal examine les documents de la séance publique. ",
                4
              ))
        )

      BrusselsWtf.Processors.Stub.put(source.sha256, %{extract: %{"page_texts" => pages}})
    end

    assert {:ok, %{queued: 2, failures: 0, sources: queued}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    for source <- queued do
      assert :ok =
               Oban.Testing.perform_job(
                 BrusselsWtf.Workers.ExtractSource,
                 %{source_version_id: source.source_version_id, generation_kind: "backfill"},
                 repo: BrusselsWtf.Repo
               )
    end

    assert {:ok, %{reused: 2, failures: 0}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    # Simulate historical observations from the shared, less restrictive HTTP lane.
    # Raw bytes, accepted runs, artifact links and checksums remain valid.
    for {source, result, filename} <- [
          {contract.installation, hd(queued), "city-install"},
          {contract.corroboration, List.last(queued), "city-report"}
        ] do
      redirected = source.url <> "?alias=1"
      chain = [%{"url" => source.url, "location" => redirected, "status" => 302}]

      Repo.query!(
        "UPDATE retrieval_observations SET final_url = $1, redirect_chain = $2 WHERE source_version_id = $3::text::uuid",
        [redirected, chain, result.source_version_id]
      )

      HTTP.Stub.put(source.url, %{
        body: File.read!(Path.join(dir, filename)),
        final_url: redirected,
        redirect_chain: chain
      })
    end

    jobs_before =
      Oban.Testing.all_enqueued(worker: BrusselsWtf.Workers.ExtractSource, repo: BrusselsWtf.Repo)
      |> Enum.map(& &1.id)

    assert {:ok, %{reused: 0, queued: 0, failures: 2, sources: failures}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    assert Enum.all?(failures, &(&1.reason == :source_redirect_rejected))

    assert Oban.Testing.all_enqueued(
             worker: BrusselsWtf.Workers.ExtractSource,
             repo: BrusselsWtf.Repo
           )
           |> Enum.map(& &1.id) == jobs_before

    assert {:ok, [%{published_new: 0, error: _}]} =
             BrusselsWtf.Identity.MunicipalInstallation.publish([contract.slug],
               actor: @actor,
               max_facts_per_commune: 1
             )

    assert BrusselsWtf.Identity.list_public_relationships!() == []

    # Append genuine exact-leaf observations; do not rewrite the rejected history.
    for {source, filename} <- [
          {contract.installation, "city-install"},
          {contract.corroboration, "city-report"}
        ] do
      HTTP.Stub.put(source.url, %{body: File.read!(Path.join(dir, filename))})
    end

    assert {:ok, %{reused: 2, queued: 0, failures: 0}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    assert {:ok, [%{published_new: 1, rejected: []}]} =
             BrusselsWtf.Identity.MunicipalInstallation.publish([contract.slug],
               actor: @actor,
               max_facts_per_commune: 1
             )

    assert length(BrusselsWtf.Identity.list_public_relationships!()) == 1
  end

  @tag :external
  test "both approved City report years acquire independently, with no general poll or coverage jobs" do
    dir = System.fetch_env!("ISSUE104_SOURCE_DIR")
    {:ok, contract} = Source.contract("city-of-brussels")

    for {source, filename, index} <- [
          {contract.installation, "city-install", "city-reports-2024"},
          {contract.corroboration, "city-report", "city-reports"}
        ] do
      HTTP.Stub.put(source.parent_index_url, %{body: File.read!(Path.join(dir, index))})
      HTTP.Stub.put(source.url, %{body: File.read!(Path.join(dir, filename))})
    end

    assert {:ok, %{queued: 2, reused: 0, failures: 0, sources: sources}} =
             Acquisition.acquire([contract.slug], actor: @actor, http: HTTP.Stub)

    assert Enum.map(sources, & &1.kind) == [:installation, :corroboration]

    for worker <- [
          BrusselsWtf.Workers.PollCommune,
          BrusselsWtf.Workers.FetchLocator,
          BrusselsWtf.Workers.PublishMeeting
        ] do
      assert Oban.Testing.all_enqueued(worker: worker, repo: BrusselsWtf.Repo) == []
    end
  end

  defp installation_index("city-of-brussels", source), do: city_index(source)

  defp installation_index("ixelles", source) do
    "<h3>[2024]</h3><table><tr><td>01/12</td><td><a href=\"#{source.url}\">Procès-verbal</a></td></tr></table>"
  end

  defp installation_index("uccle", source) do
    "<h2>2024</h2><table><caption>1 décembre</caption><tr><th>Registre des délibérations</th><td><a href=\"#{source.url}\">Registre</a></td></tr></table>"
  end

  defp installation_index("forest", source) do
    "<div class=\"card\"><time datetime=\"2024-12-01T10:00:00+01:00\"></time><a href=\"#{source.url}\">Procès verbal</a></div>"
  end

  defp city_index(source) do
    displayed = Calendar.strftime(source.date, "%d/%m/%Y")

    """
    <div class="views-row"><div class="views-field views-field-field-file-document">
      <div class="field-content"><i class="fa fa-file-pdf ext"></i><a target="_blank" href="#{URI.parse(source.url).path}">Public meeting of the City Council of #{displayed}</a></div>
    </div></div>
    """
  end
end
