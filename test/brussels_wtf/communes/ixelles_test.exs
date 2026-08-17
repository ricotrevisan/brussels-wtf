defmodule BrusselsWtf.Communes.IxellesTest do
  use ExUnit.Case, async: true

  test "discovers every exact document and recording locator and correlates rows by meeting id" do
    index = File.read!(Path.expand("../../support/fixtures/ixelles/proposal/index.html", __DIR__))
    index_url = "https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr"

    assert {:ok, locators} = BrusselsWtf.Communes.Ixelles.discover(index, index_url)

    assert Enum.map(locators, &{&1.meeting_identifier, &1.role, &1.url}) == [
             {"268", :agenda, "https://www.ixelles.be/uploads/conseil/odj/268.pdf"},
             {"268", :project, "https://www.ixelles.be/uploads/conseil/projets/268.pdf"},
             {"268", :recording, "https://www.youtube.com/watch?v=lUndSi1Qd7g"},
             {"267", :agenda, "https://www.ixelles.be/uploads/conseil/odj/267.pdf"},
             {"267", :minutes, "https://www.ixelles.be/uploads/conseil/pv/267.pdf"},
             {"267", :recording, "https://www.youtube.com/watch?v=NsLL3-0OyTI"}
           ]

    assert Enum.all?(Enum.filter(locators, &(&1.meeting_identifier == "268")), fn locator ->
             locator.scheduled_on == ~D[2026-07-02] and
               locator.parent_index_url == index_url
           end)

    assert Enum.find(locators, &(&1.role == :project)).observed_label == "Projets de dossiers"
  end

  test "rejects an empty or structurally unrecognizable index" do
    assert {:error, {:invalid_index, :missing_council_table}} =
             BrusselsWtf.Communes.Ixelles.discover(
               "<html><body><p>temporarily empty</p></body></html>",
               "https://www.ixelles.be/council"
             )

    assert {:error, {:invalid_index, :no_authoritative_locators}} =
             BrusselsWtf.Communes.Ixelles.discover(
               "<h3>[2026]</h3><table><tr><th>Date</th></tr><tr><td>02/07</td></tr></table>",
               "https://www.ixelles.be/council"
             )
  end

  test "a malformed authoritative row makes the whole parse fail rather than disappear history" do
    html = """
    <h3>[2026]</h3><table>
      <tr><th>Date</th><th>Agenda</th></tr>
      <tr><td>02/07</td><td><a href="../uploads/conseil/odj/268.pdf">Ordre du jour</a></td></tr>
      <tr><td>date inconnue</td><td><a href="../uploads/conseil/odj/269.pdf">Ordre du jour</a></td></tr>
    </table>
    """

    assert {:error, {:invalid_index, :invalid_meeting_date}} =
             BrusselsWtf.Communes.Ixelles.discover(html, "https://www.ixelles.be/council")
  end
end
