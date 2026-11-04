defmodule BrusselsWtf.Ingestion.CityOfBrusselsNormalizationIntegrationTest do
  @moduledoc """
  Proves the production wiring for real City of Brussels agendas: the composite processor,
  stale review cases resolved by the normal retry path, the publication gate's blocking
  query, and the operator script. Source bytes are controlled fixtures unknown to the
  recorded corpus; the accepted text is a minimal excerpt of a real agenda. Set
  `CITY_AGENDA_TEXT_DIR` to run the same path over retained full text kept outside Git.
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

  @fixtures "test/support/fixtures/city_of_brussels"
  @base_url "https://www.brussels.be/sites/default/files/OJ12102026.pdf"
  @supplement_url "https://www.brussels.be/sites/default/files/Supplement_OJFR.pdf"
  @script "priv/ops/retry_city_of_brussels_agendas_20261104.exs"

  setup do
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous_processors)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-10-13 12:15:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "city-of-brussels",
        name: "City of Brussels",
        index_url: "https://www.brussels.be/agenda-reports-and-motions-city-council"
      })

    {:ok, commune: commune, actor: %Actor{id: "rico", role: :reviewer}}
  end

  test "a new agenda publishes itself: proposals with evidence and a queued publication", %{
    commune: commune
  } do
    {version, run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    assert :ok = Ingestion.Pipeline.normalize(run.id, @base_url)
    assert Review.list_review_cases!(%{}, authorize?: false) == []

    meeting = Council.get_ingested_meeting!("city-of-brussels", "2026-10-12")
    assert [%{kind: :base, source_version_id: source_version_id}] = meeting.agendas
    assert source_version_id == version.id
    assert Enum.sort(Enum.map(meeting.agenda_items, & &1.item_number)) == ~w(13 3 5 6)
    assert Enum.all?(meeting.agenda_items, &(&1.outcome == :unknown and is_nil(&1.decision)))

    assert meeting.agenda_items |> Enum.filter(&(&1.proposals != [])) |> length() == 2

    assert_enqueued(
      worker: BrusselsWtf.Workers.PublishMeeting,
      args: %{meeting_id: meeting.id, generation_kind: "automatic"}
    )
  end

  test "a supplement adds its points to the base agenda of the same meeting", %{commune: commune} do
    {_base, base_run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda)

    {_supplement, supplement_run} =
      accepted(commune, @supplement_url, "supplement_20261012_excerpt", :supplement)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url)
    assert :ok = Ingestion.Pipeline.normalize(supplement_run.id, @supplement_url)

    meeting =
      Publication.load_meeting(Council.get_ingested_meeting!("city-of-brussels", "2026-10-12").id)

    assert length(meeting.agenda_items) == 7
    assert Review.list_blocking_publication_cases!(meeting) == []

    input = PublicationInput.build(meeting)
    assert PublicationInput.validate(input) == :ok
    assert Enum.map(input["items"], & &1["item_number"]) |> Enum.sort() == ~w(108 5 6 74)

    citations =
      for item <- input["items"],
          claim <- item["claims"],
          e <- claim["evidence"],
          do: e["citation_url"]

    assert Enum.uniq(citations) |> Enum.sort() == [@base_url, @supplement_url] |> Enum.sort()
  end

  test "a document outside the observed layout records nothing and opens one review case", %{
    commune: commune
  } do
    text =
      fixture("agenda_20261012_excerpt")
      |> String.replace("Dossiers de Mme l'Echevine Frelinx", "Election d'un neuvième Echevin")

    {_version, run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda, text)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    assert :ok = Ingestion.Pipeline.normalize(run.id, @base_url)

    assert [%{diagnostics: %{"classification" => "normalization_ambiguity"}} = review_case] =
             Review.list_review_cases!(%{}, authorize?: false)

    assert %{"contract" => "city-of-brussels-council"} = review_case.normalized_content
    refute inspect(review_case.normalized_content) =~ "Election"
    assert Council.list_agenda_item_identities!("city-of-brussels", "2026-10-12") == []
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "an unknown document of a recorded corpus meeting stays out of its sealed page", %{
    commune: commune
  } do
    url = "https://www.brussels.be/sites/default/files/OJSUP07092026.pdf"

    {_version, run} =
      accepted(
        commune,
        url,
        "supplement_20261012_excerpt",
        :supplement,
        nil,
        "2026-09-07",
        ~D[2026-09-07]
      )

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    assert :ok = Ingestion.Pipeline.normalize(run.id, url)

    assert [%{diagnostics: %{"classification" => "processor_unavailable"}}] =
             Review.list_review_cases!(%{}, authorize?: false)

    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "supporting documents never create agenda items", %{commune: commune} do
    url = "https://www.brussels.be/sites/default/files/bo/note.pdf"

    {_version, run} =
      accepted(commune, url, "agenda_20261012_excerpt", :supporting_document)

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    assert :ok = Ingestion.Pipeline.normalize(run.id, url)

    assert Council.list_agenda_item_identities!("city-of-brussels", "2026-10-12") == []
  end

  test "the normal retry resolves a stale unavailable case and leaves nothing blocking the gate",
       %{commune: commune, actor: actor} do
    {version, run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda)

    stale = stale_case!(run, @base_url)
    assert stale.summary == "Automatic normalization is unavailable and requires review"

    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
    retry_and_drain!(stale, version, actor)

    assert Review.list_review_cases!(%{status: :open}, actor: actor) == []
    assert Review.get_review_case!(stale.id, actor: actor).status == :resolved

    meeting =
      Publication.load_meeting(Council.get_ingested_meeting!("city-of-brussels", "2026-10-12").id)

    assert Review.list_blocking_publication_cases!(meeting) == []

    assert_enqueued(
      worker: BrusselsWtf.Workers.PublishMeeting,
      args: %{meeting_id: meeting.id, generation_kind: "automatic"}
    )
  end

  test "retried agenda and supplement publish a full FR/NL/EN page with every item cited", %{
    commune: commune,
    actor: actor
  } do
    {base, base_run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda)

    {supplement, supplement_run} =
      accepted(commune, @supplement_url, "supplement_20261012_excerpt", :supplement)

    stale_base = stale_case!(base_run, @base_url)
    stale_supplement = stale_case!(supplement_run, @supplement_url)
    Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

    retry_and_drain!(stale_base, base, actor)

    # The other document's stale case belongs to an unlinked source, so it blocks nothing.
    first =
      Publication.load_meeting(Council.get_ingested_meeting!("city-of-brussels", "2026-10-12").id)

    assert Review.list_blocking_publication_cases!(first) == []

    retry_and_drain!(stale_supplement, supplement, actor)

    meeting = Publication.load_meeting(first.id)
    input = Publication.generation_input(meeting.id)
    BrusselsWtf.Processors.Stub.put_locales("2026-10-12", coverage(input))

    assert :ok =
             perform_job(BrusselsWtf.Workers.PublishMeeting, %{
               meeting_id: meeting.id,
               generation_kind: "automatic"
             })

    page = Council.get_meeting_page!(Ash.load!(meeting, :meeting_page).meeting_page.id)
    assert page.publication_status == :published

    variants = Council.list_locale_variants!(page.id)
    assert variants |> Enum.map(& &1.locale) |> Enum.uniq() |> Enum.sort() == ~w(en fr nl)

    assert length(input["items"]) == 4

    for item <- input["items"], claim <- item["claims"] do
      assert claim["kind"] == "proposal"
      assert [evidence | _] = claim["evidence"]
      assert evidence["citation_url"] in [@base_url, @supplement_url]
      assert evidence["excerpt"] != ""
      assert evidence["location"] =~ "point #{item["item_number"]}, page"
    end
  end

  describe "the retained full documents" do
    @real_dir System.get_env("CITY_AGENDA_TEXT_DIR")
    @describetag skip: if(is_nil(@real_dir), do: "set CITY_AGENDA_TEXT_DIR to run")

    test "every emitted excerpt occurs on its cited page; the rest fail closed" do
      results =
        for path <- Path.wildcard("#{@real_dir}/*.txt") |> Enum.sort() do
          [date, role | _name] = path |> Path.basename(".txt") |> String.split("--")
          text = File.read!(path)
          pages = text |> String.split("\f") |> Enum.reject(&(String.trim(&1) == ""))

          case CouncilProcessor.normalize(%{
                 "sha256" => "unseen-#{Path.basename(path)}",
                 "commune_slug" => "city-of-brussels",
                 "meeting_identifier" => date,
                 "scheduled_on" => date,
                 "role" => role,
                 "page_count" => length(pages),
                 "text" => text
               }) do
            {:ok, normalized} ->
              proposals = Enum.flat_map(normalized["items"], &Map.get(&1, "proposals", []))
              assert proposals != []

              for proposal <- proposals do
                evidence = proposal["evidence"]

                assert [_, page, total] =
                         Regex.run(~r/, page (\d+)\/(\d+)$/, evidence["location"])

                assert String.to_integer(total) == length(pages)

                assert squish(Enum.at(pages, String.to_integer(page) - 1)) =~
                         squish(evidence["excerpt"])
              end

              {date, role, length(normalized["items"]), length(proposals)}

            {:error, {:normalization_ambiguity, details}} ->
              {date, role, :review_case, Enum.map(details["unverified"] || [], & &1["reason"])}

            {:error, :processor_unimplemented} ->
              {date, role, :unavailable}
          end
        end

      IO.inspect(results, label: "real City agendas", limit: :infinity)
      assert results != []
    end

    test "the two real agendas of the latest meeting build a valid publication input", %{
      commune: commune
    } do
      read = fn role ->
        [path] = Path.wildcard("#{@real_dir}/2026-10-12--#{role}--*.txt")
        File.read!(path)
      end

      {_base, base_run} =
        accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda, read.("agenda"))

      {_supplement, supplement_run} =
        accepted(
          commune,
          @supplement_url,
          "supplement_20261012_excerpt",
          :supplement,
          read.("supplement")
        )

      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

      assert :ok = Ingestion.Pipeline.normalize(base_run.id, @base_url)
      assert :ok = Ingestion.Pipeline.normalize(supplement_run.id, @supplement_url)
      assert Review.list_review_cases!(%{}, authorize?: false) == []

      meeting =
        Publication.load_meeting(
          Council.get_ingested_meeting!("city-of-brussels", "2026-10-12").id
        )

      assert Review.list_blocking_publication_cases!(meeting) == []

      input = PublicationInput.build(meeting)
      assert PublicationInput.validate(input) == :ok

      IO.inspect(
        %{items: length(meeting.agenda_items), publishable: length(input["items"])},
        label: "real City 2026-10-12"
      )
    end
  end

  describe "the operator script" do
    test "the default run previews candidates and changes nothing", %{
      commune: commune,
      actor: actor
    } do
      {_version, run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda)
      stale_case!(run, @base_url)
      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)
      normalizations_before = all_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)

      output = capture_io(fn -> eval_script([]) end)

      assert output =~ "read_only: true"
      assert output =~ "month_budget:"
      assert output =~ "candidate_count: 1"
      assert output =~ "ready_count: 1"
      assert output =~ "items: 4"
      assert output =~ "proposals: 2"
      assert output =~ "read-only: nothing was retried"

      assert [%{status: :open}] = Review.list_review_cases!(%{}, actor: actor)
      refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
      assert all_enqueued(worker: BrusselsWtf.Workers.NormalizeSource) == normalizations_before
    end

    test "applying takes the base agenda of the newest meeting first and honours the limit", %{
      commune: commune,
      actor: actor
    } do
      {base, base_run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda)

      {_supplement, supplement_run} =
        accepted(commune, @supplement_url, "supplement_20261012_excerpt", :supplement)

      # A second locator row for one URL, as the City's two listings produce, is one candidate.
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: @base_url,
        parent_index_url: commune.index_url <> "?field_date_document_value=2026",
        meeting_identifier: "2026-10-12",
        scheduled_on: ~D[2026-10-12],
        role: :agenda,
        language: :fr,
        observed_label: "Ordre du jour",
        discovered_at: BrusselsWtf.Clock.utc_now()
      })

      stale_case!(supplement_run, @supplement_url)
      stale_case!(base_run, @base_url)
      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

      output = capture_io(fn -> eval_script(apply?: true, limit: 1, actor_id: actor.id) end)

      assert output =~ "candidate_count: 2"
      assert output =~ "applied: 1"
      assert output =~ ~s(role: "agenda")

      assert [%{args: %{"source_version_id" => id}}] =
               all_enqueued(worker: BrusselsWtf.Workers.ExtractSource)

      assert id == base.id
      assert length(Review.list_review_cases!(%{status: :open}, actor: actor)) == 2
    end

    test "older meetings, other roles and recorded corpus meetings are never retried", %{
      commune: commune,
      actor: actor
    } do
      older_url = "https://www.brussels.be/sites/default/files/old.pdf"
      note_url = "https://www.brussels.be/sites/default/files/note.pdf"
      recorded_url = "https://www.brussels.be/sites/default/files/OJSUP07092026.pdf"

      {_v1, older} =
        accepted(
          commune,
          older_url,
          "agenda_20261012_excerpt",
          :agenda,
          nil,
          "2026-08-31",
          ~D[2026-08-31]
        )

      {_v2, note} = accepted(commune, note_url, "agenda_20261012_excerpt", :supporting_document)

      {_v3, recorded} =
        accepted(
          commune,
          recorded_url,
          "supplement_20261012_excerpt",
          :supplement,
          nil,
          "2026-09-07",
          ~D[2026-09-07]
        )

      for {run, url} <- [{older, older_url}, {note, note_url}, {recorded, recorded_url}] do
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

    test "an ambiguous preview or another open case on the source is reported, never retried", %{
      commune: commune,
      actor: actor
    } do
      text =
        fixture("agenda_20261012_excerpt")
        |> String.replace("Dossiers de Mme l'Echevine Frelinx", "Election d'un neuvième Echevin")

      {_base, base_run} = accepted(commune, @base_url, "agenda_20261012_excerpt", :agenda, text)

      {_supplement, supplement_run} =
        accepted(commune, @supplement_url, "supplement_20261012_excerpt", :supplement)

      stale_case!(base_run, @base_url)
      stale_case!(supplement_run, @supplement_url)

      Ingestion.NormalizationReview.open_contract_change(supplement_run.id, "old", "new")

      Application.put_env(:brussels_wtf, :processors, ProductionNormalization)

      output = capture_io(fn -> eval_script(apply?: true, limit: 25, actor_id: actor.id) end)

      assert output =~ "normalization_ambiguity"
      assert output =~ ":other_open_normalization_case"
      assert output =~ "ready_count: 0"
      assert output =~ "applied: 0"
      refute output =~ "Election"
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

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

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

  defp fixture(name), do: File.read!("#{@fixtures}/#{name}.txt")

  # The state production holds: the release that read this run had no City normalizer.
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
         meeting_identifier \\ "2026-10-12",
         scheduled_on \\ ~D[2026-10-12]
       ) do
    text = text || fixture(fixture_name)

    bytes =
      "%PDF controlled City normalization fixture #{origin} #{BrusselsWtf.Digest.sha256(text)}"

    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: origin,
        role: role,
        original_language: :fr
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
      language: :fr,
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
