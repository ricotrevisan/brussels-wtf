defmodule BrusselsWtf.Identity.Changes.ValidateSourcedFact do
  @moduledoc false
  use Ash.Resource.Change

  @fields [
    :kind,
    :evidence_kind,
    :evidence_excerpt,
    :evidence_location,
    :source_version_id,
    :authoritative_url,
    :effective_from,
    :effective_to
  ]

  @impl true
  def change(changeset, _opts, _context) do
    attrs = Map.new(@fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

    try do
      BrusselsWtf.Identity.validate_sourced_fact_attributes!(attrs)
      changeset
    rescue
      error in ArgumentError -> Ash.Changeset.add_error(changeset, message: error.message)
    end
  end
end
