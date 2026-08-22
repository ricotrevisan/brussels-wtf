defmodule BrusselsWtf.Council.PublicationLifecycleTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.Publication
  alias BrusselsWtf.Council.PublicationLifecycle
  alias BrusselsWtf.Review.Actor

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

  test "unscoped republication rejects newly normalized agenda items", %{
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
      authoritative_identifier: "new-item-after-publication",
      source_wording: "Newly normalized legitimate agenda item",
      current_source_version_id: existing_item.current_source_version_id,
      current_version_order: "later",
      procedural_state: :unknown,
      outcome: :unknown
    })

    assert_raise ArgumentError,
                 "withdrawn content is stale and requires a new generated revision",
                 fn ->
                   PublicationLifecycle.republish!(page.id, actor)
                 end

    assert Council.get_meeting_page!(page.id).publication_status == :draft
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
