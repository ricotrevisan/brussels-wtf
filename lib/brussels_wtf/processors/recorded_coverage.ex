defmodule BrusselsWtf.Processors.RecordedCoverage do
  @moduledoc "Deterministic recorded coverage contract for the initial Ixelles proposal."

  @behaviour BrusselsWtf.Processors.Coverage

  @page %{
    "fr" => %{
      "title" => "Subvention proposée pour « Bruxelles fait son cinéma »",
      "summary" =>
        "Le Conseil doit examiner une subvention à Libération Films Animation. L’issue reste inconnue."
    },
    "nl" => %{
      "title" => "Voorgestelde subsidie voor ‘Bruxelles fait son cinéma’",
      "summary" =>
        "De gemeenteraad moet een subsidie aan Libération Films Animation bespreken. De uitkomst is nog onbekend."
    },
    "en" => %{
      "title" => "Proposed grant for ‘Bruxelles fait son cinéma’",
      "summary" =>
        "The council is due to consider a grant to Libération Films Animation. The outcome remains unknown."
    }
  }

  @items %{
    "fr" => %{
      "title" => "Subvention proposée pour « Bruxelles fait son cinéma »",
      "summary" =>
        "Une subvention de 700,00 EUR et une aide non numéraire de 5.158,00 EUR sont proposées pour Libération Films Animation.",
      "proposal_summary" =>
        "Le Conseil doit examiner la subvention et l’aide proposées. L’issue reste inconnue."
    },
    "nl" => %{
      "title" => "Voorgestelde subsidie voor ‘Bruxelles fait son cinéma’",
      "summary" =>
        "Een subsidie van 700,00 EUR en niet-financiële steun van 5.158,00 EUR worden voorgesteld voor Libération Films Animation.",
      "proposal_summary" =>
        "De gemeenteraad moet de voorgestelde subsidie en steun bespreken. De uitkomst is nog onbekend."
    },
    "en" => %{
      "title" => "Proposed grant for ‘Bruxelles fait son cinéma’",
      "summary" =>
        "A grant of EUR 700.00 and non-cash support valued at EUR 5,158.00 are proposed for Libération Films Animation.",
      "proposal_summary" =>
        "The council is due to consider the proposed grant and support. The outcome remains unknown."
    }
  }

  @impl true
  def generate_fr(%{"meeting_identifier" => "268", "items" => [%{"key" => "4"} = item]} = input) do
    {:ok, bundle(input, item, "fr")}
  end

  def generate_fr(_input), do: {:error, :recorded_coverage_not_available}

  @impl true
  def translate(%{"meeting_identifier" => "268", "items" => %{"4" => item}} = canonical, locale)
      when locale in ["nl", "en"] do
    {:ok,
     %{
       "meeting_identifier" => canonical["meeting_identifier"],
       "page" => Map.fetch!(@page, locale),
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
  def metadata do
    %{
      processor_name: "recorded-ixelles-coverage",
      processor_version: "2026-08-19",
      config_hash: "sha256:recorded-ixelles-coverage-v1",
      provider_category: "recorded_contract",
      model: "recorded-output",
      canonical_method: :ai_generation,
      translation_method: :machine_translation,
      usage: %{"network_calls" => 0}
    }
  end

  defp bundle(input, item, locale) do
    %{
      "meeting_identifier" => input["meeting_identifier"],
      "page" => Map.fetch!(@page, locale),
      "items" => %{
        item["key"] => %{
          "claim_refs" => Enum.map(item["claims"], & &1["key"]),
          "variant" => Map.fetch!(@items, locale)
        }
      }
    }
  end
end
