defmodule BrusselsWtf.Council.PublicationLifecycleTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.Publication
  alias BrusselsWtf.Council.PublicationLifecycle
  alias BrusselsWtf.Review.Actor

  defmodule InterleavedRecordedCoverage do
    @behaviour BrusselsWtf.Processors.Coverage

    @impl true
    defdelegate generate_fr(input), to: BrusselsWtf.Processors.Stub

    @impl true
    def translate(canonical, locale) do
      if locale == "en", do: Process.get({__MODULE__, :before_en}).()
      BrusselsWtf.Processors.Stub.translate(canonical, locale)
    end

    @impl true
    def maximum_cost(_operation, _input), do: {:ok, 0}

    @impl true
    def metadata do
      BrusselsWtf.Processors.Stub.metadata()
      |> Map.merge(%{
        processor_name: "interleaved-recorded-coverage",
        config_hash: "sha256:interleaved-recorded-coverage"
      })
    end
  end

  setup do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    %{
      actor: %Actor{id: "rico", role: :reviewer},
      meeting: meeting,
      page: page,
      scenario: scenario
    }
  end

  test "factual and typography corrections preserve synchronized immutable history", %{
    conn: conn,
    actor: actor,
    meeting: meeting,
    page: page
  } do
    [original] = Council.list_publication_revisions!(page.id)
    input_before = Publication.generation_input(meeting.id)

    factual_bundles =
      original.content
      |> bundles_from_content()
      |> Map.new(fn {locale, bundle} ->
        corrected =
          bundle
          |> put_in(["page", "title"], "Corrected #{locale} meeting title")
          |> put_in(["items", "4", "variant", "summary"], "Corrected #{locale} summary")
          |> put_in(
            ["items", "4", "variant", "proposal_summary"],
            "Corrected #{locale} proposal"
          )

        {locale, corrected}
      end)

    notes = %{
      "fr" => "Correction factuelle publiée après vérification de la source.",
      "nl" => "Feitelijke correctie gepubliceerd na controle van de bron.",
      "en" => "Factual correction published after checking the source."
    }

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 09:00:00Z])
    corrected = PublicationLifecycle.factual_correction!(page.id, factual_bundles, notes, actor)

    assert corrected.revision_kind == :factual_correction
    assert corrected.previous_revision_id == original.id
    assert corrected.actor_id == "rico"
    assert corrected.correction_notes == notes
    assert corrected.publication_metadata["gate_result"]["ready"]
    assert corrected.publication_metadata["locales"] == ["fr", "nl", "en"]
    assert corrected.publication_metadata["evidence"] != []

    assert Map.keys(corrected.publication_metadata["processors"]) |> Enum.sort() ==
             ["en", "fr", "nl"]

    assert Council.list_publication_revisions!(page.id) |> Enum.map(& &1.id) == [
             original.id,
             corrected.id
           ]

    assert original.content != corrected.content
    assert Publication.generation_input(meeting.id) == input_before

    for locale <- ["fr", "nl", "en"] do
      html = conn |> get("/meetings/ixelles/268?lang=#{locale}") |> html_response(200)
      assert html =~ "Corrected #{locale} meeting title"
      assert html =~ notes[locale]
    end

    nl_bundle =
      corrected.content
      |> bundle_from_content("nl")
      |> put_in(["page", "title"], "Typografisch verbeterde titel")

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 10:00:00Z])

    typography =
      PublicationLifecycle.typography_correction!(page.id, "nl", nl_bundle, actor)

    assert typography.revision_kind == :typography_correction
    assert typography.previous_revision_id == corrected.id
    assert typography.correction_notes == %{}

    assert get_in(typography.content, ["page", "nl", "title"]) ==
             "Typografisch verbeterde titel"

    assert typography.content["page"]["fr"] == corrected.content["page"]["fr"]
    assert typography.content["page"]["en"] == corrected.content["page"]["en"]
    assert Publication.generation_input(meeting.id) == input_before

    nl_html = conn |> get("/meetings/ixelles/268?lang=nl") |> html_response(200)
    assert nl_html =~ "Typografisch verbeterde titel"
    assert nl_html =~ notes["nl"]
    refute nl_html =~ "Typography correction"
  end

  test "withdrawal keeps every stable route and republication records the interval", %{
    conn: conn,
    actor: actor,
    meeting: meeting,
    page: page
  } do
    [original] = Council.list_publication_revisions!(page.id)
    [item] = meeting.agenda_items
    original_title = get_in(original.content, ["page", "en", "title"])

    reasons = %{
      "fr" => "Contenu retiré pendant la vérification d’une correction.",
      "nl" => "Inhoud ingetrokken tijdens de controle van een correctie.",
      "en" => "Coverage withdrawn while a correction is checked."
    }

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 11:00:00Z])

    reviewer_conn =
      conn
      |> init_test_session(%{})
      |> BrusselsWtfWeb.ReviewAuth.log_in(actor)

    csrf = Plug.CSRFProtection.get_csrf_token()

    withdrawn_response =
      post(reviewer_conn, "/review/publications/#{page.id}/withdraw", %{
        "_csrf_token" => csrf,
        "reasons" => Jason.encode!(reasons)
      })

    assert redirected_to(withdrawn_response) == "/review"

    withdrawn = Council.get_meeting_page!(page.id)
    assert withdrawn.publication_status == :draft
    assert withdrawn.withdrawn_by == "rico"
    assert withdrawn.withdrawal_reasons == reasons

    for locale <- ["fr", "nl", "en"] do
      html = conn |> get("/meetings/ixelles/268?lang=#{locale}") |> html_response(200)
      assert html =~ reasons[locale]
      assert html =~ ~s(id="#{item.stable_anchor}")
      refute html =~ "Outdoor film screening"
    end

    timeline = conn |> get("/?lang=en") |> html_response(200)
    refute timeline =~ "/meetings/ixelles/268"

    assert_raise ArgumentError, "publication action requires a reviewer", fn ->
      PublicationLifecycle.republish!(page.id, %{id: "reader", role: :reader})
    end

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 12:00:00Z])

    republished_response =
      withdrawn_response
      |> recycle()
      |> post("/review/publications/#{page.id}/republish", %{"_csrf_token" => csrf})

    assert redirected_to(republished_response) == "/review"
    republished = Council.list_publication_revisions!(page.id) |> List.last()

    assert republished.revision_kind == :republication
    assert republished.previous_revision_id == original.id
    assert republished.published_at == ~U[2026-08-21 12:00:00.000000Z]

    current = Council.get_meeting_page!(page.id)
    assert current.publication_status == :published
    assert current.withdrawn_at == nil
    assert current.current_revision_id == republished.id

    html = conn |> get("/meetings/ixelles/268?lang=en") |> html_response(200)
    assert html =~ original_title
    refute html =~ reasons["en"]

    events = Council.list_publication_events!(page.id)
    assert Enum.map(events, & &1.event_type) == [:published, :withdrawn, :republished]
    assert Enum.map(events, & &1.actor_id) == [nil, "rico", "rico"]
    assert List.last(events).details["withdrawn_at"] == "2026-08-21T11:00:00.000000Z"
  end

  test "unscoped republication rejects newly normalized claim-bearing agenda items", %{
    actor: actor,
    meeting: meeting,
    page: page
  } do
    [existing_item] = meeting.agenda_items

    PublicationLifecycle.withdraw!(
      page.id,
      %{"fr" => "Retiré", "nl" => "Ingetrokken", "en" => "Withdrawn"},
      actor
    )

    new_item =
      Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "5",
        authoritative_identifier: "new-item-after-publication",
        source_wording: "Newly normalized legitimate agenda item",
        current_source_version_id: existing_item.current_source_version_id,
        current_version_order: "later",
        procedural_state: :unknown,
        outcome: :unknown
      })

    Council.record_proposal!(%{
      agenda_item_id: new_item.id,
      source_version_id: existing_item.current_source_version_id,
      text: "A newly normalized proposal that changes the publishable set."
    })

    assert_raise ArgumentError,
                 "withdrawn content is stale and requires a new generated revision",
                 fn ->
                   PublicationLifecycle.republish!(page.id, actor)
                 end

    assert Council.get_meeting_page!(page.id).publication_status == :draft
  end

  test "unscoped republication ignores newly normalized items without claims", %{
    actor: actor,
    meeting: meeting,
    page: page
  } do
    [existing_item] = meeting.agenda_items

    PublicationLifecycle.withdraw!(
      page.id,
      %{"fr" => "Retiré", "nl" => "Ingetrokken", "en" => "Withdrawn"},
      actor
    )

    Council.upsert_agenda_item!(%{
      council_meeting_id: meeting.id,
      item_number: "5",
      authoritative_identifier: "information-after-publication",
      source_wording: "Information au Conseil communal des décisions prises par le Collège.",
      current_source_version_id: existing_item.current_source_version_id,
      current_version_order: "later",
      procedural_state: :unknown,
      outcome: :unknown
    })

    revision = PublicationLifecycle.republish!(page.id, actor)
    assert revision.revision_kind == :republication

    republished = Council.get_meeting_page!(page.id)
    assert republished.publication_status == :published
    refute republished.withdrawn_at

    reloaded = Council.get_ingested_meeting!("ixelles", "268")
    assert length(reloaded.agenda_items) == 2

    information = Enum.find(reloaded.agenda_items, &(&1.item_number == "5"))
    assert Ash.load!(information, :coverage_variants).coverage_variants == []
    refute information.published?

    published_items = Enum.filter(reloaded.agenda_items, & &1.published?)
    assert Enum.map(published_items, & &1.item_number) == ["4"]
  end

  test "a newer revision survives an interleaved recorded correction and its attempted runs remain",
       %{
         conn: conn,
         actor: actor,
         page: page
       } do
    [original] = Council.list_publication_revisions!(page.id)
    previous_processor = Application.fetch_env!(:brussels_wtf, :coverage_processor)
    on_exit(fn -> Application.put_env(:brussels_wtf, :coverage_processor, previous_processor) end)
    Application.put_env(:brussels_wtf, :coverage_processor, InterleavedRecordedCoverage)

    newer_bundle =
      original.content
      |> bundle_from_content("en")
      |> put_in(["page", "title"], "Newer editorial revision")

    # Interleave another real domain publication at the external processor seam.
    # The first expected-revision check has passed, but final publication has not.
    Process.put({InterleavedRecordedCoverage, :before_en}, fn ->
      newer = PublicationLifecycle.typography_correction!(page.id, "en", newer_bundle, actor)
      Process.put(:newer_revision_id, newer.id)
    end)

    notes = %{"fr" => "Correction", "nl" => "Correctie", "en" => "Correction"}

    assert_raise ArgumentError, "stale publication revision", fn ->
      Publication.recorded_factual_correction!(page.id, original.id, notes, actor)
    end

    assert Council.get_meeting_page!(page.id).current_revision_id ==
             Process.get(:newer_revision_id)

    assert Enum.map(Council.list_publication_revisions!(page.id), & &1.id) ==
             [original.id, Process.get(:newer_revision_id)]

    attempts =
      Council.list_coverage_runs!(page.id)
      |> Enum.filter(&(&1.processor_name == "interleaved-recorded-coverage"))

    assert length(attempts) == 3
    assert Enum.sort(Enum.map(attempts, & &1.locale)) == ~w(en fr nl)
    assert Enum.all?(attempts, &(&1.status == :succeeded and &1.output != %{}))

    assert conn |> get("/meetings/ixelles/268?lang=en") |> html_response(200) =~
             "Newer editorial revision"
  end

  test "withdrawal during recorded generation is not erased by the correction", %{
    conn: conn,
    actor: actor,
    page: page
  } do
    [original] = Council.list_publication_revisions!(page.id)
    variants_before = Council.list_locale_variants!(page.id)
    previous_processor = Application.fetch_env!(:brussels_wtf, :coverage_processor)
    on_exit(fn -> Application.put_env(:brussels_wtf, :coverage_processor, previous_processor) end)
    Application.put_env(:brussels_wtf, :coverage_processor, InterleavedRecordedCoverage)

    reasons = %{
      "fr" => "Retiré pendant la vérification des sources.",
      "nl" => "Ingetrokken tijdens de bronnencontrole.",
      "en" => "Withdrawn while the sources are checked."
    }

    withdrawn_at = BrusselsWtf.Clock.utc_now()

    Process.put({InterleavedRecordedCoverage, :before_en}, fn ->
      PublicationLifecycle.withdraw!(page.id, reasons, actor)
    end)

    notes = %{"fr" => "Correction", "nl" => "Correctie", "en" => "Correction"}

    assert_raise ArgumentError, "stale publication revision", fn ->
      Publication.recorded_factual_correction!(page.id, original.id, notes, actor)
    end

    withdrawn = Council.get_meeting_page!(page.id)
    assert withdrawn.publication_status == :draft
    assert DateTime.compare(withdrawn.withdrawn_at, withdrawn_at) == :eq
    assert withdrawn.withdrawal_reasons == reasons
    assert withdrawn.current_revision_id == original.id
    assert Council.list_locale_variants!(page.id) == variants_before
    assert Enum.map(Council.list_publication_revisions!(page.id), & &1.id) == [original.id]

    assert Enum.map(Council.list_publication_events!(page.id), & &1.event_type) == [
             :published,
             :withdrawn
           ]

    attempts =
      Council.list_coverage_runs!(page.id)
      |> Enum.filter(&(&1.processor_name == "interleaved-recorded-coverage"))

    assert length(attempts) == 3
    assert Enum.sort(Enum.map(attempts, & &1.locale)) == ~w(en fr nl)
    assert Enum.all?(attempts, &(&1.status == :succeeded and &1.output != %{}))

    for locale <- ~w(fr nl en) do
      html =
        conn |> recycle() |> get("/meetings/ixelles/268?lang=#{locale}") |> html_response(200)

      assert html =~ reasons[locale]
      refute html =~ get_in(original.content, ["items", "4", "variants", locale, "title"])
    end
  end

  defp bundles_from_content(content) do
    Map.new(["fr", "nl", "en"], &{&1, bundle_from_content(content, &1)})
  end

  defp bundle_from_content(content, locale) do
    %{
      "page" => content["page"][locale],
      "items" =>
        Map.new(content["items"], fn {item_key, item} ->
          {item_key, %{"claim_refs" => item["claim_refs"], "variant" => item["variants"][locale]}}
        end)
    }
  end
end
