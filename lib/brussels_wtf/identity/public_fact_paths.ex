defmodule BrusselsWtf.Identity.PublicFactPaths do
  @moduledoc """
  Read-only two-edge public projections. Paths are never stored and never turn a
  mention into a relationship claim.
  """

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.Mention
  alias BrusselsWtf.Identity.TrustedVerifier

  defmodule Edge do
    @moduledoc false
    defstruct [
      :id,
      :kind,
      :labels,
      :subject_name,
      :object_name,
      :effective_from,
      :effective_to,
      :citation_url,
      :state
    ]
  end

  defmodule Path do
    @moduledoc false
    defstruct [:edges]
  end

  @mention_labels %{
    "en" => "named in",
    "fr" => "cité dans",
    "nl" => "genoemd in"
  }

  def for_item(nil), do: []

  def for_item(item) do
    item = Ash.load!(item, [:current_source_version, council_meeting: []])

    item.id
    |> resolved_organization_mentions()
    |> Enum.flat_map(&paths_for_mention(&1, item))
  rescue
    Ash.Error.Invalid -> []
    Ash.Error.Query.NotFound -> []
  end

  defp resolved_organization_mentions(item_id) do
    Mention
    |> Ash.Query.filter(
      agenda_item_id == ^item_id and kind == :organization and resolution_status == :resolved
    )
    |> Ash.read!(authorize?: false, domain: Identity)
  end

  defp paths_for_mention(mention, item) do
    with {:ok, mention} <-
           Ash.load(mention, [:resolved_legal_entity, source_version: [:source_record]]),
         entity when not is_nil(entity) <- mention.resolved_legal_entity,
         {:ok, profile} <- Identity.get_public_company_profile(entity.enterprise_number),
         {:ok, citation} <- mention_citation(mention),
         managers <- current_managers(profile.relationships),
         [_ | _] <- managers do
      Enum.flat_map(managers, fn manager ->
        case management_edge(manager) do
          %Edge{} = edge ->
            [
              %Path{
                edges: [
                  mention_edge(mention, item, profile, citation),
                  edge
                ]
              }
            ]

          _ ->
            []
        end
      end)
    else
      _ -> []
    end
  end

  defp current_managers(relationships) do
    Enum.filter(relationships, &(&1.kind == :management and &1.state in [nil, :current]))
  end

  defp mention_citation(mention) do
    url = mention.source_version.source_record.origin_url

    try do
      TrustedVerifier.validate_public_url!(url)
      {:ok, url}
    rescue
      ArgumentError -> :error
    end
  end

  defp mention_edge(mention, item, profile, citation) do
    meeting_date = item.council_meeting && item.council_meeting.scheduled_on

    %Edge{
      id: "mention:" <> mention.id,
      kind: :named_in,
      labels: @mention_labels,
      subject_name: profile.registered_name,
      object_name: item_name(item),
      effective_from: meeting_date,
      effective_to: nil,
      citation_url: citation,
      state: :current
    }
  end

  defp management_edge(relationship) do
    labels = relationship.role_labels

    if is_map(labels) and is_binary(relationship.authoritative_url) do
      try do
        TrustedVerifier.validate_public_url!(relationship.authoritative_url)

        %Edge{
          id: "fact:" <> relationship.fact_id,
          kind: :management,
          labels: labels,
          subject_name: relationship.subject_name,
          object_name: relationship.object_name,
          effective_from: relationship.effective_from,
          effective_to: relationship.effective_to,
          citation_url: relationship.authoritative_url,
          state: relationship.state || :current
        }
      rescue
        ArgumentError -> nil
      end
    end
  end

  defp item_name(item) do
    number = item.published_item_number || item.item_number
    "item #{number}"
  end
end
