defmodule BrusselsWtf.Council.Publication do
  @moduledoc "Generates complete localized meeting coverage and publishes it when ready."

  alias BrusselsWtf.Council

  @locales ["fr", "nl", "en"]
  @fetchable_schemes ["http", "https"]

  def generate_and_publish(meeting_id) do
    meeting = load_meeting(meeting_id)

    if meeting.meeting_page.publication_status == :published do
      :ok
    else
      generate_draft(meeting)
    end
  end

  defp generate_draft(meeting) do
    input = generation_input(meeting)

    result =
      with :ok <- validate_input(input),
           {:ok, canonical, canonical_duration_ms} <-
             timed(fn -> BrusselsWtf.Processors.generate_fr(input) end),
           :ok <- validate_locale_bundle(input, canonical, "fr"),
           {:ok, nl, nl_duration_ms} <-
             timed(fn -> BrusselsWtf.Processors.translate(canonical, "nl") end),
           :ok <- validate_locale_bundle(input, nl, "nl"),
           {:ok, en, en_duration_ms} <-
             timed(fn -> BrusselsWtf.Processors.translate(canonical, "en") end),
           :ok <- validate_locale_bundle(input, en, "en"),
           output = combine_locale_bundles(canonical, nl, en),
           :ok <- validate_output(input, output) do
        persist_and_publish(
          meeting,
          input,
          output,
          %{fr: canonical, nl: nl, en: en},
          BrusselsWtf.Processors.coverage_metadata(),
          %{fr: canonical_duration_ms, nl: nl_duration_ms, en: en_duration_ms}
        )
      end

    case result do
      {:error, {:publication_gate, failures}} ->
        report_gate_failure(meeting, input, failures)
        :ok

      other ->
        other
    end
  end

  def generation_input(meeting_id) when is_binary(meeting_id),
    do: meeting_id |> load_meeting() |> generation_input()

  def generation_input(meeting) do
    %{
      "meeting_identifier" => meeting.municipal_identifier,
      "scheduled_on" => Date.to_iso8601(meeting.scheduled_on),
      "items" => Enum.map(meeting.agenda_items, &item_input/1)
    }
  end

  defp item_input(item) do
    %{
      "key" => item.authoritative_identifier || item.continuity_key,
      "item_number" => item.item_number,
      "procedural_state" => to_string(item.procedural_state),
      "outcome" => to_string(item.outcome),
      "source_wording" => item.source_wording,
      "claims" => Enum.map(current_proposals(item), &proposal_input/1)
    }
  end

  defp proposal_input(proposal) do
    %{
      "key" => claim_key(proposal),
      "kind" => "proposal",
      "text" => proposal.text,
      "evidence" => Enum.map(proposal.evidence, &evidence_input/1)
    }
  end

  defp evidence_input(evidence) do
    %{
      "citation_url" => evidence.citation_url,
      "excerpt" => evidence.excerpt,
      "location" => evidence.location,
      "retrieved_at" => DateTime.to_iso8601(evidence.retrieved_at),
      "source_sha256" => evidence.source_version && evidence.source_version.sha256,
      "synthetic" => evidence.synthetic
    }
  end

  defp claim_key(proposal), do: "proposal:#{proposal.source_version.sha256}"

  defp current_proposals(item) do
    item.proposals
    |> Enum.reject(& &1.synthetic)
    |> Enum.group_by(& &1.source_version.source_record_id)
    |> Enum.map(fn {_source_record_id, proposals} ->
      Enum.max_by(proposals, fn proposal ->
        version = proposal.source_version

        {
          DateTime.to_unix(version.first_retrieved_at, :microsecond),
          DateTime.to_unix(version.inserted_at, :microsecond),
          version.id
        }
      end)
    end)
  end

  defp validate_input(%{"items" => []}), do: {:error, {:publication_gate, [:missing_item]}}

  defp validate_input(%{"items" => items}) do
    errors =
      Enum.flat_map(items, fn item ->
        case item["claims"] do
          [] -> [error(:missing_claim, item["key"])]
          claims -> Enum.flat_map(claims, &validate_claim(&1, item["key"]))
        end
      end)

    if errors == [], do: :ok, else: {:error, {:publication_gate, errors}}
  end

  defp validate_claim(claim, item_key) do
    if Enum.any?(claim["evidence"], &official_evidence?/1) do
      []
    else
      [error(:missing_official_evidence, item_key, claim["key"])]
    end
  end

  defp official_evidence?(evidence) do
    not evidence["synthetic"] and present?(evidence["excerpt"]) and
      present?(evidence["location"]) and present?(evidence["source_sha256"]) and
      valid_citation?(evidence["citation_url"])
  end

  defp validate_locale_bundle(input, bundle, locale) when is_map(bundle) do
    expected_items = MapSet.new(Enum.map(input["items"], & &1["key"]))
    actual_items = MapSet.new(Map.keys(Map.get(bundle, "items", %{})))

    page_errors =
      case bundle["page"] do
        %{"title" => title, "summary" => summary} when is_binary(title) and is_binary(summary) ->
          if present?(title) and present?(summary),
            do: [],
            else: [error(:blank_page_variant, nil, nil, locale)]

        _ ->
          [error(:missing_page_variant, nil, nil, locale)]
      end

    item_errors =
      Enum.flat_map(input["items"], fn item ->
        generated = get_in(bundle, ["items", item["key"]]) || %{}
        expected_claims = MapSet.new(Enum.map(item["claims"], & &1["key"]))
        actual_claims = MapSet.new(Map.get(generated, "claim_refs", []))

        claim_errors =
          if expected_claims == actual_claims,
            do: [],
            else: [error(:unsupported_claim_reference, item["key"], nil, locale)]

        variant_errors =
          case generated["variant"] do
            %{"title" => title, "summary" => summary, "proposal_summary" => proposal}
            when is_binary(title) and is_binary(summary) and is_binary(proposal) ->
              if Enum.all?([title, summary, proposal], &present?/1),
                do: [],
                else: [error(:blank_coverage_variant, item["key"], nil, locale)]

            _ ->
              [error(:missing_coverage_variant, item["key"], nil, locale)]
          end

        claim_errors ++ variant_errors
      end)

    errors = page_errors ++ validate_item_keys(expected_items, actual_items) ++ item_errors
    if errors == [], do: :ok, else: {:error, {:publication_gate, errors}}
  end

  defp validate_locale_bundle(_input, _bundle, locale),
    do: {:error, {:publication_gate, [error(:invalid_generation_output, nil, nil, locale)]}}

  defp validate_output(input, output) when is_map(output) do
    expected_items = MapSet.new(Enum.map(input["items"], & &1["key"]))
    actual_items = MapSet.new(Map.keys(Map.get(output, "items", %{})))

    errors =
      validate_page_locales(output) ++
        validate_item_keys(expected_items, actual_items) ++
        validate_item_variants(input, output)

    if errors == [], do: :ok, else: {:error, {:publication_gate, errors}}
  end

  defp validate_output(_input, _output),
    do: {:error, {:publication_gate, [error(:invalid_generation_output)]}}

  defp validate_page_locales(output) do
    page = Map.get(output, "page", %{})

    Enum.flat_map(@locales, fn locale ->
      case page[locale] do
        %{"title" => title, "summary" => summary} when is_binary(title) and is_binary(summary) ->
          if present?(title) and present?(summary),
            do: [],
            else: [error(:blank_page_variant, nil, nil, locale)]

        _ ->
          [error(:missing_page_variant, nil, nil, locale)]
      end
    end)
  end

  defp validate_item_keys(expected, actual) do
    missing = MapSet.difference(expected, actual)
    extra = MapSet.difference(actual, expected)

    Enum.map(missing, &error(:missing_item_generation, &1)) ++
      Enum.map(extra, &error(:unknown_item_generation, &1))
  end

  defp validate_item_variants(input, output) do
    Enum.flat_map(input["items"], fn item ->
      generated = get_in(output, ["items", item["key"]]) || %{}
      expected_claims = MapSet.new(Enum.map(item["claims"], & &1["key"]))
      actual_claims = MapSet.new(Map.get(generated, "claim_refs", []))

      claim_errors =
        if expected_claims == actual_claims,
          do: [],
          else: [error(:unsupported_claim_reference, item["key"])]

      variant_errors =
        Enum.flat_map(@locales, fn locale ->
          case get_in(generated, ["variants", locale]) do
            %{"title" => title, "summary" => summary, "proposal_summary" => proposal}
            when is_binary(title) and is_binary(summary) and is_binary(proposal) ->
              if Enum.all?([title, summary, proposal], &present?/1),
                do: [],
                else: [error(:blank_coverage_variant, item["key"], nil, locale)]

            _ ->
              [error(:missing_coverage_variant, item["key"], nil, locale)]
          end
        end)

      claim_errors ++ variant_errors
    end)
  end

  defp persist_and_publish(meeting, input, output, bundles, metadata, durations) do
    page = Map.fetch!(meeting, :meeting_page)
    input_hash = hash(input)

    canonical =
      record_run(
        page,
        "fr",
        :canonical_generation,
        nil,
        input,
        bundles.fr,
        metadata,
        durations.fr
      )

    canonical_input = %{
      "canonical_output_hash" => canonical.output_hash,
      "canonical" => bundles.fr
    }

    runs =
      Enum.reduce(["nl", "en"], %{"fr" => canonical}, fn locale, runs ->
        locale_atom = String.to_existing_atom(locale)

        run =
          record_run(
            page,
            locale,
            :translation,
            canonical.id,
            Map.put(canonical_input, "locale", locale),
            Map.fetch!(bundles, locale_atom),
            metadata,
            Map.fetch!(durations, locale_atom)
          )

        Map.put(runs, locale, run)
      end)

    Enum.each(@locales, fn locale ->
      page_variant = get_in(output, ["page", locale])

      Council.upsert_locale_variant!(%{
        meeting_page_id: page.id,
        coverage_run_id: runs[locale].id,
        locale: locale,
        title: page_variant["title"],
        summary: page_variant["summary"],
        provenance: provenance(locale)
      })
    end)

    Enum.each(meeting.agenda_items, fn item ->
      item_key = item.authoritative_identifier || item.continuity_key

      Enum.each(@locales, fn locale ->
        variant = get_in(output, ["items", item_key, "variants", locale])

        Council.upsert_coverage_variant!(%{
          agenda_item_id: item.id,
          coverage_run_id: runs[locale].id,
          locale: locale,
          title: variant["title"],
          summary: variant["summary"],
          proposal_summary: variant["proposal_summary"],
          provenance: provenance(locale)
        })
      end)
    end)

    case BrusselsWtf.Council.PublicationGate.evaluate(page.id, input_hash) do
      %{ready?: true} ->
        now = BrusselsWtf.Clock.utc_now()

        Council.publish_meeting_page!(page, %{
          revision_published_at: now,
          publication_input_hash: input_hash,
          last_gate_failures: [],
          gate_checked_at: now
        })

        :ok

      %{ready?: false, failures: failures} ->
        report_gate_failure(meeting, input, failures)
        :ok
    end
  end

  defp record_run(
         page,
         locale,
         operation,
         parent_run_id,
         run_input,
         run_output,
         metadata,
         duration_ms
       ) do
    Council.record_coverage_run!(%{
      meeting_page_id: page.id,
      parent_run_id: parent_run_id,
      operation: operation,
      locale: locale,
      input_hash: hash(run_input),
      output_hash: hash(run_output),
      processor_name: metadata.processor_name,
      processor_version: metadata.processor_version,
      config_hash: metadata.config_hash,
      provider_category: metadata.provider_category,
      model: metadata.model,
      status: :succeeded,
      input: run_input,
      output: run_output,
      usage: metadata.usage,
      duration_ms: duration_ms,
      failure_details: %{}
    })
  end

  defp timed(fun) do
    started_at = System.monotonic_time()

    case fun.() do
      {:ok, output} ->
        duration =
          System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

        {:ok, output, duration}

      {:error, _reason} = error ->
        error
    end
  end

  defp combine_locale_bundles(fr, nl, en) do
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

  defp hash(value) do
    "sha256:" <> BrusselsWtf.Digest.sha256(:erlang.term_to_binary(canonical(value)))
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp report_gate_failure(meeting, input, failures) do
    page = Map.fetch!(meeting, :meeting_page)
    input_hash = hash(input)
    serialized = Enum.map(failures, &serialize_failure/1)
    now = BrusselsWtf.Clock.utc_now()

    Council.record_publication_gate_failure!(page, %{
      publication_input_hash: input_hash,
      last_gate_failures: serialized,
      gate_checked_at: now
    })

    BrusselsWtf.Review.open_review_case!(%{
      kind: :publication,
      commune_id: meeting.commune_id,
      affected_record_id: page.id,
      affected_record_type: "meeting_page",
      processing_generation: input_hash,
      urgency: :high,
      summary: "Publication gate requires complete localized, evidenced coverage",
      normalized_content: input,
      diagnostics: %{"failures" => serialized}
    })
  end

  defp serialize_failure(failure) do
    %{
      "code" => Atom.to_string(failure.code),
      "item_key" => failure.item_key,
      "claim_key" => failure.claim_key,
      "locale" => failure.locale
    }
  end

  defp load_meeting(meeting_id) do
    meeting_id
    |> Council.get_meeting!()
    |> Ash.load!([
      :meeting_page,
      agenda_items: [proposals: [:source_version, evidence: [:source_version]]]
    ])
  end

  defp provenance("fr"), do: [:ai_generated]
  defp provenance(_locale), do: [:ai_generated, :machine_translated]

  defp valid_citation?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in @fetchable_schemes -> present?(host)
      _ -> false
    end
  end

  defp valid_citation?(_url), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp error(code, item_key \\ nil, claim_key \\ nil, locale \\ nil) do
    %{code: code, item_key: item_key, claim_key: claim_key, locale: locale}
  end
end
