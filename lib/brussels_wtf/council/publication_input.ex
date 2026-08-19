defmodule BrusselsWtf.Council.PublicationInput do
  @moduledoc "Builds and hashes the deterministic normalized input allowed into coverage generation."

  @fetchable_schemes ["http", "https"]

  def build(meeting) do
    %{
      "commune_slug" => meeting.commune.slug,
      "meeting_identifier" => meeting.municipal_identifier,
      "scheduled_on" => Date.to_iso8601(meeting.scheduled_on),
      "items" =>
        meeting.agenda_items
        |> Enum.sort_by(&item_sort_key/1)
        |> Enum.map(&item_input/1)
    }
  end

  def validate(%{"items" => []}),
    do: {:error, {:publication_gate, [error(:missing_item)]}}

  def validate(%{"items" => items}) do
    failures =
      Enum.flat_map(items, fn item ->
        state_failures =
          if item["procedural_state"] == "proposal" and item["outcome"] == "unknown",
            do: [],
            else: [error(:unsupported_publication_state, item["key"])]

        claim_failures =
          case item["claims"] do
            [] -> [error(:missing_claim, item["key"])]
            claims -> Enum.flat_map(claims, &validate_claim(&1, item["key"]))
          end

        state_failures ++ claim_failures
      end)

    if failures == [], do: :ok, else: {:error, {:publication_gate, failures}}
  end

  def hash(value) do
    "sha256:" <> BrusselsWtf.Digest.sha256(:erlang.term_to_binary(canonical(value)))
  end

  defp item_input(item) do
    %{
      "key" => item_key(item),
      "item_number" => item.item_number,
      "procedural_state" => to_string(item.procedural_state),
      "outcome" => to_string(item.outcome),
      "source_wording" => item.source_wording,
      "claims" =>
        item
        |> current_proposals()
        |> Enum.sort_by(&claim_key/1)
        |> Enum.map(&proposal_input/1)
    }
  end

  defp proposal_input(proposal) do
    %{
      "key" => claim_key(proposal),
      "kind" => "proposal",
      "text" => proposal.text,
      "evidence" =>
        proposal.evidence
        |> Enum.sort_by(&evidence_sort_key/1)
        |> Enum.map(&evidence_input/1)
    }
  end

  defp evidence_input(evidence) do
    %{
      "citation_url" => evidence.citation_url,
      "excerpt" => evidence.excerpt,
      "location" => evidence.location,
      "retrieved_at" => DateTime.to_iso8601(evidence.retrieved_at),
      "source_sha256" => evidence.source_version && evidence.source_version.sha256,
      "source_origin_url" =>
        evidence.source_version && evidence.source_version.source_record.origin_url,
      "synthetic" => evidence.synthetic
    }
  end

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

  defp validate_claim(%{"evidence" => []} = claim, item_key) do
    [error(:missing_evidence, item_key, claim["key"])]
  end

  defp validate_claim(claim, item_key) do
    if Enum.any?(claim["evidence"], &official_evidence?/1) do
      []
    else
      claim["evidence"]
      |> Enum.flat_map(&evidence_failures(&1, item_key, claim["key"]))
      |> Enum.uniq()
    end
  end

  defp evidence_failures(evidence, item_key, claim_key) do
    []
    |> maybe_error(evidence["synthetic"], :synthetic_evidence, item_key, claim_key)
    |> maybe_error(
      not present?(evidence["excerpt"]),
      :missing_evidence_excerpt,
      item_key,
      claim_key
    )
    |> maybe_error(
      not present?(evidence["location"]),
      :missing_evidence_location,
      item_key,
      claim_key
    )
    |> maybe_error(
      not present?(evidence["source_sha256"]),
      :missing_evidence_checksum,
      item_key,
      claim_key
    )
    |> maybe_error(not present?(evidence["citation_url"]), :missing_citation, item_key, claim_key)
    |> maybe_error(
      present?(evidence["citation_url"]) and not valid_citation?(evidence),
      :unofficial_citation,
      item_key,
      claim_key
    )
  end

  defp maybe_error(failures, true, code, item_key, claim_key),
    do: failures ++ [error(code, item_key, claim_key)]

  defp maybe_error(failures, false, _code, _item_key, _claim_key), do: failures

  defp official_evidence?(evidence) do
    not evidence["synthetic"] and present?(evidence["excerpt"]) and
      present?(evidence["location"]) and present?(evidence["source_sha256"]) and
      valid_citation?(evidence)
  end

  defp valid_citation?(evidence) do
    citation = evidence["citation_url"]
    origin = evidence["source_origin_url"]

    with true <- is_binary(citation),
         true <- citation == origin,
         %URI{scheme: scheme, host: host} <- URI.parse(citation),
         true <- scheme in @fetchable_schemes do
      present?(host)
    else
      _other -> false
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
  defp item_key(item), do: item.authoritative_identifier || item.continuity_key
  defp item_sort_key(item), do: {item_key(item), item.item_number}
  defp claim_key(proposal), do: "proposal:#{proposal.source_version.sha256}"

  defp evidence_sort_key(evidence) do
    {
      evidence.source_version && evidence.source_version.sha256,
      evidence.citation_url,
      evidence.location,
      evidence.excerpt
    }
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp error(code, item_key \\ nil, claim_key \\ nil, locale \\ nil) do
    %{code: code, item_key: item_key, claim_key: claim_key, locale: locale}
  end
end
