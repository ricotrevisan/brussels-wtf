defmodule BrusselsWtf.Identity.MandateDeclaration do
  @moduledoc """
  The bounded, inspected Ixelles declaration contract.

  A scanned signature cannot be established by finding the word "Signature" in
  OCR. The first slice therefore accepts only inspected byte versions and their
  exact declaration/page/row bindings. New bytes require a new inspected contract;
  they never inherit the signature or identity of an older version at the URL.
  No signature image, fiscal sheet, private identifier or income is projected.

  Poppler still runs first. This inspected source is a scanned bundle with an
  existing noisy OCR layer, not born-digital text. Character density alone
  cannot establish native evidence quality here: its source-specific native
  decision therefore requires independent OCR of the two inspected pages.
  The remainder of the bundle is never selected for OCR or retained as text.
  """

  @origin "https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf"
  @index "https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr"
  @documents %{
    "c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2" => %{
      origin: @origin,
      year: 2024,
      page: 14,
      attestation_page: 17,
      attestation: "Fait à Ixelles, le 30 septembre 2025",
      given_name: "Gautier",
      family_name: "CALOMNE",
      row: "Premier Echevin et Officier de l'Etat Civil (Décembre 2024)",
      role: "Premier Echevin et Officier de l'Etat Civil",
      role_labels: %{
        "fr" => "Premier Echevin et Officier de l'Etat Civil",
        "nl" => "Eerste schepen en ambtenaar van de burgerlijke stand",
        "en" => "First alderman and civil registrar"
      },
      revision: 1,
      body: "Commune d'Ixelles",
      section: "mandat",
      key: "ixelles-municipal-executive-mandate",
      effective_from: ~D[2024-12-01],
      effective_to: ~D[2024-12-31],
      signed?: true
    }
  }

  # Synthetic contracts are injected only in tests, just like the controlled
  # HTTP/PDF adapters. Production always uses the compiled inspected registry.
  @test_contracts Application.compile_env(:brussels_wtf, :mandate_test_contracts, false)

  def origin, do: @origin
  def index, do: @index

  def contract(sha256) do
    documents =
      if @test_contracts,
        do:
          Map.merge(@documents, Application.get_env(:brussels_wtf, :mandate_test_documents, %{})),
        else: @documents

    case Map.fetch(documents, sha256) do
      {:ok, %{signed?: true} = document} -> {:ok, document}
      {:ok, _} -> {:error, :unsigned_declaration}
      :error -> {:error, :uninspected_source_version}
    end
  end

  def parse(sha256, origin, text) when is_binary(text) do
    with {:ok, document} <- contract(sha256),
         true <- origin == document.origin,
         pages = String.split(text, "\f"),
         page when is_binary(page) <- Enum.at(pages, document.page - 1),
         attestation when is_binary(attestation) <- Enum.at(pages, document.attestation_page - 1),
         {:ok, name} <- declarant(page),
         true <- name == name(document),
         {:ok, rows} <- section_rows(page, document.section),
         true <- Enum.count(rows, &(normalize(&1) == normalize(document.row))) == 1,
         true <- attested?(attestation, document) do
      {:ok, document}
    else
      {:error, _} = error -> error
      _ -> {:error, :declaration_scope_or_text_mismatch}
    end
  end

  def normalize(value) when is_binary(value) do
    value
    |> String.normalize(:nfc)
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.downcase()
  end

  def name(document), do: normalize(document.given_name <> " " <> document.family_name)

  def metadata(document) do
    %{
      "key" => document.key,
      "role" => document.role,
      "revision" => document.revision,
      "body" => document.body,
      "section" => document.section,
      "reporting_year" => document.year,
      "page" => document.page,
      "attestation_page" => document.attestation_page,
      "declarant" => document.given_name <> " " <> document.family_name
    }
  end

  def location(document), do: "declaration #{document.year} page #{document.page}"

  def matches?(fact, person, document) do
    normalize(person.legal_name) == name(document) and
      fact.mandate_declaration == metadata(document) and
      fact.evidence_excerpt == document.row and
      fact.evidence_location == location(document) and
      fact.effective_from == document.effective_from and
      fact.effective_to == document.effective_to and
      fact.authoritative_url == document.origin
  end

  def unique_person?(person) do
    rows =
      BrusselsWtf.Repo.query!(
        "SELECT legal_name, explicit_identifier FROM people WHERE status = 'active'"
      ).rows

    identity_valid? =
      person.resolution_basis == :corroborated_name or
        (person.resolution_basis == :explicit_identifier and
           is_binary(person.explicit_identifier) and person.explicit_identifier != "" and
           Enum.count(rows, fn [_, id] -> id == person.explicit_identifier end) == 1)

    person.status == :active and identity_valid? and
      Enum.count(rows, fn [name, _] -> normalize(name) == normalize(person.legal_name) end) == 1
  end

  def safe_text(sha256, text) do
    with {:ok, document} <- contract(sha256),
         {:ok, _} <- parse(sha256, document.origin, text) do
      # Preserve page numbers while retaining only fields already validated
      # against the inspected contract. Never archive extracted fiscal content.
      pages = List.duplicate("", max(document.page, document.attestation_page))

      pages =
        List.replace_at(
          pages,
          document.page - 1,
          "Nom : #{document.family_name}\nPrénom : #{document.given_name}\nMANDATS\n#{document.row}\nFONCTIONS"
        )

      pages =
        List.replace_at(
          pages,
          document.attestation_page - 1,
          "#{document.attestation}\n#{document.given_name} #{document.family_name}\nSignature"
        )

      Enum.join(pages, "\f")
    else
      _ -> ""
    end
  end

  def quality(sha256, quality, stage) do
    numbers =
      case contract(sha256) do
        {:ok, document} -> [document.page, document.attestation_page]
        _ -> []
      end

    pages = Enum.filter(quality["pages"], &(&1["page"] in numbers))

    accepted =
      stage == :ocr and length(pages) == 2 and
        Enum.all?(pages, &(&1["decision"] == "accepted"))

    quality
    |> Map.put("pages", pages)
    |> Map.put("accepted", accepted)
    |> Map.put("rejected_pages", if(accepted, do: [], else: numbers))
  end

  defp declarant(page) do
    with [[_, surname]] <-
           Regex.scan(~r/^[ \t]*(?:Nom|Nam)[ \t]*[:;]+[ \t]*([^\r\n]+)$/imu, page),
         [[_, given]] <- Regex.scan(~r/^[ \t]*Prénom[ \t]*[:;]+[ \t]*([^\r\n]+)$/imu, page) do
      {:ok, normalize(given <> " " <> surname)}
    else
      _ -> {:error, :missing_or_ambiguous_declarant}
    end
  end

  defp section_rows(page, "mandat") do
    # Scanned table rules yield border glyphs and O/0 artifacts in the inspected
    # OCR profile. Only those header decorations are ignored; role and identity
    # values are never fuzzy-matched or repaired.
    lines = String.split(page, "\n") |> Enum.map(&clean_border/1)

    starts =
      Enum.with_index(lines)
      |> Enum.filter(fn {line, _} -> Regex.match?(~r/\AMANDATS[ O0|]*\z/, line) end)

    stops =
      Enum.with_index(lines)
      |> Enum.filter(fn {line, _} -> Regex.match?(~r/\AFONCTIONS[ O0|]*\z/, line) end)

    case {starts, stops} do
      {[{_, start}], [{_, stop}]} when start < stop ->
        {:ok, Enum.slice(lines, start + 1, stop - start - 1)}

      _ ->
        {:error, :missing_or_ambiguous_section}
    end
  end

  defp section_rows(_, _), do: {:error, :unsupported_section}

  defp clean_border(line),
    do: line |> String.trim() |> String.replace(~r/\A[|\[]\s*/, "") |> String.trim()

  defp attested?(text, document) do
    lines = String.split(text, "\n") |> Enum.map(&normalize/1)
    normalize(document.attestation) in lines and name(document) in lines and "signature" in lines
  end
end
