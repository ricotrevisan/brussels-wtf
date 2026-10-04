defmodule BrusselsWtf.Contracts.MunicipalInstallationRealTest do
  use BrusselsWtf.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]

  alias BrusselsWtf.{Archive, Digest, HTTP, Identity, Ingestion}
  alias BrusselsWtf.Identity.MunicipalInstallation
  alias MunicipalInstallation.{Acquisition, Source}
  alias BrusselsWtf.PDF.{PopplerOcr, Processor}

  defmodule SafeFailure do
    @moduledoc false
    defexception [:message]
  end

  @endpoint BrusselsWtfWeb.Endpoint
  @moduletag :external
  @moduletag timeout: 600_000
  @moduletag skip: is_nil(System.get_env("MUNICIPAL_INSTALLATION_REAL_SOURCE_DIRECTORY"))
  @actor %BrusselsWtf.Review.Actor{id: "private-real-acceptance", role: :reviewer}
  @slugs ~w(ixelles uccle forest city-of-brussels)
  @counts %{"ixelles" => 30, "uccle" => 39, "forest" => 29, "city-of-brussels" => 2}
  @first_pages %{
    "ixelles" => [4, 4],
    "uccle" => [3, 3],
    "forest" => [3, 3],
    "city-of-brussels" => [25, 57]
  }

  # This is deliberately NOT MunicipalInstallationArchiveFixture: no synthetic
  # PDF, padded text, processor stub, SQL pin substitution or quality override.
  # Private directory layout: <slug>-installation.pdf, <slug>-corroboration.pdf,
  # and the six exact retained HTML responses below. Bytes never enter Git.
  # Run with MIX_ENV=test MIX_TEST_PARTITION=issue104real and
  # MUNICIPAL_INSTALLATION_REAL_SOURCE_DIRECTORY=/private/retained/directory:
  # mise exec elixir@1.19.5-otp-28 erlang@28.1 -- mix test \
  #   test/contracts/municipal_installation_real_test.exs --include external
  # Also set MUNICIPAL_INSTALLATION_REAL_PRODUCTION_IMAGE=sha256:<image-id>
  # to run the network-disabled, read-only production executable contract.
  @indexes %{
    "ixelles-installation.html" =>
      "f2c6952bc7eb816598ab5af5c9b15ce04bde78d8314c024289c644c9c9b587c6",
    "ixelles-corroboration.html" =>
      "30648021b8d962d08546b9f692cab4daad618dbda672e03e3405cba927e77962",
    "uccle-index.html" => "6f862e79496e49453face3bad2f2004c3b597a10237b69bd35a2fbbf52d33c5d",
    "forest-index.html" => "a577d4281db5239eae685588bb0ddb39b1a87bad2524dcd569fca3ae4c1c7bb7",
    "city-of-brussels-installation.html" =>
      "e329c7bedbb57f91711ebb65dc22f9e7ef54bc68823758ebe1d1f5c4ab01d91c",
    "city-of-brussels-corroboration.html" =>
      "e0f7c4008e122006a1babdcdef7522676bfc3abcda6c1ae82e7a42a42af56158"
  }

  setup do
    assert System.get_env("MIX_TEST_PARTITION") == "issue104real"
    assert Application.fetch_env!(:brussels_wtf, :archive) == Archive.Memory
    old = Application.fetch_env!(:brussels_wtf, :pdf_processor)
    Application.put_env(:brussels_wtf, :pdf_processor, PopplerOcr)
    Archive.Memory.reset()
    HTTP.Stub.reset()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :pdf_processor, old)
      Archive.Memory.reset()
      HTTP.Stub.reset()
    end)

    :ok
  end

  test "eight retained official PDFs acquire real native lineage and publish eight localized profiles" do
    # Unexpected Ash/Match errors must not print private source bodies or maps.
    # Assertions below receive booleans, never the private value being checked.
    ExUnit.CaptureLog.capture_log(fn -> acceptance!() end)
  rescue
    error in SafeFailure -> flunk(error.message)
    error -> flunk("private acceptance raised #{inspect(error.__struct__)}; details withheld")
  end

  # Set this to the exact release image ID/digest, not a moving tag. This check
  # runs the existing release-owned PDF.Contract without starting the app or
  # accessing a database/network. The principal Ash/route test above is local.
  @tag skip:
         is_nil(System.get_env("MUNICIPAL_INSTALLATION_REAL_PRODUCTION_IMAGE")) or
           is_nil(System.get_env("MUNICIPAL_INSTALLATION_REAL_SOURCE_DIRECTORY"))
  test "the exact production image independently accepts all eight complete native PDFs" do
    image = System.fetch_env!("MUNICIPAL_INSTALLATION_REAL_PRODUCTION_IMAGE")

    check!(
      Regex.match?(~r/(?:\Asha256:|@sha256:)[a-f0-9]{64}\z/, image),
      "immutable image ID or digest required"
    )

    directory = System.fetch_env!("MUNICIPAL_INSTALLATION_REAL_SOURCE_DIRECTORY") |> Path.expand()
    {uid, 0} = System.cmd("id", ["-u"])
    {gid, 0} = System.cmd("id", ["-g"])

    results =
      for contract <- Source.contracts(), kind <- [:installation, :corroboration] do
        source = Map.fetch!(contract, kind)
        file = "#{contract.slug}-#{kind}.pdf"
        read_pinned!(file, source.sha256)

        args = [
          "run",
          "--rm",
          "--network",
          "none",
          "--read-only",
          "--tmpfs",
          "/tmp:rw,nosuid,nodev,size=256m",
          "--ulimit",
          "nofile=65536:65536",
          "--user",
          String.trim(uid) <> ":" <> String.trim(gid),
          "-v",
          "#{directory}:/fixtures:ro",
          "-e",
          "REVIEW_USERNAME=contract",
          "-e",
          "REVIEW_PASSWORD=contract-password-long",
          "-e",
          "DATABASE_URL=ecto://unused:unused@127.0.0.1/unused",
          "-e",
          "SECRET_KEY_BASE=" <> String.duplicate("x", 64),
          "-e",
          "PROCESS_ROLE=app",
          "-e",
          "PDF_CONTRACT_MODE=native",
          "-e",
          "PDF_CONTRACT_PATH=/fixtures/#{file}",
          "--entrypoint",
          "/app/bin/brussels_wtf",
          image,
          "eval",
          "BrusselsWtf.PDF.Contract.print_from_env()"
        ]

        {output, status} = System.cmd("docker", args, stderr_to_stdout: true)

        check!(
          status == 0,
          "#{contract.slug}/#{kind}: isolated production image execution failed"
        )

        line =
          output
          |> String.split("\n")
          |> Enum.find(&String.starts_with?(&1, "PDF_CONTRACT_JSON="))

        check!(is_binary(line), "production image contract result missing")
        result = line |> String.replace_prefix("PDF_CONTRACT_JSON=", "") |> Jason.decode!()

        check!(
          result["status"] == "ok",
          "#{contract.slug}/#{kind}: production native execution rejected"
        )

        emit_quality(contract.slug, kind, result["quality_measurements"])

        if contract.slug == "ixelles" and kind == :installation,
          do: emit("image_toolchain", result["tool_versions"])

        check!(
          result["tool_versions"]["tesseract_languages"] == "fra,nld,osd",
          "production bilingual toolchain"
        )

        check!(
          result["quality_measurements"]["thresholds"] ==
            Map.new(BrusselsWtf.PDF.Quality.thresholds(), fn {k, v} -> {to_string(k), v} end),
          "production quality contract unchanged"
        )

        check!(
          is_binary(result["text_sha256"]) and byte_size(result["text_sha256"]) == 64,
          "production text checksum"
        )

        result["quality_measurements"]["accepted"]
      end

    check!(
      length(results) == 8 and Enum.all?(results),
      "production full-document quality rejected; see safe page counts above"
    )
  rescue
    error in SafeFailure ->
      flunk(error.message)

    error ->
      flunk("private image acceptance raised #{inspect(error.__struct__)}; details withheld")
  end

  defp acceptance! do
    metadata = Processor.metadata()
    check!(metadata == PopplerOcr.metadata(), "actual native processor metadata")
    check!(metadata.native_processor_name == "poppler-native-text", "native processor name")
    check!(metadata.tool_versions["pdftotext"] != "unavailable", "Poppler must be installed")
    emit("toolchain", metadata.tool_versions)

    documents = load_documents!()

    native =
      Map.new(documents, fn {{slug, kind} = key, %{source: source, bytes: bytes}} ->
        result = PopplerOcr.native(%{sha256: source.sha256, media_type: source.media_type}, bytes)
        check!(match?({:ok, _}, result), "#{slug}/#{kind}: native execution")
        {:ok, result} = result
        emit_quality(slug, kind, result.quality_measurements)
        {key, result}
      end)

    candidates =
      Map.new(Source.contracts(), fn contract ->
        result =
          Source.match_candidates(
            contract,
            native[{contract.slug, :installation}].text,
            native[{contract.slug, :corroboration}].text
          )

        reason =
          case result do
            {:error, reason} when is_atom(reason) -> Atom.to_string(reason)
            _ -> "unknown"
          end

        check!(match?({:ok, _}, result), "#{contract.slug}: candidate parser rejected: #{reason}")
        {:ok, parsed} = result
        emit("candidates", %{slug: contract.slug, count: length(parsed.candidates)})
        check!(length(parsed.candidates) == @counts[contract.slug], "audited candidate count")
        selected = Enum.take(parsed.candidates, 2)
        emit("citation_pages", %{slug: contract.slug, pages: Enum.map(selected, & &1.page)})

        check!(
          Enum.map(selected, & &1.page) == @first_pages[contract.slug],
          "#{contract.slug}: independently audited first-two citation pages"
        )

        {contract.slug, selected}
      end)

    {:ok, acquired} = Acquisition.acquire(@slugs, actor: @actor, http: HTTP.Stub)
    emit("acquisition", Map.take(acquired, [:queued, :reused, :failures]))

    for source <- acquired.sources do
      emit("source", Map.take(source, [:slug, :kind, :status, :reason]))
    end

    check!(acquired.queued == 8 and acquired.failures == 0, "all eight official sources acquired")

    for source <- acquired.sources do
      result =
        Oban.Testing.perform_job(
          BrusselsWtf.Workers.ExtractSource,
          %{source_version_id: source.source_version_id, generation_kind: "backfill"},
          repo: Repo
        )

      check!(result == :ok, "#{source.slug}/#{source.kind}: extraction job")
      assert_lineage!(source, documents[{source.slug, source.kind}], native, metadata)
    end

    # All documents are processed before evaluating the gate: a rejected full PDF
    # remains a failed acceptance, not an excuse to bless selected role pages.
    {:ok, previews} = MunicipalInstallation.preview(@slugs, actor: @actor)
    for report <- previews, do: emit_report("preview", report)
    check!(Identity.list_public_relationships!() == [], "preview must not publish")

    {:ok, reports} =
      MunicipalInstallation.publish(@slugs, actor: @actor, max_facts_per_commune: 2)

    for report <- reports, do: emit_report("publication", report)
    roles = Identity.list_public_relationships!()

    emit("public", %{
      relationships: length(roles),
      profiles: length(Enum.uniq_by(roles, & &1.subject_id))
    })

    all_accepted =
      Enum.all?(native, fn {_, result} -> result.quality_measurements["accepted"] end)

    check!(all_accepted, "full-document native quality rejected; see safe page counts above")

    check!(
      Enum.all?(previews, &(&1.eligible == @counts[&1.slug])),
      "all candidate gates accepted"
    )

    check!(Enum.all?(reports, &(&1.published_new == 2)), "two new relationships per commune")
    check!(length(roles) == 8, "exactly eight public relationships")
    check!(length(Enum.uniq_by(roles, & &1.subject_id)) == 8, "exactly eight public people")

    for contract <- Source.contracts() do
      commune = Ingestion.get_commune_by_slug!(contract.slug)
      selected = Enum.filter(roles, &(&1.object_id == commune.id))
      expected = candidates[contract.slug]
      check!(length(selected) == 2, "two public relationships for #{contract.slug}")

      for candidate <- expected do
        role = Enum.find(selected, &(&1.subject_name == candidate.legal_name))
        check!(not is_nil(role), "source-ordered candidate published")
        check!(role.state == :documented, "historical rather than ongoing mandate")

        check!(
          role.effective_from == ~D[2024-12-01] and is_nil(role.effective_to),
          "dated installation"
        )

        check!(role.authoritative_url == contract.installation.url, "official origin")
        check!(role.evidence_location == candidate.evidence_location, "exact source page")

        check!(
          role.role_labels == Map.new(candidate.role_labels, fn {k, v} -> {to_string(k), v} end),
          "source role labels"
        )

        assert_routes!(role, candidate.page)
      end
    end

    {:ok, rerun} = MunicipalInstallation.publish(@slugs, actor: @actor, max_facts_per_commune: 2)

    check!(
      Enum.all?(rerun, &(&1.published_new == 0 and &1.published_existing == 2)),
      "bounded rerun converges"
    )

    check!(
      length(Identity.list_public_relationships!()) == 8,
      "rerun retains exactly eight facts"
    )

    {:ok, reused} = Acquisition.acquire(@slugs, actor: @actor, http: HTTP.Stub)

    check!(
      reused.reused == 8 and reused.failures == 0,
      "all eight accepted native chains reusable"
    )

    for {_key, doc} <- documents,
        do: check!(length(HTTP.Stub.requests(doc.source.url)) == 1, "no refetch on reuse")
  end

  defp load_documents! do
    Map.new(
      for contract <- Source.contracts(), kind <- [:installation, :corroboration] do
        source = Map.fetch!(contract, kind)
        bytes = read_pinned!("#{contract.slug}-#{kind}.pdf", source.sha256)

        index_file =
          if contract.slug in ["uccle", "forest"],
            do: "#{contract.slug}-index.html",
            else: "#{contract.slug}-#{kind}.html"

        index = read_pinned!(index_file, Map.fetch!(@indexes, index_file))

        HTTP.Stub.put(source.parent_index_url, %{
          body: index,
          headers: %{"content-type" => "text/html"}
        })

        HTTP.Stub.put(source.url, %{body: bytes, headers: %{"content-type" => "application/pdf"}})
        {{contract.slug, kind}, %{source: source, bytes: bytes, index: index}}
      end
    )
  end

  defp assert_lineage!(acquired, doc, native, metadata) do
    source = doc.source
    commune = Ingestion.get_commune_by_slug!(acquired.slug)
    history = Ingestion.source_history!(commune.id, source.url)
    check!(length(history.versions) == 1, "one immutable PDF version")
    [version] = history.versions

    check!(
      version.id == acquired.source_version_id and version.sha256 == source.sha256,
      "production raw pin"
    )

    check!(version.byte_size == byte_size(doc.bytes), "raw byte size")
    check!(Archive.get(version.object_key) == {:ok, doc.bytes}, "exact private PDF retained")
    check!(history.source_record.council_meeting_id == nil, "no fabricated meeting")

    locators = Ingestion.locator_history!(commune.id, source.url)
    check!(length(locators) == 1, "one discovered official locator")
    [locator] = locators

    check!(
      locator.parent_index_url == source.parent_index_url and locator.scheduled_on == source.date and
        locator.meeting_identifier == source.meeting_identifier and locator.role == source.role,
      "official discovery context"
    )

    check!(
      Enum.any?(
        locator.observations,
        &(&1.status == :success and &1.sha256 == source.sha256 and
            &1.source_version_id == version.id and &1.final_url == source.url)
      ),
      "successful exact-source observation"
    )

    parent = Ingestion.source_history!(commune.id, source.parent_index_url)
    check!(length(parent.versions) == 1, "one retained official index snapshot")

    check!(
      Archive.get(hd(parent.versions).object_key) == {:ok, doc.index},
      "exact official index retained"
    )

    runs = Enum.filter(history.processing_runs, &(&1.processor_role == :native_extraction))
    check!(length(runs) == 1, "one native generation")
    run = hd(runs) |> Ash.load!([:derived_artifacts, :artifact_links])
    result = native[{acquired.slug, acquired.kind}]
    check!(run.status == :succeeded and not is_nil(run.completed_at), "completed native run")

    check!(
      run.processor_name == metadata.native_processor_name and
        run.processor_version == metadata.native_processor_version and
        run.config_hash == metadata.config_hash and run.tool_versions == metadata.tool_versions,
      "actual executable provenance"
    )

    check!(
      run.quality_measurements == result.quality_measurements,
      "independently reproduced page quality"
    )

    artifacts = Enum.filter(run.derived_artifacts, &(&1.output_kind == "native-text"))
    check!(length(artifacts) == 1, "one native text artifact")
    artifact = hd(artifacts)

    check!(
      artifact.input_sha256 == source.sha256 and
        artifact.output_sha256 == Digest.sha256(result.text),
      "native artifact hash lineage"
    )

    check!(
      artifact.processor_name == run.processor_name and
        artifact.processor_version == run.processor_version and
        artifact.config_hash == run.config_hash and
        artifact.quality_measurements == result.quality_measurements,
      "artifact provenance and quality"
    )

    check!(
      Archive.get(artifact.object_key) == {:ok, result.text},
      "private native text retained unchanged"
    )

    check!(
      Enum.any?(
        run.artifact_links,
        &(&1.role == :native_output and &1.derived_artifact_id == artifact.id)
      ),
      "authoritative run artifact link"
    )
  end

  defp assert_routes!(role, source_page) do
    for locale <- ~w(fr nl en) do
      response = get(build_conn(), "/people/#{role.subject_id}?lang=#{locale}")
      check!(response.status == 200, "localized public person route")

      check!(
        Plug.Conn.get_resp_header(response, "content-language") == [locale],
        "profile locale"
      )

      page = LazyHTML.from_document(response.resp_body)
      fact = page["#fact-#{role.fact_id}"]
      check!(LazyHTML.text(page["h1"]) == role.subject_name, "public legal name")

      check!(
        String.trim(LazyHTML.text(fact["h4"])) == role.role_labels[locale],
        "localized public role"
      )

      check!(
        LazyHTML.attribute(page[~s(link[rel="canonical"])], "href") == [
          "/people/#{role.subject_id}"
        ],
        "stable canonical route"
      )

      citation = role.authoritative_url <> "#page=#{source_page}"

      check!(
        LazyHTML.attribute(fact[~s(a[rel="external"])], "href") == [citation],
        "formatted official PDF page citation"
      )

      home_response = get(build_conn(), "/mandates?lang=#{locale}")
      check!(home_response.status == 200, "localized public mandate directory")
      home = LazyHTML.from_document(home_response.resp_body)

      check!(
        length(LazyHTML.to_tree(home["#verified-mandates + ul > li"])) == 8,
        "eight discoverable mandates"
      )

      check!(
        "/people/#{role.subject_id}?lang=#{locale}#fact-#{role.fact_id}" in LazyHTML.attribute(
          home["#verified-mandates + ul a"],
          "href"
        ),
        "localized profile discovery"
      )

      check!(
        citation in LazyHTML.attribute(home[~s(a[rel="external"])], "href"),
        "directory exact page citation"
      )

      for body <- [response.resp_body, home_response.resp_body],
          private <- [
            "object_key",
            "corroborating_facts",
            "identity_evidence",
            "municipal_installation_v1",
            "raw/sha256/",
            "derived/sha256/"
          ] do
        check!(not String.contains?(body, private), "private lineage not exposed")
      end
    end
  end

  defp read_pinned!(filename, sha) do
    directory = System.fetch_env!("MUNICIPAL_INSTALLATION_REAL_SOURCE_DIRECTORY")
    result = File.read(Path.join(directory, filename))
    check!(match?({:ok, _}, result), "missing private fixture #{filename}")
    {:ok, bytes} = result
    check!(Digest.sha256(bytes) == sha, "private fixture checksum #{filename}")
    bytes
  end

  defp emit_quality(slug, kind, quality) do
    emit("quality", %{
      slug: slug,
      kind: kind,
      pages: quality["page_count"],
      rejected: length(quality["rejected_pages"]),
      accepted: quality["accepted"]
    })
  end

  defp emit_report(stage, report) do
    # Never print arbitrary exception strings, candidates or corroborating maps.
    reason =
      case Map.get(report, :error) do
        nil -> nil
        "accepted native extraction is required" -> "accepted native extraction is required"
        "missing or ambiguous approved installation source" -> "missing approved installation"
        "missing or ambiguous approved corroboration source" -> "missing approved corroboration"
        _ -> "evidence gate rejected (details withheld)"
      end

    emit(
      stage,
      report
      |> Map.take([:slug, :eligible, :published_new, :published_existing])
      |> Map.put(:error, reason)
      |> Map.put(:rejected, length(Map.get(report, :rejected, [])))
    )
  end

  defp emit(stage, safe), do: IO.puts("MUNICIPAL_REAL_#{stage}=" <> Jason.encode!(safe))
  defp check!(true, _message), do: :ok
  defp check!(_, message), do: raise(SafeFailure, message: message)
end
