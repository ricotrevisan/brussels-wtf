defmodule BrusselsWtfWeb.SourceInterpretationTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council
  alias BrusselsWtf.Test.Harness

  @proposal_interpretation "Approuver le procès-verbal de la séance du Conseil communal du 21 mai 2026."
  @proposal_excerpt "Procès-verbal de la séance du Conseil communal du 21 mai 2026. Approbation."

  test "published proposal interpretations are not presented as source quotations in any locale" do
    scenario = Harness.load("ixelles/final-267")

    # A normalized interpretation can differ from the retained official evidence.
    outputs =
      put_in(
        scenario.sources.minutes.outputs,
        [:normalize, "items", Access.at(0), "decisions", Access.at(0), "statement"],
        "Le procès-verbal précédent est approuvé par le Conseil."
      )

    BrusselsWtf.Processors.Stub.put(scenario.sources.minutes.sha256, outputs)

    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = Harness.drain_pipeline()
    assert_interpretation(scenario.expected.path)

    assert :ok = Harness.advance("final")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = Harness.drain_pipeline(until: :normalize)

    # Normalizing a final record does not publish the decision or its interpretation.
    assert_interpretation(scenario.expected.path)
    staged = build_conn() |> get(scenario.expected.path <> "?lang=en") |> html_response(200)
    refute staged =~ "Decision: approved"
    refute staged =~ "37 for"

    assert :ok = Harness.drain_pipeline(from: :publish)
    assert_interpretation(scenario.expected.path)
    published = build_conn() |> get(scenario.expected.path <> "?lang=en") |> html_response(200)
    assert published =~ "Decision: approved"
    assert published =~ "37 for"

    # A new interpretation of the same immutable bytes is still unpublished.
    page = Council.get_published_meeting_page!("ixelles", "267")
    [item] = page.council_meeting.agenda_items

    Council.record_proposal!(%{
      agenda_item_id: item.id,
      source_version_id: item.published_proposal.source_version_id,
      interpretation_key: "unpublished-interpretation-regression",
      source_version_order: "9:unpublished",
      text: "UNPUBLISHED INTERPRETATION MUST STAY PRIVATE"
    })

    assert_interpretation(scenario.expected.path)
  end

  defp assert_interpretation(path) do
    for {locale, label, old_label} <- [
          {"fr", "Interprétation de la proposition fondée sur les sources",
           "Extrait dans la langue de la source"},
          {"nl", "Brononderbouwde interpretatie van het voorstel",
           "Bronfragment in de oorspronkelijke taal"},
          {"en", "Source-backed proposal interpretation", "Original-language source excerpt"}
        ] do
      html = build_conn() |> get(path <> "?lang=#{locale}") |> html_response(200)
      document = LazyHTML.from_document(html)

      quotations =
        Enum.map(document["article blockquote, article q"], &(LazyHTML.text(&1) |> String.trim()))

      refute @proposal_interpretation in quotations
      refute "Le procès-verbal précédent est approuvé par le Conseil." in quotations

      interpretation =
        Enum.find(document["article details"], fn details ->
          LazyHTML.text(details["summary"]) |> String.trim() == label
        end)

      assert interpretation, "missing truthful interpretation label for #{locale}"
      assert LazyHTML.text(interpretation["p"]) |> String.trim() == @proposal_interpretation
      assert LazyHTML.attribute(interpretation["p"], "lang") == ["und"]
      refute html =~ old_label
      refute html =~ @proposal_excerpt
      refute html =~ "UNPUBLISHED INTERPRETATION MUST STAY PRIVATE"
      refute html =~ "object_key"
      refute html =~ "/review/artifacts"

      assert "https://www.ixelles.be/uploads/conseil/odj/267.pdf#page=1" in LazyHTML.attribute(
               document[~s(article a[rel="external"])],
               "href"
             )

      assert html =~ "Ordre du jour complémentaire, page 1/14"
    end
  end
end
