defmodule BrusselsWtf.Council.PublicationGate do
  @moduledoc "Evaluates whether one generated meeting-page revision is complete and coherent."

  alias BrusselsWtf.Council

  @locales ["fr", "nl", "en"]

  def evaluate(meeting_page_id, expected_input_hash) do
    page =
      meeting_page_id
      |> Council.get_meeting_page!()
      |> Ash.load!([
        :coverage_runs,
        locale_variants: [:coverage_run],
        council_meeting: [agenda_items: [coverage_variants: [:coverage_run]]]
      ])

    canonical =
      Enum.find(page.coverage_runs, fn run ->
        run.operation == :canonical_generation and run.locale == "fr" and
          run.input_hash == expected_input_hash and run.status == :succeeded
      end)

    failures =
      page_failures(page, canonical) ++
        Enum.flat_map(page.council_meeting.agenda_items, &item_failures(&1, canonical))

    %{ready?: failures == [], failures: failures, input_hash: expected_input_hash}
  end

  defp page_failures(page, canonical) do
    missing = missing_locales(page.locale_variants)

    Enum.map(missing, &error(:missing_page_variant, nil, &1)) ++
      Enum.flat_map(page.locale_variants, &variant_failures(&1, canonical, nil))
  end

  defp item_failures(item, canonical) do
    item_key = item.authoritative_identifier || item.continuity_key
    missing = missing_locales(item.coverage_variants)

    Enum.map(missing, &error(:missing_coverage_variant, item_key, &1)) ++
      Enum.flat_map(item.coverage_variants, &variant_failures(&1, canonical, item_key))
  end

  defp variant_failures(variant, canonical, item_key) do
    provenance_errors =
      if required_provenance?(variant.locale, variant.provenance),
        do: [],
        else: [error(:missing_provenance, item_key, variant.locale)]

    run_errors =
      if current_run?(variant.coverage_run, variant.locale, canonical),
        do: [],
        else: [error(:stale_generation, item_key, variant.locale)]

    provenance_errors ++ run_errors
  end

  defp current_run?(_run, _locale, nil), do: false
  defp current_run?(%Ash.NotLoaded{}, _locale, _canonical), do: false
  defp current_run?(nil, _locale, _canonical), do: false

  defp current_run?(run, "fr", canonical),
    do: run.id == canonical.id and run.status == :succeeded

  defp current_run?(run, locale, canonical) do
    run.locale == locale and run.operation == :translation and run.status == :succeeded and
      run.parent_run_id == canonical.id and
      run.input["canonical_output_hash"] == canonical.output_hash
  end

  defp required_provenance?("fr", provenance), do: :ai_generated in provenance

  defp required_provenance?(locale, provenance) when locale in ["nl", "en"],
    do: :ai_generated in provenance and :machine_translated in provenance

  defp missing_locales(variants) do
    present = MapSet.new(Enum.map(variants, & &1.locale))
    Enum.reject(@locales, &MapSet.member?(present, &1))
  end

  defp error(code, item_key, locale) do
    %{code: code, item_key: item_key, claim_key: nil, locale: locale}
  end
end
