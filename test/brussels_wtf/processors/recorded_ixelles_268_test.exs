defmodule BrusselsWtf.Processors.RecordedIxelles268Test do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Processors.RecordedIxelles268

  @agenda_sha256 "f412ee4ddc45b454691fff79b190e36de0ae60fe6b696ae7861c82557b38fd4b"
  @projects_sha256 "f3fddb8f231916b128b83002d2eeee82b591120b9aa556338a3992df95f9c1f4"

  @source_wording "Octroi d’une subvention de projet en numéraire d’un montant de 700,00 EUR et en non numéraire évaluée à un montant de 5.158,00 EUR, relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre. Bénéficiaire : asbl Libération Films Animation. Conventions. Approbation."

  @agenda_text """
  CONSEIL COMMUNAL DU 2 JUILLET 2026
  ORDRE DU JOUR COMPLÉMENTAIRE
  4 #{@source_wording}
  Conseil communal - 02.07.2026 - Ordre du jour complémentaire public 2/25
  """

  @projects_text """
  Conseil communal - 02.07.2026 - Notes explicatives publiques 10/483
  3 #{@source_wording}
  DECIDE :
  1. d'octroyer une subvention de projet en numéraire d'un montant de 700,00 EUR relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre, au profit de l’asbl Libération Films Animation
  2. d'octroyer une subvention de projet en non numéraire évaluée à un montant de 5.158,00 EUR
  Conseil communal - 02.07.2026 - Notes explicatives publiques 12/483
  """

  test "normalizes the observed official complementary agenda source version" do
    assert {:ok, normalized} =
             RecordedIxelles268.normalize(%{
               "sha256" => @agenda_sha256,
               "text" => @agenda_text
             })

    assert normalized == %{
             "meeting_identifier" => "268",
             "scheduled_on" => "2026-07-02",
             "agenda" => %{"kind" => "complementary", "language" => "bilingual"},
             "items" => [
               %{
                 "item_number" => "4",
                 "authoritative_identifier" => "4",
                 "source_wording" => @source_wording
               }
             ]
           }
  end

  test "normalizes the observed official project source version with claim-specific evidence" do
    assert {:ok, normalized} =
             RecordedIxelles268.normalize(%{
               "sha256" => @projects_sha256,
               "text" => @projects_text
             })

    assert get_in(normalized, ["items", Access.at(0), "item_number"]) == "4"
    assert get_in(normalized, ["items", Access.at(0), "source_wording"]) == @source_wording

    assert get_in(normalized, ["items", Access.at(0), "proposals", Access.at(0)]) == %{
             "text" =>
               "Octroyer une subvention de 700,00 EUR et une aide non numéraire évaluée à 5.158,00 EUR à l’asbl Libération Films Animation.",
             "evidence" => %{
               "claim" => "proposal",
               "excerpt" =>
                 "1. d'octroyer une subvention de projet en numéraire d'un montant de 700,00 EUR relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre, au profit de l’asbl Libération Films Animation […] 2. d'octroyer une subvention de projet en non numéraire évaluée à un montant de 5.158,00 EUR.",
               "location" => "Notes explicatives publiques, page 12/483",
               "applicable_from" => "2026-07-02"
             }
           }
  end

  test "fails closed when a known source version lacks its recorded markers" do
    assert {:error, {:normalization_ambiguity, details}} =
             RecordedIxelles268.normalize(%{
               "sha256" => @projects_sha256,
               "text" => "unexpected extracted text"
             })

    assert details["contract"] == "ixelles-268-projects"
    assert details["missing_markers"] != []
  end

  test "leaves unknown source versions unsupported" do
    assert {:error, :processor_unimplemented} =
             RecordedIxelles268.normalize(%{
               "sha256" => String.duplicate("0", 64),
               "text" => @projects_text
             })
  end
end
