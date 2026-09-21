defmodule BrusselsWtf.Identity.MunicipalInstallation.Source do
  @moduledoc """
  Pure, fail-closed municipal installation source policy, version 1.

  The registry approves document versions and layouts, never people. Callers must
  independently verify archived PDF hashes, locator/discovery context and the
  accepted native-text artifact lineage before using these parsing results.
  Passing a registry map and arbitrary text is not proof of authenticity.

  Text is Poppler `-layout` output with form-feed page separators. Maps use atom
  keys, roles and slugs are strings, dates are `Date`s. Installation events have
  an unknown `effective_to`; corroboration does not extend tenure. Matching adds
  `identity_evidence` to each event and uses the corroborating source's canonical
  name. Evidence excerpts remain exact continuous source spans, not reconstructions.
  City chair events additionally retain the separate page-58 `oath_evidence`.
  Candidates stay in installation source order; this module imposes no batch cap.

  Exclusions contain only classification, page and role, never raw rejected text.
  They report unmatched/ambiguous identities and City's explicitly quarantined
  surname lists and uncertain rank. Out-of-scope replacements and other sections
  are not parsed. Uccle's mixed-order roster and Ixelles's family-first list are
  the only profiles permitting unique complete-token permutations.
  """

  @uccle_index "https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal"
  @forest_index "https://forest.brussels/fr/publications/conseil-communal-1"
  @city_index "https://www.brussels.be/complete-reports-public-meetings-city-council"

  @doc "Parser policy identity; bump whenever parsing or candidate-matching rules change."
  def parser_policy_version, do: "municipal-installation-parser-v1.1"

  @doc "The immutable document/layout registry; suitable input to a processor configuration hash."
  @spec contracts() :: [map()]
  def contracts do
    [
      %{
        slug: "ixelles",
        policy_version: 1,
        parserprofile: :ixelles_titular_v1,
        name_order: :family_given_installation,
        installation:
          document(
            "https://www.ixelles.be/uploads/conseil/pv/245.pdf",
            "57b4ca56118d46178cf9c80692c49c92d6ab62f0cef5580610e8fb816b7eac06",
            ~D[2024-12-01],
            "https://www.ixelles.be/site/page.php?numpage=11&annee=2024",
            "245",
            :minutes
          ),
        corroboration:
          document(
            "https://www.ixelles.be/uploads/conseil/pv/267.pdf",
            "4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5",
            ~D[2026-06-11],
            "https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr",
            "267",
            :minutes
          )
      },
      %{
        slug: "uccle",
        policy_version: 1,
        parserprofile: :uccle_titular_v1,
        name_order: :mixed_roster_order,
        installation:
          document(
            "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2024-12-01_REGISTRE_U1180_fr_nl.pdf",
            "74bf6d25bb6800c66453b14ddae58be03d290b7554148170fa3e69b3ef137612",
            ~D[2024-12-01],
            @uccle_index,
            "2024-12-01",
            :register
          ),
        corroboration:
          document(
            "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC_2025-06-26_REGISTRE_U1180_fr_nl.pdf",
            "3ea29d0bdf4e09f329cc73027fec8583f36b811f9999e671c37e86d7f71cc8f9",
            ~D[2025-06-26],
            @uccle_index,
            "2025-06-26",
            :register
          )
      },
      %{
        slug: "forest",
        policy_version: 1,
        parserprofile: :forest_titular_v1,
        name_order: :given_family,
        installation:
          document(
            "https://forest.brussels/sites/default/files/publications/registre/2025-01/PV%20%20conseil%20communal%20-%20gemeenteraad%2001122024_1.pdf",
            "266bbbd6960ed51ff569b80f3e9e4f2b0a3f9c02df09ecf531a66d5c6e4fcf26",
            ~D[2024-12-01],
            @forest_index,
            "2024-12-01",
            :minutes
          ),
        corroboration:
          document(
            "https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf",
            "6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26",
            ~D[2026-03-24],
            @forest_index,
            "2026-03-24",
            :minutes
          )
      },
      %{
        slug: "city-of-brussels",
        policy_version: 1,
        parserprofile: :city_completed_offices_v1,
        name_order: :given_family,
        installation:
          document(
            "https://www.brussels.be/sites/default/files/13.-%20Conseil%20communal%20du%2001decembre%202024.pdf",
            "51ff7ef8d38e0437c06ec3fefe50b0039cc08b1d35b5a529a97a342b1c09537c",
            ~D[2024-12-01],
            @city_index <> "?field_date_document_value=2024",
            "2024-12-01",
            :minutes
          ),
        corroboration:
          document(
            "https://www.brussels.be/sites/default/files/CRI20avril2026.pdf",
            "f3133ec17d84044f54712b2c5dc09c38c688c71a7d9b89f042c774d7869d2582",
            ~D[2026-04-20],
            @city_index,
            "2026-04-20",
            :minutes
          )
      }
    ]
    |> Enum.map(&with_role_labels/1)
  end

  @spec contract(String.t()) :: {:ok, map()} | {:error, :unsupported_commune}
  def contract(slug) do
    case Enum.find(contracts(), &(&1.slug == slug)) do
      nil -> {:error, :unsupported_commune}
      contract -> {:ok, contract}
    end
  end

  @role_labels %{
    "municipal_councillor" => %{
      fr: "Conseiller communal",
      nl: "Gemeenteraadslid",
      en: "Municipal councillor"
    },
    "alderman" => %{fr: "Membre du collège communal", nl: "Schepen", en: "Alderperson"},
    "council_chair" => %{
      fr: "Président du Conseil communal",
      nl: "Voorzitter van de gemeenteraad",
      en: "Council chair"
    },
    "mayor" => %{fr: "Bourgmestre", nl: "Burgemeester", en: "Mayor"}
  }

  defp with_role_labels(contract) do
    roles =
      if contract.parserprofile == :city_completed_offices_v1,
        do: ["alderman", "council_chair"],
        else: ["municipal_councillor"]

    Map.put(contract, :role_labels, Map.take(@role_labels, roles))
  end

  @doc "Parse completed, scoped installation events, without resolving identity."
  @spec installations(map(), String.t()) :: {:ok, [map()]} | {:error, atom()}
  def installations(contract, text) do
    with :ok <- approved(contract),
         {:ok, pages} <- envelope(contract, :installation, text) do
      parse_installations(contract, pages)
    end
  end

  @doc "Parse independent public-role contexts; these are not appointment claims."
  @spec corroborations(map(), String.t()) :: {:ok, [map()]} | {:error, atom()}
  def corroborations(contract, text) do
    with :ok <- approved(contract),
         {:ok, pages} <- envelope(contract, :corroboration, text) do
      parse_corroborations(contract, pages)
    end
  end

  @doc "Match unique complete names within both approved source scopes, never fuzzily."
  @spec match_candidates(map(), String.t(), String.t()) ::
          {:ok, %{candidates: [map()], excluded: [map()]}} | {:error, atom()}
  def match_candidates(contract, installation_text, corroboration_text) do
    with {:ok, events} <- installations(contract, installation_text),
         {:ok, identities} <- corroborations(contract, corroboration_text) do
      {candidates, excluded} =
        Enum.reduce(events, {[], []}, fn event, {candidates, excluded} ->
          key = identity_key(contract, event.legal_name)
          matching = Enum.filter(identities, &(identity_key(contract, &1.legal_name) == key))
          # Separate offices do not make one unique corroborated identity ambiguous.
          # Duplicate same-office events or multiple corroborating identities still do.
          count =
            Enum.count(events, fn other ->
              identity_key(contract, other.legal_name) == key and other.role_key == event.role_key
            end)

          case {count, matching} do
            {1, [identity]} ->
              candidate =
                event
                |> Map.put(:legal_name, identity.legal_name)
                |> Map.put(:identity_evidence, identity)

              {[candidate | candidates], excluded}

            {_, matches} ->
              reason = if matches == [], do: :identity_not_corroborated, else: :ambiguous_identity
              exclusion = %{reason: reason, page: event.page, role_key: event.role_key}
              {candidates, [exclusion | excluded]}
          end
        end)

      excluded =
        (Enum.reverse(excluded) ++ scope_exclusions(contract, installation_text))
        |> Enum.sort_by(& &1.page)

      {:ok, %{candidates: Enum.reverse(candidates), excluded: excluded}}
    end
  end

  defp scope_exclusions(%{parserprofile: :city_completed_offices_v1}, text) do
    pages = String.split(text, "\f")

    for {number, marker, role, reason} <- [
          {8, "Prêtent serment en français", "municipal_councillor", :surname_only_installation},
          {9, "Prêtent serment en néerlandais", "municipal_councillor",
           :surname_only_installation},
          {44, "septième (?)", "alderman", :uncertain_rank}
        ],
        String.contains?(page(pages, number), marker) do
      %{page: number, role_key: role, reason: reason}
    end
  end

  defp scope_exclusions(_, _), do: []

  defp approved(contract) do
    if contract in contracts(), do: :ok, else: {:error, :unsupported_contract}
  end

  defp envelope(contract, kind, text) when is_binary(text) do
    if String.valid?(text) do
      pages = String.split(text, "\f")
      first = page(pages, 1)

      header =
        if contract.slug == "city-of-brussels" do
          Regex.run(
            ~r/Séance publique du (?:dimanche|lundi) (\d{1,2})(?:er)? (décembre|avril) (\d{4})/u,
            first
          )
        else
          Regex.run(
            ~r/CONSEIL\s+COMMUNAL\s+DU\s+(\d{1,2})\s+(DÉCEMBRE|JUIN|MARS)\s+(\d{4})/u,
            first
          )
        end

      commune =
        %{
          "ixelles" => "COMMUNE D'IXELLES",
          "uccle" => "COMMUNE D'UCCLE",
          "forest" => "ADMINISTRATION COMMUNALE DE FOREST",
          "city-of-brussels" => "CONSEIL COMMUNAL DE BRUXELLES"
        }[contract.slug]

      with true <- is_binary(commune) and String.contains?(first, commune),
           [_, day, month, year] <- header,
           {:ok, date} <-
             Date.new(String.to_integer(year), month_number(month), String.to_integer(day)),
           true <- date == Map.fetch!(contract, kind).date do
        {:ok, pages}
      else
        _ -> {:error, :invalid_document_header}
      end
    else
      {:error, :invalid_text}
    end
  end

  defp envelope(_, _, _), do: {:error, :invalid_text}
  defp month_number("décembre"), do: 12
  defp month_number("avril"), do: 4
  defp month_number("DÉCEMBRE"), do: 12
  defp month_number("JUIN"), do: 6
  defp month_number("MARS"), do: 3
  defp page(pages, number), do: Enum.at(pages, number - 1, "")

  defp parse_installations(%{parserprofile: :ixelles_titular_v1} = contract, pages) do
    heading =
      ~r/01\.12\.2024\/A\/0001\s+Vérification des pouvoirs, prestation de serment et installation des Conseillers\s+communaux élus le 13 octobre 2024\./u

    oath =
      ~r/Considérant qu’à l’appel de leur nom, les élus suivants ont prononcé le serment\s+d’usage:\s*(?<names>[^;]+)\s*;\s*Considérant que le Bourgmestre donne acte de leur prestation serment aux élus et\s+déclare le Conseil légalement constitué\s*;\s*PREND ACTE\s+de la vérification des pouvoirs, de la prestation de serment et de l’installation des\s+membres du Conseil communal élus le 13 octobre 2024\./u

    with true <- Regex.match?(heading, page(pages, 1)),
         [[excerpt, names]] <- Regex.scan(oath, page(pages, 4)),
         {:ok, names} <- names_list(names) do
      {:ok, Enum.map(names, &event(contract, &1, "municipal_councillor", 4, excerpt))}
    else
      _ -> {:error, :installation_section_invalid}
    end
  end

  defp parse_installations(%{parserprofile: :uccle_titular_v1} = contract, pages) do
    heading =
      ~r/01\.12\.2024\/A\/0004\s+Vérification complémentaire des pouvoirs, prestation de serment et installation\s+des conseillers communaux\./u

    intro =
      ~r/Les membres de l'Assemblée prêtent successivement, entre les mains de M\. le\s+Président, le serment prévu par l'article 80 de la nouvelle loi communale\s*:/u

    third = page(pages, 3)
    fourth = page(pages, 4)

    with true <- Regex.match?(heading, third),
         [_, first_rows] <- Regex.split(intro, third),
         [last_rows, closing] <- String.split(fourth, "M. le Président informe", parts: 2),
         [french, _] <- String.split(closing, "Bijkomend onderzoek", parts: 2),
         true <- String.contains?(french, "Le Conseil prend connaissance.") do
      row =
        ~r/^\h*- (?:M\.|Mme) (?<name>[^;\n]+?) prête serment en (?:français|néerlandais)(?: et en (?:français|néerlandais))?\s*[;.]/mu

      events =
        Enum.flat_map([{first_rows, 3}, {last_rows, 4}], fn {text, number} ->
          for [excerpt, name] <- Regex.scan(row, text), safe_name?(canonical_name(name)) do
            event(
              contract,
              canonical_name(name),
              "municipal_councillor",
              number,
              String.trim(excerpt)
            )
          end
        end)

      if events == [], do: {:error, :installation_section_invalid}, else: {:ok, events}
    else
      _ -> {:error, :installation_section_invalid}
    end
  end

  defp parse_installations(%{parserprofile: :forest_titular_v1} = contract, pages) do
    heading =
      ~r/C\. Vérification des pouvoirs, prestation de serment et installation des membres du nouveau\s+Conseil communal\./u

    intro =
      ~r/Les élus prêtent successivement, entre les mains de M\. le Bourgmestre-Président, le serment prévu à\s+l'article 80 de la nouvelle loi communale\s*:/u

    oath =
      ~r/Il est procédé l’appel suivant le tableau de préséance qu'il leur sera proposé d'adopter\s*:\s*(?<names>.*?)\.\s*prêtent serment en français\* \/ en néerlandais\*\*\./su

    third = page(pages, 3)

    with true <- Regex.match?(heading, page(pages, 2)),
         [_, after_intro] <- Regex.split(intro, third),
         [section, _] <-
           String.split(
             after_intro,
             "D. Fixation du tableau de préséance des membres du Conseil.",
             parts: 2
           ),
         [[excerpt, fields]] <- Regex.scan(oath, section),
         {:ok, names} <- forest_names(fields) do
      {:ok, Enum.map(names, &event(contract, &1, "municipal_councillor", 3, excerpt))}
    else
      _ -> {:error, :installation_section_invalid}
    end
  end

  defp parse_installations(%{parserprofile: :city_completed_offices_v1} = contract, pages) do
    clause =
      ~r/^\h*En conséquence, (?:Mme|M\.) (?<name>[\p{L}\p{M}'’\-\s]+?) est proclamée? (?:première|deuxième|troisième|quatrième|cinquième|sixième|huitième)\s+échevine?\. (?:Elle|Il)\s+prête\s+serment en (?:français|néerlandais) et est installée? dans ses fonctions\s+d’échevine?\./mu

    aldermen =
      for number <- [22, 25, 29, 33, 36, 40, 48],
          [excerpt, name] <- Regex.scan(clause, page(pages, number)),
          safe_name?(canonical_name(name)) do
        event(contract, canonical_name(name), "alderman", number, String.trim(excerpt))
      end

    events = aldermen ++ city_chair(contract, pages)
    if events == [], do: {:error, :installation_section_invalid}, else: {:ok, events}
  end

  defp city_chair(contract, pages) do
    election =
      ~r/^\h*En conséquence, M\. (?<name>[\p{L}\p{M}'’\-\s]+?) est élu en qualité de Président du Conseil\s+communal, et M\. (?<deputy>[\p{L}\p{M}'’\-\s]+?) comme son suppléant pour la durée de la\s+législature\./mu

    oath =
      ~r/^\h*M\. (?<name>[\p{L}\p{M}'’\-\s]+?) prête le serment suivant\s*:\s*« Je jure fidélité au Roi, obeisance à la Constitution et aux lois du peuple\s+belge\. »/mu

    with [[excerpt, name, deputy]] <- Regex.scan(election, page(pages, 57)),
         true <- safe_name?(canonical_name(name)) and safe_name?(canonical_name(deputy)),
         [{oath_excerpt, _}] <-
           for(
             [span, sworn_name] <- Regex.scan(oath, page(pages, 58)),
             identity_key(contract, sworn_name) == identity_key(contract, name),
             do: {String.trim(span), sworn_name}
           ) do
      oath_evidence = %{
        page: 58,
        evidence_excerpt: oath_excerpt,
        evidence_location: "installation #{contract.installation.date} page 58"
      }

      [
        event(contract, canonical_name(name), "council_chair", 57, String.trim(excerpt))
        |> Map.put(:oath_evidence, oath_evidence)
      ]
    else
      _ -> []
    end
  end

  defp parse_corroborations(%{parserprofile: :city_completed_offices_v1} = contract, pages) do
    chair =
      ~r/La séance publique est ouverte à \d{1,2}h\d{2} sous la présidence de M\. (?<name>[\p{L}\p{M}'’\-\s]+?), Président\./u

    alderman = ~r/notre échevine de\s+l’instruction publique, Mme (?<name>[\p{L}\p{M}'’\-\s]+?),/u

    identities =
      for {number, role, pattern} <- [{1, "council_chair", chair}, {99, "alderman", alderman}],
          [excerpt, name] <- Regex.scan(pattern, page(pages, number)),
          safe_name?(canonical_name(name)) do
        evidence(contract, :corroboration, canonical_name(name), role, number, excerpt)
      end

    if identities == [], do: {:error, :corroboration_section_invalid}, else: {:ok, identities}
  end

  defp parse_corroborations(contract, pages), do: parse_roster(contract, page(pages, 1))

  defp forest_names(fields) do
    names =
      Enum.map(String.split(fields, ","), fn field ->
        case Regex.run(~r/\A\s*(?:M\.|Mme|M\s+me)\s+(.+?)\*{1,2}\s*\z/su, field) do
          [_, name] -> canonical_name(name)
          _ -> ""
        end
      end)

    if Enum.all?(names, &safe_name?/1), do: {:ok, names}, else: {:error, :unsafe_name_list}
  end

  defp parse_roster(contract, first) do
    case Regex.run(~r/Présents(?<roster>.*?)Ouverture de la séance/su, first, capture: [:roster]) do
      [roster] ->
        identities =
          ~r/Excusés?\b|[;.]/u
          |> Regex.split(roster)
          |> Enum.flat_map(&roster_group(contract, &1))

        if identities == [], do: {:error, :corroboration_section_invalid}, else: {:ok, identities}

      _ ->
        {:error, :corroboration_section_invalid}
    end
  end

  defp roster_group(contract, raw) do
    raw = Regex.replace(~r/\A\s*(?:(?:Aanwezig|Verontschuldigd)\s*)*/u, raw, "") |> String.trim()

    role =
      ~r/\A(?<names>.+?),\s*(?:Verontschuldigd\s+)?(?<role>Présidente?\/(?:De )?Voorzit(?:ster|ter)|(?:Le )?Bourgmestre\/(?:De )?Burgemeester|Échevin\(e\)s\/Schepenen|Echevin\(s\)\/Schepen\(en\)|Conseillers\(ères\) communaux\(ales\)\/Gemeenteraadsleden|Conseiller\(s\)\s+(?:Verontschuldigd\s+)?communal\(aux\)\/Gemeenteraadslid\(leden\)|Conseillers\s+(?:Verontschuldigd\s+)?communaux\/Gemeenteraadsleden)\s*,?\s*\z/su

    case Regex.named_captures(role, raw) do
      %{"names" => names, "role" => label} ->
        # Column labels can occur mid-list in Poppler layout output. They are
        # removed only for names; the published continuous excerpt is untouched.
        names = Regex.replace(~r/\b(?:Aanwezig|Verontschuldigd)\b/u, names, "")

        case names_list(names) do
          {:ok, names} ->
            key = roster_role(label)

            Enum.map(
              names,
              &evidence(contract, :corroboration, &1, key, 1, String.trim_trailing(raw, ","))
            )

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp roster_role("Président" <> _), do: "council_chair"
  defp roster_role("Conseiller" <> _), do: "municipal_councillor"
  defp roster_role("Échevin" <> _), do: "alderman"
  defp roster_role("Echevin" <> _), do: "alderman"
  defp roster_role(_), do: "mayor"

  defp names_list(raw) do
    names = raw |> String.split(",") |> Enum.map(&canonical_name/1)
    if Enum.all?(names, &safe_name?/1), do: {:ok, names}, else: {:error, :unsafe_name_list}
  end

  defp canonical_name(name) do
    name
    |> String.normalize(:nfc)
    |> String.replace(~r/-\s*\n\s*/u, "-")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp safe_name?(name) do
    tokens = String.split(name)

    length(tokens) in 2..12 and
      Regex.match?(
        ~r/\A[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*(?: [\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*)+\z/u,
        name
      ) and
      not Regex.match?(
        ~r/\b(?:domicile|adresse|rue|téléphone|contact|signature|secrétaire|née?|né|parti)\b/iu,
        name
      )
  end

  defp identity_key(contract, name) do
    tokens = name |> canonical_name() |> String.downcase() |> String.split()

    if contract.name_order in [:family_given_installation, :mixed_roster_order],
      do: Enum.sort(tokens),
      else: tokens
  end

  defp event(contract, name, role, page, excerpt) do
    contract
    |> evidence(:installation, name, role, page, excerpt)
    |> Map.merge(%{effective_from: contract.installation.date, effective_to: nil})
  end

  defp evidence(contract, kind, name, role, page, excerpt) do
    %{
      legal_name: name,
      role_key: role,
      role_labels: Map.fetch!(@role_labels, role),
      page: page,
      evidence_excerpt: excerpt,
      evidence_location: "#{kind} #{Map.fetch!(contract, kind).date} page #{page}"
    }
  end

  defp document(url, sha256, date, parent, meeting, role) do
    %{
      url: url,
      sha256: sha256,
      date: date,
      parent_index_url: parent,
      meeting_identifier: meeting,
      role: role,
      language: :bilingual,
      media_type: "application/pdf"
    }
  end
end
