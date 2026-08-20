defmodule BrusselsWtf.Council.Dossiers do
  @moduledoc "Dossier matching, public correction intake, and audited editorial revisions."

  require Ash.Query

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.{Dossier, DossierLink, DossierMatchExclusion}
  alias BrusselsWtf.Review

  @high_confidence 0.85
  @medium_confidence 0.60

  def record_match!(attrs) do
    agenda_item_id = Map.fetch!(attrs, :agenda_item_id)
    candidate_dossier_id = Map.fetch!(attrs, :candidate_dossier_id)

    if excluded?(agenda_item_id, candidate_dossier_id) do
      {:excluded, candidate_dossier_id}
    else
      record_unexcluded_match!(attrs)
    end
  end

  def report_incorrect_link!(link_id, dossier_id, reason) when is_binary(reason) do
    link = load_link!(link_id)

    if link.status != :active or link.dossier_id != dossier_id do
      raise ArgumentError, "only an active dossier link can be reported"
    end

    meeting = link.agenda_item.council_meeting

    Review.open_review_case!(%{
      kind: :link_correction,
      commune_id: meeting.commune_id,
      affected_record_id: link.id,
      affected_record_type: "dossier_link",
      processing_generation: "reader-report:#{Ecto.UUID.generate()}",
      urgency: :normal,
      summary: "Reader reported an incorrect dossier link",
      normalized_content: %{
        "dossier_link_id" => link.id,
        "dossier_id" => link.dossier_id,
        "agenda_item_id" => link.agenda_item_id,
        "reason" => String.trim(reason)
      },
      related_evidence: %{
        "matcher_name" => link.matcher_name,
        "matcher_version" => link.matcher_version,
        "match_features" => link.match_features,
        "confidence" => link.confidence
      }
    })
  end

  def confirm_link!(link_id, review_case_id, note, actor) do
    transact!(fn ->
      validate_link_case!(review_case_id, link_id, actor)

      {link, link_notifications} =
        link_id
        |> Council.get_dossier_link!()
        |> Council.confirm_dossier_link!(return_notifications?: true)

      {_action, action_notifications} =
        audit!(actor, review_case_id, link.id, "dossier_link", :confirm_link, note, %{
          "agenda_item_id" => link.agenda_item_id,
          "dossier_id" => link.dossier_id
        })

      case_notifications = resolve_case!(review_case_id, :dossier_link_confirmed, actor)
      {link, link_notifications ++ action_notifications ++ case_notifications}
    end)
  end

  def remove_link!(link_id, review_case_id, note, actor) do
    transact!(fn ->
      validate_link_case!(review_case_id, link_id, actor)

      {link, link_notifications} =
        link_id
        |> Council.get_dossier_link!()
        |> Council.remove_dossier_link!(return_notifications?: true)

      {action, action_notifications} =
        audit!(actor, review_case_id, link.id, "dossier_link", :remove_link, note, %{
          "agenda_item_id" => link.agenda_item_id,
          "dossier_id" => link.dossier_id
        })

      {_exclusion, exclusion_notifications} =
        Council.record_dossier_match_exclusion!(
          %{
            agenda_item_id: link.agenda_item_id,
            dossier_id: link.dossier_id,
            dossier_action_id: action.id,
            matcher_name: link.matcher_name,
            matcher_version: link.matcher_version,
            match_features: link.match_features,
            reason: note
          },
          actor: actor,
          return_notifications?: true
        )

      case_notifications = resolve_case!(review_case_id, :dossier_link_removed, actor)

      {link,
       link_notifications ++
         action_notifications ++ exclusion_notifications ++ case_notifications}
    end)
  end

  def merge!(source_dossier_id, target_dossier_id, review_case_id, note, actor)
      when source_dossier_id != target_dossier_id do
    transact!(fn ->
      source = get_dossier_with_links!(source_dossier_id)
      target = Council.get_dossier_by_id!(target_dossier_id)
      ensure_active!(source)
      ensure_active!(target)
      validate_dossier_case!(review_case_id, source.id, target.id, actor)

      {moved_link_ids, link_notifications} =
        source.dossier_links
        |> Enum.filter(&(&1.status == :active))
        |> Enum.map_reduce([], fn link, notifications ->
          {link_id, current_notifications} = move_or_remove_duplicate!(link, target.id)
          {link_id, notifications ++ current_notifications}
        end)

      {_retired, retire_notifications} =
        Council.retire_dossier!(
          source,
          %{retired_into_id: target.id},
          return_notifications?: true
        )

      {_action, action_notifications} =
        audit!(actor, review_case_id, source.id, "dossier", :merge, note, %{
          "source_dossier_id" => source.id,
          "target_dossier_id" => target.id,
          "dossier_link_ids" => moved_link_ids
        })

      case_notifications = resolve_case!(review_case_id, :dossiers_merged, actor)

      {target,
       link_notifications ++ retire_notifications ++ action_notifications ++ case_notifications}
    end)
  end

  def split!(source_dossier_id, link_ids, new_dossier_attrs, review_case_id, note, actor)
      when is_list(link_ids) and link_ids != [] do
    transact!(fn ->
      source = get_dossier_with_links!(source_dossier_id)
      ensure_active!(source)
      validate_split_case!(review_case_id, source.id, link_ids, actor)
      selected = Enum.filter(source.dossier_links, &(&1.id in link_ids and &1.status == :active))

      if length(selected) != length(Enum.uniq(link_ids)) do
        raise ArgumentError, "every split link must be active and belong to the source dossier"
      end

      {dossier, dossier_notifications} =
        Council.create_dossier!(new_dossier_attrs, return_notifications?: true)

      link_notifications =
        Enum.flat_map(selected, fn link ->
          {_moved, notifications} =
            Council.move_dossier_link!(
              link,
              %{dossier_id: dossier.id},
              return_notifications?: true
            )

          notifications
        end)

      {_action, action_notifications} =
        audit!(actor, review_case_id, source.id, "dossier", :split, note, %{
          "source_dossier_id" => source.id,
          "new_dossier_id" => dossier.id,
          "dossier_link_ids" => link_ids
        })

      case_notifications = resolve_case!(review_case_id, :dossier_split, actor)

      {dossier,
       dossier_notifications ++ link_notifications ++ action_notifications ++ case_notifications}
    end)
  end

  def relink!(link_id, target_dossier_id, review_case_id, note, actor) do
    transact!(fn ->
      link = Council.get_dossier_link!(link_id)
      validate_link_case!(review_case_id, link_id, actor)

      target = Council.get_dossier_by_id!(target_dossier_id)
      ensure_active!(target)
      previous_dossier_id = link.dossier_id

      if previous_dossier_id == target_dossier_id do
        raise ArgumentError, "target dossier must differ from the current dossier"
      end

      {moved, link_notifications} = relink_without_duplicate!(link, target_dossier_id)

      {_action, action_notifications} =
        audit!(actor, review_case_id, moved.id, "dossier_link", :relink, note, %{
          "agenda_item_id" => moved.agenda_item_id,
          "previous_dossier_id" => previous_dossier_id,
          "target_dossier_id" => target_dossier_id
        })

      case_notifications = resolve_case!(review_case_id, :dossier_relinked, actor)
      {moved, link_notifications ++ action_notifications ++ case_notifications}
    end)
  end

  defp record_unexcluded_match!(%{match_method: :authoritative_identifier} = attrs),
    do: {:linked, upsert_matched_link!(attrs, :confirmed)}

  defp record_unexcluded_match!(%{confidence: confidence} = attrs)
       when confidence >= @high_confidence,
       do: {:linked, upsert_matched_link!(attrs, :confirmed)}

  defp record_unexcluded_match!(%{confidence: confidence} = attrs)
       when confidence >= @medium_confidence do
    dossier_attrs = Map.fetch!(attrs, :separate_dossier)

    transact!(fn ->
      {dossier, dossier_notifications} =
        Council.create_dossier!(dossier_attrs, return_notifications?: true)

      {link, link_notifications} =
        attrs
        |> Map.put(:candidate_dossier_id, dossier.id)
        |> upsert_matched_link!(:unreviewed, return_notifications?: true)

      {review_case, case_notifications} =
        Review.open_review_case!(
          %{
            kind: :link_correction,
            affected_record_id: dossier.id,
            affected_record_type: "dossier_merge_suggestion",
            processing_generation: Map.fetch!(attrs, :processing_generation),
            urgency: :normal,
            summary: "Possible dossier merge requires review",
            normalized_content: %{
              "dossier_link_id" => link.id,
              "source_dossier_id" => dossier.id,
              "target_dossier_id" => Map.fetch!(attrs, :candidate_dossier_id),
              "agenda_item_id" => Map.fetch!(attrs, :agenda_item_id)
            },
            related_evidence: provenance(attrs)
          },
          return_notifications?: true
        )

      {{:merge_suggested, dossier, link, review_case},
       dossier_notifications ++ link_notifications ++ case_notifications}
    end)
  end

  defp record_unexcluded_match!(attrs), do: {:private_signal, provenance(attrs)}

  defp upsert_matched_link!(attrs, disposition, options \\ []) do
    Council.upsert_dossier_link!(
      %{
        agenda_item_id: Map.fetch!(attrs, :agenda_item_id),
        dossier_id: Map.fetch!(attrs, :candidate_dossier_id),
        match_method: Map.fetch!(attrs, :match_method),
        confidence: Map.fetch!(attrs, :confidence),
        matcher_name: Map.fetch!(attrs, :matcher_name),
        matcher_version: Map.fetch!(attrs, :matcher_version),
        match_features: Map.get(attrs, :match_features, %{}),
        processing_generation: Map.fetch!(attrs, :processing_generation),
        status: :active,
        disposition: disposition
      },
      options
    )
  end

  defp provenance(attrs) do
    %{
      "match_method" => Map.fetch!(attrs, :match_method),
      "confidence" => Map.fetch!(attrs, :confidence),
      "matcher_name" => Map.fetch!(attrs, :matcher_name),
      "matcher_version" => Map.fetch!(attrs, :matcher_version),
      "match_features" => Map.get(attrs, :match_features, %{}),
      "processing_generation" => Map.fetch!(attrs, :processing_generation)
    }
  end

  defp excluded?(agenda_item_id, dossier_id) do
    DossierMatchExclusion
    |> Ash.Query.filter(agenda_item_id == ^agenda_item_id and dossier_id == ^dossier_id)
    |> Ash.exists?(authorize?: false, domain: Council)
  end

  defp load_link!(link_id) do
    DossierLink
    |> Ash.Query.filter(id == ^link_id)
    |> Ash.Query.load(agenda_item: [:council_meeting])
    |> Ash.read_one!(authorize?: false, domain: Council)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: DossierLink, primary_key: %{id: link_id}
      link -> link
    end
  end

  defp get_dossier_with_links!(id) do
    Dossier
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load(:dossier_links)
    |> Ash.read_one!(authorize?: false, domain: Council)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: Dossier, primary_key: %{id: id}
      dossier -> dossier
    end
  end

  defp move_or_remove_duplicate!(link, target_dossier_id) do
    duplicate =
      DossierLink
      |> Ash.Query.filter(
        agenda_item_id == ^link.agenda_item_id and dossier_id == ^target_dossier_id
      )
      |> Ash.read_one!(authorize?: false, domain: Council)

    if duplicate do
      {_duplicate, duplicate_notifications} = confirm_if_removed!(duplicate)

      {_removed, remove_notifications} =
        Council.remove_dossier_link!(link, return_notifications?: true)

      {link.id, duplicate_notifications ++ remove_notifications}
    else
      {_moved, notifications} =
        Council.move_dossier_link!(
          link,
          %{dossier_id: target_dossier_id},
          return_notifications?: true
        )

      {link.id, notifications}
    end
  end

  defp relink_without_duplicate!(link, target_dossier_id) do
    duplicate =
      DossierLink
      |> Ash.Query.filter(
        agenda_item_id == ^link.agenda_item_id and dossier_id == ^target_dossier_id and
          id != ^link.id
      )
      |> Ash.read_one!(authorize?: false, domain: Council)

    if duplicate do
      {moved, duplicate_notifications} = confirm_if_removed!(duplicate)

      {_removed, remove_notifications} =
        Council.remove_dossier_link!(link, return_notifications?: true)

      {moved, duplicate_notifications ++ remove_notifications}
    else
      Council.move_dossier_link!(
        link,
        %{dossier_id: target_dossier_id},
        return_notifications?: true
      )
    end
  end

  defp confirm_if_removed!(%{status: :removed} = link) do
    Council.confirm_dossier_link!(link, return_notifications?: true)
  end

  defp confirm_if_removed!(link), do: {link, []}

  defp audit!(actor, review_case_id, subject_id, subject_type, action, note, details) do
    Council.record_dossier_action!(
      %{
        review_case_id: review_case_id,
        subject_id: subject_id,
        subject_type: subject_type,
        action: action,
        note: note,
        details: details
      },
      actor: actor,
      return_notifications?: true
    )
  end

  defp resolve_case!(nil, _disposition, _actor), do: []

  defp resolve_case!(review_case_id, disposition, actor) do
    review_case = Review.get_review_case!(review_case_id, actor: actor)

    {_review_case, notifications} =
      Review.resolve_dossier_review_case!(
        review_case,
        %{disposition: disposition},
        actor: actor,
        return_notifications?: true
      )

    notifications
  end

  defp validate_link_case!(nil, _link_id, _actor), do: :ok

  defp validate_link_case!(review_case_id, link_id, actor) do
    review_case = open_link_case!(review_case_id, actor)

    if review_case.normalized_content["dossier_link_id"] != link_id do
      raise ArgumentError, "review case does not concern this dossier link"
    end
  end

  defp validate_dossier_case!(nil, _source_id, _target_id, _actor), do: :ok

  defp validate_dossier_case!(review_case_id, source_id, target_id, actor) do
    review_case = open_link_case!(review_case_id, actor)
    content = review_case.normalized_content
    expected_source = content["source_dossier_id"] || content["dossier_id"]
    expected_target = content["target_dossier_id"]

    if expected_source != source_id or (expected_target && expected_target != target_id) do
      raise ArgumentError, "review case does not concern this dossier merge"
    end
  end

  defp validate_split_case!(nil, _source_id, _link_ids, _actor), do: :ok

  defp validate_split_case!(review_case_id, source_id, link_ids, actor) do
    review_case = open_link_case!(review_case_id, actor)
    content = review_case.normalized_content
    expected_source = content["source_dossier_id"] || content["dossier_id"]
    expected_link = content["dossier_link_id"]

    if expected_source != source_id or (expected_link && expected_link not in link_ids) do
      raise ArgumentError, "review case does not concern this dossier split"
    end
  end

  defp open_link_case!(review_case_id, actor) do
    case Review.get_review_case!(review_case_id, actor: actor) do
      %{kind: :link_correction, status: :open} = review_case -> review_case
      _review_case -> raise ArgumentError, "dossier action requires an open link-correction case"
    end
  end

  defp ensure_active!(%{status: :active}), do: :ok
  defp ensure_active!(_dossier), do: raise(ArgumentError, "dossier must be active")

  defp transact!(fun) do
    case BrusselsWtf.Repo.transaction(fun) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        result

      {:error, reason} ->
        raise "dossier transaction failed: #{inspect(reason)}"
    end
  end
end
