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

  def validate(%{"items" => []}), do: {:error, {:publication_gate, [error(:missing_item)]}}

  def validate(%{"items" => items}) do
    failures =
      Enum.flat_map(items, fn item ->
        state_failures = validate_state(item)

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

  defp validate_state(%{"procedural_state" => "proposal", "outcome" => "unknown"}), do: []

  defp validate_state(
         %{"procedural_state" => "decision", "outcome" => outcome, "claims" => claims} = item
       )
       when outcome in ["approved", "rejected", "amended", "postponed", "withdrawn", "other"] do
    if Enum.any?(claims, &(&1["kind"] == "decision")),
      do: [],
      else: [
        error(:unsupported_publication_state, item["key"]),
        error(:missing_decision_claim, item["key"])
      ]
  end

  defp validate_state(item), do: [error(:unsupported_publication_state, item["key"])]

  defp item_input(item) do
    key = item_key(item)

    proposals =
      item
      |> current_proposals()
      |> Enum.sort_by(& &1.source_version.sha256)
      |> Enum.map(&proposal_input(&1, key))

    decisions = item |> current_decisions() |> Enum.map(&decision_input(&1, key))

    %{
      "key" => key,
      "item_number" => item.item_number,
      "procedural_state" => to_string(item.procedural_state),
      "outcome" => to_string(item.outcome),
      "source_wording" => item.source_wording,
      "claims" => proposals ++ decisions
    }
  end

  defp proposal_input(proposal, item_key) do
    %{
      "key" => "proposal:#{item_key}:#{proposal.source_version.sha256}",
      "kind" => "proposal",
      "text" => proposal.text,
      "evidence" =>
        proposal.evidence |> Enum.sort_by(&evidence_sort_key/1) |> Enum.map(&evidence_input/1)
    }
  end

  defp decision_input(decision, item_key) do
    %{
      "key" => "decision:#{item_key}:#{decision.source_version.sha256}",
      "kind" => "decision",
      "text" => decision.statement,
      "disposition" => to_string(decision.disposition),
      "vote" => vote_input(decision),
      "evidence" =>
        decision.evidence
        |> Enum.filter(&(&1.claim == :decision))
        |> Enum.sort_by(&evidence_sort_key/1)
        |> Enum.map(&evidence_input/1)
    }
  end

  defp vote_input(decision) do
    values = %{
      "for" => decision.votes_for,
      "against" => decision.votes_against,
      "abstentions" => decision.abstentions
    }

    evidence =
      decision.evidence
      |> Enum.filter(&(&1.claim == :vote))
      |> Enum.sort_by(&evidence_sort_key/1)
      |> Enum.map(&evidence_input/1)

    if Enum.all?(Map.values(values), &is_nil/1) and evidence == [],
      do: nil,
      else: Map.put(values, "evidence", evidence)
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
    case Enum.reject(item.proposals, & &1.synthetic) do
      [] ->
        case loaded_or_nil(Map.get(item, :published_proposal)) do
          nil -> []
          proposal -> [proposal]
        end

      proposals ->
        [
          Enum.max_by(
            proposals,
            &{Map.get(&1, :source_version_order) || "0:#{&1.source_version.id}",
             Map.get(&1, :id, "")}
          )
        ]
    end
  end

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value

  defp current_decisions(item) when not is_map_key(item, :decision), do: []
  defp current_decisions(%{decision: %Ash.NotLoaded{}}), do: []
  defp current_decisions(%{decision: nil}), do: []
  defp current_decisions(%{decision: %{synthetic: true}}), do: []
  defp current_decisions(%{decision: decision}), do: [decision]

  defp validate_claim(%{"evidence" => []} = claim, item_key) do
    [error(:missing_evidence, item_key, claim["key"])]
  end

  defp validate_claim(claim, item_key) do
    claim["evidence"]
    |> Enum.flat_map(&evidence_failures(&1, item_key, claim["key"]))
    |> Enum.uniq()
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

  defp evidence_sort_key(evidence),
    do:
      {evidence.source_version && evidence.source_version.sha256, evidence.citation_url,
       evidence.location, evidence.excerpt}

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
      |> Enum.sort_by(&elem(&1, 0))

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp error(code, item_key \\ nil, claim_key \\ nil, locale \\ nil),
    do: %{code: code, item_key: item_key, claim_key: claim_key, locale: locale}
end
