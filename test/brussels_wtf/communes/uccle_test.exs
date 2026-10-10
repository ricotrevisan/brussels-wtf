defmodule BrusselsWtf.Communes.UccleTest do
  use ExUnit.Case, async: true

  @index_url "https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal"

  @current_index_url "https://www.uccle.be/fr/ma-commune/le-conseil-communal"

  test "discovers the captured current September agendas and notes without inventing a register" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    assert {:ok, locators} = BrusselsWtf.Communes.Uccle.discover(index, @current_index_url)

    september = Enum.filter(locators, &(&1.scheduled_on == ~D[2026-09-10]))

    assert Enum.map(september, &{&1.role, &1.url}) == [
             {:agenda,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-ODJ-U1180_fr_nl.pdf"},
             {:complementary_agenda,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-ODJC-U1180_fr_nl.pdf"},
             {:explanatory_note,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-NE_U1180_fr_nl.pdf"},
             {:complementary_explanatory_note,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-NEC-U1180_fr_nl.pdf"}
           ]

    assert Enum.all?(september, fn locator ->
             locator.meeting_identifier == "2026-09-10" and
               locator.parent_index_url == @current_index_url and
               locator.language == :bilingual
           end)

    refute Enum.any?(september, &(&1.role == :register))
    refute Enum.any?(locators, &(&1.scheduled_on == ~D[2026-10-15]))
  end

  test "discovers October agendas and notes when the table matches the next dated calendar session" do
    index =
      File.read!(
        Path.expand("../../support/fixtures/uccle/current-index-october-2026.html", __DIR__)
      )

    assert {:ok, locators} = BrusselsWtf.Communes.Uccle.discover(index, @current_index_url)

    assert Enum.map(locators, &{&1.role, &1.url}) == [
             {:agenda,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-10-15-ODJ-U1180_fr_nl.pdf"},
             {:explanatory_note,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-10-15-NE_U1180_fr_nl.pdf"}
           ]

    assert Enum.all?(locators, fn locator ->
             locator.scheduled_on == ~D[2026-10-15] and
               locator.meeting_identifier == "2026-10-15" and
               locator.parent_index_url == @current_index_url and
               locator.language == :bilingual
           end)
  end

  test "current year context cannot come from filenames, the clock, or a mixed-year calendar" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    for calendar <- [
          "<ul><li>Jeudi 15 octobre</li></ul>",
          "<ul><li>Jeudi 15 octobre 2026</li><li>Jeudi 14 janvier 2027</li></ul>",
          "<ul><li>Jeudi 14 janvier 2027</li></ul>"
        ] do
      ambiguous = Regex.replace(~r/<ul>.*?<\/ul>/s, index, calendar, global: false)

      assert {:error, {:invalid_index, :ambiguous_current_year}} =
               BrusselsWtf.Communes.Uccle.discover(ambiguous, @current_index_url)
    end
  end

  test "current tables accept equality with the next dated calendar session" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    matching = String.replace(index, "Jeudi 15 octobre 2026", "Jeudi 10 septembre 2026")

    assert {:ok, locators} = BrusselsWtf.Communes.Uccle.discover(matching, @current_index_url)
    assert Enum.any?(locators, &(&1.scheduled_on == ~D[2026-09-10]))
  end

  test "current tables cannot be shifted after the next dated calendar session" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    for {old, replacement} <- [
          {"10 septembre&nbsp;", "10 décembre"},
          {"Jeudi 15 octobre 2026", "Jeudi 25 juin 2026"},
          {"Jeudi 15 octobre 2026", "Jeudi 31 septembre 2026"}
        ] do
      ambiguous = String.replace(index, old, replacement)

      assert {:error, {:invalid_index, :ambiguous_current_year}} =
               BrusselsWtf.Communes.Uccle.discover(ambiguous, @current_index_url)
    end
  end

  test "unrelated notice and footer years cannot supply or change the current section year" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    html = "<p>Service fermé le 3 janvier 2027</p>" <> index <> "<footer>2027</footer>"
    assert {:ok, locators} = BrusselsWtf.Communes.Uccle.discover(html, @current_index_url)
    assert Enum.all?(locators, &(&1.scheduled_on.year == 2026))

    no_calendar_year =
      Regex.replace(~r/<ul>.*?<\/ul>/s, html, "<ul><li>Jeudi 15 octobre</li></ul>", global: false)

    assert {:error, {:invalid_index, :ambiguous_current_year}} =
             BrusselsWtf.Communes.Uccle.discover(no_calendar_year, @current_index_url)
  end

  test "mixed current-calendar and archive year sections cannot silently drop the current tables" do
    current =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    archive = File.read!(Path.expand("../../support/fixtures/uccle/adapter-index.html", __DIR__))

    assert {:error, {:invalid_index, :ambiguous_current_year}} =
             BrusselsWtf.Communes.Uccle.discover(current <> archive, @current_index_url)
  end

  test "current tables retain misleading years and malformed suffixes as exact URL observations" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    assert {:ok, locators} = BrusselsWtf.Communes.Uccle.discover(index, @current_index_url)

    assert Enum.any?(locators, fn locator ->
             locator.scheduled_on == ~D[2026-01-22] and locator.role == :question and
               locator.url ==
                 "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-09-11-QE-Cools-sur-les-departs-naturels_U1180_fr.pdf"
           end)

    assert Enum.any?(locators, fn locator ->
             locator.scheduled_on == ~D[2026-06-25] and
               locator.role == :complementary_explanatory_note and
               locator.url ==
                 "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-06-25-NEC-U1180_fr_nl..pdf"
           end)
  end

  test "current tables fail closed on conflicting or ambiguous meeting captions" do
    index =
      File.read!(Path.expand("../../support/fixtures/uccle/current-index-2026.html", __DIR__))

    for caption <- ["10 septembre 2025", "10 et 11 septembre", "31 septembre"] do
      ambiguous = String.replace(index, "10 septembre&nbsp;", caption)

      assert {:error, {:invalid_index, :invalid_meeting_date}} =
               BrusselsWtf.Communes.Uccle.discover(ambiguous, @current_index_url)
    end
  end

  test "discovers every exact link from the meeting table without deriving context from filenames" do
    index = File.read!(Path.expand("../../support/fixtures/uccle/adapter-index.html", __DIR__))

    assert {:ok, locators} = BrusselsWtf.Communes.Uccle.discover(index, @index_url)

    assert Enum.map(locators, &{&1.role, &1.url}) == [
             {:agenda,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJ_U1180_fr_nl.pdf"},
             {:complementary_agenda,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-ODJC-bis_U1180_fr_nl.pdf"},
             {:explanatory_note,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-05-22-NE_U1180_fr_nl.pdf"},
             {:complementary_explanatory_note,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-NEC-bis_U1180_fr_nl.pdf"},
             {:register,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf"},
             {:question,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-QO-ASSAL-Exclusion-des-cheques-sports-des-enfants-de-moins-de-6-ans_U1180_fr.pdf"},
             {:question,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-QO-COOLS-Adoption-a-Uccle-de-la-tarification-reduite-dIxelles-sur-le-stationnement_U1180_fr.pdf"},
             {:question,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-QO-JUNQUE-Engagement-pour-la-solidarite-internationale_U1180_fr.pdf"},
             {:question,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-QO-LAMBERT-LIMBOSCH-Actions-entreprises-suite-a-la-tempete-du-090724_U1180_fr.pdf"},
             {:question,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-QO-TOJEROW-Mise-en-danger-des-pietons-le-long-du-domaine-Latour-de-Freins_U1180_fr.pdf"},
             {:question,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-QO-COOLS-KABACHI-DUVIEUSART-Pollution-PFAS-site-SICLI-quartier-du-Merlo_U1180_fr.pdf"},
             {:interpellation,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-Interpellation-COOLS-Logements-Airbnb_U1180_fr.pdf"},
             {:interpellation,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-Interpellation-NAGELMACKERS-MERCENIER-Deprogrammation-spectacle-Guillaume-Meurice-U1180-fr.pdf"},
             {:motion,
              "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2025-06-26-Motion-Prevention-et-lutte-contre-les-violences-sexistes-et-sexuelles-en-politique_U1180_fr.pdf"}
           ]

    assert Enum.all?(locators, fn locator ->
             locator.meeting_identifier == "2025-06-26" and
               locator.scheduled_on == ~D[2025-06-26] and
               locator.parent_index_url == @index_url and
               locator.item_identifier == nil
           end)

    assert Enum.map(locators, & &1.language) ==
             List.duplicate(:bilingual, 5) ++ List.duplicate(:fr, 9)

    assert Enum.at(locators, 1).observed_label == "Ordre du jour complémentaire"
    assert Enum.at(locators, 2).observed_label == "Notes explicatives"
    assert Enum.at(locators, 13).observed_label =~ "Prévention et lutte"

    malformed_note = Enum.at(locators, 2)
    assert malformed_note.url =~ "CC-2025-05-22-NE"
    refute malformed_note.url =~ "CC-2025-06-26-NE_U1180"
  end

  test "rejects an empty or structurally unrecognizable archive" do
    assert {:error, {:invalid_index, :missing_meeting_tables}} =
             BrusselsWtf.Communes.Uccle.discover(
               "<html><body><p>temporarily empty</p></body></html>",
               @index_url
             )

    assert {:error, {:invalid_index, :no_authoritative_locators}} =
             BrusselsWtf.Communes.Uccle.discover(
               ~s(<h2 id="2025">2025</h2><table><caption>26 juin</caption></table>),
               @index_url
             )
  end

  test "a linked row with unknown semantics fails the whole parse" do
    html = """
    <h2 id="2025">2025</h2>
    <table>
      <caption>26 juin</caption>
      <tr><th>Ordre du jour</th><td><a href="/agenda.pdf">Ordre du jour</a></td></tr>
      <tr><th>Pièce inattendue</th><td><a href="/mystery..pdf">Document</a></td></tr>
    </table>
    """

    assert {:error, {:invalid_index, {:unknown_document_role, "Pièce inattendue"}}} =
             BrusselsWtf.Communes.Uccle.discover(html, @index_url)
  end

  test "a malformed meeting caption fails the whole parse" do
    html = """
    <h2 id="2025">2025</h2>
    <table>
      <caption>date inconnue</caption>
      <tr><th>Ordre du jour</th><td><a href="/agenda.pdf">Ordre du jour</a></td></tr>
    </table>
    """

    assert {:error, {:invalid_index, :invalid_meeting_date}} =
             BrusselsWtf.Communes.Uccle.discover(html, @index_url)
  end
end
