defmodule BrusselsWtf.Review do
  @moduledoc """
  Actionable domain ambiguity and its audit trail, distinct from Oban transport state.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  require Ash.Query

  resources do
    resource BrusselsWtf.Review.Case do
      define :open_review_case, action: :open

      define :retry_review_case, action: :retry
      define :complete_review_retry, action: :complete_retry
      define :reclassify_review_case, action: :reclassify
      define :relink_review_case, action: :relink
      define :correct_review_case, action: :correct
      define :mark_review_case_unsupported, action: :mark_unsupported
    end

    resource BrusselsWtf.Review.Action do
      define :record_review_action, action: :record
    end

    resource BrusselsWtf.Review.Note do
      define :add_review_note, action: :add
    end

    resource BrusselsWtf.Review.Revision do
      define :record_review_revision, action: :record
    end

    resource BrusselsWtf.Review.Exclusion do
      define :record_review_exclusion, action: :record
    end
  end

  def complete_retry!(review_case_id) do
    review_case =
      Ash.get!(BrusselsWtf.Review.Case, review_case_id,
        authorize?: false,
        domain: __MODULE__
      )

    complete_review_retry!(review_case)
  end

  def list_blocking_publication_cases!(meeting) do
    affected_ids =
      [meeting.id, meeting.meeting_page.id] ++
        Enum.flat_map(meeting.agenda_items, fn item ->
          [item.id] ++
            Enum.flat_map(item.proposals, fn proposal ->
              [proposal.id | Enum.map(proposal.evidence, & &1.id)]
            end)
        end)

    BrusselsWtf.Review.Case
    |> Ash.Query.filter(
      status == :open and kind in [:normalization, :evidence] and
        (source_record.council_meeting_id == ^meeting.id or affected_record_id in ^affected_ids)
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false, domain: __MODULE__)
  end

  def resolve_publication_case!(meeting_page_id, generation) do
    BrusselsWtf.Review.Case
    |> Ash.Query.filter(
      kind == :publication and affected_record_id == ^meeting_page_id and
        processing_generation == ^generation and status == :open
    )
    |> Ash.read!(authorize?: false, domain: __MODULE__)
    |> Enum.each(&complete_review_retry!/1)

    :ok
  end

  def list_review_cases!(filters \\ %{}, opts \\ []) do
    BrusselsWtf.Review.Case
    |> Ash.Query.for_read(:inbox, filters)
    |> Ash.Query.load(:commune)
    |> Ash.read!(Keyword.merge([domain: __MODULE__], opts))
  end

  def get_review_case!(id, opts \\ []) do
    BrusselsWtf.Review.Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([
      :commune,
      :actions,
      :notes,
      :revisions,
      :exclusions,
      source_record: [:versions],
      source_version: [:observations, processing_runs: [:derived_artifacts]]
    ])
    |> Ash.read_one!(Keyword.merge([domain: __MODULE__], opts))
    |> case do
      nil ->
        raise Ash.Error.Query.NotFound, resource: BrusselsWtf.Review.Case, primary_key: %{id: id}

      review_case ->
        review_case
    end
  end
end
