defmodule BrusselsWtf.Processors.RecordedCoverage do
  @moduledoc "Deterministic recorded coverage contract for the initial Ixelles proposal."

  @behaviour BrusselsWtf.Processors.Coverage

  @expected_source_wording "Octroi d’une subvention de projet en numéraire d’un montant de 700,00 EUR et en non numéraire évaluée à un montant de 5.158,00 EUR, relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre. Bénéficiaire : asbl Libération Films Animation. Conventions. Approbation."
  @expected_proposal "Octroyer une subvention de 700,00 EUR et une aide non numéraire évaluée à 5.158,00 EUR à l’asbl Libération Films Animation."
  @expected_citation "https://www.ixelles.be/uploads/conseil/projets/268.pdf"

  @page %{
    "fr" => %{
      "title" => "Subvention proposée pour une projection de « La venue de l’avenir »",
      "summary" =>
        "Le Conseil doit examiner une subvention à Libération Films Animation. L’issue reste inconnue."
    },
    "nl" => %{
      "title" => "Voorgestelde subsidie voor een vertoning van ‘La venue de l’avenir’",
      "summary" =>
        "De gemeenteraad moet een subsidie aan Libération Films Animation bespreken. De uitkomst is nog onbekend."
    },
    "en" => %{
      "title" => "Proposed grant for a screening of ‘La venue de l’avenir’",
      "summary" =>
        "The council is due to consider a grant to Libération Films Animation. The outcome remains unknown."
    }
  }

  @items %{
    "fr" => %{
      "title" => "Subvention proposée pour une projection de « La venue de l’avenir »",
      "summary" =>
        "Une subvention de 700,00 EUR et une aide non numéraire de 5.158,00 EUR sont proposées pour Libération Films Animation.",
      "proposal_summary" =>
        "Le Conseil doit examiner la subvention et l’aide proposées. L’issue reste inconnue."
    },
    "nl" => %{
      "title" => "Voorgestelde subsidie voor een vertoning van ‘La venue de l’avenir’",
      "summary" =>
        "Een subsidie van 700,00 EUR en niet-financiële steun van 5.158,00 EUR worden voorgesteld voor Libération Films Animation.",
      "proposal_summary" =>
        "De gemeenteraad moet de voorgestelde subsidie en steun bespreken. De uitkomst is nog onbekend."
    },
    "en" => %{
      "title" => "Proposed grant for a screening of ‘La venue de l’avenir’",
      "summary" =>
        "A grant of EUR 700.00 and non-cash support valued at EUR 5,158.00 are proposed for Libération Films Animation.",
      "proposal_summary" =>
        "The council is due to consider the proposed grant and support. The outcome remains unknown."
    }
  }

  @impl true
  def generate_fr(
        %{
          "commune_slug" => "ixelles",
          "meeting_identifier" => "268",
          "items" => [
            %{
              "key" => "4",
              "procedural_state" => "proposal",
              "outcome" => "unknown",
              "source_wording" => @expected_source_wording,
              "claims" => [
                %{"text" => @expected_proposal, "evidence" => evidence}
              ]
            } = item
          ]
        } = input
      ) do
    if Enum.any?(evidence, &(&1["citation_url"] == @expected_citation)) do
      {:ok, bundle(input, item, "fr")}
    else
      {:error, :recorded_coverage_not_available}
    end
  end

  def generate_fr(_input), do: {:error, :recorded_coverage_not_available}

  @impl true
  def translate(%{"meeting_identifier" => "268", "items" => %{"4" => item}} = canonical, locale)
      when locale in ["nl", "en"] do
    {:ok,
     %{
       "meeting_identifier" => canonical["meeting_identifier"],
       "page" =>
         @page
         |> Map.fetch!(locale)
         |> Map.put("claim_refs", item["claim_refs"]),
       "items" => %{
         "4" => %{
           "claim_refs" => item["claim_refs"],
           "variant" => Map.fetch!(@items, locale)
         }
       }
     }}
  end

  def translate(_canonical, _locale), do: {:error, :recorded_translation_not_available}

  @impl true
  def maximum_cost(_operation, _input), do: {:ok, 0}

  @impl true
  def metadata do
    %{
      processor_name: "recorded-ixelles-coverage",
      processor_version: "2026-08-19",
      config_hash: "sha256:recorded-ixelles-coverage-v1",
      provider_category: "recorded_contract",
      billing_mode: :recorded,
      network_access: :none,
      model: "recorded-output",
      canonical_method: :ai_generation,
      translation_method: :machine_translation,
      usage: %{"network_calls" => 0}
    }
  end

  defp bundle(input, item, locale) do
    %{
      "meeting_identifier" => input["meeting_identifier"],
      "page" =>
        @page
        |> Map.fetch!(locale)
        |> Map.put("claim_refs", Enum.map(item["claims"], & &1["key"])),
      "items" => %{
        item["key"] => %{
          "claim_refs" => Enum.map(item["claims"], & &1["key"]),
          "variant" => Map.fetch!(@items, locale)
        }
      }
    }
  end
end
