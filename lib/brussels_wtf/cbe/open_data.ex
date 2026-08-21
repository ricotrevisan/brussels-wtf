defmodule BrusselsWtf.CBE.OpenData do
  @moduledoc """
  Private reader for an operator-provisioned CBE Open Data full release.

  It reads only the official metadata, enterprise, denomination, establishment,
  and code CSV files. The registered archive hash is supplied separately so the
  resulting facts remain tied to the exact downloaded release.
  """

  @behaviour BrusselsWtf.CBE

  alias BrusselsWtf.CBE.OpenData.CSV

  @required_files [
    meta: {"meta.csv", :missing_meta_csv},
    code: {"code.csv", :missing_code_csv},
    enterprise: {"enterprise.csv", :missing_enterprise_csv},
    establishment: {"establishment.csv", :missing_establishment_csv},
    denomination: {"denomination.csv", :missing_denomination_csv}
  ]

  @impl true
  def fetch_enterprise(enterprise_number) do
    with {:ok, number} <- normalize_number(enterprise_number),
         {:ok, config} <- configured_release(),
         {:ok, paths} <- release_paths(config.directory),
         {:ok, metadata} <- metadata(paths.meta),
         :ok <- require_full_release(metadata),
         {:ok, codes} <- codes(paths.code),
         {:ok, enterprise} <- enterprise(paths.enterprise, number),
         {:ok, units} <- establishments(paths.establishment, number),
         {:ok, names} <- denominations(paths.denomination, number, units, codes),
         {:ok, registered_name} <- registered_name(names, number) do
      {:ok,
       %{
         release: release(metadata, config.release_sha256),
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
    error in File.Error ->
      {:error, {:cbe_open_data_unavailable, error.reason}}

    error ->
      {:error, {:invalid_cbe_open_data_release, Exception.message(error)}}
  end

  defp configured_release do
    config = Application.get_env(:brussels_wtf, __MODULE__, [])
    directory = config[:directory]
    sha256 = config[:release_sha256]

    cond do
      not is_binary(directory) or directory == "" ->
        {:error, :cbe_source_unconfigured}

      not is_binary(sha256) or not Regex.match?(~r/\A[0-9a-f]{64}\z/i, sha256) ->
        {:error, {:invalid_cbe_open_data_release, :invalid_release_sha256}}

      true ->
        {:ok, %{directory: directory, release_sha256: String.downcase(sha256)}}
    end
  end

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

  defp metadata(path) do
    with {:ok, rows} <- rows(path, ["Variable", "Value"]) do
      {:ok, Map.new(rows, &{&1["Variable"], &1["Value"]})}
    end
  end

  defp require_full_release(%{"ExtractType" => type}) do
    if String.downcase(type) == "full" do
      :ok
    else
      {:error, {:invalid_cbe_open_data_release, :full_release_required}}
    end
  end

  defp require_full_release(_metadata),
    do: {:error, {:invalid_cbe_open_data_release, :missing_extract_type}}

  defp codes(path) do
    with {:ok, rows} <- rows(path, ["Category", "Code", "Language", "Description"]) do
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
  end

  defp enterprise(path, number) do
    with {:ok, rows} <-
           rows(path, [
             "EnterpriseNumber",
             "Status",
             "JuridicalSituation",
             "TypeOfEnterprise",
             "JuridicalForm",
             "JuridicalFormCAC",
             "StartDate"
           ]) do
      case Enum.find(rows, &(normalize_number_value(&1["EnterpriseNumber"]) == number)) do
        nil -> {:error, :not_found}
        enterprise -> {:ok, enterprise}
      end
    end
  end

  defp establishments(path, number) do
    with {:ok, rows} <-
           rows(path, ["EstablishmentNumber", "StartDate", "EnterpriseNumber"]) do
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
  end

  defp denominations(path, number, units, codes) do
    entity_numbers = MapSet.new([number | Enum.map(units, & &1.unit_number)])

    with {:ok, rows} <-
           rows(path, ["EntityNumber", "Language", "TypeOfDenomination", "Denomination"]) do
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

          Map.update(acc, entity_number, [observation], &(&1 ++ [observation]))
        end)

      {:ok, names}
    end
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

  defp status("AC"), do: :active
  defp status(_status), do: :inactive

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

  defp rows(path, required_headers) do
    headers =
      path
      |> File.stream!()
      |> CSV.parse_stream(skip_headers: false)
      |> Enum.take(1)
      |> case do
        [headers] -> headers
        [] -> raise ArgumentError, "empty CBE Open Data CSV"
      end

    headers =
      Enum.map(headers, fn header ->
        header |> String.trim_leading("\uFEFF") |> String.trim_trailing("\r")
      end)

    data =
      path
      |> File.stream!()
      |> CSV.parse_stream()
      |> Stream.map(fn row -> Enum.map(row, &String.trim_trailing(&1, "\r")) end)

    missing_headers = required_headers -- headers

    if missing_headers == [] do
      {:ok, Stream.map(data, &Map.new(Enum.zip(headers, &1)))}
    else
      {:error, {:invalid_cbe_open_data_release, {:missing_headers, missing_headers}}}
    end
  end

  defp normalize_number(value) when is_binary(value) do
    case normalize_number_value(value) do
      <<_::binary-size(10)>> = number -> {:ok, number}
      _ -> {:error, :invalid_enterprise_number}
    end
  end

  defp normalize_number(_value), do: {:error, :invalid_enterprise_number}
  defp normalize_number_value(value), do: String.replace(value || "", ~r/\D/, "")

  defp parse_optional_date(""), do: nil
  defp parse_optional_date(nil), do: nil
  defp parse_optional_date(value), do: parse_date!(value)

  defp parse_date!(value) do
    case String.split(value, "-") do
      [day, month, year] ->
        Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      _ ->
        raise ArgumentError, "invalid CBE Open Data date"
    end
  end
end

NimbleCSV.define(BrusselsWtf.CBE.OpenData.CSV,
  separator: ",",
  escape: "\"",
  line_separator: "\n"
)
