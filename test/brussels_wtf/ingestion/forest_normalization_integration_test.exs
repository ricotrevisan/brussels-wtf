defmodule BrusselsWtf.Ingestion.ForestNormalizationIntegrationTest do
  @moduledoc """
  Proves the Forest path through the real composite: a stale "normalization unavailable"
  case, the operator requeue, the audited review retry, normalization, and an FR/NL/EN
  publication with every item cited. Only extraction and coverage text use fixtures.
  """

  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  import ExUnit.CaptureIO
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, html_response: 2]

  alias BrusselsWtf.{Council, ForestAgendaFixture, Ingestion, Review}
  alias BrusselsWtf.Processors.Stub

  @endpoint BrusselsWtfWeb.Endpoint
  @script "priv/ops/requeue_forest_agendas_20261104.exs"
  @actor %Review.Actor{id: "rico", role: :reviewer}
  @index "https://forest.brussels/fr/publications/conseil-communal-1"

  defmodule CompositeWithStubExtraction do
    @moduledoc false
    @behaviour BrusselsWtf.Processors

    @impl true
    def extract(meta, bytes), do: BrusselsWtf.Processors.Stub.extract(meta, bytes)

    @impl true
    def normalize(input), do: BrusselsWtf.Processors.Council.normalize(input)
  end

  setup do
    previous = Application.fetch_env!(:brussels_wtf, :processors)
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    BrusselsWtf.Archive.Memory.reset()
    Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-11-04 08:00:00Z])

    commune =
      Ingestion.create_commune!(%{slug: "forest", name: "Forest", index_url: @index})

    {:ok, commune: commune}
  end

  defp archived_source(commune, name, identifier, role, text, pages) do
    origin = "https://forest.brussels/#{name}.pdf"
    bytes = "%PDF forest integration fixture #{name}"
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
      parent_index_url: @index,
      meeting_identifier: identifier,
      scheduled_on: Date.from_iso8601!(identifier),
      role: role,
      language: :bilingual,
      observed_label: "Ordre du jour",
      discovered_at: BrusselsWtf.Clock.utc_now()
    })

    Stub.put(version.sha256, %{
      extract: %{"text" => text, "page_texts" => pages},
      normalize: {:error, :processor_unimplemented}
    })

    %{origin: origin, version: version}
  end

  # A source processed before this normalizer existed: accepted text and one stale case.
  defp stale_source(commune, name, identifier, role, text, pages) do
    %{origin: origin, version: version} =
      source =
      archived_source(commune, name, identifier, role, text, pages)

    assert :ok = Ingestion.Pipeline.extract(version.id, 1, :backfill)

    run =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.status == :succeeded))

    assert :ok = Ingestion.Pipeline.normalize(run.id, origin, 1, 3, :backfill)

    # Production holds no queued work from this earlier generation.
    BrusselsWtf.Repo.delete_all(Oban.Job)

    review_case =
      Review.list_review_cases!(%{kind: :normalization, status: :open}, actor: @actor)
      |> Enum.find(&(&1.source_version_id == version.id))

    assert review_case.diagnostics["classification"] == "processor_unavailable"
    Map.merge(source, %{run: run, review_case: review_case})
  end

  defp stale_agenda(commune) do
    stale_source(
      commune,
      "agenda-20260922",
      "2026-09-22",
      :agenda,
      ForestAgendaFixture.text(),
      ForestAgendaFixture.pages()
    )
  end

  defp use_composite,
    do: Application.put_env(:brussels_wtf, :processors, CompositeWithStubExtraction)

  defp dry_run do
    capture_io(fn ->
      {result, _bindings} = Code.eval_file(@script)
      assert result == :ok
    end)
  end

  defp apply_requeue(limit \\ 2) do
    capture_io(fn ->
      {result, _bindings} =
        Code.eval_string(File.read!(@script), apply?: true, limit: limit, actor_id: "rico")

      assert result == :ok
    end)
  end

  defp locale_fixture(numbers, sha256) do
    labels = %{
      "fr" => {"Point", "Proposition à l'ordre du jour"},
      "nl" => {"Punt", "Voorstel op de agenda"},
      "en" => {"Item", "Proposal on the agenda"}
    }

    %{
      "page" =>
        Map.new(labels, fn {locale, {_title, summary}} ->
          {locale, %{"title" => "Conseil 2026-09-22 #{locale}", "summary" => summary}}
        end),
      "items" =>
        Map.new(numbers, fn number ->
          {"@item_number:#{number}",
           %{
             "claim_refs" => ["proposal:@item_key:#{sha256}"],
             "variants" =>
               Map.new(labels, fn {locale, {title, summary}} ->
                 {locale,
                  %{
                    "title" => "#{title} #{number}",
                    "summary" => summary,
                    "proposal_summary" => summary
                  }}
               end)
           }}
        end)
    }
  end

  test "the requeue dry run previews the agenda and changes nothing", %{commune: commune} do
    source = stale_agenda(commune)
    use_composite()

    output = dry_run()

    assert output =~ ~s(generate: "issue-149-forest-agenda-requeue")
    assert output =~ "read_only: true"
    assert output =~ "ready_count: 1"
    assert output =~ "items: 6"
    assert output =~ "proposals: 4"
    assert output =~ "non_votable: 2"
    assert output =~ "read-only: nothing was requeued"

    assert Review.get_review_case!(source.review_case.id, actor: @actor).status == :open
    assert {:error, _} = Council.get_ingested_meeting("forest", "2026-09-22")
    refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
    refute_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "the retry resolves the stale case and publishes FR/NL/EN with every item cited", %{
    commune: commune
  } do
    source = stale_agenda(commune)
    use_composite()
    Stub.put_locales("2026-09-22", locale_fixture(~w(1 2 3 4), source.version.sha256))

    assert apply_requeue() =~ "retry_requested"
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(from: :extract)

    detail = Review.get_review_case!(source.review_case.id, actor: @actor)
    assert detail.status == :resolved
    assert Review.list_review_cases!(%{kind: :normalization, status: :open}, actor: @actor) == []

    meeting = Council.get_ingested_meeting!("forest", "2026-09-22")
    assert meeting.scheduled_on == ~D[2026-09-22]
    assert length(meeting.agenda_items) == 6

    # Every item is a proposal or a non-votable point; an agenda never decides.
    for item <- meeting.agenda_items do
      assert item.outcome == :unknown
      assert is_nil(item.decision)
      refute item.procedural_state == :decision
    end

    assert meeting.agenda_items
           |> Enum.reject(&(&1.proposals == []))
           |> Enum.map(& &1.item_number)
           |> Enum.sort() == ~w(1 2 3 4)

    for item <- meeting.agenda_items, proposal <- item.proposals do
      assert [evidence] = proposal.evidence
      assert evidence.citation_url == source.origin
      assert evidence.excerpt == proposal.text
      assert evidence.source_version_id == source.version.id
      refute evidence.synthetic

      assert BrusselsWtf.Processors.ForestCouncil.excerpt_on_cited_pages?(
               %{"excerpt" => evidence.excerpt, "location" => evidence.location},
               ForestAgendaFixture.pages()
             )
    end

    assert {:ok, page} = Council.get_published_meeting_page("forest", "2026-09-22")
    assert page.publication_status == :published
    assert page.current_revision_id

    assert Council.publication_readiness!(page.id).ready?

    for {locale, heading} <- [{"fr", "Point 1"}, {"nl", "Punt 1"}, {"en", "Item 1"}] do
      html =
        build_conn()
        |> get("/meetings/forest/2026-09-22?lang=#{locale}")
        |> html_response(200)

      assert html =~ heading
      assert html =~ source.origin
      refute html =~ "BRASS"
    end
  end

  test "a new agenda publishes with no operator, and its notes case does not block it", %{
    commune: commune
  } do
    use_composite()
    text = ForestAgendaFixture.text()
    pages = ForestAgendaFixture.pages()

    agenda = archived_source(commune, "new-agenda", "2026-09-22", :agenda, text, pages)
    notes = archived_source(commune, "new-notes", "2026-09-22", :explanatory_notes, text, pages)
    Stub.put_locales("2026-09-22", locale_fixture(~w(1 2 3 4), agenda.version.sha256))

    assert :ok = Ingestion.Pipeline.extract(agenda.version.id)
    assert :ok = Ingestion.Pipeline.extract(notes.version.id)
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(from: :normalize)

    assert [notes_case] =
             Review.list_review_cases!(%{kind: :normalization, status: :open}, actor: @actor)

    assert notes_case.source_version_id == notes.version.id
    assert notes_case.diagnostics["classification"] == "processor_unavailable"

    assert {:ok, %{publication_status: :published}} =
             Council.get_published_meeting_page("forest", "2026-09-22")
  end

  describe "a complementary agenda restates the whole list" do
    defp complementary(text) do
      text
      |> String.replace("ORDRE DU JOUR\n", "ORDRE DU JOUR COMPLÉMENTAIRE\n")
      |> String.replace("AGENDA\n", "AANVULLENDE AGENDA\n")
      |> String.replace("- Ordre du jour public", "- Ordre du jour complémentaire public")
      |> String.replace("- Openbare agenda", "- Aanvullende openbare agenda")
    end

    defp normalize_new_source(source) do
      assert :ok = Ingestion.Pipeline.extract(source.version.id)
      assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(from: :normalize, until: :normalize)
    end

    test "an earlier point it drops opens a blocking review instead of staying current", %{
      commune: commune
    } do
      use_composite()
      base_text = ForestAgendaFixture.text()
      base_pages = ForestAgendaFixture.pages()

      base = archived_source(commune, "base", "2026-09-22", :agenda, base_text, base_pages)
      normalize_new_source(base)
      BrusselsWtf.Repo.delete_all(Oban.Job)

      [question | _rest] = String.split(List.last(base_pages), "    6        Question orale")

      shortened_pages =
        List.replace_at(base_pages, 3, question <> ForestAgendaFixture.footer(4, 4))

      shortened = Enum.map(shortened_pages, &complementary/1)

      later =
        archived_source(
          commune,
          "complementary",
          "2026-09-22",
          :complementary_agenda,
          Enum.join(shortened, "\f") <> "\f",
          shortened
        )

      normalize_new_source(later)

      assert [review_case] =
               Review.list_review_cases!(%{kind: :normalization, status: :open}, actor: @actor)

      assert review_case.diagnostics["classification"] == "normalization_ambiguity"
      assert [%{"item_number" => "6"}] = review_case.normalized_content["unrestated_items"]
      refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
    end
  end

  test "an ambiguous document stays out of the requeue and opens no second path", %{
    commune: commune
  } do
    text = String.replace(ForestAgendaFixture.text(), "GEMEENTEBESTUUR VORST", "GEMEENTEBESTUUR")

    source =
      stale_source(
        commune,
        "broken",
        "2026-09-22",
        :agenda,
        text,
        String.split(text, "\f", trim: true)
      )

    use_composite()

    output = apply_requeue()

    assert output =~ "preview_ambiguous"
    assert output =~ "applied: 0"
    assert Review.get_review_case!(source.review_case.id, actor: @actor).status == :open
    refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
  end

  test "a document that stops verifying after the preview opens a new case and never publishes",
       %{commune: commune} do
    source = stale_agenda(commune)
    use_composite()

    assert apply_requeue() =~ "retry_requested"

    # New text at extraction time: the retry resolves the stale case, the normalizer refuses.
    broken =
      String.replace(ForestAgendaFixture.text(), "GEMEENTEBESTUUR VORST", "GEMEENTEBESTUUR")

    Stub.put(source.version.sha256, %{
      extract: %{"text" => broken, "page_texts" => String.split(broken, "\f", trim: true)}
    })

    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(from: :extract)

    assert [review_case] =
             Review.list_review_cases!(%{kind: :normalization, status: :open}, actor: @actor)

    assert review_case.id != source.review_case.id
    assert review_case.diagnostics["classification"] == "normalization_ambiguity"
    assert review_case.normalized_content["contract"] == "forest-council"
    assert {:error, _} = Council.get_ingested_meeting("forest", "2026-09-22")
  end

  test "notes, the recorded corpus meeting and earlier meetings are never requeued", %{
    commune: commune
  } do
    notes =
      stale_source(
        commune,
        "notes",
        "2026-10-13",
        :explanatory_notes,
        ForestAgendaFixture.text(),
        ForestAgendaFixture.pages()
      )

    corpus =
      stale_source(
        commune,
        "corpus-agenda",
        "2026-09-01",
        :agenda,
        ForestAgendaFixture.text(),
        ForestAgendaFixture.pages()
      )

    early =
      stale_source(
        commune,
        "early",
        "2026-06-23",
        :complementary_agenda,
        ForestAgendaFixture.text(),
        ForestAgendaFixture.pages()
      )

    use_composite()

    output = apply_requeue(25)

    assert output =~ ~s(reason: "not_an_agenda")
    assert output =~ ~s(reason: "recorded_corpus_meeting")
    assert output =~ "untouched_before_2026_09_01: 1"
    assert output =~ "ready_count: 0"
    assert output =~ "applied: 0"

    for source <- [notes, corpus, early] do
      assert Review.get_review_case!(source.review_case.id, actor: @actor).disposition == :open
    end

    refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
  end

  test "a second apply does not retry a case already requested", %{commune: commune} do
    stale_agenda(commune)
    use_composite()

    assert apply_requeue() =~ "applied: 1"
    assert apply_requeue() =~ "applied: 0"
    assert length(all_enqueued(worker: BrusselsWtf.Workers.ExtractSource)) == 1
  end

  test "the script refuses an unbounded or unattributed apply" do
    source = File.read!(@script)

    assert_raise RuntimeError, ~r/more than 25/, fn ->
      Code.eval_string(source, apply?: true, limit: 26, actor_id: "rico")
    end

    assert_raise RuntimeError, ~r/limit must be positive/, fn ->
      Code.eval_string(source, apply?: true, limit: 0, actor_id: "rico")
    end

    assert_raise RuntimeError, ~r/limit must be an integer/, fn ->
      Code.eval_string(source, apply?: true, actor_id: "rico")
    end

    assert_raise RuntimeError, ~r/actor_id must name/, fn ->
      Code.eval_string(source, apply?: true, limit: 1)
    end
  end
end
