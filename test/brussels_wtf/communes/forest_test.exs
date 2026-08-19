defmodule BrusselsWtf.Communes.ForestTest do
  use ExUnit.Case, async: true

  test "discovers exact source locators from authoritative dated meeting cards" do
    index = File.read!(Path.expand("../../support/fixtures/forest/adapter/index.html", __DIR__))
    index_url = "https://forest.brussels/fr/publications/conseil-communal-1"

    assert {:ok, locators} = BrusselsWtf.Communes.Forest.discover(index, index_url)

    assert Enum.map(locators, &{&1.meeting_identifier, &1.role, &1.url}) == [
             {"2025-04-22", :complementary_agenda,
              "https://forest.brussels/sites/default/files/publications/ordre-du-jour/2025-04/CC%20-%2022042025%20-%20agenda%20compl.pdf"},
             {"2025-04-22", :complementary_explanatory_note,
              "https://forest.brussels/sites/default/files/publications/notes/2025-04/22042025%20-%20Notes%20explicatives%20compl%C3%A9mentaires.pdf"},
             {"2025-04-22", :motion,
              "https://forest.brussels/sites/default/files/publications/avis/2025-04/Motion%20relative%20%C3%A0%20la%20d%C3%A9claration%20de%20Forest%20comme%20commune%20antifasciste%20et%20appartenant%20%C3%A0%20la%20%20coalition%208%20mai.pdf"},
             {"2025-04-22", :minutes,
              "https://forest.brussels/sites/default/files/publications/registre/2025-04/PV%20%20conseil%20communal%20-%20gemeenteraad%2022042025.pdf"},
             {"2025-03-25", :agenda,
              "https://forest.brussels/sites/default/files/publications/ordre-du-jour/2025-03/CC-%2025032025%20agenda.pdf"},
             {"2025-03-25", :explanatory_notes,
              "https://forest.brussels/sites/default/files/publications/notes/2025-03/CC%20-%2025032025%20-%20Notes%20explicatives%20publiques.pdf"},
             {"2025-03-25", :minutes,
              "https://forest.brussels/sites/default/files/publications/registre/2025-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2025032025_1.pdf"},
             {"2025-03-25", :interpellation,
              "https://forest.brussels/sites/default/files/publications/pdf/2025-03/250325%20Interpellation%20citoyenne%20Place%20Saint-Denis%20et%20r%C3%A9ponse%20coll%C3%A8ge.pdf"}
           ]

    assert Enum.all?(locators, &(&1.parent_index_url == index_url))
    assert Enum.all?(Enum.take(locators, 4), &(&1.scheduled_on == ~D[2025-04-22]))
    assert Enum.all?(Enum.drop(locators, 4), &(&1.scheduled_on == ~D[2025-03-25]))
    assert Enum.find(locators, &(&1.role == :motion)).observed_label == "Motion"

    assert Enum.find(locators, &(&1.role == :interpellation)).observed_label ==
             "Interpellation citoyenne et réponse du collège sur le Réaménagement de la place Saint-Denis"
  end

  test "rejects missing, malformed, and unclassified authoritative meeting cards" do
    index_url = "https://forest.brussels/fr/publications/conseil-communal-1"

    assert {:error, {:invalid_index, :missing_council_cards}} =
             BrusselsWtf.Communes.Forest.discover(
               ~s(<html><body><div class="card">Navigation</div></body></html>),
               index_url
             )

    assert {:error, {:invalid_index, :invalid_meeting_date}} =
             BrusselsWtf.Communes.Forest.discover(
               """
               <div class="card mt-3 mb-2">
                 <div class="date"><time class="datetime" datetime="not-a-date">inconnue</time></div>
                 <div><a href="/agenda.pdf">Ordre du jour</a></div>
               </div>
               """,
               index_url
             )

    assert {:error, {:invalid_index, {:unknown_source_role, "Document mystère"}}} =
             BrusselsWtf.Communes.Forest.discover(
               """
               <div class="card mt-3 mb-2">
                 <div class="date"><time class="datetime" datetime="2025-04-22T12:00:00Z">22/04/2025</time></div>
                 <div><a href="/mystere.pdf">Document mystère</a></div>
               </div>
               """,
               index_url
             )
  end
end
