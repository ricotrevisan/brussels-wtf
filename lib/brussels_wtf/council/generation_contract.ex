defmodule BrusselsWtf.Council.GenerationContract do
  @moduledoc "Validates provider bundles against normalized claim and locale requirements."

  @locales ["fr", "nl", "en"]

  def validate_bundle(input, bundle, locale) when locale in @locales and is_map(bundle) do
    expected_items = MapSet.new(Enum.map(input["items"], & &1["key"]))
    actual_items = MapSet.new(Map.keys(Map.get(bundle, "items", %{})))

    expected_page_claims =
      input["items"]
      |> Enum.flat_map(& &1["claims"])
      |> MapSet.new(& &1["key"])

    failures =
      validate_page(bundle["page"], locale, expected_page_claims) ++
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
         %{"title" => title, "summary" => summary, "claim_refs" => claim_refs},
         locale,
         expected_claims
       )
       when is_binary(title) and is_binary(summary) and is_list(claim_refs) do
    cond do
      not Enum.all?([title, summary], &present?/1) ->
        [error(:blank_page_variant, nil, nil, locale)]

      MapSet.new(claim_refs) != expected_claims ->
        [error(:unsupported_page_claim_reference, nil, nil, locale)]

      true ->
        []
    end
  end

  defp validate_page(_page, locale, _expected_claims),
    do: [error(:missing_page_variant, nil, nil, locale)]

  defp validate_item(item, bundle, locale) do
    generated = get_in(bundle, ["items", item["key"]]) || %{}
    expected_claims = MapSet.new(Enum.map(item["claims"], & &1["key"]))
    actual_claims = MapSet.new(Map.get(generated, "claim_refs", []))

    claim_failures =
      if expected_claims == actual_claims,
        do: [],
        else: [error(:unsupported_claim_reference, item["key"], nil, locale)]

    claim_failures ++ validate_variant(generated["variant"], item, locale)
  end

  defp validate_variant(%{"title" => title, "summary" => summary} = variant, item, locale)
       when is_binary(title) and is_binary(summary) do
    kinds = MapSet.new(Enum.map(item["claims"], & &1["kind"]))

    required =
      [title, summary] ++
        if(MapSet.member?(kinds, "proposal"), do: [variant["proposal_summary"]], else: []) ++
        if(MapSet.member?(kinds, "decision"), do: [variant["decision_summary"]], else: [])

    if Enum.all?(required, &present?/1),
      do: [],
      else: [error(:blank_coverage_variant, item["key"], nil, locale)]
  end

  defp validate_variant(_variant, item, locale),
    do: [error(:missing_coverage_variant, item["key"], nil, locale)]

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
