defmodule BrusselsWtf.CBE.Source do
  @moduledoc false
  alias BrusselsWtf.CBE.OpenData.CSV

  @headers %{
    "meta.csv" => ~w(Variable Value),
    "code.csv" => ~w(Category Code Language Description),
    "enterprise.csv" =>
      ~w(EnterpriseNumber Status JuridicalSituation TypeOfEnterprise JuridicalForm JuridicalFormCAC StartDate),
    "establishment.csv" => ~w(EstablishmentNumber StartDate EnterpriseNumber),
    "denomination.csv" => ~w(EntityNumber Language TypeOfDenomination Denomination)
  }

  def files, do: ~w(meta.csv code.csv enterprise.csv establishment.csv denomination.csv)

  def load(directory, sha256, number) do
    with {:ok, paths} <- release_paths(directory) do
      rows =
        Map.new(paths, fn {key, path} -> {key, rows(path, Atom.to_string(key) <> ".csv")} end)

      project(rows, sha256, number)
    end
  rescue
    error in File.Error -> {:error, {:cbe_open_data_unavailable, error.reason}}
    _ -> {:error, {:invalid_cbe_open_data_release, :malformed_source}}
  catch
    {:source_error, reason} -> {:error, {:invalid_cbe_open_data_release, reason}}
  end

  def project(rows, sha256, number) do
    with {:ok, metadata} <- metadata(rows.meta),
         :ok <- require_full_release(metadata),
         {:ok, codes} <- codes(rows.code),
         {:ok, enterprise} <- enterprise(rows.enterprise, number),
         {:ok, units} <- establishments(rows.establishment, number),
         {:ok, names} <- denominations(rows.denomination, number, units, codes),
         {:ok, registered_name} <- registered_name(names, number) do
      {:ok,
       %{
         release: release(metadata, sha256),
         entity: %{
           enterprise_number: number,
           entity_type: entity_type(enterprise),
           registered_name: registered_name,
           status: status(enterprise["Status"])
         },
         names: Map.fetch!(names, number),
         establishment_units: attach_unit_names(units, names)
       }}
    end
  rescue
    _ -> {:error, {:invalid_cbe_open_data_release, :malformed_source}}
  end

  def validate_metadata(rows, sha256) do
    with {:ok, metadata} <- metadata(rows), :ok <- require_full_release(metadata) do
      _ = release(metadata, sha256)
      :ok
    end
  rescue
    _ -> {:error, {:invalid_cbe_open_data_release, :malformed_source}}
  end

  def rows(path, file, max_record_bytes \\ 1_048_576, expected \\ nil) do
    required = Map.fetch!(@headers, file)

    path
    |> BrusselsWtf.CBE.Source.Records.stream(max_record_bytes, expected)
    |> CSV.parse_stream(skip_headers: false)
    |> Stream.transform(nil, fn
      headers, nil ->
        headers =
          Enum.map(headers, &(&1 |> String.trim_leading("\uFEFF") |> String.trim_trailing("\r")))

        missing = required -- headers

        if missing != [] do
          throw({:source_error, {:missing_headers, missing}})
        end

        {[], headers}

      row, headers ->
        values = Enum.map(row, &String.trim_trailing(&1, "\r"))

        if length(values) != length(headers) do
          throw({:source_error, :invalid_row})
        end

        {[Map.new(Enum.zip(headers, values)) |> Map.take(required)], headers}
    end)
  end

  @required_files meta: {"meta.csv", :missing_meta_csv},
                  code: {"code.csv", :missing_code_csv},
                  enterprise: {"enterprise.csv", :missing_enterprise_csv},
                  establishment: {"establishment.csv", :missing_establishment_csv},
                  denomination: {"denomination.csv", :missing_denomination_csv}
  defp release_paths(directory) do
    Enum.reduce_while(@required_files, {:ok, %{}}, fn {key, {filename, reason}}, {:ok, paths} ->
      path = Path.join(directory, filename)

      if File.regular?(path) do
        {:cont, {:ok, Map.put(paths, key, path)}}
      else
        {:halt, {:error, {:invalid_cbe_open_data_release, reason}}}
      end
    end)
  end

  defp metadata(rows) do
    {:ok, Map.new(rows, &{&1["Variable"], &1["Value"]})}
  end

  defp require_full_release(%{"ExtractType" => type}) do
    if String.downcase(type) == "full" do
      :ok
    else
      {:error, {:invalid_cbe_open_data_release, :full_release_required}}
    end
  end

  defp require_full_release(_metadata) do
    {:error, {:invalid_cbe_open_data_release, :missing_extract_type}}
  end

  defp codes(rows) do
    codes =
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(
          acc,
          {row["Category"], row["Code"]},
          [row["Description"]],
          &[row["Description"] | &1]
        )
      end)

    {:ok, codes}
  end

  defp enterprise(rows, number) do
    case Enum.find(rows, &(normalize_number_value(&1["EnterpriseNumber"]) == number)) do
      nil -> {:error, :not_found}
      enterprise -> {:ok, enterprise}
    end
  end

  defp establishments(rows, number) do
    units =
      rows
      |> Stream.filter(&(normalize_number_value(&1["EnterpriseNumber"]) == number))
      |> Enum.map(fn row ->
        %{
          unit_number: normalize_number_value(row["EstablishmentNumber"]),
          name: nil,
          status: :active,
          started_on: parse_optional_date(row["StartDate"])
        }
      end)

    {:ok, units}
  end

  defp denominations(rows, number, units, codes) do
    entity_numbers = MapSet.new([number | Enum.map(units, & &1.unit_number)])

    names =
      rows
      |> Stream.map(fn row -> {normalize_number_value(row["EntityNumber"]), row} end)
      |> Stream.filter(fn {entity_number, _row} ->
        MapSet.member?(entity_numbers, entity_number)
      end)
      |> Enum.reduce(%{}, fn {entity_number, row}, acc ->
        observation = %{
          name: row["Denomination"],
          kind: denomination_kind(row["TypeOfDenomination"], codes),
          language: language(row["Language"], codes),
          effective_from: nil
        }

        Map.update(acc, entity_number, [observation], &[observation | &1])
      end)
      |> Map.new(fn {number, names} -> {number, Enum.reverse(names)} end)

    {:ok, names}
  end

  defp registered_name(names, number) do
    names
    |> Map.get(number, [])
    |> Enum.find(&(&1.kind == :registered))
    |> case do
      nil -> {:error, {:invalid_cbe_open_data_release, :registered_name_missing}}
      observation -> {:ok, observation.name}
    end
  end

  defp attach_unit_names(units, names) do
    Enum.map(units, fn unit ->
      name =
        names
        |> Map.get(unit.unit_number, [])
        |> Enum.find(&(&1.kind == :registered))
        |> case do
          nil -> nil
          observation -> observation.name
        end

      %{unit | name: name}
    end)
  end

  defp release(metadata, sha256) do
    published_on = parse_date!(Map.fetch!(metadata, "SnapshotDate"))
    extract_number = Map.fetch!(metadata, "ExtractNumber")
    version = Map.fetch!(metadata, "Version")

    %{
      release_key: "cbe-open-data:#{extract_number}:#{Date.to_iso8601(published_on)}:#{version}",
      published_on: published_on,
      sha256: sha256
    }
  end

  defp entity_type(enterprise) do
    if enterprise["JuridicalForm"] not in [nil, ""] or
         enterprise["JuridicalFormCAC"] not in [nil, ""] do
      :legal_person
    else
      :natural_person
    end
  end

  defp status("AC") do
    :active
  end

  defp status(_status) do
    :inactive
  end

  defp denomination_kind(code, codes) do
    descriptions = Map.get(codes, {"TypeOfDenomination", code}, [])

    cond do
      Enum.any?(descriptions, &contains?(&1, ["commercial", "handels"])) ->
        :trading

      Enum.any?(descriptions, &contains?(&1, ["abréviation", "afkort", "abkürzung"])) ->
        :abbreviated

      true ->
        :registered
    end
  end

  defp language(code, codes) do
    descriptions = Map.get(codes, {"Language", code}, [])

    cond do
      Enum.any?(descriptions, &contains?(&1, ["français", "frans", "französisch"])) ->
        "fr"

      Enum.any?(descriptions, &contains?(&1, ["néerlandais", "nederlands", "niederländisch"])) ->
        "nl"

      Enum.any?(descriptions, &contains?(&1, ["allemand", "duits", "deutsch"])) ->
        "de"

      true ->
        code
    end
  end

  defp contains?(value, needles) do
    normalized = value |> String.downcase() |> String.normalize(:nfd)
    Enum.any?(needles, &String.contains?(normalized, String.normalize(&1, :nfd)))
  end

  def normalize_number(value) when is_binary(value) do
    case normalize_number_value(value) do
      <<_::binary-size(10)>> = number -> {:ok, number}
      _ -> {:error, :invalid_enterprise_number}
    end
  end

  def normalize_number(_value) do
    {:error, :invalid_enterprise_number}
  end

  def normalize_number_value(value) do
    String.replace(value || "", ~r/\D/, "")
  end

  defp parse_optional_date("") do
    nil
  end

  defp parse_optional_date(nil) do
    nil
  end

  defp parse_optional_date(value) do
    parse_date!(value)
  end

  defp parse_date!(value) do
    case String.split(value, "-") do
      [day, month, year] ->
        Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      _ ->
        raise ArgumentError, "invalid CBE Open Data date"
    end
  end
end

NimbleCSV.define(BrusselsWtf.CBE.OpenData.CSV, separator: ",", escape: "\"", line_separator: "\n")
