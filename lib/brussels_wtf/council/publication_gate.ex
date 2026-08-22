defmodule BrusselsWtf.Council.PublicationGate do
  @moduledoc "Evaluates whether one generated meeting-page revision is complete and coherent."

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.Provenance
  alias BrusselsWtf.Council.PublicationInput
  alias BrusselsWtf.Council.PublicationScope

  @locales ["fr", "nl", "en"]

  def evaluate(meeting_page_id, expected_input_hash) do
    page =
      meeting_page_id
      |> Council.get_meeting_page!()
      |> Ash.load!([
        :coverage_runs,
        locale_variants: [:coverage_run],
        council_meeting: [
          :commune,
          :meeting_page,
          agenda_items: [
            coverage_variants: [:coverage_run],
            decision: [
              evidence: [source_version: [:source_record]],
              source_version: [:source_record]
            ],
            proposals: [
              source_version: [:source_record],
              evidence: [source_version: [:source_record]]
            ]
          ]
        ]
      ])

    canonical =
      case Enum.find(page.locale_variants, &(&1.locale == "fr")) do
        %{coverage_run: run}
        when not is_struct(run, Ash.NotLoaded) and run.operation == :canonical_generation and
               run.locale == "fr" and run.input_hash == expected_input_hash and
               run.status == :succeeded ->
          run

        _variant ->
          nil
      end

    {current_meeting, current_input} =
      case canonical && PublicationScope.restore(page.council_meeting, canonical.input) do
        {:ok, scoped} -> scoped
        _other -> {page.council_meeting, PublicationInput.build(page.council_meeting)}
      end

    input_failures =
      case PublicationInput.validate(current_input) do
        :ok ->
          if PublicationInput.hash(current_input) == expected_input_hash,
            do: [],
            else: [error(:stale_publication_input, nil, nil)]

        {:error, {:publication_gate, failures}} ->
          failures
      end

    blocking_failures =
      page.council_meeting
      |> BrusselsWtf.Review.list_blocking_publication_cases!()
      |> Enum.map(fn review_case ->
        %{
          code: :blocking_review_case,
          item_key: nil,
          claim_key: nil,
          locale: nil,
          review_case_id: review_case.id
        }
      end)

    failures =
      input_failures ++
        page_failures(page, canonical) ++
        Enum.flat_map(current_meeting.agenda_items, &item_failures(&1, canonical)) ++
        blocking_failures

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
      if required_provenance?(variant.coverage_run, canonical, variant.provenance),
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

  defp required_provenance?(%Ash.NotLoaded{}, _canonical, _provenance), do: false
  defp required_provenance?(nil, _canonical, _provenance), do: false

  defp required_provenance?(run, canonical, provenance) do
    Provenance.sufficient?(run, canonical, provenance)
  end

  defp missing_locales(variants) do
    present = MapSet.new(Enum.map(variants, & &1.locale))
    Enum.reject(@locales, &MapSet.member?(present, &1))
  end

  defp error(code, item_key, locale) do
    %{code: code, item_key: item_key, claim_key: nil, locale: locale}
  end
end
