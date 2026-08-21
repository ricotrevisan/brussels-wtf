defmodule BrusselsWtf.Council do
  @moduledoc """
  Normalized meetings, agenda items, and publishable meeting pages.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  resources do
    resource BrusselsWtf.Council.Meeting do
      define :get_meeting, action: :read, get_by: [:id]
      define :upsert_meeting, action: :upsert

      define :get_ingested_meeting,
        action: :ingested_by_identity,
        args: [:commune_slug, :municipal_identifier]
    end

    resource BrusselsWtf.Council.Agenda do
      define :record_agenda, action: :record
    end

    resource BrusselsWtf.Council.AgendaItem do
      define :get_agenda_item, action: :read, get_by: [:id]
      define :upsert_agenda_item, action: :upsert
      define :upsert_rendered_agenda_item, action: :upsert_rendered
      define :mark_agenda_item_proposed, action: :mark_proposed
      define :mark_agenda_item_decided, action: :mark_decided
      define :publish_agenda_item_state, action: :publish_current_state
    end

    resource BrusselsWtf.Council.AgendaItemVersion do
      define :record_agenda_item_version, action: :record
    end

    resource BrusselsWtf.Council.Proposal do
      define :record_proposal, action: :record
      define :upsert_proposal, action: :upsert_rendered
    end

    resource BrusselsWtf.Council.Evidence do
      define :record_evidence, action: :record
      define :record_decision_evidence, action: :record_decision
      define :upsert_evidence, action: :upsert_reference
    end

    resource BrusselsWtf.Council.Decision do
      define :get_decision, action: :read, get_by: [:id]
      define :record_decision, action: :record
      define :upsert_decision, action: :upsert_rendered
    end

    resource BrusselsWtf.Council.Dossier do
      define :get_dossier_by_id, action: :read, get_by: [:id]
      define :create_dossier, action: :create
      define :upsert_dossier, action: :upsert
      define :get_dossier, action: :by_slug, args: [:slug]
      define :retire_dossier, action: :retire
    end

    resource BrusselsWtf.Council.DossierLink do
      define :get_dossier_link, action: :read, get_by: [:id]
      define :upsert_dossier_link, action: :upsert
      define :confirm_dossier_link, action: :confirm
      define :remove_dossier_link, action: :remove
      define :move_dossier_link, action: :move
    end

    resource BrusselsWtf.Council.DossierAction do
      define :record_dossier_action, action: :record
    end

    resource BrusselsWtf.Council.DossierMatchExclusion do
      define :record_dossier_match_exclusion, action: :record
    end

    resource BrusselsWtf.Council.CoverageVariant do
      define :upsert_coverage_variant, action: :upsert
    end

    resource BrusselsWtf.Council.CoverageBatch do
      define :get_coverage_batch, action: :read, get_by: [:id]
      define :list_coverage_batches, action: :read
    end

    resource BrusselsWtf.Council.CoverageRun do
      define :record_coverage_run, action: :record
      define :list_coverage_runs, action: :for_page, args: [:meeting_page_id]
    end

    resource BrusselsWtf.Council.CoverageBudget do
      define :get_coverage_budget_by_period, action: :by_period, args: [:period_start]
    end

    resource BrusselsWtf.Council.CoverageReservation do
      define :get_coverage_reservation_by_call_key, action: :by_call_key, args: [:call_key]
    end

    resource BrusselsWtf.Council.PublicationRevision do
      define :record_publication_revision, action: :record
      define :list_publication_revisions, action: :for_page, args: [:meeting_page_id]
    end

    resource BrusselsWtf.Council.PublicationEvent do
      define :record_publication_event, action: :record
      define :list_publication_events, action: :for_page, args: [:meeting_page_id]
    end

    resource BrusselsWtf.Council.MeetingPage do
      define :generate_meeting_coverage,
        action: :generate_coverage,
        args: [:meeting_id, :attempt, :max_attempts]

      define :generate_backfill_meeting_coverage,
        action: :generate_coverage,
        args: [:meeting_id, :attempt, :max_attempts, :generation_kind, :coverage_batch_id]

      define :evaluate_publication_gate,
        action: :evaluate_publication_gate,
        args: [:meeting_page_id, :expected_input_hash]

      define :get_meeting_page, action: :read, get_by: [:id]
      define :upsert_meeting_page, action: :upsert
      define :stage_meeting_page_revision, action: :stage_revision
      define :withdraw_meeting_page, action: :withdraw
      define :record_publication_gate_failure, action: :record_gate_failure
      define :publish_meeting_page, action: :publish
      define :list_published_meeting_pages, action: :published

      define :get_published_meeting_page,
        action: :public_by_identity,
        args: [:commune_slug, :municipal_identifier]
    end

    resource BrusselsWtf.Council.LocaleVariant do
      define :upsert_locale_variant, action: :upsert
      define :list_locale_variants, action: :for_page, args: [:meeting_page_id]
    end
  end

  @doc false
  def coverage_batch_allows?(batch_id, meeting_id)
      when is_binary(batch_id) and is_binary(meeting_id) do
    case get_coverage_batch(batch_id) do
      {:ok, %{status: :queued, meeting_ids: meeting_ids}} -> meeting_id in meeting_ids
      _other -> false
    end
  end

  def coverage_batch_allows?(_batch_id, _meeting_id), do: false

  @doc "Persists and queues an authenticated bounded coverage batch."
  def request_coverage_batch!(meeting_ids, opts) when is_list(meeting_ids) and is_list(opts) do
    actor = Keyword.fetch!(opts, :actor)
    authorize_coverage_batch!(actor)
    config = Application.fetch_env!(:brussels_wtf, :coverage_generation)
    validate_coverage_batch!(meeting_ids, config)

    meeting_ids = Enum.uniq(meeting_ids)
    Enum.each(meeting_ids, &get_meeting!/1)

    case BrusselsWtf.Repo.transaction(fn ->
           {batch, notifications} =
             Ash.create!(
               BrusselsWtf.Council.CoverageBatch,
               %{
                 requester_id: actor.id,
                 meeting_ids: meeting_ids,
                 generation_kind: :backfill,
                 status: :queued
               },
               action: :record,
               domain: __MODULE__,
               return_notifications?: true
             )

           Enum.each(meeting_ids, fn meeting_id ->
             %{
               meeting_id: meeting_id,
               generation_kind: "backfill",
               coverage_batch_id: batch.id
             }
             |> BrusselsWtf.Workers.PublishMeeting.new()
             |> Oban.insert!()
           end)

           {batch, notifications}
         end) do
      {:ok, {batch, notifications}} ->
        Ash.Notifier.notify(notifications)
        batch

      {:error, reason} ->
        raise ArgumentError, "coverage batch could not be queued: #{inspect(reason)}"
    end
  end

  defp authorize_coverage_batch!(%BrusselsWtf.Review.Actor{role: :reviewer}), do: :ok
  defp authorize_coverage_batch!(_actor), do: raise(ArgumentError, "reviewer is required")

  defp validate_coverage_batch!(meeting_ids, config) do
    max_size = Map.get(config, :backfill_max_batch_size, 10)

    cond do
      not config.backfill_enabled ->
        raise ArgumentError, "coverage backfill generation is disabled"

      meeting_ids == [] ->
        raise ArgumentError, "coverage batch must include at least one meeting"

      length(Enum.uniq(meeting_ids)) > max_size ->
        raise ArgumentError, "coverage batch may include at most #{max_size} meetings"

      true ->
        :ok
    end
  end

  @doc "Returns the last evaluated publication gate result for one meeting page."
  def publication_readiness!(meeting_page_id) do
    page = get_meeting_page!(meeting_page_id)

    %{
      ready?: page.publication_status == :published and page.last_gate_failures == [],
      input_hash: page.publication_input_hash,
      checked_at: page.gate_checked_at,
      failures: Enum.map(page.last_gate_failures, &atomize_gate_failure/1)
    }
  end

  defp atomize_gate_failure(failure) do
    %{
      code: failure["code"] |> String.to_existing_atom(),
      item_key: failure["item_key"],
      claim_key: failure["claim_key"],
      locale: failure["locale"]
    }
  end
end
