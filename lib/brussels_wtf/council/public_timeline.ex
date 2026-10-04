defmodule BrusselsWtf.Council.PublicTimeline do
  @moduledoc "Public coverage selection, search, ordering, and bounded category previews."

  alias BrusselsWtf.Council
  @real_corpus_meeting_count 8

  def list!(opts) do
    selected = Keyword.fetch!(opts, :communes)
    locale = Keyword.fetch!(opts, :locale)
    names = Keyword.fetch!(opts, :commune_names)
    needle = opts |> Keyword.get(:search, "") |> String.downcase()
    groups = Keyword.get(opts, :groups, [:coming, :awaiting, :decided])
    limit = Keyword.get(opts, :limit)

    today =
      BrusselsWtf.Clock.utc_now()
      |> DateTime.shift_zone!("Europe/Brussels", Tzdata.TimeZoneDatabase)
      |> DateTime.to_date()

    entries =
      Council.list_published_meeting_pages!()
      |> prefer_real_corpus()
      |> Enum.filter(&(&1.council_meeting.commune.slug in selected))
      |> Enum.flat_map(fn page ->
        for item <- page.council_meeting.agenda_items, item.published? do
          decision = loaded_or_nil(item.published_decision)
          state = display_state(item, decision)
          variant = Enum.find(item.coverage_variants, &(&1.locale == locale))

          %{
            page: page,
            item: item,
            variant: variant,
            state: state,
            group: group(state, page.council_meeting.scheduled_on, today)
          }
        end
      end)
      |> Enum.filter(fn entry ->
        needle == "" or String.contains?(search_text(entry, names), needle)
      end)
      |> Enum.sort_by(& &1.page.council_meeting.scheduled_on, {:desc, Date})
      |> Enum.group_by(& &1.group)

    Map.new(groups, fn group ->
      matching = Map.get(entries, group, [])
      {group, if(limit, do: Enum.take(matching, limit), else: matching)}
    end)
  end

  defp search_text(%{page: page, item: item, variant: variant}, names) do
    [
      variant && variant.title,
      variant && variant.summary,
      Map.fetch!(names, page.council_meeting.commune.slug),
      item.published_item_number || item.item_number,
      Date.to_iso8601(page.council_meeting.scheduled_on)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp prefer_real_corpus(pages) do
    real = Enum.filter(pages, &real_page?/1)
    if length(real) >= @real_corpus_meeting_count, do: real, else: pages
  end

  defp real_page?(page) do
    Enum.any?(page.council_meeting.agenda_items, fn item ->
      proposal = loaded_or_nil(item.published_proposal)
      decision = loaded_or_nil(item.published_decision)

      (proposal && not proposal.synthetic) ||
        (decision && Enum.any?(decision.evidence, &(not &1.synthetic)))
    end)
  end

  defp display_state(_item, decision) when not is_nil(decision), do: :decision
  defp display_state(%{published_procedural_state: :decision}, nil), do: :unknown
  defp display_state(item, nil), do: item.published_procedural_state || :unknown
  defp group(:decision, _date, _today), do: :decided

  defp group(:proposal, date, today),
    do: if(Date.compare(date, today) == :lt, do: :awaiting, else: :coming)

  defp group(_state, _date, _today), do: :awaiting
  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value
end
