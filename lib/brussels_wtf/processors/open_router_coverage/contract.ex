defmodule BrusselsWtf.Processors.OpenRouterCoverage.Contract do
  @moduledoc false

  def input(input) do
    valid =
      keys?(input, ~w(commune_slug meeting_identifier scheduled_on items)) and
        Enum.all?(~w(commune_slug meeting_identifier scheduled_on), &text?(input[&1])) and
        is_list(input["items"]) and input["items"] != [] and
        Enum.all?(input["items"], &input_item?/1) and
        unique?(Enum.map(input["items"], & &1["key"])) and
        unique?(Enum.flat_map(input["items"], fn i -> Enum.map(i["claims"], & &1["key"]) end))

    result(valid)
  end

  def bundle(output) do
    valid =
      keys?(output, ~w(meeting_identifier page items)) and text?(output["meeting_identifier"]) and
        page?(output["page"]) and is_map(output["items"]) and map_size(output["items"]) > 0 and
        Enum.all?(output["items"], fn {key, item} -> text?(key) and generated_item?(item) end)

    result(valid)
  end

  def canonical_fields(input, output) do
    page_refs =
      Enum.flat_map(input["items"], fn item -> Enum.map(item["claims"], & &1["key"]) end)

    result(
      MapSet.new(output["page"]["claim_refs"]) == MapSet.new(page_refs) and
        Enum.all?(input["items"], fn item ->
          generated = output["items"][item["key"]]
          fields = ~w(title summary) ++ Enum.map(item["claims"], &(&1["kind"] <> "_summary"))

          is_map(generated) and
            MapSet.new(generated["claim_refs"]) ==
              MapSet.new(Enum.map(item["claims"], & &1["key"])) and
            keys?(generated["variant"], Enum.uniq(fields))
        end)
    )
  end

  def translation(canonical, output) do
    with :ok <- bundle(output) do
      result(
        output["meeting_identifier"] == canonical["meeting_identifier"] and
          output["page"]["claim_refs"] == canonical["page"]["claim_refs"] and
          Map.keys(output["items"]) == Map.keys(canonical["items"]) and
          Enum.all?(canonical["items"], fn {key, item} ->
            translated = output["items"][key]

            translated["claim_refs"] == item["claim_refs"] and
              Map.keys(translated["variant"]) == Map.keys(item["variant"])
          end)
      )
    end
  end

  defp input_item?(item) do
    keys?(item, ~w(key item_number procedural_state outcome source_wording claims)) and
      text?(item["key"]) and text?(item["source_wording"]) and
      item["procedural_state"] in ["proposal", "decision"] and
      is_list(item["claims"]) and item["claims"] != [] and Enum.all?(item["claims"], &claim?/1)
  end

  defp claim?(%{"kind" => kind} = claim) when kind in ["proposal", "decision"] do
    fields =
      ~w(key kind text evidence) ++ if(kind == "decision", do: ~w(disposition vote), else: [])

    keys?(claim, fields) and text?(claim["key"]) and text?(claim["text"]) and
      evidence?(claim["evidence"]) and (kind != "decision" or vote?(claim["vote"]))
  end

  defp claim?(_), do: false

  defp evidence?(evidence) when is_list(evidence) and evidence != [] do
    Enum.all?(evidence, fn e ->
      keys?(
        e,
        ~w(citation_url excerpt location retrieved_at source_sha256 source_origin_url synthetic)
      ) and
        Enum.all?(
          ~w(citation_url excerpt location retrieved_at source_sha256 source_origin_url),
          &text?(e[&1])
        ) and e["synthetic"] == false
    end)
  end

  defp evidence?(_), do: false
  defp vote?(nil), do: true

  defp vote?(vote) do
    keys?(vote, ~w(for against abstentions evidence)) and
      Enum.all?(
        ~w(for against abstentions),
        &(is_nil(vote[&1]) or (is_integer(vote[&1]) and vote[&1] >= 0))
      ) and
      evidence?(vote["evidence"])
  end

  defp page?(page),
    do:
      keys?(page, ~w(title summary claim_refs)) and text?(page["title"]) and
        text?(page["summary"]) and refs?(page["claim_refs"])

  defp generated_item?(item) do
    keys?(item, ~w(claim_refs variant)) and refs?(item["claim_refs"]) and
      variant?(item["variant"])
  end

  defp variant?(v) when is_map(v) do
    keys = Map.keys(v)

    Enum.all?(~w(title summary), &(&1 in keys)) and
      Enum.all?(keys, &(&1 in ~w(title summary proposal_summary decision_summary))) and
      Enum.all?(Map.values(v), &text?/1)
  end

  defp variant?(_), do: false

  defp refs?(refs) when is_list(refs) and refs != [],
    do: Enum.all?(refs, &text?/1) and unique?(refs)

  defp refs?(_), do: false
  defp unique?(list), do: length(list) == MapSet.size(MapSet.new(list))
  defp keys?(map, keys) when is_map(map), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)
  defp keys?(_, _), do: false
  defp text?(s) when is_binary(s), do: String.valid?(s) and String.trim(s) != ""
  defp text?(_), do: false
  defp result(true), do: :ok
  defp result(_), do: {:error, :invalid_generation_output}
end
