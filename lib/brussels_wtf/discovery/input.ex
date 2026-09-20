defmodule BrusselsWtf.Discovery.Input do
  @moduledoc """
  Pinned discovery inputs with conservative text minimization.

  Sensitive markers exclude their entire blank-delimited paragraph, including
  continuation lines across page breaks. A private-session marker excludes the
  rest of the document. These heuristics deliberately lose coverage and do not
  guarantee detection of all private information in arbitrary municipal text.
  """
  require Ash.Query
  alias BrusselsWtf.{Archive, Digest, Ingestion}

  @contract "municipal-mentions-v1"
  @roles [
    :agenda,
    :complementary_agenda,
    :project,
    :explanatory_note,
    :complementary_explanatory_note,
    :explanatory_notes,
    :supplement,
    :addendum,
    :minutes,
    :register,
    :motion,
    :question,
    :interpellation
  ]
  @private ~r/huis\s*clos|s[ée]ance\s+(?:non\s+publique|priv[ée]e|secr[èe]te)|comit[ée]\s+secret|(?:besloten|gesloten)\s+(?:zitting|vergadering)|geheime\s+zitting|private\s+session/iu
  @sensitive ~r/@|https?:\/\/|\b(?:e-?mail|courriel|contact|phone|telefoon|t[ée]l[ée]phone|gsm|fax|domicil[eié]s?|adresses?|addresses?|adres(?:sen)?|woonplaats|woonadres(?:sen)?|rue|straat|avenue|laan|boulevard|chauss[ée]e|steenweg|dr[èe]ve|dreef|place|plein|n[ée]e?s?\s+le|dates?\s+de\s+naissance|lieu\s+de\s+naissance|geboren|geboortedatum|geboorteplaats|registre\s+national|rijksregister(?:nummer)?|national\s+number|num[ée]ro\s+national|niss|bis-nummer|identit[ée]|identiteitskaart|identiteitsnummer|signature|handtekening|fisca(?:l|le|ux|les)|revenus?|imposables?|inkomen|inkomsten|belastbaar|belastbare|salaires?|salarissen|traitements?|appointements?|wages?|loon|lonen|wedden?|r[ée]mun[ée]rations?|bezoldiging(?:en)?|iban|comptes?\s+bancaires?|bankrekening(?:en)?|[ée]poux|[ée]pouses?|conjoints?|enfants?|kinderen|parents?|familles?|familie|m[ée]nage|gezin|gezinsleden|personnes?\s+[àa]\s+charge)\b|\bBE\d{2}|\b\d{11}\b|\d{2}[.\/-]\d{2}[.\/-]\d{2}[-. ]?\d{3}[-. ]?\d{2}|(?:\+\d[\d ()\/.-]{7,}\d)|\b0\d[\d ()\/.-]{7,}\d/iu

  def contract, do: @contract
  def sensitive?(text), do: Regex.match?(@sensitive, text) or Regex.match?(@private, text)
  def hash(value), do: Digest.sha256(:erlang.term_to_binary(value, [:deterministic]))

  def prepare(run_id, chunk_offset \\ 0) do
    with {:ok, run} <- Ingestion.get_processing_run(run_id),
         true <-
           run.status == :succeeded and run.processor_role in [:native_extraction, :ocr] and
             run.quality_measurements["accepted"] == true,
         version <- Ingestion.get_source_version!(run.source_version_id),
         record <-
           Ingestion.get_source_record!(version.source_record_id)
           |> Ash.load!([:commune, :council_meeting]),
         true <-
           record.role in @roles and
             record.commune.slug in ~w(ixelles uccle forest city-of-brussels),
         true <- municipal_origin?(record),
         {:ok, context} <- source_context(version, record),
         {:ok, artifact} <- text_artifact(run, version),
         true <- artifact.byte_size in 1..5_000_000,
         {:ok, text} <- Archive.get(artifact.object_key),
         true <-
           byte_size(text) == artifact.byte_size and byte_size(text) <= 5_000_000 and
             Digest.sha256(text) == artifact.output_sha256 and String.valid?(text) do
      {lines, measurements} = minimize(text)
      all_chunks = chunks(lines)
      selected = Enum.slice(all_chunks, chunk_offset, 8)
      has_more = chunk_offset + length(selected) < length(all_chunks)

      measurements =
        Map.merge(measurements, %{
          "eligible_lines" => length(lines),
          "omitted_chunk_lines" => length(lines) - length(List.flatten(selected)),
          "total_chunks" => length(all_chunks),
          "selected_chunks" => length(selected),
          "chunk_offset" => chunk_offset,
          "next_chunk_offset" => if(has_more, do: chunk_offset + length(selected)),
          "has_more" => has_more
        })

      context =
        Map.merge(context, %{
          "artifact_sha256" => artifact.output_sha256,
          "source_sha256" => version.sha256,
          "extraction_processor" => %{
            "name" => run.processor_name,
            "version" => run.processor_version,
            "config_hash" => run.config_hash
          }
        })

      jobs =
        selected
        |> Enum.with_index(chunk_offset)
        |> Enum.map(fn {chunk_lines, chunk} ->
          pinned = %{
            "contract" => @contract,
            "extraction_run_id" => run.id,
            "artifact_id" => artifact.id,
            "source_version_id" => version.id,
            "context" => context,
            "chunk" => chunk,
            "lines" => chunk_lines
          }

          %{
            extraction_run_id: run.id,
            source_version_id: version.id,
            derived_artifact_id: artifact.id,
            contract: @contract,
            chunk: chunk,
            lines: chunk_lines,
            source_context: context,
            input_hash: hash(pinned),
            measurements: measurements
          }
        end)

      {:ok, %{jobs: jobs, measurements: measurements}}
    else
      _ -> {:error, :ineligible_or_unverified_source}
    end
  rescue
    Ash.Error.Invalid -> {:error, :ineligible_or_unverified_source}
  end

  defp municipal_origin?(record) do
    expected = BrusselsWtf.Communes.configuration!(record.commune.slug).index_url |> URI.parse()
    actual = URI.parse(record.origin_url)

    actual.scheme == "https" and is_nil(actual.userinfo) and is_binary(actual.host) and
      String.trim_leading(actual.host, "www.") == String.trim_leading(expected.host, "www.")
  end

  defp text_artifact(run, version) do
    {kind, role} =
      if run.processor_role == :ocr,
        do: {"ocr-text", :ocr_output},
        else: {"native-text", :native_output}

    links =
      Ingestion.ProcessingRunArtifact
      |> Ash.Query.filter(processing_run_id == ^run.id and role == ^role)
      |> Ash.Query.load(:derived_artifact)
      |> Ash.read!()

    # The link is authoritative; shared content-addressed artifacts can originate at another source.
    case Enum.map(links, & &1.derived_artifact)
         |> Enum.filter(fn a ->
           a.input_sha256 == version.sha256 and a.output_kind == kind and
             a.quality_measurements["accepted"] == true and a.processor_name == run.processor_name and
             a.processor_version == run.processor_version and a.config_hash == run.config_hash and
             a.media_type == "text/plain; charset=utf-8"
         end) do
      [artifact] -> {:ok, artifact}
      _ -> {:error, :missing_authoritative_text}
    end
  end

  defp source_context(version, record) do
    contexts =
      Ingestion.RetrievalObservation
      |> Ash.Query.filter(source_version_id == ^version.id and status in [:success, :unchanged])
      |> Ash.Query.load(:source_locator)
      |> Ash.read!()
      |> Enum.map(& &1.source_locator)
      |> Enum.filter(
        &(&1.commune_id == record.commune_id and &1.url == record.origin_url and &1.role in @roles)
      )
      |> Enum.map(&{&1.meeting_identifier, &1.scheduled_on})
      |> Enum.uniq()

    meeting = record.council_meeting

    contexts =
      if meeting,
        do: Enum.uniq([{meeting.municipal_identifier, meeting.scheduled_on} | contexts]),
        else: contexts

    case contexts do
      [{identifier, %Date{} = date}] when is_binary(identifier) and identifier != "" ->
        if Date.compare(date, ~D[2024-01-01]) != :lt and
             (is_nil(meeting) or meeting.commune_id == record.commune_id) do
          {:ok,
           %{
             "commune" => record.commune.slug,
             "meeting_identifier" => identifier,
             "scheduled_on" => Date.to_iso8601(date),
             "source_record_id" => record.id,
             "council_meeting_id" => record.council_meeting_id,
             "agenda_item_id" => record.agenda_item_id,
             "origin_url" => record.origin_url,
             "role" => to_string(record.role)
           }}
        else
          {:error, :ineligible_date}
        end

      _ ->
        {:error, :uncertain_meeting_context}
    end
  end

  defp minimize(text) do
    {public, private} =
      text
      |> String.split("\f")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {page, p} ->
        page
        |> String.split(~r/\r?\n/)
        |> Enum.with_index(1)
        |> Enum.map(fn {line, l} -> %{"id" => "p#{p}-l#{l}", "text" => line} end)
      end)
      |> split_private_section()

    counts = if private == [], do: %{}, else: %{"private_session" => length(private)}

    public
    |> Enum.chunk_by(&(String.trim(&1["text"]) == ""))
    |> Enum.reduce({[], counts}, fn block, {kept, counts} ->
      reason =
        cond do
          String.trim(hd(block)["text"]) == "" ->
            "blank_line"

          sensitive?(Enum.map_join(block, "\n", & &1["text"])) ->
            "sensitive_block"

          Enum.any?(block, &(byte_size(&1["text"]) > 1_000)) ->
            "oversized_block"

          Enum.any?(block, &Regex.match?(~r/[\x00-\x08\x0B\x0E-\x1F]/u, &1["text"])) ->
            "control_characters"

          true ->
            nil
        end

      if reason,
        do: {kept, Map.update(counts, reason, length(block), &(&1 + length(block)))},
        else: {[block | kept], counts}
    end)
    |> then(fn {blocks, counts} ->
      {blocks |> Enum.reverse() |> List.flatten(), %{"excluded_lines" => counts}}
    end)
  end

  defp split_private_section(lines) do
    text = Enum.map_join(lines, "\n", & &1["text"])

    case Regex.run(@private, text, return: :index, capture: :first) do
      [{offset, _length}] ->
        # Match across line/page boundaries, then exclude from the heading's
        # first original line, not merely the line containing its last word.
        heading_line = text |> binary_part(0, offset) |> :binary.matches("\n") |> length()
        Enum.split(lines, heading_line)

      nil ->
        {lines, []}
    end
  end

  defp chunks(lines) do
    {done, current, _bytes} =
      Enum.reduce(lines, {[], [], 0}, fn line, {done, current, bytes} ->
        size = byte_size(line["text"])

        if length(current) >= 60 or bytes + size > 12_000 do
          {[Enum.reverse(current) | done], [line], size}
        else
          {done, [line | current], bytes + size}
        end
      end)

    Enum.reverse(if current == [], do: done, else: [Enum.reverse(current) | done])
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["schema_version", "input_hash", "mentions"],
      "properties" => %{
        "schema_version" => %{"type" => "string", "const" => @contract},
        "input_hash" => %{"type" => "string", "pattern" => "^[a-f0-9]{64}$"},
        "mentions" => %{
          "type" => "array",
          "maxItems" => 100,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["kind", "text", "line_id", "quote"],
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["person", "organization"]},
              "text" => %{"type" => "string", "minLength" => 2, "maxLength" => 200},
              "line_id" => %{"type" => "string", "maxLength" => 40},
              "quote" => %{"type" => "string", "minLength" => 2, "maxLength" => 1000}
            }
          }
        }
      }
    }
  end

  def valid_result?(job, result, processor) do
    exact_keys?(result, ~w(schema_version input_hash mentions)) and
      result["schema_version"] == job.contract and result["input_hash"] == job.input_hash and
      is_list(result["mentions"]) and length(result["mentions"]) <= 100 and
      Enum.all?(result["mentions"], &valid_mention?(job.lines, &1)) and
      length(Enum.uniq_by(result["mentions"], &{&1["line_id"], &1["text"]})) ==
        length(result["mentions"]) and
      exact_keys?(processor, ~w(name version model)) and processor["name"] == "codex-cli" and
      Enum.all?(Map.values(processor), &bounded_string?(&1, 1, 100))
  end

  def exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_mention?(lines, mention) do
    exact_keys?(mention, ~w(kind text line_id quote)) and
      mention["kind"] in ~w(person organization) and
      bounded_string?(mention["text"], 2, 200) and bounded_string?(mention["quote"], 2, 1000) and
      bounded_string?(mention["line_id"], 1, 40) and not sensitive?(mention["quote"]) and
      case Enum.find(lines, &(&1["id"] == mention["line_id"])) do
        nil ->
          false

        line ->
          unique_span?(line["text"], mention["quote"]) and
            unique_span?(mention["quote"], mention["text"])
      end
  end

  defp unique_span?(source, text) do
    length(:binary.matches(source, text)) == 1 and
      Regex.match?(
        Regex.compile!(
          "(?<![\\p{L}\\p{M}\\p{N}])" <> Regex.escape(text) <> "(?![\\p{L}\\p{M}\\p{N}])",
          "u"
        ),
        source
      )
  end

  defp bounded_string?(value, min, max),
    do:
      is_binary(value) and String.valid?(value) and
        length(String.codepoints(value)) >= min and byte_size(value) <= max and
        String.trim(value) == value and
        not Regex.match?(~r/[\x00-\x1F]/u, value)
end
