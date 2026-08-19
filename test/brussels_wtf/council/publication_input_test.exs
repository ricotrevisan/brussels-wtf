defmodule BrusselsWtf.Council.PublicationInputTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Council.PublicationInput

  test "relationship order cannot change the deterministic publication hash" do
    first = item("2", "bbb", ~U[2026-08-10 11:00:00Z])
    second = item("1", "aaa", ~U[2026-08-10 10:00:00Z])

    meeting = %{
      municipal_identifier: "268",
      scheduled_on: ~D[2026-07-02],
      agenda_items: [first, second]
    }

    reordered = %{
      meeting
      | agenda_items: [
          reverse_relationships(second),
          reverse_relationships(first)
        ]
    }

    assert PublicationInput.build(meeting) == PublicationInput.build(reordered)

    assert PublicationInput.hash(PublicationInput.build(meeting)) ==
             PublicationInput.hash(PublicationInput.build(reordered))
  end

  defp item(key, sha, retrieved_at) do
    source_version = %{
      sha256: sha,
      source_record_id: "record-#{key}",
      first_retrieved_at: retrieved_at,
      inserted_at: retrieved_at,
      id: "version-#{key}"
    }

    evidence = fn suffix ->
      %{
        citation_url: "https://example.test/#{key}/#{suffix}",
        excerpt: "excerpt #{suffix}",
        location: "page #{suffix}",
        retrieved_at: retrieved_at,
        source_version: source_version,
        synthetic: false
      }
    end

    proposal = fn suffix ->
      %{
        text: "proposal #{suffix}",
        synthetic: false,
        source_version: %{source_version | sha256: sha <> suffix, id: "version-#{key}-#{suffix}"},
        evidence: [evidence.("b"), evidence.("a")]
      }
    end

    %{
      authoritative_identifier: key,
      continuity_key: key,
      item_number: key,
      procedural_state: :proposal,
      outcome: :unknown,
      source_wording: "wording #{key}",
      proposals: [proposal.("b"), proposal.("a")]
    }
  end

  defp reverse_relationships(item) do
    %{
      item
      | proposals:
          item.proposals
          |> Enum.reverse()
          |> Enum.map(&%{&1 | evidence: Enum.reverse(&1.evidence)})
    }
  end
end
