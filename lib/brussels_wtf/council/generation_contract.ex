defmodule BrusselsWtf.Council.GenerationContract do
  @moduledoc "Validates provider bundles against normalized claim and locale requirements."

  @locales ["fr", "nl", "en"]

  def validate_bundle(input, bundle, locale) when locale in @locales and is_map(bundle) do
    expected_items = MapSet.new(Enum.map(input["items"], & &1["key"]))
    actual_items = MapSet.new(Map.keys(Map.get(bundle, "items", %{})))

    failures =
      validate_page(bundle["page"], locale) ++
        validate_item_keys(expected_items, actual_items) ++
        Enum.flat_map(input["items"], &validate_item(&1, bundle, locale))

    if failures == [], do: :ok, else: {:error, {:publication_gate, failures}}
  end

  def validate_bundle(_input, _bundle, locale),
    do: {:error, {:publication_gate, [error(:invalid_generation_output, nil, nil, locale)]}}

  def combine(fr, nl, en) do
    bundles = %{"fr" => fr, "nl" => nl, "en" => en}

    %{
      "page" => Map.new(bundles, fn {locale, bundle} -> {locale, bundle["page"]} end),
      "items" =>
        Map.new(fr["items"], fn {item_key, canonical_item} ->
          {item_key,
           %{
             "claim_refs" => canonical_item["claim_refs"],
             "variants" =>
               Map.new(bundles, fn {locale, bundle} ->
                 {locale, get_in(bundle, ["items", item_key, "variant"])}
               end)
           }}
        end)
    }
  end

  defp validate_page(
         %{"title" => title, "summary" => summary},
         locale
       )
       when is_binary(title) and is_binary(summary) do
    if Enum.all?([title, summary], &present?/1),
      do: [],
      else: [error(:blank_page_variant, nil, nil, locale)]
  end

  defp validate_page(_page, locale), do: [error(:missing_page_variant, nil, nil, locale)]

  defp validate_item(item, bundle, locale) do
    generated = get_in(bundle, ["items", item["key"]]) || %{}
    expected_claims = MapSet.new(Enum.map(item["claims"], & &1["key"]))
    actual_claims = MapSet.new(Map.get(generated, "claim_refs", []))

    claim_failures =
      if expected_claims == actual_claims,
        do: [],
        else: [error(:unsupported_claim_reference, item["key"], nil, locale)]

    claim_failures ++ validate_variant(generated["variant"], item["key"], locale)
  end

  defp validate_variant(
         %{"title" => title, "summary" => summary, "proposal_summary" => proposal},
         item_key,
         locale
       )
       when is_binary(title) and is_binary(summary) and is_binary(proposal) do
    if Enum.all?([title, summary, proposal], &present?/1),
      do: [],
      else: [error(:blank_coverage_variant, item_key, nil, locale)]
  end

  defp validate_variant(_variant, item_key, locale),
    do: [error(:missing_coverage_variant, item_key, nil, locale)]

  defp validate_item_keys(expected, actual) do
    Enum.map(MapSet.difference(expected, actual), &error(:missing_item_generation, &1)) ++
      Enum.map(MapSet.difference(actual, expected), &error(:unknown_item_generation, &1))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp error(code, item_key), do: error(code, item_key, nil, nil)

  defp error(code, item_key, claim_key, locale) do
    %{code: code, item_key: item_key, claim_key: claim_key, locale: locale}
  end
end
