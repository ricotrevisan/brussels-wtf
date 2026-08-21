defmodule BrusselsWtf.Corpus.Manifest do
  @moduledoc "Hash-pinned, recorded contract for the bounded real-meeting corpus."

  def load! do
    manifest_path()
    |> File.read!()
    |> Jason.decode!()
    |> validate!()
  end

  def digest do
    manifest_path() |> File.read!() |> BrusselsWtf.Digest.sha256()
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
    Enum.find(load!()["meetings"], &(&1["key"] == key)) ||
      raise ArgumentError, "unknown real-corpus meeting #{inspect(key)}"
  end

  def meeting_by_identity(commune, municipal_identifier) do
    Enum.find(load!()["meetings"], fn meeting ->
      meeting["commune"] == commune and
        meeting["municipal_identifier"] == municipal_identifier
    end)
  end

  def source_by_sha256(sha256) do
    Enum.find_value(load!()["meetings"], fn meeting ->
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
         true <- MapSet.new(Map.keys(canonical["items"] || %{})) == item_keys(meeting) do
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

  defp valid_datetime?(value) when is_binary(value),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp valid_datetime?(_value), do: false

  defp verify_markers(text, meeting, source) do
    normalized = String.replace(text, ~r/\s+/u, " ")

    evidence_markers =
      meeting["items"]
      |> Enum.filter(&(&1["source"] == source["name"]))
      |> Enum.map(fn item ->
        if item["state"] == "proposal",
          do: item["proposal"]["excerpt"],
          else: item["decision"]["excerpt"]
      end)

    missing =
      source["markers"]
      |> Kernel.++(evidence_markers)
      |> Enum.reject(&String.contains?(normalized, &1))

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

  defp manifest_path do
    Application.app_dir(:brussels_wtf, "priv/corpus/issue-33/manifest.json")
  end
end
