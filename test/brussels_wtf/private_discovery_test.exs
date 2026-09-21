defmodule BrusselsWtf.PrivateDiscoveryTest do
  use BrusselsWtf.DataCase, async: false
  import Phoenix.ConnTest
  @endpoint BrusselsWtfWeb.Endpoint
  require Ash.Query

  alias BrusselsWtf.{Discovery, Ingestion, Identity}
  alias BrusselsWtf.Test.Harness

  @actor %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
  @token String.duplicate("discovery-machine-only-", 3)
  @text "SÉANCE PUBLIQUE\nÉlodie D’Haene présente le projet de l’ASBL Élan.\nDe vereniging Groene Toekomst neemt deel.\n\nCourriel privé: secret@example.be\nHUIS CLOS\nPrivate Example est présent."

  # Independent connections prove PostgreSQL coordination, not sandbox serialization.
  setup tags do
    if tags[:independent_connections] do
      config =
        Repo.config()
        |> Keyword.put(:database, "discovery_#{String.replace(Ash.UUID.generate(), "-", "")}")
        |> Keyword.put(:pool, DBConnection.ConnectionPool)
        |> Keyword.put(:pool_size, 6)
        |> Keyword.put(:name, nil)

      :ok = Ecto.Adapters.Postgres.storage_up(config)
      on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)
      {:ok, pid} = Repo.start_link(config)
      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
      previous_repo = Repo.put_dynamic_repo(pid)
      on_exit(fn -> Repo.put_dynamic_repo(previous_repo) end)
      Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
    end

    previous = Application.get_env(:brussels_wtf, :discovery_token_digest)
    Application.put_env(:brussels_wtf, :discovery_token_digest, BrusselsWtf.Digest.sha256(@token))
    on_exit(fn -> Application.put_env(:brussels_wtf, :discovery_token_digest, previous) end)
    :ok
  end

  test "archived native text through scoped API retains only exact private mentions and replays safely" do
    run = source!()
    assert {:error, :reviewer_required} = Discovery.preview([run.id], max_jobs: 4)
    assert {:ok, preview} = Discovery.preview([run.id], actor: @actor, max_jobs: 4)
    assert preview.job_count == 1
    assert {:ok, batch} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 4)
    assert {:ok, overlap} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 4)
    assert batch.job_ids == overlap.job_ids
    assert post(build_conn(), "/internal/discovery/claim", %{}) |> response(401)
    assert request("/internal/discovery/claim", %{}, "wrong") |> response(401)
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)
    refute Jason.encode!(claim) =~ "secret@example"
    refute Jason.encode!(claim) =~ "Private Example"
    assert request("/internal/discovery/claim", %{}) |> response(204)
    payload = result(claim)
    assert request("/internal/discovery/#{claim["id"]}/result", payload) |> json_response(200)
    assert request("/internal/discovery/#{claim["id"]}/result", payload) |> json_response(200)
    conflict = put_in(payload, ["result", "mentions"], [])
    assert request("/internal/discovery/#{claim["id"]}/result", conflict) |> response(409)
    [mention] = Ash.read!(Identity.Mention)
    assert mention.text == "Élodie D’Haene"
    assert mention.resolution_status == :unresolved
    assert mention.context["discovery_job_id"] == claim["id"]
    assert mention.context["extraction_run_id"] == run.id
    assert Ash.count!(Identity.Person) == 0
    assert Ash.count!(Identity.LegalEntity) == 0
    assert Ash.count!(Identity.SourcedFact) == 0
    assert Identity.list_public_relationships!() == []

    assert {:ok, %{jobs: [%{state: :completed, mention_count: 1}]}} =
             Discovery.status(batch.batch_id, actor: @actor)
  end

  test "invented, extra-key, ambiguous and private evidence cannot commit" do
    run = source!()
    assert {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 4)
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)
    payload = result(claim)

    for bad <- [
          put_in(payload, ["result", "mentions", Access.at(0), "quote"], "Invented quote"),
          put_in(payload, ["result", "mentions", Access.at(0), "text"], "Private Example"),
          put_in(payload, ["result", "input_hash"], String.duplicate("0", 64)),
          put_in(payload, ["result", "people"], [])
        ] do
      assert request("/internal/discovery/#{claim["id"]}/result", bad) |> response(422)
    end

    assert Ash.count!(Identity.Mention) == 0
  end

  test "expired leases cannot commit, retries are delayed and bounded, quota pauses globally" do
    run = source!()
    {:ok, batch} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 4)
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)
    advance(901)
    assert request("/internal/discovery/#{claim["id"]}/result", result(claim)) |> response(409)
    assert request("/internal/discovery/claim", %{}) |> response(204)
    advance(61)
    second = request("/internal/discovery/claim", %{}) |> json_response(200)
    assert second["lease_token"] != claim["lease_token"]
    assert request("/internal/discovery/#{claim["id"]}/result", result(claim)) |> response(409)

    assert request("/internal/discovery/#{second["id"]}/fail", %{
             "lease_token" => second["lease_token"],
             "reason" => "quota"
           })
           |> json_response(200)

    assert request("/internal/discovery/claim", %{}) |> response(204)

    assert {:ok, %{jobs: [%{state: :paused, failure_reason: "quota"}]}} =
             Discovery.status(batch.batch_id, actor: @actor)
  end

  for {scenario, name, role} <- [
        {"uccle/end-to-end", :explanatory_note, :ocr},
        {"forest/end-to-end", :agenda, :native_extraction},
        {"city_of_brussels/end-to-end", :agenda, :native_extraction}
      ] do
    test "#{scenario} accepted #{role} keeps original page/line and discovery meeting context" do
      run = source!(unquote(scenario), unquote(name), unquote(role))

      refute Ingestion.get_source_version!(run.source_version_id)
             |> Ash.load!(:source_record)
             |> Map.fetch!(:source_record)
             |> Map.fetch!(:council_meeting_id)

      assert {:ok, preview} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)
      assert [%{source_context: context}] = preview.jobs
      assert context["scheduled_on"] >= "2024-01-01"
      assert context["meeting_identifier"] != ""
      assert {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
      claim = request("/internal/discovery/claim", %{}) |> json_response(200)
      payload = result(claim)
      line = Enum.find(claim["input"]["lines"], &String.contains?(&1["text"], "Groene Toekomst"))

      payload =
        put_in(payload, ["result", "mentions"], [
          %{
            "kind" => "organization",
            "text" => "Groene Toekomst",
            "line_id" => line["id"],
            "quote" => line["text"]
          }
        ])

      refute BrusselsWtf.Discovery.Input.sensitive?(line["text"])
      assert request("/internal/discovery/#{claim["id"]}/result", payload) |> json_response(200)
      [mention] = Ash.read!(Identity.Mention)
      assert mention.text == "Groene Toekomst"
      assert mention.context["line_id"] == "p1-l3"
      assert mention.context["extraction_run_id"] == run.id
    end
  end

  test "checksums and authoritative run links cannot be replaced by output maps" do
    run = source!()
    [artifact] = Ash.load!(run, :derived_artifacts).derived_artifacts
    Agent.update(BrusselsWtf.Archive.Memory, &Map.put(&1, artifact.object_key, "corrupted"))

    assert {:ok, %{job_count: 0, runs: [%{eligible: false}]}} =
             Discovery.preview([run.id], actor: @actor, max_jobs: 8)

    assert {:error, :ineligible_or_empty_batch} =
             Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)

    Agent.update(BrusselsWtf.Archive.Memory, &Map.put(&1, artifact.object_key, @text))
    assert {:ok, %{job_count: 1}} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)

    Repo.query!("DELETE FROM processing_run_artifacts WHERE processing_run_id = $1", [
      Ecto.UUID.dump!(run.id)
    ])

    assert {:ok, %{job_count: 0}} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)
  end

  test "shared content-addressed artifacts use the run link rather than originating source ownership" do
    run = source!()
    old_version = Ingestion.get_source_version!(run.source_version_id)
    record = Ingestion.get_source_record!(old_version.source_record_id)

    other_record =
      Ingestion.upsert_source_record!(%{
        commune_id: record.commune_id,
        origin_url: record.origin_url <> "?copy=1",
        role: record.role,
        original_language: :fr
      })

    meeting =
      BrusselsWtf.Council.upsert_meeting!(%{
        commune_id: record.commune_id,
        municipal_identifier: "copy",
        scheduled_on: ~D[2024-01-01]
      })

    Ingestion.link_source_record_to_meeting!(other_record, %{council_meeting_id: meeting.id})

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: other_record.id,
        sha256: old_version.sha256,
        byte_size: old_version.byte_size,
        media_type: old_version.media_type,
        object_key: old_version.object_key,
        first_retrieved_at: old_version.first_retrieved_at
      })

    copied =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        processor_name: run.processor_name,
        processor_version: run.processor_version,
        config_hash: run.config_hash,
        processor_role: run.processor_role,
        status: :succeeded,
        quality_measurements: run.quality_measurements,
        completed_at: run.completed_at
      })

    [artifact] = Ash.load!(run, :derived_artifacts).derived_artifacts

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: copied.id,
      derived_artifact_id: artifact.id,
      role: :native_output
    })

    assert {:ok, %{job_count: 1}} = Discovery.preview([copied.id], actor: @actor, max_jobs: 8)
  end

  test "dates, uncertain context and excluded source roles fail closed" do
    run = source!()
    version = Ingestion.get_source_version!(run.source_version_id)
    record = Ingestion.get_source_record!(version.source_record_id)

    for role <- [:mandate_declaration, :gazette_annex, :supporting_document] do
      Ingestion.reclassify_source_record!(record, %{role: role})
      assert {:ok, %{job_count: 0}} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)
    end

    Ingestion.reclassify_source_record!(record, %{role: :agenda})

    Repo.query!("UPDATE source_locators SET scheduled_on = '2023-12-31' WHERE url = $1", [
      record.origin_url
    ])

    assert {:ok, %{job_count: 0}} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)

    Repo.query!("UPDATE source_locators SET scheduled_on = NULL WHERE url = $1", [
      record.origin_url
    ])

    assert {:ok, %{job_count: 0}} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)
  end

  test "run chunks, explicit batch cap and measured exclusions are bounded" do
    text = Enum.map_join(1..600, "\n", &"Élodie D’Haene présente le projet numéro #{&1}.")
    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    assert {:error, :explicit_batch_cap_required} = Discovery.enqueue([run.id], actor: @actor)
    assert {:error, :batch_cap_exceeded} = Discovery.preview([run.id], actor: @actor, max_jobs: 7)

    assert {:ok, %{job_count: 8, runs: [%{measurements: counts}]}} =
             Discovery.preview([run.id], actor: @actor, max_jobs: 8)

    assert counts["omitted_chunk_lines"] == 120
    assert {:ok, batch} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    assert {:error, :reviewer_required} = Discovery.status(batch.batch_id)
    assert {:error, :reviewer_required} = Discovery.pause()
    assert {:ok, %{paused: 8}} = Discovery.pause(actor: @actor)
    assert request("/internal/discovery/claim", %{}) |> response(204)
    assert {:ok, %{resumed: 8}} = Discovery.resume(actor: @actor)
    assert request("/internal/discovery/claim", %{}) |> json_response(200)
  end

  test "three executions exhaust retries even after operator pause/resume" do
    run = source!()
    {:ok, batch} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)

    receipts =
      for attempt <- 1..3 do
        claim = request("/internal/discovery/claim", %{}) |> json_response(200)
        payload = %{"lease_token" => claim["lease_token"], "reason" => "timeout"}
        path = "/internal/discovery/#{claim["id"]}/fail"
        ack = request(path, payload) |> json_response(200)
        assert request("/internal/discovery/claim", %{}) |> response(204)
        advance(61 * attempt)
        {path, payload, ack}
      end

    terminal = Discovery.status(batch.batch_id, actor: @actor)

    for {path, payload, ack} <- receipts do
      assert request(path, payload) |> json_response(200) == ack
    end

    assert Discovery.status(batch.batch_id, actor: @actor) == terminal
    [job] = Ash.read!(Discovery.Job, authorize?: false)
    assert length(job.failure_receipts) == 3

    for {_path, payload, _ack} <- receipts do
      refute Jason.encode!(job.failure_receipts) =~ payload["lease_token"]
    end

    assert {:ok, %{jobs: [%{state: :failed, attempts: 3, failure_reason: "timeout"}]}} =
             Discovery.status(batch.batch_id, actor: @actor)

    assert {:ok, %{resumed: 0}} = Discovery.resume(actor: @actor)
    assert request("/internal/discovery/claim", %{}) |> response(204)

    assert {:ok, %{counts: %{failed: 1}, failures: [%{failure_reason: "timeout", attempts: 3}]}} =
             Discovery.sweep_status(actor: @actor)
  end

  test "ambiguous occurrences, partial names, invalid processor and excess keys are rejected without logging payloads" do
    run =
      source!(
        "ixelles/proposal",
        :agenda,
        :native_extraction,
        String.replace(
          @text,
          "\n\nCourriel",
          "\nÉlodie D’Haene et Élodie D’Haene sont présentes.\n\nCourriel"
        )
      )

    {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)
    payload = result(claim)
    line = Enum.find(claim["input"]["lines"], &String.contains?(&1["text"], " et Élodie"))

    bads = [
      put_in(payload, ["result", "mentions", Access.at(0), "text"], "lodie"),
      put_in(payload, ["result", "mentions"], [
        %{
          "kind" => "person",
          "text" => "Élodie D’Haene",
          "quote" => line["text"],
          "line_id" => line["id"]
        }
      ]),
      put_in(payload, ["processor", "name"], "unknown"),
      Map.put(payload, "id", claim["id"]),
      put_in(
        payload,
        ["result", "mentions"],
        payload["result"]["mentions"] ++
          [Map.put(hd(payload["result"]["mentions"]), "kind", "organization")]
      )
    ]

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        Enum.each(bads, fn bad ->
          assert request("/internal/discovery/#{claim["id"]}/result", bad) |> response(422)
        end)

        assert request("/internal/discovery/#{claim["id"]}/result", payload) |> json_response(200)
      end)

    refute log =~ "Élodie"
    refute log =~ claim["lease_token"]
    refute log =~ @token

    assert build_conn()
           |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
           |> get("/review/artifacts/derived/#{Ash.UUID.generate()}")
           |> response(302)

    assert Discovery.enqueue([run.id], actor: %{id: "worker", role: :machine}, max_jobs: 8) ==
             {:error, :reviewer_required}
  end

  test "discovery completion leaves an existing published meeting revision and public identities unchanged" do
    run = source!()
    Harness.drain_pipeline(from: :ocr)
    pages = Ash.read!(BrusselsWtf.Council.MeetingPage)
    assert Enum.any?(pages, &(&1.publication_status == :published))
    revisions = Ash.read!(BrusselsWtf.Council.PublicationRevision)
    isolate_sweep_run!(run)
    {:ok, _} = Discovery.enable_sweep(actor: @actor)
    assert {:ok, %{new_jobs: 1}} = Discovery.sweep_tick()
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)

    assert request("/internal/discovery/#{claim["id"]}/result", result(claim))
           |> json_response(200)

    assert Ash.read!(BrusselsWtf.Council.MeetingPage) == pages
    assert Ash.read!(BrusselsWtf.Council.PublicationRevision) == revisions
    html = get(build_conn(), "/") |> html_response(200)
    refute html =~ "Élodie D’Haene"
    assert Identity.list_public_relationships!() == []
  end

  @tag :independent_connections
  test "overlapping batches and simultaneous HTTP claims converge across independent DB connections" do
    text = Enum.map_join(1..70, "\n", &"Élodie D’Haene présente le projet numéro #{&1}.")
    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    repo = Repo.get_dynamic_repo()

    batches =
      for _ <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
        end)
      end
      |> Task.await_many(30_000)

    assert Enum.all?(batches, &match?({:ok, _}, &1))

    assert batches |> Enum.map(fn {:ok, batch} -> batch.job_ids end) |> Enum.uniq() |> length() ==
             1

    claims =
      for _ <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          request("/internal/discovery/claim", %{})
        end)
      end
      |> Task.await_many(30_000)

    assert Enum.count(claims, &(&1.status == 200)) == 1
    assert Enum.count(claims, &(&1.status == 204)) == 3
    claim = claims |> Enum.find(&(&1.status == 200)) |> json_response(200)

    submissions =
      for _ <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          request("/internal/discovery/#{claim["id"]}/result", result(claim))
        end)
      end
      |> Task.await_many(30_000)

    assert Enum.all?(submissions, &(&1.status == 200))
    assert Ash.count!(Identity.Mention) == 1
  end

  test "a unique quote locates a repeated name and minimum length counts Unicode code points" do
    text =
      "Élodie D’Haene présente le projet de l’ASBL Élan.\n" <>
        "Alice Dupont préside; Alice Dupont intervient.\n" <>
        "Alice Dupont préside; Alice Dupont préside.\n" <>
        "E\u0301 intervient.\nAE\u0301 témoigne."

    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)

    alice = %{
      "kind" => "person",
      "text" => "Alice Dupont",
      "line_id" => "p1-l2",
      "quote" => "Alice Dupont préside"
    }

    decomposed = %{
      "kind" => "person",
      "text" => "E\u0301",
      "line_id" => "p1-l4",
      "quote" => "E\u0301 intervient"
    }

    payload = result(claim) |> put_in(["result", "mentions"], [alice, decomposed])
    path = "/internal/discovery/#{claim["id"]}/result"

    for invalid <- [
          [Map.put(alice, "line_id", "p1-l3")],
          [alice, Map.put(alice, "quote", "Alice Dupont intervient")],
          [Map.put(alice, "text", "Alice Dupon")],
          [
            %{
              "kind" => "person",
              "text" => "AE",
              "line_id" => "p1-l5",
              "quote" => "AE\u0301 témoigne"
            }
          ]
        ] do
      assert request(path, put_in(payload, ["result", "mentions"], invalid)) |> response(422)
    end

    assert Ash.count!(Identity.Mention) == 0
    assert request(path, payload) |> json_response(200)

    assert Enum.sort(Enum.map(Ash.read!(Identity.Mention), & &1.text)) == [
             "Alice Dupont",
             "E\u0301"
           ]
  end

  test "page mapping and decomposed Unicode remain exact, not normalized or fuzzy" do
    name = "E\u0301lodie Van der Meer"

    text =
      "Élodie D’Haene présente le projet de l’ASBL Élan.\n\n" <>
        "Domicile:\n12 Drève des Saules\n1180 Uccle\n\n" <>
        "\fSÉANCE PUBLIQUE\n#{name} témoigne devant le conseil communal.\n\nHUIS CLOS\nPrivate Example est présent."

    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    {:ok, preview} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)

    assert hd(preview.runs).measurements["excluded_lines"] == %{
             "sensitive_block" => 3,
             "blank_line" => 4,
             "private_session" => 2
           }

    {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)
    line = Enum.find(claim["input"]["lines"], &(&1["id"] == "p2-l2"))

    payload =
      result(claim)
      |> put_in(["result", "mentions"], [
        %{"kind" => "person", "text" => name, "line_id" => line["id"], "quote" => line["text"]}
      ])

    fuzzy =
      put_in(payload, ["result", "mentions", Access.at(0), "text"], String.normalize(name, :nfc))

    assert request("/internal/discovery/#{claim["id"]}/result", fuzzy) |> response(422)
    assert request("/internal/discovery/#{claim["id"]}/result", payload) |> json_response(200)
    [mention] = Ash.read!(Identity.Mention)
    assert mention.text == name
    assert mention.context["line_id"] == "p2-l2"
  end

  test "body bounds and strict protocol reject excess data before inference" do
    assert_error_sent 413, fn ->
      request("/internal/discovery/claim", %{"padding" => String.duplicate("x", 140_000)})
    end

    assert request("/internal/discovery/claim", %{"unexpected" => true}) |> response(422)
    assert {:error, :unauthorized} = Discovery.claim("invalid")
    assert {:error, :unauthorized} = Discovery.submit(Ash.UUID.generate(), %{}, "invalid")
    assert {:error, :unauthorized} = Discovery.fail(Ash.UUID.generate(), %{}, "invalid")
    run = source!()
    assert {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    assert {:ok, []} = Ash.read(Discovery.Job)
  end

  for heading <- ["HUIS CLOS", "Séance\nnon publique", "Besloten\nzitting", "Geheime\nzitting"] do
    test "private-session #{inspect(heading)} excludes its entire heading and later paragraphs" do
      heading = unquote(heading)
      heading_lines = length(String.split(heading, "\n"))

      text =
        "SÉANCE PUBLIQUE\nÉlodie D’Haene présente le projet de l’ASBL Élan.\n\n" <>
          heading <>
          "\nLe président rappelle la décision prise en séance publique.\n\n" <>
          "Jean Dupont demande une aide individuelle.\n\nSÉANCE PUBLIQUE\n" <>
          "Marie Martin demande une aide individuelle.\fOpenbare zitting\nJan Janssens vraagt steun."

      run = source!("ixelles/proposal", :agenda, :native_extraction, text)
      {:ok, preview} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)

      assert hd(preview.runs).measurements["excluded_lines"]["private_session"] ==
               8 + heading_lines

      {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
      claim = request("/internal/discovery/claim", %{}) |> json_response(200)
      assert Enum.map(claim["input"]["lines"], & &1["id"]) == ["p1-l1", "p1-l2"]

      payload =
        result(claim)
        |> put_in(["result", "mentions"], [
          %{
            "kind" => "person",
            "text" => "Jean Dupont",
            "line_id" => "p1-l#{heading_lines + 6}",
            "quote" => "Jean Dupont demande une aide individuelle."
          }
        ])

      assert request("/internal/discovery/#{claim["id"]}/result", payload) |> response(422)

      assert request("/internal/discovery/#{claim["id"]}/result", result(claim))
             |> json_response(200)

      assert Enum.map(Ash.read!(Identity.Mention), & &1.text) == ["Élodie D’Haene"]
    end
  end

  for {scenario, source, role} <- [
        {"ixelles/proposal", :agenda, :native_extraction},
        {"uccle/end-to-end", :explanatory_note, :ocr}
      ] do
    test "#{role} excludes complete French/Dutch sensitive blocks including continuation lines" do
      blocks = [
        "Jean Dupont\nDomicile:\n12 Drève des Saules\n1180 Uccle",
        "Revenus imposables de Jean Dupont : 35 000 EUR\nPersonne à charge :\nMarie Martin",
        "Salaires annuels\nPierre Lambert\n25 000 EUR",
        "Jan Janssens\nWoonadres:\n12 Lindendreef\n1180 Ukkel",
        "Belastbare inkomsten\nPieter Peeters\nLonen: 25 000 EUR",
        "Date de naissance:\nAlice Laurent\n12 janvier 1980",
        "Geboortedatum:\nEls Vermeulen\n12 januari 1980",
        "Composition de ménage\nPaul Laurent\nGezinsleden:\nAnna Peeters",
        "NISS:\nLuc Martin\nIdentiteitskaart:\n123456789012"
      ]

      text =
        "SÉANCE PUBLIQUE\nÉlodie D’Haene présente le projet de l’ASBL Élan.\n\n" <>
          Enum.join(blocks, "\n\n") <> "\n\nDe vereniging Groene Toekomst neemt deel."

      run = source!(unquote(scenario), unquote(source), unquote(role), text)
      {:ok, preview} = Discovery.preview([run.id], actor: @actor, max_jobs: 8)
      excluded = Enum.sum(Enum.map(blocks, &length(String.split(&1, "\n"))))
      assert hd(preview.runs).measurements["excluded_lines"]["sensitive_block"] == excluded
      {:ok, _} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
      claim = request("/internal/discovery/claim", %{}) |> json_response(200)

      assert Enum.map(claim["input"]["lines"], & &1["text"]) == [
               "SÉANCE PUBLIQUE",
               "Élodie D’Haene présente le projet de l’ASBL Élan.",
               "De vereniging Groene Toekomst neemt deel."
             ]

      payload =
        result(claim)
        |> put_in(["result", "mentions"], [
          %{
            "kind" => "person",
            "text" => "Jean Dupont",
            "line_id" => "p1-l4",
            "quote" => "Jean Dupont"
          }
        ])

      assert request("/internal/discovery/#{claim["id"]}/result", payload) |> response(422)

      assert request("/internal/discovery/#{claim["id"]}/result", result(claim))
             |> json_response(200)

      assert Ash.count!(Identity.Mention) == 1
    end
  end

  test "explicit offsets reach later chunks without resetting absolute identities or batch caps" do
    text = Enum.map_join(1..600, "\n", &"Élodie D’Haene présente le projet numéro #{&1}.")
    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    opts = [actor: @actor, max_jobs: 8, chunk_offset: 0]
    {:ok, first} = Discovery.enqueue([run.id], opts)
    assert hd(first.runs).measurements["next_chunk_offset"] == 8
    assert hd(first.runs).measurements["has_more"] == true
    {:ok, preview} = Discovery.preview([run.id], Keyword.put(opts, :chunk_offset, 8))
    assert Enum.map(preview.jobs, & &1.chunk) == [8, 9]
    assert hd(preview.jobs).lines |> hd() |> Map.fetch!("id") == "p1-l481"
    assert hd(preview.runs).measurements["next_chunk_offset"] == nil
    assert hd(preview.runs).measurements["has_more"] == false
    {:ok, second} = Discovery.enqueue([run.id], Keyword.put(opts, :chunk_offset, 8))
    {:ok, repeated} = Discovery.enqueue([run.id], Keyword.put(opts, :chunk_offset, 8))
    assert repeated.job_ids == second.job_ids
    {:ok, overlap} = Discovery.enqueue([run.id], Keyword.put(opts, :chunk_offset, 7))
    assert overlap.job_ids == [List.last(first.job_ids) | second.job_ids]

    for offset <- [-1, 100_001, "8", nil] do
      assert {:error, :invalid_chunk_offset} =
               Discovery.preview([run.id], Keyword.put(opts, :chunk_offset, offset))

      assert {:error, :invalid_chunk_offset} =
               Discovery.enqueue([run.id], Keyword.put(opts, :chunk_offset, offset))
    end

    assert {:error, :batch_cap_exceeded} =
             Discovery.enqueue([run.id], actor: @actor, max_jobs: 1, chunk_offset: 8)

    {:ok, beyond} = Discovery.preview([run.id], Keyword.put(opts, :chunk_offset, 10))
    assert beyond.job_count == 0
    refute hd(beyond.runs).measurements["has_more"]

    for _ <- 1..10 do
      claim = request("/internal/discovery/claim", %{}) |> json_response(200)

      assert request("/internal/discovery/#{claim["id"]}/result", result(claim))
             |> json_response(200)
    end

    assert request("/internal/discovery/claim", %{}) |> response(204)
    assert Ash.read!(Identity.Mention) |> Enum.any?(&(&1.context["line_id"] == "p1-l481"))
    assert Ash.count!(Identity.Mention) == 10
  end

  test "lost failure acknowledgments replay across new leases and completion without mutation" do
    run = source!()
    {:ok, batch} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    first = request("/internal/discovery/claim", %{}) |> json_response(200)
    fail_path = "/internal/discovery/#{first["id"]}/fail"
    failure = %{"lease_token" => first["lease_token"], "reason" => "unavailable"}
    ack = request(fail_path, failure) |> json_response(200)
    assert request(fail_path, failure) |> json_response(200) == ack
    assert request(fail_path, Map.put(failure, "reason", "timeout")) |> response(409)
    advance(61)
    second = request("/internal/discovery/claim", %{}) |> json_response(200)
    before_replay = Discovery.status(batch.batch_id, actor: @actor)
    assert request(fail_path, failure) |> json_response(200) == ack
    assert Discovery.status(batch.batch_id, actor: @actor) == before_replay
    quota = %{"lease_token" => second["lease_token"], "reason" => "quota"}
    quota_ack = request(fail_path, quota) |> json_response(200)
    assert request(fail_path, quota) |> json_response(200) == quota_ack
    Discovery.resume(actor: @actor)
    third = request("/internal/discovery/claim", %{}) |> json_response(200)
    before_replay = Discovery.status(batch.batch_id, actor: @actor)
    assert request(fail_path, failure) |> json_response(200) == ack
    assert request(fail_path, quota) |> json_response(200) == quota_ack
    assert Discovery.status(batch.batch_id, actor: @actor) == before_replay

    assert request("/internal/discovery/#{third["id"]}/result", result(third))
           |> json_response(200)

    completed = Discovery.status(batch.batch_id, actor: @actor)
    assert request(fail_path, failure) |> json_response(200) == ack
    assert request(fail_path, quota) |> json_response(200) == quota_ack
    assert Discovery.status(batch.batch_id, actor: @actor) == completed
    assert Ash.count!(Identity.Mention) == 1
  end

  test "operator candidates are authorized, bounded, cursor ordered and contain only safe summaries" do
    run = source!()

    ocr =
      Ingestion.record_processing_run!(%{
        source_version_id: run.source_version_id,
        processor_name: "candidate-ocr",
        processor_version: "1",
        config_hash: "candidate-test",
        processor_role: :ocr,
        status: :succeeded,
        quality_measurements: %{"accepted" => true}
      })

    rejected =
      for {role, status, quality} <- [
            {:native_extraction, :failed, true},
            {:ocr, :queued, true},
            {:native_extraction, :succeeded, false},
            {:ocr, :succeeded, "true"},
            {:relationship_verification, :succeeded, true}
          ] do
        Ingestion.record_processing_run!(%{
          source_version_id: run.source_version_id,
          processor_name: "candidate-negative-#{Ash.UUID.generate()}",
          processor_version: "1",
          config_hash: "candidate-test",
          processor_role: role,
          status: status,
          quality_measurements: %{"accepted" => quality}
        }).id
      end

    assert {:error, :reviewer_required} = Discovery.candidates(limit: 1)

    assert {:error, :reviewer_required} =
             Discovery.candidates(actor: %{id: "worker", role: :machine}, limit: 1)

    for limit <- [nil, 0, 21, "1"] do
      assert {:error, :invalid_limit} = Discovery.candidates(actor: @actor, limit: limit)
    end

    assert {:error, :invalid_limit} = Discovery.candidates(actor: @actor)

    assert {:error, :invalid_commune} =
             Discovery.candidates(actor: @actor, limit: 1, commune: "anderlecht")

    assert {:error, :invalid_cursor} =
             Discovery.candidates(actor: @actor, limit: 1, cursor: "not-a-run-id")

    {:ok, all} = Discovery.candidates(actor: @actor, limit: 20)
    ids = Enum.map(all.candidates, & &1.run_id)
    assert ids == Enum.sort(ids)
    assert run.id in ids
    assert ocr.id in ids
    refute Enum.any?(rejected, &(&1 in ids))
    assert all.next_cursor == nil

    assert Enum.all?(all.candidates, fn candidate ->
             Enum.sort(Map.keys(candidate)) ==
               Enum.sort([:run_id, :source_version_id, :commune, :source_role, :origin_url]) and
               candidate.commune == "ixelles" and
               String.starts_with?(candidate.origin_url, "https://www.ixelles.be/")
           end)

    {:ok, first} = Discovery.candidates(actor: @actor, limit: 1, commune: "ixelles")
    assert [%{run_id: first_id}] = first.candidates
    assert first_id == hd(ids)
    assert first.next_cursor == first_id
    {:ok, rest} = Discovery.candidates(actor: @actor, limit: 20, cursor: first.next_cursor)
    assert Enum.map(rest.candidates, & &1.run_id) == tl(ids)
    assert rest.next_cursor == nil
    {:ok, rejected_page} = Discovery.candidates(actor: @actor, limit: 1, cursor: ocr.id)
    assert rejected_page.candidates == []
    assert is_binary(rejected_page.next_cursor)
    assert rejected_page.next_cursor > ocr.id
    {:ok, empty} = Discovery.candidates(actor: @actor, limit: 20, cursor: List.last(ids))
    assert empty == %{candidates: [], next_cursor: nil}

    for commune <- ["uccle", "forest", "city-of-brussels"] do
      assert {:ok, %{candidates: [], next_cursor: nil}} =
               Discovery.candidates(actor: @actor, limit: 20, commune: commune)
    end

    assert Ash.count!(Discovery.Job, authorize?: false) == 0
    assert Ash.count!(Identity.Mention) == 0
  end

  test "sweep is opt-in, bounded, audited and manual holds survive an empty queue" do
    run = source!()
    assert {:ok, %{reason: :disabled, new_jobs: 0}} = Discovery.sweep_tick()
    assert {:error, :reviewer_required} = Discovery.enable_sweep()

    for options <- [
          [max_runs: 5],
          [max_jobs: 9],
          [max_unfinished: 65],
          [daily_jobs: 501],
          [daily_jobs: 0]
        ] do
      assert {:error, :invalid_sweep_limits} = Discovery.enable_sweep([actor: @actor] ++ options)
    end

    assert {:ok, _} = Discovery.pause(actor: @actor)
    assert {:ok, _} = Discovery.enable_sweep(actor: @actor)
    assert {:ok, %{reason: :paused}} = Discovery.sweep_tick()
    assert {:error, :discovery_paused} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    assert {:ok, nil} = Discovery.claim(@token)
    assert {:ok, %{control: %{hold: "operator_pause"}}} = Discovery.sweep_status(actor: @actor)
    assert {:ok, _} = Discovery.resume(actor: @actor)
    assert {:ok, %{examined: 1, new_jobs: 1}} = Discovery.sweep_tick()
    assert {:ok, report} = Discovery.sweep_status(actor: @actor)
    assert report.control.daily_jobs == 12
    assert report.control.day_used == 1
    assert report.counts.eligible == 1
    assert report.counts.queued == 1
    assert Enum.any?(report.events, &(&1.operation == "pause" and &1.actor_id == "rico"))
    assert {:error, :reviewer_required} = Discovery.sweep_status()
  end

  test "sweep resumes absolute chunk progress, counts only new jobs and retains UTC budget" do
    text = Enum.map_join(1..900, "\n", &"Élodie D’Haene présente le projet numéro #{&1}.")
    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    isolate_sweep_run!(run)
    assert {:ok, _} = Discovery.enable_sweep(actor: @actor)
    assert {:ok, %{new_jobs: 8}} = Discovery.sweep_tick()
    assert {:ok, %{new_jobs: 4}} = Discovery.sweep_tick()
    assert {:ok, %{reason: :daily_budget, new_jobs: 0}} = Discovery.sweep_tick()
    assert {:ok, report} = Discovery.sweep_status(actor: @actor)
    assert [%{next_chunk: 12, total_chunks: 15}] = report.runs
    assert report.control.day_used == 12
    Discovery.pause(actor: @actor)
    Discovery.resume(actor: @actor)
    assert {:ok, %{reason: :daily_budget}} = Discovery.sweep_tick()

    assert {:error, :daily_budget} =
             Discovery.enqueue([run.id], actor: @actor, max_jobs: 8, chunk_offset: 12)

    advance(86_400)
    assert {:ok, %{new_jobs: 3}} = Discovery.sweep_tick()
    assert {:ok, %{new_jobs: 0}} = Discovery.sweep_tick()
    assert Ash.count!(Discovery.Job, authorize?: false) == 15

    for _ <- 1..15 do
      claim = request("/internal/discovery/claim", %{}) |> json_response(200)

      assert request("/internal/discovery/#{claim["id"]}/result", result(claim))
             |> json_response(200)
    end

    assert {:ok, %{new_jobs: 0}} = Discovery.sweep_tick()
    assert {:ok, report} = Discovery.sweep_status(actor: @actor)
    assert report.counts.completed == 15
    assert report.counts.mention_occurrences == 15
    assert report.counts.unique_mention_names == 1
    assert report.counts.repeated_mention_names == 14
    assert Ash.count!(Identity.Person) == 0
    assert Ash.count!(Identity.SourcedFact) == 0
  end

  test "bounded cycles pass twenty runs and revisit an old newly accepted generation" do
    first = source!()
    isolate_sweep_run!(first)
    old = copy_generation!(first, :queued)
    for _ <- 1..23, do: copy_generation!(first)
    Discovery.enable_sweep(actor: @actor, daily_jobs: 100)

    for _ <- 1..26 do
      assert {:ok, %{examined: examined, new_jobs: jobs}} = Discovery.sweep_tick()
      assert examined <= 4 and jobs <= 8
    end

    assert Ash.count!(Discovery.Job, authorize?: false) == 24

    Ingestion.complete_processing_run!(old, %{
      status: :succeeded,
      quality_measurements: first.quality_measurements
    })

    for _ <- 1..26, do: Discovery.sweep_tick()
    assert Ash.count!(Discovery.Job, authorize?: false) == 25
    assert {:ok, report} = Discovery.sweep_status(actor: @actor)
    assert length(report.runs) == 25
    assert Enum.all?(report.runs, &(&1.next_chunk == 1))
  end

  test "sweep exclusions and quality failures remain durable and empty quota holds block admission" do
    run = source!()
    version = Ingestion.get_source_version!(run.source_version_id)
    record = Ingestion.get_source_record!(version.source_record_id)

    Repo.query!("UPDATE source_locators SET scheduled_on = NULL WHERE url = $1", [
      record.origin_url
    ])

    Discovery.enable_sweep(actor: @actor)
    assert {:ok, %{excluded: 1, new_jobs: 0}} = Discovery.sweep_tick()
    assert {:ok, report} = Discovery.sweep_status(actor: @actor)
    assert [%{skip_reason: "uncertain_meeting_context"}] = report.runs

    Repo.query!("UPDATE source_locators SET scheduled_on = '2024-01-01' WHERE url = $1", [
      record.origin_url
    ])

    assert {:ok, %{new_jobs: 1}} = Discovery.sweep_tick()
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)

    assert request("/internal/discovery/#{claim["id"]}/fail", %{
             "lease_token" => claim["lease_token"],
             "reason" => "quota"
           })
           |> json_response(200)

    Repo.query!("DELETE FROM discovery_jobs")
    assert {:ok, %{reason: :paused}} = Discovery.sweep_tick()
    assert {:error, :discovery_paused} = Discovery.enqueue([run.id], actor: @actor, max_jobs: 8)
    assert {:ok, nil} = Discovery.claim(@token)
    assert {:ok, %{control: %{hold: "quota"}}} = Discovery.sweep_status(actor: @actor)
  end

  test "one run per commune is examined per tick, with rotating admission priority" do
    text = Enum.map_join(1..600, "\n", &"Élodie D’Haene présente le projet numéro #{&1}.")

    {runs, _archive} =
      Enum.reduce(
        [
          {"ixelles/proposal", :agenda, :native_extraction},
          {"uccle/end-to-end", :explanatory_note, :ocr},
          {"forest/end-to-end", :agenda, :native_extraction},
          {"city_of_brussels/end-to-end", :agenda, :native_extraction}
        ],
        {[], %{}},
        fn {scenario, name, role}, {runs, archive} ->
          run = source!(scenario, name, role, text)
          archive = Map.merge(archive, Agent.get(BrusselsWtf.Archive.Memory, & &1))
          Agent.update(BrusselsWtf.Archive.Memory, fn _ -> archive end)
          {[run | runs], archive}
        end
      )

    ids = Enum.map(runs, &Ecto.UUID.dump!(&1.id))
    Repo.query!("UPDATE processing_runs SET status = 'failed' WHERE NOT (id = ANY($1))", [ids])
    Discovery.enable_sweep(actor: @actor, daily_jobs: 100)

    for _ <- 1..4 do
      assert {:ok, %{examined: 4, new_jobs: count}} = Discovery.sweep_tick()
      assert count <= 8
    end

    jobs = Ash.read!(Discovery.Job, authorize?: false)

    assert jobs |> Enum.map(& &1.source_context["commune"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(city-of-brussels forest ixelles uccle)

    for _ <- 1..4, do: Discovery.sweep_tick()
    assert Ash.count!(Discovery.Job, authorize?: false) == 40
    assert {:ok, report} = Discovery.sweep_status(actor: @actor)
    assert report.counts.fully_admitted == 4
    assert Ash.count!(Identity.Person) == 0
    assert Ash.count!(BrusselsWtf.Council.PublicationRevision) == 0
  end

  test "64 unfinished jobs is a global bound including a leased job, and completion frees one slot" do
    text = Enum.map_join(1..4800, "\n", &"Élodie D’Haene présente le projet numéro #{&1}.")
    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    isolate_sweep_run!(run)
    Discovery.enable_sweep(actor: @actor, daily_jobs: 100)
    for _ <- 1..8, do: assert({:ok, %{new_jobs: 8}} = Discovery.sweep_tick())
    _claim = request("/internal/discovery/claim", %{}) |> json_response(200)
    assert {:ok, %{reason: :backpressure}} = Discovery.sweep_tick()

    assert {:error, :backpressure} =
             Discovery.enqueue([run.id], actor: @actor, max_jobs: 8, chunk_offset: 64)

    Discovery.pause(actor: @actor)

    assert {:ok, %{control: %{day_used: 64}, counts: %{paused: 64}}} =
             Discovery.sweep_status(actor: @actor)

    Discovery.resume(actor: @actor)
    assert {:ok, %{reason: :backpressure}} = Discovery.sweep_tick()
    claim = request("/internal/discovery/claim", %{}) |> json_response(200)

    assert request("/internal/discovery/#{claim["id"]}/result", result(claim))
           |> json_response(200)

    assert {:ok, %{new_jobs: 1}} = Discovery.sweep_tick()
    assert {:ok, %{reason: :backpressure}} = Discovery.sweep_tick()
    assert Ash.count!(Discovery.Job, authorize?: false) == 65
  end

  for {scenario, name, role} <- [
        {"ixelles/proposal", :agenda, :native_extraction},
        {"uccle/end-to-end", :explanatory_note, :ocr}
      ] do
    test "sweep rejects malformed #{role} quality on both run and authoritative artifact" do
      run = source!(unquote(scenario), unquote(name), unquote(role))
      isolate_sweep_run!(run)

      artifact =
        Ash.load!(run, :derived_artifacts).derived_artifacts
        |> Enum.find(&(&1.output_kind in ["native-text", "ocr-text"]))

      Discovery.enable_sweep(actor: @actor)

      for malformed <- [%{}, %{"accepted" => "true"}, %{"accepted" => 1}, %{"accepted" => false}] do
        Repo.query!("UPDATE processing_runs SET quality_measurements = $1 WHERE id = $2", [
          malformed,
          Ecto.UUID.dump!(run.id)
        ])

        assert {:ok, %{excluded: 1, new_jobs: 0}} = Discovery.sweep_tick()
      end

      Repo.query!("UPDATE processing_runs SET quality_measurements = $1 WHERE id = $2", [
        run.quality_measurements,
        Ecto.UUID.dump!(run.id)
      ])

      Repo.query!("UPDATE derived_artifacts SET quality_measurements = $1 WHERE id = $2", [
        %{"accepted" => "true"},
        Ecto.UUID.dump!(artifact.id)
      ])

      assert {:ok, %{excluded: 1, new_jobs: 0}} = Discovery.sweep_tick()

      assert {:ok, %{runs: [%{skip_reason: "missing_authoritative_text"}]}} =
               Discovery.sweep_status(actor: @actor)

      assert Ash.count!(Discovery.Job, authorize?: false) == 0
    end
  end

  test "all-private text and old meeting dates retain exclusions without creating jobs" do
    text =
      "HUIS CLOS\n" <>
        String.duplicate("Le conseil examine la demande de soutien communal.\n", 20)

    run = source!("ixelles/proposal", :agenda, :native_extraction, text)
    isolate_sweep_run!(run)
    Discovery.enable_sweep(actor: @actor)
    assert {:ok, %{excluded: 1, new_jobs: 0}} = Discovery.sweep_tick()

    assert {:ok, %{runs: [%{skip_reason: "no_eligible_lines", measurements: measurements}]}} =
             Discovery.sweep_status(actor: @actor)

    assert measurements["excluded_lines"]["private_session"] > 0
    Repo.query!("UPDATE source_locators SET scheduled_on = '2023-12-31'")
    assert {:ok, %{excluded: 1, new_jobs: 0}} = Discovery.sweep_tick()

    assert {:ok, %{runs: [%{skip_reason: "ineligible_date"}]}} =
             Discovery.sweep_status(actor: @actor)

    assert Ash.count!(Discovery.Job, authorize?: false) == 0
  end

  test "stored lower limits govern ticks and maintenance never changes another queue" do
    run = source!()
    isolate_sweep_run!(run)
    copy_generation!(run)
    queued = Repo.query!("SELECT id, state FROM oban_jobs ORDER BY id").rows
    assert :ok = BrusselsWtf.Workers.SweepPrivateDiscovery.perform(%Oban.Job{})
    assert Ash.count!(Discovery.Job, authorize?: false) == 0

    Discovery.enable_sweep(
      actor: @actor,
      max_runs: 1,
      max_jobs: 1,
      max_unfinished: 1,
      daily_jobs: 2
    )

    Discovery.enable_sweep(actor: @actor)
    assert :ok = BrusselsWtf.Workers.SweepPrivateDiscovery.perform(%Oban.Job{})
    assert {:ok, %{reason: :backpressure}} = Discovery.sweep_tick()

    assert {:ok,
            %{control: %{max_runs: 1, max_jobs: 1, max_unfinished: 1, daily_jobs: 2, day_used: 1}}} =
             Discovery.sweep_status(actor: @actor)

    assert Repo.query!("SELECT id, state FROM oban_jobs ORDER BY id").rows == queued
    assert Ash.read!(Discovery.SweepState) == []
    assert Ash.read!(Discovery.SweepRun) == []
    assert Ash.read!(Discovery.SweepEvent) == []
    assert {:error, :invalid_cursor} = Discovery.sweep_status(actor: @actor, cursor: "bad")
  end

  defmodule WaitingArchive do
    def get(key) do
      send(
        Application.fetch_env!(:brussels_wtf, :discovery_archive_test_owner),
        {:archive_read, self()}
      )

      receive do
        :continue -> BrusselsWtf.Archive.Memory.get(key)
      after
        5_000 -> {:error, :test_timeout}
      end
    end
  end

  @tag :independent_connections
  test "pause commits during archive IO and invalidates the prepared cursor; restart and racing ticks converge" do
    run = source!()
    isolate_sweep_run!(run)
    Discovery.enable_sweep(actor: @actor)
    repo = Repo.get_dynamic_repo()
    previous = Application.get_env(:brussels_wtf, :archive)
    Application.put_env(:brussels_wtf, :archive, WaitingArchive)
    Application.put_env(:brussels_wtf, :discovery_archive_test_owner, self())

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :archive, previous)
      Application.delete_env(:brussels_wtf, :discovery_archive_test_owner)
    end)

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        Discovery.sweep_tick()
      end)

    assert_receive {:archive_read, reader}, 2_000
    assert {:ok, %{paused: 0}} = Discovery.pause(actor: @actor)
    send(reader, :continue)
    assert {:ok, %{reason: :stale_plan}} = Task.await(task)

    assert {:ok, %{control: %{cursors: %{}}, counts: %{examined: 0}}} =
             Discovery.sweep_status(actor: @actor)

    Application.put_env(:brussels_wtf, :archive, previous)
    Discovery.resume(actor: @actor)

    tasks =
      for _ <- 1..3,
          do:
            Task.async(fn ->
              Repo.put_dynamic_repo(repo)
              Discovery.sweep_tick()
            end)

    results = Task.await_many(tasks)
    assert Enum.sum(Enum.map(results, fn {:ok, report} -> report.new_jobs end)) == 1
    assert Ash.count!(Discovery.Job, authorize?: false) == 1

    assert {:ok, %{control: %{day_used: 1}, runs: [%{next_chunk: 1}]}} =
             Discovery.sweep_status(actor: @actor)
  end

  defp isolate_sweep_run!(run) do
    Repo.query!("UPDATE processing_runs SET status = 'failed' WHERE id != $1", [
      Ecto.UUID.dump!(run.id)
    ])
  end

  defp copy_generation!(run, status \\ :succeeded) do
    copy =
      Ingestion.record_processing_run!(%{
        source_version_id: run.source_version_id,
        generation_key: Ash.UUID.generate(),
        processor_name: run.processor_name,
        processor_version: run.processor_version,
        config_hash: run.config_hash,
        processor_role: run.processor_role,
        status: status,
        quality_measurements: run.quality_measurements
      })

    [artifact] = Ash.load!(run, :derived_artifacts).derived_artifacts

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: copy.id,
      derived_artifact_id: artifact.id,
      role: :native_output
    })

    copy
  end

  test "disabled credential fails closed" do
    Application.delete_env(:brussels_wtf, :discovery_token_digest)
    assert request("/internal/discovery/claim", %{}) |> response(404)
  end

  defp source!(
         scenario \\ "ixelles/proposal",
         name \\ :agenda,
         role \\ :native_extraction,
         text \\ @text
       ) do
    fixture = Harness.load(scenario)
    source = fixture.sources[name]

    outputs =
      if role == :ocr,
        do: put_in(source.outputs, [:ocr, "page_texts"], [text]),
        else:
          source.outputs
          |> put_in([:extract, "text"], text)
          |> put_in([:extract, "page_texts"], [text])

    BrusselsWtf.Processors.Stub.put(source.sha256, outputs)

    if fixture.commune.slug == "uccle" do
      Ingestion.request_backfill!(%{type: :commune, id: fixture.commune.id}, actor: @actor)
    else
      Ingestion.request_poll_now!(%{type: :commune, id: fixture.commune.id}, actor: @actor)
    end

    Harness.drain_pipeline(until: if(role == :ocr, do: :ocr, else: :extract))

    Ingestion.ProcessingRun
    |> Ash.Query.filter(
      source_version.sha256 == ^source.sha256 and status == :succeeded and processor_role == ^role
    )
    |> Ash.read!()
    |> then(fn runs ->
      assert [_] = runs
      List.first(runs)
    end)
  end

  defp request(path, body, token \\ @token) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp result(claim) do
    line = Enum.find(claim["input"]["lines"], &String.contains?(&1["text"], "Élodie"))

    %{
      "lease_token" => claim["lease_token"],
      "result" => %{
        "schema_version" => "municipal-mentions-v1",
        "input_hash" => claim["input"]["input_hash"],
        "mentions" => [
          %{
            "kind" => "person",
            "text" => "Élodie D’Haene",
            "line_id" => line["id"],
            "quote" => line["text"]
          }
        ]
      },
      "processor" => %{
        "name" => "codex-cli",
        "version" => "0.155.0",
        "model" => "controlled-test"
      }
    }
  end

  defp advance(seconds),
    do: BrusselsWtf.Clock.Controlled.set(DateTime.add(BrusselsWtf.Clock.utc_now(), seconds))
end
