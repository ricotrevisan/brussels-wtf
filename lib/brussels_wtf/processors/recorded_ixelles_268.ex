defmodule BrusselsWtf.Processors.RecordedIxelles268 do
  @moduledoc """
  Hash-pinned normalization contract for the first real Ixelles meeting.

  Only the observed official meeting 268 agenda and project source versions are
  accepted. The source hash selects the contract, and exact normalized text
  markers guard against extraction drift before any council state is created.
  """

  @behaviour BrusselsWtf.Processors

  @agenda_sha256 "f412ee4ddc45b454691fff79b190e36de0ae60fe6b696ae7861c82557b38fd4b"
  @projects_sha256 "f3fddb8f231916b128b83002d2eeee82b591120b9aa556338a3992df95f9c1f4"

  @source_wording "Octroi d’une subvention de projet en numéraire d’un montant de 700,00 EUR et en non numéraire évaluée à un montant de 5.158,00 EUR, relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre. Bénéficiaire : asbl Libération Films Animation. Conventions. Approbation."

  @project_cash "1. d'octroyer une subvention de projet en numéraire d'un montant de 700,00 EUR relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre, au profit de l’asbl Libération Films Animation"
  @project_non_cash "2. d'octroyer une subvention de projet en non numéraire évaluée à un montant de 5.158,00 EUR"

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(%{"sha256" => @agenda_sha256, "text" => text}) when is_binary(text) do
    with :ok <- verify_markers(text, "ixelles-268-agenda", agenda_markers()) do
      {:ok, agenda()}
    end
  end

  def normalize(%{"sha256" => @projects_sha256, "text" => text}) when is_binary(text) do
    with :ok <- verify_markers(text, "ixelles-268-projects", project_markers()) do
      {:ok, projects()}
    end
  end

  def normalize(_extracted), do: {:error, :processor_unimplemented}

  defp agenda do
    %{
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

  defp projects do
    %{
      "meeting_identifier" => "268",
      "scheduled_on" => "2026-07-02",
      "items" => [
        %{
          "item_number" => "4",
          "authoritative_identifier" => "4",
          "source_wording" => @source_wording,
          "proposals" => [
            %{
              "text" =>
                "Octroyer une subvention de 700,00 EUR et une aide non numéraire évaluée à 5.158,00 EUR à l’asbl Libération Films Animation.",
              "evidence" => %{
                "claim" => "proposal",
                "excerpt" => @project_cash <> " […] " <> @project_non_cash <> ".",
                "location" => "Notes explicatives publiques, page 12/483",
                "applicable_from" => "2026-07-02"
              }
            }
          ]
        }
      ]
    }
  end

  defp agenda_markers do
    [
      "CONSEIL COMMUNAL DU 2 JUILLET 2026",
      "ORDRE DU JOUR COMPLÉMENTAIRE",
      "4 " <> @source_wording,
      "Conseil communal - 02.07.2026 - Ordre du jour complémentaire public"
    ]
  end

  defp project_markers do
    [
      "3 " <> @source_wording,
      "DECIDE :",
      @project_cash,
      @project_non_cash,
      "Conseil communal - 02.07.2026 - Notes explicatives publiques",
      "12/483"
    ]
  end

  defp verify_markers(text, contract, markers) do
    normalized_text = normalize_whitespace(text)
    missing = Enum.reject(markers, &String.contains?(normalized_text, &1))

    case missing do
      [] ->
        :ok

      missing ->
        {:error,
         {:normalization_ambiguity,
          %{
            "contract" => contract,
            "missing_markers" => Enum.map(missing, &marker_name/1)
          }}}
    end
  end

  defp normalize_whitespace(text), do: String.replace(text, ~r/\s+/u, " ")

  defp marker_name("CONSEIL COMMUNAL DU 2 JUILLET 2026"), do: "meeting_heading"
  defp marker_name("ORDRE DU JOUR COMPLÉMENTAIRE"), do: "agenda_kind"
  defp marker_name("DECIDE :"), do: "proposal_decision_heading"
  defp marker_name("12/483"), do: "evidence_page"
  defp marker_name(marker) when marker == @project_cash, do: "cash_proposal"
  defp marker_name(marker) when marker == @project_non_cash, do: "non_cash_proposal"
  defp marker_name(marker) when marker == "4 " <> @source_wording, do: "agenda_item"
  defp marker_name(marker) when marker == "3 " <> @source_wording, do: "project_item"
  defp marker_name(_marker), do: "document_footer"
end
