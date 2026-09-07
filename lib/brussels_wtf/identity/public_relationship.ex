defmodule BrusselsWtf.Identity.PublicRelationship do
  @moduledoc "A closed, redacted relationship projection safe for public callers."

  @enforce_keys [
    :fact_id,
    :subject_type,
    :subject_id,
    :subject_name,
    :object_type,
    :object_id,
    :object_name,
    :kind,
    :source_authority,
    :evidence_location,
    :source_retrieved_at,
    :verified_at
  ]

  defstruct @enforce_keys ++
              [:effective_from, :effective_to, :authoritative_url, :mandate_declaration, :state]
end
