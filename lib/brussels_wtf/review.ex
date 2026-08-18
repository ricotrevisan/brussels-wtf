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
      :source_record,
      :actions,
      :notes,
      :revisions,
      :exclusions,
      source_version: [:processing_runs, :observations]
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
