defmodule BrusselsWtf.Corpus.Manifest do
  @moduledoc "Hash-pinned, recorded contract for the bounded real-meeting corpus."

  @contract_ids ~w(issue-33 current-20260911)

  def load!(id \\ "issue-33") do
    manifest = id |> manifest_path() |> File.read!() |> Jason.decode!()

    case id do
      "issue-33" -> validate!(manifest)
      "current-20260911" -> validate_current!(manifest)
    end
  end

  def digest(id \\ "issue-33") do
    id |> manifest_path() |> File.read!() |> BrusselsWtf.Digest.sha256()
  end

  def all_meetings do
    Enum.flat_map(@contract_ids, &load!(&1)["meetings"])
  end

  def bundle_path!(source) do
    base = Application.app_dir(:brussels_wtf, "priv/corpus/issue-33")
    path = Path.expand(Map.fetch!(source, "bundle_path"), base)
    sources = Path.join(base, "sources") <> "/"

    if String.starts_with?(path, sources),
      do: path,
      else: raise(ArgumentError, "real-corpus source path escapes the sealed bundle")
  end

  def meeting!(key) do
    Enum.find(all_meetings(), &(&1["key"] == key)) ||
      raise ArgumentError, "unknown real-corpus meeting #{inspect(key)}"
  end

  def meeting_by_identity(commune, municipal_identifier) do
    Enum.find(all_meetings(), fn meeting ->
      meeting["commune"] == commune and
        meeting["municipal_identifier"] == municipal_identifier
    end)
  end

  def contract_scope(meeting) do
    commune = meeting.commune.slug

    case meeting_by_identity(commune, meeting.municipal_identifier) do
      %{"scheduled_on" => scheduled_on} = contract ->
        if scheduled_on == Date.to_iso8601(meeting.scheduled_on) do
          keys = MapSet.new(Enum.map(contract["items"], & &1["key"]))
          %{meeting | agenda_items: Enum.filter(meeting.agenda_items, &item_in?(&1, keys))}
        else
          meeting
        end

      _other ->
        meeting
    end
  end

  def contract_item_count(meetings) do
    Enum.sum(Enum.map(meetings, &(contract_scope(&1).agenda_items |> length())))
  end

  def source_by_sha256(sha256) do
    Enum.find_value(all_meetings(), fn meeting ->
      case Enum.find(meeting["sources"], &(&1["sha256"] == sha256)) do
        nil -> nil
        source -> {meeting, source}
      end
    end)
  end

  def normalize(%{"sha256" => sha256, "text" => text}) when is_binary(text) do
    case source_by_sha256(sha256) do
      nil ->
        {:error, :processor_unimplemented}

      {meeting, source} ->
        with :ok <- verify_markers(text, meeting, source) do
          {:ok, normalization(meeting, source)}
        end
    end
  end

  def normalize(_extracted), do: {:error, :processor_unimplemented}

  def recorded_bundle(input, locale) when locale in ["fr", "nl", "en"] do
    with %{} = meeting <-
           meeting_by_identity(input["commune_slug"], input["meeting_identifier"]),
         :ok <- verify_publication_input(input, meeting) do
      {:ok, bundle(input, meeting, locale)}
    else
      _other -> {:error, :recorded_coverage_not_available}
    end
  end

  def recorded_translation(canonical, locale) when locale in ["nl", "en"] do
    with %{} = meeting <-
           meeting_by_identity(canonical["commune_slug"], canonical["meeting_identifier"]),
         true <- MapSet.new(Map.keys(canonical["items"] || %{})) == item_keys(meeting),
         true <- current_canonical_matches?(canonical, meeting) do
      {:ok, translated_bundle(canonical, meeting, locale)}
    else
      _other -> {:error, :recorded_translation_not_available}
    end
  end

  def recorded_translation(_canonical, _locale), do: {:error, :recorded_translation_not_available}

  defp validate!(%{"version" => 1, "meetings" => meetings, "dossiers" => dossiers} = manifest)
       when is_list(meetings) and is_list(dossiers) do
    identities = Enum.map(meetings, &{&1["commune"], &1["municipal_identifier"]})
    keys = Enum.map(meetings, & &1["key"])

    if length(meetings) != 8 or length(Enum.uniq(identities)) != 8 or
         length(Enum.uniq(keys)) != 8 or Enum.sum(Enum.map(meetings, &length(&1["items"]))) != 24 do
      raise "invalid issue-33 corpus bounds"
    end

    Enum.each(meetings, &validate_meeting!/1)

    unless Enum.all?(dossiers, fn dossier ->
             Enum.sort(Map.keys(dossier["titles"] || %{})) == ~w(en fr nl) and
               Enum.all?(dossier["titles"], fn {_locale, title} ->
                 is_binary(title) and String.trim(title) != ""
               end)
           end),
           do: raise("invalid issue-33 dossier coverage")

    manifest
  end

  defp validate!(_manifest), do: raise("invalid issue-33 corpus manifest")

  defp validate_meeting!(meeting) do
    item_keys = Enum.map(meeting["items"], & &1["key"])
    source_names = MapSet.new(Enum.map(meeting["sources"], & &1["name"]))

    Enum.each(meeting["sources"], &bundle_path!/1)

    valid_sources? =
      meeting["sources"] != [] and
        Enum.all?(meeting["sources"], fn source ->
          is_binary(source["url"]) and String.starts_with?(source["url"], "https://") and
            is_binary(source["sha256"]) and byte_size(source["sha256"]) == 64 and
            is_integer(source["byte_size"]) and source["byte_size"] > 0 and
            source["byte_size"] <= 2_000_000 and
            is_binary(source["bundle_path"]) and
            String.starts_with?(source["bundle_path"], "sources/") and
            is_binary(source["parent_index_url"]) and
            String.starts_with?(source["parent_index_url"], "https://") and
            valid_datetime?(source["captured_at"]) and
            is_list(source["markers"]) and source["markers"] != [] and
            source["role"] in ~w(agenda explanatory_note minutes register supplement)
        end)

    valid_items? =
      length(meeting["items"]) == 3 and length(Enum.uniq(item_keys)) == 3 and
        Enum.all?(meeting["items"], fn item ->
          item["state"] in ["proposal", "decision"] and
            Enum.sort(Map.keys(item["coverage"])) == ~w(en fr nl) and
            MapSet.member?(source_names, item["source"])
        end)

    unless valid_sources? and valid_items?,
      do: raise("invalid issue-33 meeting #{inspect(meeting["key"])}")
  end

  # This is a second sealed contract, not a generic manifest-upload API.
  @current_meetings %{
    "ixelles-269" => %{
      "commune" => "ixelles",
      "municipal_identifier" => "269",
      "scheduled_on" => "2026-09-17",
      "item_numbers" => ["38", "39"],
      "item_keys" => ["38", "39"],
      "source_url" => "https://www.ixelles.be/uploads/conseil/odj/269.pdf",
      "parent_index_url" =>
        "https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr",
      "role" => "agenda"
    },
    "forest-2026-09-01" => %{
      "commune" => "forest",
      "municipal_identifier" => "2026-09-01",
      "scheduled_on" => "2026-09-01",
      "item_numbers" => ["13", "45"],
      "item_keys" => ["forest-2026-09-01-13", "forest-2026-09-01-45"],
      "source_url" =>
        "https://forest.brussels/sites/default/files/publications/notes/2026-08/CC%20-%2001092026%20-%20Notes%20explicatives%20publiques%20compl%C3%A9mentaires.pdf",
      "parent_index_url" => "https://forest.brussels/fr/publications/conseil-communal-1",
      "role" => "complementary_explanatory_note"
    },
    "uccle-2026-09-10" => %{
      "commune" => "uccle",
      "municipal_identifier" => "2026-09-10",
      "scheduled_on" => "2026-09-10",
      "item_numbers" => ["12", "38"],
      "item_keys" => ["12", "38"],
      "source_url" =>
        "https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-NEC-U1180_fr_nl.pdf",
      "parent_index_url" => "https://www.uccle.be/fr/ma-commune/le-conseil-communal",
      "role" => "complementary_explanatory_note"
    },
    "city-2026-09-07" => %{
      "commune" => "city-of-brussels",
      "municipal_identifier" => "2026-09-07",
      "scheduled_on" => "2026-09-07",
      "item_numbers" => ["30", "31"],
      "item_keys" => ["2722248", "2728690"],
      "source_url" => "https://www.brussels.be/sites/default/files/OJ20260907.pdf",
      "parent_index_url" =>
        "https://www.brussels.be/agenda-reports-and-motions-city-council?field_date_document_value=2026",
      "role" => "agenda"
    }
  }

  defp validate_current!(%{"version" => 1, "meetings" => meetings, "dossiers" => []} = manifest)
       when is_list(meetings) do
    keys = Enum.map(meetings, & &1["key"])

    unless length(meetings) == 4 and Enum.sort(keys) == Enum.sort(Map.keys(@current_meetings)) and
             Enum.sum(Enum.map(meetings, &length(&1["items"]))) == 8 and
             manifest["provenance"]["canonical_method"] == "AI-generated" and
             manifest["provenance"]["translation_method"] == "machine-translated" and
             manifest["provenance"]["human_reviewed"] == false do
      raise "invalid current-20260911 corpus bounds or provenance"
    end

    Enum.each(meetings, &validate_current_meeting!/1)
    manifest
  end

  defp validate_current!(_manifest), do: raise("invalid current-20260911 corpus manifest")

  defp validate_current_meeting!(meeting) do
    expected = Map.fetch!(@current_meetings, meeting["key"])
    sources = meeting["sources"]
    items = meeting["items"]

    valid_identity? =
      Map.take(meeting, ~w(commune municipal_identifier scheduled_on)) ==
        Map.take(expected, ~w(commune municipal_identifier scheduled_on))

    valid_sources? =
      length(sources) == 1 and
        Enum.all?(sources, fn source ->
          source["url"] == expected["source_url"] and
            source["parent_index_url"] == expected["parent_index_url"] and
            official_url?(source["url"], meeting["commune"]) and
            official_url?(source["parent_index_url"], meeting["commune"]) and
            source["role"] == expected["role"] and
            source["role"] in ~w(agenda complementary_explanatory_note) and
            source["acquisition"] == "official_fetch" and not Map.has_key?(source, "bundle_path") and
            is_binary(source["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, source["sha256"]) and
            is_integer(source["byte_size"]) and source["byte_size"] > 0 and
            source["byte_size"] <= 2_000_000 and source["media_type"] == "application/pdf" and
            is_integer(source["page_count"]) and source["page_count"] > 0 and
            source["language"] in ~w(fr bilingual) and
            valid_datetime?(source["captured_at"]) and
            String.starts_with?(source["captured_at"], "2026-09-11T") and
            nonempty?(source["name"]) and nonempty_strings?(source["markers"])
        end)

    valid_items? =
      length(items) == 2 and Enum.map(items, & &1["item_number"]) == expected["item_numbers"] and
        Enum.map(items, & &1["key"]) == expected["item_keys"] and
        Enum.all?(items, fn item ->
          source = Enum.find(sources, &(&1["name"] == item["source"]))

          item["state"] == "proposal" and item["outcome"] == "unknown" and
            not Map.has_key?(item, "decision") and nonempty?(item["source_wording"]) and
            nonempty?(item["identity_marker"]) and is_map(source) and
            valid_pages?(item["evidence_pages"], source["page_count"]) and
            is_list(item["evidence_markers"]) and
            Enum.all?(item["evidence_markers"], &nonempty?/1) and
            is_map(item["proposal"]) and
            Enum.all?(~w(text excerpt location), &nonempty?(item["proposal"][&1])) and
            valid_coverage?(item["coverage"])
        end)

    unless valid_identity? and valid_sources? and valid_items? and
             valid_coverage?(meeting["coverage"]),
           do: raise("invalid current-20260911 meeting #{inspect(meeting["key"])}")
  end

  defp official_url?(url, commune) do
    host =
      %{
        "ixelles" => "www.ixelles.be",
        "uccle" => "www.uccle.be",
        "forest" => "forest.brussels",
        "city-of-brussels" => "www.brussels.be"
      }[commune]

    case URI.parse(url) do
      %URI{scheme: "https", host: ^host, userinfo: nil, port: 443} -> true
      _other -> false
    end
  end

  defp valid_pages?([first, last], count),
    do: is_integer(first) and is_integer(last) and first > 0 and first <= last and last <= count

  defp valid_pages?(_pages, _count), do: false

  defp valid_coverage?(coverage) when is_map(coverage) do
    Enum.sort(Map.keys(coverage)) == ~w(en fr nl) and
      Enum.all?(coverage, fn {_locale, variant} ->
        is_map(variant) and nonempty?(variant["title"]) and nonempty?(variant["summary"])
      end)
  end

  defp valid_coverage?(_coverage), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp nonempty_strings?(values),
    do: is_list(values) and values != [] and Enum.all?(values, &nonempty?/1)

  defp valid_datetime?(value) when is_binary(value),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp valid_datetime?(_value), do: false

  defp verify_markers(text, meeting, source) do
    normalized = String.replace(text, ~r/\s+/u, " ")

    pages = String.split(text, "\f")

    missing_items =
      meeting["items"]
      |> Enum.filter(&(&1["source"] == source["name"]))
      |> Enum.flat_map(fn item ->
        [first, last] = item["evidence_pages"]
        scope = pages |> Enum.slice((first - 1)..(last - 1)) |> Enum.join(" ")
        scope = String.replace(scope, ~r/\s+/u, " ")
        claim = item[item["state"]]

        wording =
          if source["acquisition"] == "official_fetch", do: [item["source_wording"]], else: []

        (wording ++ [item["identity_marker"], claim["excerpt"] | item["evidence_markers"]])
        |> Enum.reject(&String.contains?(scope, &1))
        |> Enum.map(&"#{item["key"]} pages #{first}-#{last}: #{&1}")
      end)

    missing = Enum.reject(source["markers"], &String.contains?(normalized, &1)) ++ missing_items

    if missing == [],
      do: :ok,
      else:
        {:error,
         {:normalization_ambiguity,
          %{"contract" => "#{meeting["key"]}:#{source["name"]}", "missing_markers" => missing}}}
  end

  defp normalization(meeting, source) do
    %{
      "meeting_identifier" => meeting["municipal_identifier"],
      "scheduled_on" => meeting["scheduled_on"],
      "agenda" => %{
        "kind" => if(source["role"] in ["minutes", "register"], do: "final", else: "base"),
        "language" => source["language"]
      },
      "items" =>
        meeting["items"]
        |> Enum.filter(&(&1["source"] == source["name"]))
        |> Enum.map(&normalized_item/1)
    }
  end

  defp normalized_item(item) do
    base = %{
      "item_number" => item["item_number"],
      "authoritative_identifier" => item["key"],
      "source_wording" => item["source_wording"]
    }

    case item["state"] do
      "proposal" ->
        proposal = item["proposal"]

        Map.put(base, "proposals", [
          %{
            "text" => proposal["text"],
            "evidence" => %{
              "claim" => "proposal",
              "excerpt" => proposal["excerpt"],
              "location" => proposal["location"]
            }
          }
        ])

      "decision" ->
        decision = item["decision"]

        Map.put(base, "decisions", [
          %{
            "disposition" => decision["disposition"],
            "statement" => decision["statement"],
            "evidence" => %{
              "excerpt" => decision["excerpt"],
              "location" => decision["location"]
            }
          }
        ])
    end
  end

  defp verify_publication_input(input, meeting) do
    actual = canonical_publication_contract(input)
    expected = expected_publication_contract(meeting)
    if actual == expected, do: :ok, else: {:error, :recorded_coverage_not_available}
  end

  defp canonical_publication_contract(input) do
    %{
      "commune_slug" => input["commune_slug"],
      "meeting_identifier" => input["meeting_identifier"],
      "scheduled_on" => input["scheduled_on"],
      "items" =>
        input
        |> Map.get("items", [])
        |> Enum.map(fn item ->
          Map.take(item, [
            "key",
            "item_number",
            "procedural_state",
            "outcome",
            "source_wording",
            "claims"
          ])
          |> update_in(["claims"], fn claims ->
            Enum.map(claims || [], fn claim ->
              Map.update(claim, "evidence", [], fn evidence ->
                Enum.map(evidence, &Map.delete(&1, "retrieved_at"))
              end)
            end)
          end)
        end)
        |> Enum.sort_by(& &1["key"])
    }
  end

  defp expected_publication_contract(meeting) do
    sources = Map.new(meeting["sources"], &{&1["name"], &1})

    %{
      "commune_slug" => meeting["commune"],
      "meeting_identifier" => meeting["municipal_identifier"],
      "scheduled_on" => meeting["scheduled_on"],
      "items" =>
        meeting["items"]
        |> Enum.map(fn item ->
          expected_publication_item(item, Map.fetch!(sources, item["source"]))
        end)
        |> Enum.sort_by(& &1["key"])
    }
  end

  defp current_canonical_matches?(canonical, meeting) do
    if Map.has_key?(@current_meetings, meeting["key"]) do
      expected = meeting |> expected_publication_contract() |> bundle(meeting, "fr")
      canonical == expected
    else
      true
    end
  end

  defp expected_publication_item(item, source) do
    claim = if item["state"] == "proposal", do: item["proposal"], else: item["decision"]
    kind = item["state"]

    evidence = %{
      "citation_url" => source["url"],
      "excerpt" => claim["excerpt"],
      "location" => claim["location"],
      "source_sha256" => source["sha256"],
      "source_origin_url" => source["url"],
      "synthetic" => false
    }

    normalized_claim = %{
      "key" => "#{kind}:#{item["key"]}:#{source["sha256"]}",
      "kind" => kind,
      "text" => if(kind == "decision", do: claim["statement"], else: claim["text"]),
      "evidence" => [evidence]
    }

    normalized_claim =
      if kind == "decision" do
        normalized_claim
        |> Map.put("disposition", claim["disposition"])
        |> Map.put("vote", nil)
      else
        normalized_claim
      end

    %{
      "key" => item["key"],
      "item_number" => item["item_number"],
      "procedural_state" => item["state"],
      "outcome" => if(kind == "decision", do: claim["disposition"], else: "unknown"),
      "source_wording" => item["source_wording"],
      "claims" => [normalized_claim]
    }
  end

  defp bundle(input, meeting, locale) do
    refs_by_item =
      Map.new(input["items"], &{&1["key"], Enum.map(&1["claims"], fn claim -> claim["key"] end)})

    coverage = meeting["coverage"][locale]

    %{
      "commune_slug" => meeting["commune"],
      "meeting_identifier" => meeting["municipal_identifier"],
      "page" => Map.put(coverage, "claim_refs", refs_by_item |> Map.values() |> List.flatten()),
      "items" =>
        Map.new(meeting["items"], fn item ->
          refs = refs_by_item[item["key"]]
          {item["key"], %{"claim_refs" => refs, "variant" => variant(item, locale)}}
        end)
    }
  end

  defp translated_bundle(canonical, meeting, locale) do
    coverage = meeting["coverage"][locale]

    %{
      "commune_slug" => meeting["commune"],
      "meeting_identifier" => meeting["municipal_identifier"],
      "page" => Map.put(coverage, "claim_refs", canonical["page"]["claim_refs"]),
      "items" =>
        Map.new(meeting["items"], fn item ->
          refs = canonical["items"][item["key"]]["claim_refs"]
          {item["key"], %{"claim_refs" => refs, "variant" => variant(item, locale)}}
        end)
    }
  end

  defp variant(item, locale) do
    coverage = item["coverage"][locale]

    coverage
    |> Map.put("proposal_summary", if(item["state"] == "proposal", do: coverage["summary"]))
    |> Map.put("decision_summary", if(item["state"] == "decision", do: coverage["summary"]))
  end

  defp item_keys(meeting), do: meeting["items"] |> Enum.map(& &1["key"]) |> MapSet.new()

  defp manifest_path(id) when id in @contract_ids do
    Application.app_dir(:brussels_wtf, "priv/corpus/#{id}/manifest.json")
  end

  defp manifest_path(id), do: raise(ArgumentError, "unknown real-corpus contract #{inspect(id)}")

  defp item_in?(item, keys) do
    MapSet.member?(keys, item.authoritative_identifier || item.continuity_key)
  end
end
