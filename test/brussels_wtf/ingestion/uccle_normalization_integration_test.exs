defmodule BrusselsWtf.Ingestion.UccleNormalizationIntegrationTest do
  @moduledoc """
  Proves the production wiring for real Uccle agendas: the composite processor, stale
  review cases resolved by the normal retry path, the publication gate's blocking query,
  and the operator script. Source bytes are controlled fixtures unknown to the recorded
  corpus; the accepted text is a minimal excerpt of a real agenda. Set
  `UCCLE_REAL_AGENDA_DIR` to run the same path over retained full text kept outside Git.
  """

  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  import ExUnit.CaptureIO

  alias BrusselsWtf.{Council, Ingestion, Review}
  alias BrusselsWtf.Council.{Publication, PublicationInput}
  alias BrusselsWtf.Processors.Council, as: CouncilProcessor
  alias BrusselsWtf.Review.Actor

  # Production extracts through Poppler, which the test PDF stub replaces with the
  # processor seam. Only that seam is stubbed: normalization is the production composite.
  defmodule ProductionNormalization do
    @behaviour BrusselsWtf.Processors

    @impl true
    def extract(meta, bytes), do: BrusselsWtf.Processors.Stub.extract(meta, bytes)

    @impl true
    def normalize(input), do: BrusselsWtf.Processors.Council.normalize(input)

    @impl true
    def normalization_digest, do: BrusselsWtf.Processors.Council.normalization_digest()
  end

  @fixtures "test/support/fixtures/uccle/agendas"
  @base_url "https://www.uccle.be/CC-2026-10-15-ODJ-U1180_fr_nl.pdf"
  @complementary_url "https://www.uccle.be/CC-2026-10-15-ODJC-U1180_fr_nl.pdf"
  @script "priv/ops/retry_uccle_agendas_20261103.exs"

  setup do
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous_processors)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-10-16 12:15:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "uccle",
        name: "Uccle",
        index_url: "https://www.uccle.be/fr/ma-commune/le-conseil-communal"
      })

    {:ok, commune: commune, actor: %Actor{id: "rico", role: :reviewer}}
  end

  test "a new agenda publishes itself: proposals with evidence and a queued publication", %{
    commune: commune
  } do
    {_version, run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)
    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @base_url)
    assert Review.list_review_cases!(%{}, authorize?: false) == []

    meeting = Council.get_ingested_meeting!("uccle", "2026-10-15")
    assert meeting.scheduled_on == ~D[2026-10-15]
    assert [%{kind: :base, language: :bilingual}] = meeting.agendas
    assert length(meeting.agenda_items) == 6

    proposed = Enum.filter(meeting.agenda_items, &(&1.proposals != []))
    assert length(proposed) == 4
    assert Enum.all?(meeting.agenda_items, &(&1.outcome == :unknown and is_nil(&1.decision)))

    for item <- proposed, proposal <- item.proposals, evidence <- proposal.evidence do
      assert evidence.claim == :proposal
      assert evidence.citation_url == @base_url
      refute evidence.synthetic
    end

    input = Publication.generation_input(meeting.id)
    assert PublicationInput.validate(input) == :ok
    assert length(input["items"]) == 4

    assert_enqueued(
      worker: BrusselsWtf.Workers.PublishMeeting,
      args: %{meeting_id: meeting.id, generation_kind: "automatic"}
    )
  end

  test "the complementary agenda moves renumbered items instead of merging different matters",
       %{commune: commune} do
    {_base_version, base_run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)

    {complementary_version, complementary_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url)
    assert :ok = Ingestion.Pipeline.normalize(complementary_run.id, @complementary_url)
    assert Review.list_review_cases!(%{}, authorize?: false) == []

    meeting = Publication.load_meeting(Council.get_ingested_meeting!("uccle", "2026-10-15").id)
    assert length(meeting.agenda_items) == 8

    numbers = Enum.map(meeting.agenda_items, & &1.item_number)
    assert Enum.sort(numbers) == Enum.sort(Enum.map(2..9, &Integer.to_string/1))

    cemetery = Enum.find(meeting.agenda_items, &(&1.source_wording =~ "Cimetière du Dieweg"))
    assert cemetery.item_number == "6"
    assert cemetery.current_source_version_id == complementary_version.id
    assert length(cemetery.proposals) == 2

    # Every published claim now cites the complementary agenda at its current number.
    input = PublicationInput.build(meeting)
    assert length(input["items"]) == 6
    assert PublicationInput.validate(input) == :ok

    for item <- input["items"], claim <- item["claims"], evidence <- claim["evidence"] do
      assert evidence["location"] =~
               "Ordre du jour complémentaire, point #{item["item_number"]}, page"
    end
  end

  test "processing order does not change the publication input", %{commune: commune} do
    {_base, base_run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)

    {_complementary, complementary_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok = Ingestion.Pipeline.normalize(complementary_run.id, @complementary_url)
    meeting = Council.get_ingested_meeting!("uccle", "2026-10-15")
    first = Publication.generation_input(meeting.id)

    assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url)
    assert Publication.generation_input(meeting.id) == first
    assert Review.list_review_cases!(%{}, authorize?: false) == []
  end

  test "re-reading a base agenda under an unchanged published page spends nothing", %{
    commune: commune
  } do
    {_base, base_run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)

    {_complementary, complementary_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok =
             Ingestion.Pipeline.normalize(
               complementary_run.id,
               @complementary_url,
               1,
               3,
               :backfill
             )

    meeting = Council.get_ingested_meeting!("uccle", "2026-10-15")
    mark_published!(meeting)

    assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url)
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "an earlier item the complementary agenda does not restate blocks publication for review",
       %{commune: commune} do
    reworded =
      fixture("2026-10-15-odjc")
      |> String.replace("Approbation du registre", "Adoption du registre")

    {_base, base_run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)

    {_complementary, complementary_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda, reworded)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url, 1, 3, :backfill)
    assert :ok = Ingestion.Pipeline.normalize(complementary_run.id, @complementary_url)

    assert [review_case] = Review.list_review_cases!(%{}, authorize?: false)
    assert review_case.summary == "Normalized item continuity is ambiguous and requires review"
    assert [%{"item_number" => "3"}] = review_case.normalized_content["unrestated_items"]

    meeting = Publication.load_meeting(Council.get_ingested_meeting!("uccle", "2026-10-15").id)
    assert [%{id: id}] = Review.list_blocking_publication_cases!(meeting)
    assert id == review_case.id
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "a real malformed agenda stays out of the record and opens one review case", %{
    commune: commune
  } do
    {_version, run} =
      accepted(
        commune,
        "https://www.uccle.be/CC-2026-06-25-ODJ.pdf",
        "2026-06-25-odj",
        :agenda,
        nil,
        "2026-06-25",
        ~D[2026-06-25]
      )

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok =
             Ingestion.Pipeline.normalize(run.id, "https://www.uccle.be/CC-2026-06-25-ODJ.pdf")

    assert [review_case] = Review.list_review_cases!(%{}, authorize?: false)
    assert review_case.diagnostics["classification"] == "normalization_ambiguity"
    assert review_case.normalized_content["contract"] == "uccle-council"
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)

    assert_raise Ash.Error.Invalid, fn ->
      Council.get_ingested_meeting!("uccle", "2026-06-25")
    end
  end

  test "the normal retry resolves a stale unavailable case and leaves nothing blocking the gate",
       %{commune: commune, actor: actor} do
    {version, run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    stale_case!(run, @complementary_url)
    assert [stale] = Review.list_review_cases!(%{status: :open}, actor: actor)
    assert stale.summary == "Automatic normalization is unavailable and requires review"

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    retry_and_drain!(stale, version, actor)

    assert Review.list_review_cases!(%{status: :open}, actor: actor) == []
    assert Review.get_review_case!(stale.id, actor: actor).status == :resolved

    meeting = Publication.load_meeting(Council.get_ingested_meeting!("uccle", "2026-10-15").id)
    assert Review.list_blocking_publication_cases!(meeting) == []
    assert length(PublicationInput.build(meeting)["items"]) == 6

    assert_enqueued(
      worker: BrusselsWtf.Workers.PublishMeeting,
      args: %{meeting_id: meeting.id, generation_kind: "automatic"}
    )
  end

  test "a newer complementary agenda that drops an item blocks publication for review", %{
    commune: commune
  } do
    {_first, first_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    BrusselsWtf.Clock.Controlled.set(~U[2026-10-16 13:15:00Z])

    corrected =
      String.replace(
        fixture("2026-10-15-odjc"),
        "Approbation du registre",
        "Adoption du registre"
      )

    {_second, second_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda, corrected)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    assert :ok = Ingestion.Pipeline.normalize(first_run.id, @complementary_url, 1, 3, :backfill)
    assert :ok = Ingestion.Pipeline.normalize(second_run.id, @complementary_url)

    assert [review_case] = Review.list_review_cases!(%{}, authorize?: false)
    assert [%{"item_number" => "3"}] = review_case.normalized_content["unrestated_items"]
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "an unknown agenda of a recorded corpus meeting stays out of its sealed page", %{
    commune: commune
  } do
    text =
      fixture("2026-10-15-odj")
      |> String.replace("DU 15 OCTOBRE 2026", "DU 10 SEPTEMBRE 2026")
      |> String.replace("VAN 15 OKTOBER 2026", "VAN 10 SEPTEMBER 2026")
      |> String.replace("15.10.2026", "10.09.2026")

    url = "https://www.uccle.be/CC-2026-09-10-ODJ.pdf"

    {_version, run} =
      accepted(commune, url, "2026-10-15-odj", :agenda, text, "2026-09-10", ~D[2026-09-10])

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    assert :ok = Ingestion.Pipeline.normalize(run.id, url)

    assert [%{diagnostics: %{"classification" => "processor_unavailable"}}] =
             Review.list_review_cases!(%{}, authorize?: false)

    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "retrying one agenda does not wait on the other agenda's stale case", %{
    commune: commune,
    actor: actor
  } do
    {_base, base_run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)

    {complementary, complementary_run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    stale_case!(base_run, @base_url)
    stale_complementary = stale_case!(complementary_run, @complementary_url)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    retry_and_drain!(stale_complementary, complementary, actor)

    assert [still_open] = Review.list_review_cases!(%{status: :open}, actor: actor)
    assert still_open.source_record_id != stale_complementary.source_record_id

    meeting = Publication.load_meeting(Council.get_ingested_meeting!("uccle", "2026-10-15").id)
    assert Review.list_blocking_publication_cases!(meeting) == []
  end

  test "a retried agenda publishes a full FR/NL/EN page with every item cited", %{
    commune: commune,
    actor: actor
  } do
    {version, run} =
      accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

    stale = stale_case!(run, @complementary_url)
    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    retry_and_drain!(stale, version, actor)

    meeting = Publication.load_meeting(Council.get_ingested_meeting!("uccle", "2026-10-15").id)
    input = Publication.generation_input(meeting.id)
    BrusselsWtf.Processors.Stub.put_locales("2026-10-15", coverage(input))

    assert :ok =
             perform_job(BrusselsWtf.Workers.PublishMeeting, %{
               meeting_id: meeting.id,
               generation_kind: "automatic"
             })

    page = Ash.load!(meeting, :meeting_page).meeting_page
    page = Council.get_meeting_page!(page.id)
    assert page.publication_status == :published

    variants = Council.list_locale_variants!(page.id)
    assert variants |> Enum.map(& &1.locale) |> Enum.uniq() |> Enum.sort() == ~w(en fr nl)

    assert length(input["items"]) == 6

    for item <- input["items"], claim <- item["claims"] do
      assert claim["kind"] == "proposal"
      assert [evidence | _] = claim["evidence"]
      assert evidence["citation_url"] == @complementary_url
      assert evidence["excerpt"] != ""
      assert evidence["location"] =~ "point #{item["item_number"]}, page"
    end
  end

  describe "the retained full documents" do
    @real_dir System.get_env("UCCLE_REAL_AGENDA_DIR")
    @describetag skip: if(is_nil(@real_dir), do: "set UCCLE_REAL_AGENDA_DIR to run")

    test "every emitted excerpt occurs on its cited page; the rest fail closed" do
      results =
        for path <- Path.wildcard("#{@real_dir}/*.txt") |> Enum.sort() do
          [date, role, _sha, page_count] =
            path |> Path.basename(".txt") |> String.split("--")

          text = File.read!(path)

          result =
            CouncilProcessor.normalize(%{
              "sha256" => "unseen-#{Path.basename(path)}",
              "commune_slug" => "uccle",
              "meeting_identifier" => date,
              "scheduled_on" => date,
              "role" => role,
              "page_count" => String.to_integer(page_count),
              "text" => text
            })

          case result do
            {:ok, normalized} ->
              proposals = BrusselsWtf.UccleAgendaEvidence.assert_on_cited_pages(normalized, text)
              {date, role, length(normalized["items"]), proposals}

            {:error, {:normalization_ambiguity, _details}} ->
              {date, role, :review_case}

            {:error, :processor_unimplemented} ->
              {date, role, :unavailable}
          end
        end

      IO.inspect(results, label: "real Uccle agendas", limit: :infinity)
      assert results != []
    end

    test "the two real agendas of the latest meeting build a valid publication input", %{
      commune: commune
    } do
      read = fn role ->
        [path] = Path.wildcard("#{@real_dir}/2026-10-15--#{role}--*.txt")
        File.read!(path)
      end

      {_base, base_run} =
        accepted(commune, @base_url, "2026-10-15-odj", :agenda, read.("agenda"))

      {_complementary, complementary_run} =
        accepted(
          commune,
          @complementary_url,
          "2026-10-15-odjc",
          :complementary_agenda,
          read.("complementary_agenda")
        )

      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

      assert :ok = Ingestion.Pipeline.normalize(complementary_run.id, @complementary_url)
      assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url)
      assert Review.list_review_cases!(%{}, authorize?: false) == []

      meeting = Publication.load_meeting(Council.get_ingested_meeting!("uccle", "2026-10-15").id)
      assert Review.list_blocking_publication_cases!(meeting) == []

      input = PublicationInput.build(meeting)
      assert PublicationInput.validate(input) == :ok

      IO.inspect(
        %{items: length(meeting.agenda_items), publishable: length(input["items"])},
        label: "real Uccle 2026-10-15"
      )
    end
  end

  describe "the operator script" do
    test "the default run previews candidates and changes nothing", %{
      commune: commune,
      actor: actor
    } do
      {_version, run} =
        accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

      stale_case!(run, @complementary_url)
      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
      normalizations_before = all_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)

      output = capture_io(fn -> eval_script([]) end)

      assert output =~ "read_only: true"
      assert output =~ "month_budget:"
      assert output =~ "candidate_count: 1"
      assert output =~ "ready_count: 1"
      assert output =~ "proposals: 6"
      assert output =~ "read-only: nothing was retried"

      assert [%{status: :open}] = Review.list_review_cases!(%{}, actor: actor)
      refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
      assert all_enqueued(worker: BrusselsWtf.Workers.NormalizeSource) == normalizations_before
    end

    test "applying takes the complementary agenda first and honours the limit", %{
      commune: commune,
      actor: actor
    } do
      {_b, base_run} = accepted(commune, @base_url, "2026-10-15-odj", :agenda)

      {c, comp_run} =
        accepted(commune, @complementary_url, "2026-10-15-odjc", :complementary_agenda)

      stale_case!(base_run, @base_url)
      stale_case!(comp_run, @complementary_url)
      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

      output =
        capture_io(fn -> eval_script(apply?: true, limit: 1, actor_id: actor.id) end)

      assert output =~ "applied: 1"
      assert output =~ ~s(role: "complementary_agenda")

      assert [%{args: %{"source_version_id" => id}}] =
               all_enqueued(worker: BrusselsWtf.Workers.ExtractSource)

      assert id == c.id
      assert length(Review.list_review_cases!(%{status: :open}, actor: actor)) == 2
    end

    test "older meetings, other roles and recorded corpus meetings are never candidates", %{
      commune: commune,
      actor: actor
    } do
      {_v1, older} =
        accepted(
          commune,
          "https://www.uccle.be/old.pdf",
          "2026-06-25-odj",
          :agenda,
          nil,
          "2026-06-25",
          ~D[2026-06-25]
        )

      {_v2, note} =
        accepted(commune, "https://www.uccle.be/note.pdf", "2026-10-15-odj", :explanatory_note)

      {_v3, recorded} =
        accepted(
          commune,
          "https://www.uccle.be/recorded.pdf",
          "2026-10-15-odj",
          :agenda,
          nil,
          "2026-09-10",
          ~D[2026-09-10]
        )

      for {run, url} <- [
            {older, "https://www.uccle.be/old.pdf"},
            {note, "https://www.uccle.be/note.pdf"},
            {recorded, "https://www.uccle.be/recorded.pdf"}
          ] do
        stale_case!(run, url)
      end

      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

      output = capture_io(fn -> eval_script(apply?: true, limit: 25, actor_id: actor.id) end)

      assert output =~ "candidate_count: 1"
      assert output =~ "ready_count: 0"
      assert output =~ ":recorded_corpus_meeting"
      assert output =~ "applied: 0"
      refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
    end

    test "invalid bindings refuse to apply" do
      source = File.read!(@script)

      assert_raise RuntimeError, ~r/refusing to retry more than 25/, fn ->
        Code.eval_string(source, apply?: true, limit: 26, actor_id: "rico")
      end

      assert_raise RuntimeError, ~r/limit must be positive/, fn ->
        Code.eval_string(source, apply?: true, limit: 0, actor_id: "rico")
      end

      assert_raise RuntimeError, ~r/actor_id must name/, fn ->
        Code.eval_string(source, apply?: true, limit: 1)
      end
    end
  end

  defp eval_script(bindings) do
    {result, _bindings} = Code.eval_string(File.read!(@script), bindings)
    result
  end

  defp retry_and_drain!(review_case, version, actor) do
    Review.retry_review_case!(review_case, %{note: "retry with the normalizer"}, actor: actor)

    retry_run =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.status == :queued))

    assert :ok =
             perform_job(
               BrusselsWtf.Workers.ExtractSource,
               %{source_version_id: version.id, processing_run_id: retry_run.id},
               attempt: 1
             )

    [job] =
      all_enqueued(
        worker: BrusselsWtf.Workers.NormalizeSource,
        args: %{processing_run_id: retry_run.id}
      )

    assert :ok = perform_job(BrusselsWtf.Workers.NormalizeSource, job.args, attempt: 1)
  end

  defp coverage(input) do
    text = fn locale, label ->
      %{"title" => "#{label} #{locale}", "summary" => "#{label} #{locale}."}
    end

    %{
      "page" => Map.new(~w(fr nl en), &{&1, text.(&1, "Conseil")}),
      "items" =>
        Map.new(input["items"], fn item ->
          {item["key"],
           %{
             "claim_refs" => Enum.map(item["claims"], & &1["key"]),
             "variants" =>
               Map.new(~w(fr nl en), fn locale ->
                 {locale,
                  text.(locale, "Point #{item["item_number"]}")
                  |> Map.put("proposal_summary", "Proposition #{locale}.")}
               end)
           }}
        end)
    }
  end

  defp mark_published!(meeting) do
    hash = meeting.id |> Publication.generation_input() |> PublicationInput.hash()

    BrusselsWtf.Repo.query!(
      "UPDATE meeting_pages SET publication_status = 'published', publication_input_hash = $1 WHERE council_meeting_id = $2",
      [hash, Ecto.UUID.dump!(meeting.id)]
    )
  end

  defp fixture(name), do: File.read!("#{@fixtures}/#{name}.excerpt.txt")

  # The state production holds: the release that read this run had no Uccle normalizer.
  defp stale_case!(run, url) do
    run = Ash.load!(run, source_version: [source_record: [:commune]])
    Ingestion.NormalizationReview.open_for_run(run, url)
  end

  defp accepted(
         commune,
         origin,
         fixture_name,
         role,
         text \\ nil,
         meeting_identifier \\ "2026-10-15",
         scheduled_on \\ ~D[2026-10-15]
       ) do
    text = text || fixture(fixture_name)

    bytes =
      "%PDF controlled Uccle normalization fixture #{origin} #{BrusselsWtf.Digest.sha256(text)}"

    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: origin,
        role: role,
        original_language: :bilingual
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archived.sha256,
        byte_size: byte_size(bytes),
        media_type: "application/pdf",
        object_key: archived.object_key,
        first_retrieved_at: BrusselsWtf.Clock.utc_now()
      })

    Ingestion.upsert_locator!(%{
      commune_id: commune.id,
      url: origin,
      parent_index_url: commune.index_url,
      meeting_identifier: meeting_identifier,
      scheduled_on: scheduled_on,
      role: role,
      language: :bilingual,
      observed_label: "Ordre du jour",
      discovered_at: BrusselsWtf.Clock.utc_now()
    })

    pages = text |> String.split("\f") |> Enum.reject(&(&1 == ""))

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{"text" => text, "page_texts" => pages}
    })

    assert :ok = Ingestion.Pipeline.extract(version.id, 1, :backfill)

    run =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.status == :succeeded and &1.processor_role == :native_extraction))

    {version, run}
  end
end
