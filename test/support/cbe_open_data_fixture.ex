defmodule BrusselsWtf.CBE.OpenDataFixture do
  @moduledoc false

  def write_release do
    directory =
      Path.join(
        System.tmp_dir!(),
        "brussels-wtf-cbe-open-data-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "meta.csv"),
      """
      Variable,Value
      SnapshotDate,21-08-2026
      ExtractTimestamp,21-08-2026 01:02:03
      ExtractType,Full
      ExtractNumber,4321
      Version,R018.00
      """
    )

    File.write!(
      Path.join(directory, "code.csv"),
      """
      Category,Code,Language,Description
      Language,1,FR,Néerlandais
      Language,2,FR,Français
      TypeOfDenomination,001,FR,Dénomination
      TypeOfDenomination,002,FR,Abréviation
      TypeOfDenomination,003,FR,Dénomination commerciale
      """
    )

    File.write!(
      Path.join(directory, "enterprise.csv"),
      """
      EnterpriseNumber,Status,JuridicalSituation,TypeOfEnterprise,JuridicalForm,JuridicalFormCAC,StartDate
      0123.456.749,AC,000,2,610,,01-01-2000
      0474.521.921,AC,000,1,,,02-02-2002
      """
    )

    File.write!(
      Path.join(directory, "establishment.csv"),
      """
      EstablishmentNumber,StartDate,EnterpriseNumber
      2.123.456.789,03-04-2005,0123.456.749
      """
    )

    File.write!(
      Path.join(directory, "denomination.csv"),
      String.replace(
        """
        EntityNumber,Language,TypeOfDenomination,Denomination
        0123.456.749,2,001,"Example Brussels, ASBL"
        0123.456.749,1,002,EB
        0123.456.749,2,003,Example Trading
        2.123.456.789,2,001,Example Brussels Unit
        0474.521.921,2,001,Example Natural Registration
        """,
        "\n",
        "\r\n"
      )
    )

    directory
  end

  def add_enterprises(directory, count) do
    File.open!(Path.join(directory, "enterprise.csv"), [:append], fn file ->
      Enum.each(1..count, fn n ->
        number = n |> Integer.to_string() |> String.pad_leading(10, "0")
        IO.binwrite(file, "#{number},AC,000,2,610,,01-01-2000\n")
      end)
    end)

    directory
  end

  def add_edge_cases(directory) do
    File.write!(
      Path.join(directory, "enterprise.csv"),
      """
      0123.456.749,ST,000,1,,,01-01-2001
      0000.000.001,ST,000,1,,999,02-02-2002
      0000.000.002,AC,000,2,610,,01-01-2000
      """,
      [:append]
    )

    File.write!(
      Path.join(directory, "establishment.csv"),
      """
      2.000.000.001,,0123.456.749
      2.123.456.789,05-06-2007,0123.456.749
      """,
      [:append]
    )

    File.write!(
      Path.join(directory, "denomination.csv"),
      """
      0123.456.749,99,999,"Duplicate registered\nwith ""quotes\"""
      0123.456.749,2,001,"Example Brussels, ASBL"
      0000.000.001,99,999,Inactive Example
      """,
      [:append]
    )

    for file <- ~w(meta.csv code.csv enterprise.csv establishment.csv denomination.csv) do
      path = Path.join(directory, file)
      bytes = File.read!(path) |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")
      File.write!(path, "\uFEFF" <> bytes)
    end

    directory
  end

  def manifest(directory, sha256 \\ String.duplicate("a", 64)) do
    files =
      Map.new(~w(meta code enterprise establishment denomination), fn name ->
        filename = name <> ".csv"
        bytes = File.read!(Path.join(directory, filename))

        {filename,
         %{
           "bytes" => byte_size(bytes),
           "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
         }}
      end)

    %{"sha256" => sha256, "metadata" => %{"source" => "synthetic fixture"}, "files" => files}
  end
end
