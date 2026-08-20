defmodule BrusselsWtf.Council.DossierWorkflowTest do
  use BrusselsWtf.DataCase, async: false

  require Ash.Query

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.{DossierAction, DossierMatchExclusion, Dossiers}
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    %{actor: %Actor{id: "rico", role: :reviewer}, item: agenda_item!("demo-ixelles")}
  end

  test "authoritative and high-confidence matches link directly with provenance", %{item: item} do
    authoritative = Council.upsert_dossier!(%{slug: "authority", title: "Authoritative dossier"})

    assert {:linked, authority_link} =
             Dossiers.record_match!(
               match_attrs(item, authoritative,
                 match_method: :authoritative_identifier,
                 confidence: 0.20,
                 match_features: %{"municipal_dossier_id" => "IX-42"}
               )
             )

    assert authority_link.disposition == :confirmed
    assert authority_link.matcher_name == "dossier-contract"
    assert authority_link.match_features == %{"municipal_dossier_id" => "IX-42"}

    high = Council.upsert_dossier!(%{slug: "high", title: "High-confidence dossier"})

    assert {:linked, high_link} =
             Dossiers.record_match!(match_attrs(item, high, confidence: 0.91))

    assert high_link.match_method == :automated
    assert high_link.confidence == 0.91
  end

  test "medium confidence stays separate and opens a private merge suggestion", %{item: item} do
    candidate = Council.upsert_dossier!(%{slug: "candidate", title: "Existing dossier"})

    assert {:merge_suggested, separate, link, review_case} =
             Dossiers.record_match!(
               match_attrs(item, candidate,
                 confidence: 0.70,
                 separate_dossier: %{slug: "separate", title: "Separate matter"}
               )
             )

    assert separate.id != candidate.id
    assert link.dossier_id == separate.id
    assert link.disposition == :unreviewed
    assert review_case.kind == :link_correction
    assert review_case.status == :open
    assert review_case.normalized_content["source_dossier_id"] == separate.id
    assert review_case.normalized_content["target_dossier_id"] == candidate.id
  end

  test "low confidence remains private and a rejected association stays excluded", %{
    actor: actor,
    item: item
  } do
    candidate = Council.upsert_dossier!(%{slug: "rejected", title: "Rejected dossier"})

    assert {:private_signal, provenance} =
             Dossiers.record_match!(match_attrs(item, candidate, confidence: 0.40))

    assert provenance["confidence"] == 0.40
    assert Council.get_dossier!("rejected").dossier_links == []

    assert {:linked, link} =
             Dossiers.record_match!(match_attrs(item, candidate, confidence: 0.95))

    review_case = correction_case!(link)
    removed = Dossiers.remove_link!(link.id, review_case.id, "Different municipal matter", actor)

    assert removed.status == :removed
    assert Review.get_review_case!(review_case.id, actor: actor).status == :resolved
    assert {:excluded, candidate_id} = Dossiers.record_match!(match_attrs(item, candidate))
    assert candidate_id == candidate.id

    assert [exclusion] =
             Ash.read!(DossierMatchExclusion, actor: actor, domain: Council)

    assert exclusion.agenda_item_id == item.id
    assert exclusion.dossier_id == candidate.id

    assert [%{action: :remove_link, actor_id: "rico"}] =
             Ash.read!(DossierAction, actor: actor, domain: Council)
  end

  test "merge, split, and relink preserve audited history and retired redirects", %{
    actor: actor,
    item: item
  } do
    source = Council.upsert_dossier!(%{slug: "source-matter", title: "Source matter"})
    target = Council.upsert_dossier!(%{slug: "target-matter", title: "Target matter"})
    other = Council.upsert_dossier!(%{slug: "other-matter", title: "Other matter"})
    link = Council.upsert_dossier_link!(%{agenda_item_id: item.id, dossier_id: source.id})

    merge_case = correction_case!(link, "merge")

    assert %{id: target_id} =
             Dossiers.merge!(source.id, target.id, merge_case.id, "Same matter", actor)

    assert target_id == target.id

    retired = Council.get_dossier!("source-matter")
    assert retired.status == :retired
    assert retired.retired_into.id == target.id

    target_link =
      target.id
      |> dossier_links!()
      |> Enum.find(&(&1.agenda_item_id == item.id and &1.status == :active))

    split_case = correction_case!(target_link, "split")

    split =
      Dossiers.split!(
        target.id,
        [target_link.id],
        %{slug: "split-matter", title: "Split matter"},
        split_case.id,
        "Items diverged",
        actor
      )

    assert Enum.any?(
             dossier_links!(split.id),
             &(&1.id == target_link.id and &1.status == :active)
           )

    relink_case = correction_case!(target_link, "relink")

    moved =
      Dossiers.relink!(
        target_link.id,
        other.id,
        relink_case.id,
        "Authoritative correction",
        actor
      )

    assert moved.dossier_id == other.id

    assert [:merge, :split, :relink] ==
             DossierAction
             |> Ash.Query.sort(inserted_at: :asc)
             |> Ash.read!(actor: actor, domain: Council)
             |> Enum.map(& &1.action)
  end

  test "relink rejects the current dossier without changing the link", %{actor: actor, item: item} do
    dossier = Council.upsert_dossier!(%{slug: "same-target", title: "Same target"})
    link = Council.upsert_dossier_link!(%{agenda_item_id: item.id, dossier_id: dossier.id})
    review_case = correction_case!(link, "same-target")

    assert_raise ArgumentError, "target dossier must differ from the current dossier", fn ->
      Dossiers.relink!(
        link.id,
        dossier.id,
        review_case.id,
        "No destination change",
        actor
      )
    end

    assert Council.get_dossier_link!(link.id).status == :active
    assert Review.get_review_case!(review_case.id, actor: actor).status == :open
  end

  defp match_attrs(item, dossier, overrides \\ []) do
    %{
      agenda_item_id: item.id,
      candidate_dossier_id: dossier.id,
      match_method: Keyword.get(overrides, :match_method, :automated),
      confidence: Keyword.get(overrides, :confidence, 0.95),
      matcher_name: "dossier-contract",
      matcher_version: "2026-08-20",
      match_features: Keyword.get(overrides, :match_features, %{"shared_identifier" => true}),
      processing_generation: "dossier-contract:#{Ecto.UUID.generate()}"
    }
    |> maybe_put(:separate_dossier, overrides[:separate_dossier])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp correction_case!(link, suffix \\ "remove") do
    Review.open_review_case!(%{
      kind: :link_correction,
      affected_record_id: link.id,
      affected_record_type: "dossier_link",
      processing_generation: "#{suffix}:#{Ecto.UUID.generate()}",
      summary: "Review dossier association",
      normalized_content: %{
        "dossier_link_id" => link.id,
        "dossier_id" => link.dossier_id,
        "agenda_item_id" => link.agenda_item_id
      }
    })
  end

  defp agenda_item!(municipal_identifier) do
    Council.list_published_meeting_pages!()
    |> Enum.find(&(&1.council_meeting.municipal_identifier == municipal_identifier))
    |> Map.fetch!(:council_meeting)
    |> Map.fetch!(:agenda_items)
    |> List.first()
  end

  defp dossier_links!(dossier_id) do
    dossier_id
    |> Council.get_dossier_by_id!()
    |> Ash.load!(:dossier_links)
    |> Map.fetch!(:dossier_links)
  end
end
