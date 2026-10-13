defmodule BrusselsWtf.Council.PublicationInputTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Council.PublicationInput

  test "relationship order cannot change the deterministic publication hash" do
    first = item("2", "bbb", ~U[2026-08-10 11:00:00Z])
    second = item("1", "aaa", ~U[2026-08-10 10:00:00Z])

    meeting = %{
      commune: %{slug: "ixelles"},
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

  test "decision state is rejected until decision evidence joins the publication input" do
    input = %{
      "items" => [
        %{
          "key" => "4",
          "procedural_state" => "decision",
          "outcome" => "approved",
          "claims" => []
        }
      ]
    }

    assert {:error, {:publication_gate, failures}} = PublicationInput.validate(input)
    assert Enum.any?(failures, &(&1.code == :unsupported_publication_state))
  end

  test "evidence failures identify the missing citation requirement" do
    input = %{
      "items" => [
        %{
          "key" => "4",
          "procedural_state" => "proposal",
          "outcome" => "unknown",
          "claims" => [
            %{
              "key" => "claim",
              "evidence" => [
                %{
                  "synthetic" => false,
                  "excerpt" => "official excerpt",
                  "location" => "page 1",
                  "source_sha256" => "abc",
                  "citation_url" => "",
                  "source_origin_url" => "https://example.test/source.pdf"
                }
              ]
            }
          ]
        }
      ]
    }

    assert {:error, {:publication_gate, [%{code: :missing_citation}]}} =
             PublicationInput.validate(input)
  end

  test "a citation must match the official source origin" do
    claim = %{
      "key" => "claim",
      "evidence" => [
        %{
          "synthetic" => false,
          "excerpt" => "official excerpt",
          "location" => "page 1",
          "source_sha256" => "abc",
          "citation_url" => "https://unrelated.example/claim",
          "source_origin_url" => "https://example.test/source.pdf"
        }
      ]
    }

    input = %{
      "items" => [
        %{
          "key" => "4",
          "procedural_state" => "proposal",
          "outcome" => "unknown",
          "claims" => [claim]
        }
      ]
    }

    assert {:error, {:publication_gate, [%{code: :unofficial_citation}]}} =
             PublicationInput.validate(input)
  end

  test "every rendered evidence citation must be official" do
    valid = %{
      "synthetic" => false,
      "excerpt" => "official excerpt",
      "location" => "page 1",
      "source_sha256" => "abc",
      "citation_url" => "https://example.test/source.pdf",
      "source_origin_url" => "https://example.test/source.pdf"
    }

    invalid = %{valid | "citation_url" => "https://unrelated.example/claim"}

    input = %{
      "items" => [
        %{
          "key" => "4",
          "procedural_state" => "proposal",
          "outcome" => "unknown",
          "claims" => [%{"key" => "claim", "evidence" => [valid, invalid]}]
        }
      ]
    }

    assert {:error, {:publication_gate, [%{code: :unofficial_citation}]}} =
             PublicationInput.validate(input)
  end

  test "an agenda item without current claims is excluded from the publishable input" do
    publishable = publishable_proposal_item("1", "aaa")
    information = unclaimed_item("2")

    meeting = %{
      commune: %{slug: "ixelles"},
      municipal_identifier: "268",
      scheduled_on: ~D[2026-07-02],
      agenda_items: [information, publishable]
    }

    input = PublicationInput.build(meeting)

    assert Enum.map(input["items"], & &1["key"]) == ["1"]
    assert PublicationInput.validate(input) == :ok
    refute Map.has_key?(input, "publication_scope")
  end

  test "an item that asserts a decision outcome without a decision record stays publishable" do
    publishable = publishable_proposal_item("1", "aaa")

    withdrawn_decision = %{
      unclaimed_item("4")
      | procedural_state: :decision,
        outcome: :withdrawn,
        proposals: [],
        decision: nil
    }

    meeting = %{
      commune: %{slug: "ixelles"},
      municipal_identifier: "268",
      scheduled_on: ~D[2026-07-02],
      agenda_items: [publishable, withdrawn_decision]
    }

    input = PublicationInput.build(meeting)

    assert Enum.map(input["items"], & &1["key"]) == ["1", "4"]

    assert {:error, {:publication_gate, failures}} = PublicationInput.validate(input)

    assert Enum.any?(
             failures,
             &(&1.code == :unsupported_publication_state and &1.item_key == "4")
           )

    assert Enum.any?(failures, &(&1.code == :missing_decision_claim and &1.item_key == "4"))
    assert Enum.any?(failures, &(&1.code == :missing_claim and &1.item_key == "4"))
  end

  test "a terminal outcome without a decision record also stays publishable" do
    approved_without_record = %{
      unclaimed_item("5")
      | procedural_state: :unknown,
        outcome: :approved
    }

    meeting = %{
      commune: %{slug: "ixelles"},
      municipal_identifier: "268",
      scheduled_on: ~D[2026-07-02],
      agenda_items: [publishable_proposal_item("1", "aaa"), approved_without_record]
    }

    input = PublicationInput.build(meeting)

    assert Enum.map(input["items"], & &1["key"]) == ["1", "5"]

    assert {:error, {:publication_gate, failures}} = PublicationInput.validate(input)

    assert Enum.any?(
             failures,
             &(&1.code == :unsupported_publication_state and &1.item_key == "5")
           )

    assert Enum.any?(failures, &(&1.code == :missing_claim and &1.item_key == "5"))
  end

  test "a meeting whose publishable set is empty still fails with missing_item" do
    meeting = %{
      commune: %{slug: "ixelles"},
      municipal_identifier: "268",
      scheduled_on: ~D[2026-07-02],
      agenda_items: [unclaimed_item("2"), unclaimed_item("3")]
    }

    input = PublicationInput.build(meeting)

    assert input["items"] == []

    assert {:error, {:publication_gate, [%{code: :missing_item}]}} =
             PublicationInput.validate(input)
  end

  test "a decision item with a terminal outcome but no decision claim still fails" do
    input = %{
      "items" => [
        %{
          "key" => "4",
          "procedural_state" => "decision",
          "outcome" => "approved",
          "claims" => [
            %{
              "key" => "proposal:4:abc",
              "kind" => "proposal",
              "text" => "proposal text",
              "evidence" => [
                %{
                  "synthetic" => false,
                  "excerpt" => "official excerpt",
                  "location" => "page 1",
                  "source_sha256" => "abc",
                  "citation_url" => "https://example.test/source.pdf",
                  "source_origin_url" => "https://example.test/source.pdf"
                }
              ]
            }
          ]
        }
      ]
    }

    assert {:error, {:publication_gate, failures}} = PublicationInput.validate(input)

    assert Enum.any?(failures, &(&1.code == :unsupported_publication_state))
    assert Enum.any?(failures, &(&1.code == :missing_decision_claim))
  end

  test "a proposal claim without evidence still fails" do
    input = %{
      "items" => [
        %{
          "key" => "4",
          "procedural_state" => "proposal",
          "outcome" => "unknown",
          "claims" => [
            %{"key" => "proposal:4:abc", "kind" => "proposal", "text" => "text", "evidence" => []}
          ]
        }
      ]
    }

    assert {:error, {:publication_gate, [%{code: :missing_evidence}]}} =
             PublicationInput.validate(input)
  end

  # Regression: the sealed recorded corpus carries claims on every item, so its
  # projection must not change. Manifest.recorded_bundle/2 compares the built
  # input against the sealed contract, and the pinned hashes capture the exact
  # bytes (including captured_at-based retrieval times) produced before and
  # after the publishable-set change.
  test "recorded corpus meetings keep byte-identical publication inputs" do
    for key <- ["ixelles-268", "ixelles-267"] do
      input = key |> recorded_meeting() |> PublicationInput.build()

      assert {:ok, _bundle} = Manifest.recorded_bundle(input, "fr")
      assert PublicationInput.hash(input) == expected_recorded_hash(key)
    end
  end

  defp publishable_proposal_item(key, sha) do
    retrieved_at = ~U[2026-08-10 10:00:00Z]

    source_version = %{
      sha256: sha,
      id: "version-#{key}",
      source_record: %{origin_url: "https://example.test/#{key}.pdf"}
    }

    %{
      authoritative_identifier: key,
      continuity_key: key,
      item_number: key,
      procedural_state: :proposal,
      outcome: :unknown,
      source_wording: "wording #{key}",
      proposals: [
        %{
          text: "proposal #{key}",
          synthetic: false,
          source_version: source_version,
          evidence: [
            %{
              citation_url: "https://example.test/#{key}.pdf",
              excerpt: "official excerpt",
              location: "page 1",
              retrieved_at: retrieved_at,
              source_version: source_version,
              synthetic: false
            }
          ]
        }
      ]
    }
  end

  defp unclaimed_item(key) do
    %{
      authoritative_identifier: key,
      continuity_key: key,
      item_number: key,
      procedural_state: :unknown,
      outcome: :unknown,
      source_wording: "Information au Conseil communal",
      proposals: [],
      decision: nil
    }
  end

  @recorded_hashes %{
    "ixelles-268" => "sha256:23dbde86c479a1d0f6b9e61f80fd061ced36fe54b1c48a7b6ccc3cc414469e78",
    # Re-pinned for issue 127: each decision now carries its cited vote tally.
    "ixelles-267" => "sha256:41e3319d45d4a03beae74fddc9f515e859ae3924feeb3c60b92ac3655b762a01"
  }

  defp expected_recorded_hash(key), do: Map.fetch!(@recorded_hashes, key)

  defp recorded_meeting(key) do
    contract = Manifest.meeting!(key)
    [source] = contract["sources"]
    {:ok, captured_at, _offset} = DateTime.from_iso8601(source["captured_at"])

    version = %{
      sha256: source["sha256"],
      id: "version-#{key}",
      source_record: %{origin_url: source["url"]}
    }

    %{
      commune: %{slug: contract["commune"]},
      municipal_identifier: contract["municipal_identifier"],
      scheduled_on: Date.from_iso8601!(contract["scheduled_on"]),
      agenda_items: Enum.map(contract["items"], &recorded_agenda_item(&1, version, captured_at))
    }
  end

  defp recorded_agenda_item(contract, version, captured_at) do
    base = %{
      authoritative_identifier: contract["key"],
      continuity_key: contract["key"],
      item_number: contract["item_number"],
      source_wording: contract["source_wording"],
      proposals: []
    }

    case contract["state"] do
      "proposal" ->
        proposal = contract["proposal"]

        Map.merge(base, %{
          procedural_state: :proposal,
          outcome: :unknown,
          proposals: [
            %{
              text: proposal["text"],
              synthetic: false,
              source_version: version,
              evidence: [recorded_evidence(proposal, version, captured_at, :proposal)]
            }
          ]
        })

      "decision" ->
        decision = contract["decision"]
        disposition = String.to_existing_atom(decision["disposition"])
        vote = decision["vote"]

        tally =
          case vote && BrusselsWtf.Council.VoteTally.parse(vote["excerpt"]) do
            {:ok, counts} -> counts
            _none -> nil
          end

        Map.merge(base, %{
          procedural_state: :decision,
          outcome: disposition,
          decision: %{
            statement: decision["statement"],
            disposition: disposition,
            synthetic: false,
            source_version: version,
            votes_for: tally && tally.for,
            votes_against: tally && tally.against,
            abstentions: tally && tally.abstentions,
            evidence:
              [recorded_evidence(decision, version, captured_at, :decision)] ++
                if(vote, do: [recorded_evidence(vote, version, captured_at, :vote)], else: [])
          }
        })
    end
  end

  defp recorded_evidence(claim, version, captured_at, kind) do
    %{
      claim: kind,
      citation_url: version.source_record.origin_url,
      excerpt: claim["excerpt"],
      location: claim["location"],
      retrieved_at: captured_at,
      source_version: version,
      synthetic: false
    }
  end

  defp item(key, sha, retrieved_at) do
    source_version = %{
      sha256: sha,
      source_record_id: "record-#{key}",
      source_record: %{origin_url: "https://example.test/#{key}/a"},
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
