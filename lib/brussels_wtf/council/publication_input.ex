defmodule BrusselsWtf.Council.PublicationInput do
  @moduledoc "Builds and hashes the deterministic normalized input allowed into coverage generation."

  @fetchable_schemes ["http", "https"]

  def build(meeting) do
    %{
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
        case item["claims"] do
          [] -> [error(:missing_claim, item["key"])]
          claims -> Enum.flat_map(claims, &validate_claim(&1, item["key"]))
        end
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

  defp valid_citation?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in @fetchable_schemes -> present?(host)
      _ -> false
    end
  end

  defp valid_citation?(_url), do: false
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
