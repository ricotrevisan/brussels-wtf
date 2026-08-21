defmodule BrusselsWtf.CBE.OpenDataTest do
  use ExUnit.Case, async: false

  alias BrusselsWtf.CBE.OpenData

  setup do
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
      0474.521.965,AC,000,1,,,02-02-2002
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
        0474.521.965,2,001,Example Natural Registration
        """,
        "\n",
        "\r\n"
      )
    )

    previous = Application.get_env(:brussels_wtf, OpenData)

    Application.put_env(:brussels_wtf, OpenData,
      directory: directory,
      release_sha256: String.duplicate("a", 64)
    )

    on_exit(fn ->
      File.rm_rf!(directory)

      if previous do
        Application.put_env(:brussels_wtf, OpenData, previous)
      else
        Application.delete_env(:brussels_wtf, OpenData)
      end
    end)

    :ok
  end

  test "reads a legal entity, names, and establishment units from an official full release" do
    assert {:ok, bundle} = OpenData.fetch_enterprise("0123456749")

    assert bundle.release == %{
             release_key: "cbe-open-data:4321:2026-08-21:R018.00",
             published_on: ~D[2026-08-21],
             sha256: String.duplicate("a", 64)
           }

    assert bundle.entity == %{
             enterprise_number: "0123456749",
             entity_type: :legal_person,
             registered_name: "Example Brussels, ASBL",
             status: :active
           }

    assert bundle.names == [
             %{
               name: "Example Brussels, ASBL",
               kind: :registered,
               language: "fr",
               effective_from: nil
             },
             %{name: "EB", kind: :abbreviated, language: "nl", effective_from: nil},
             %{
               name: "Example Trading",
               kind: :trading,
               language: "fr",
               effective_from: nil
             }
           ]

    assert bundle.establishment_units == [
             %{
               unit_number: "2123456789",
               name: "Example Brussels Unit",
               status: :active,
               started_on: ~D[2005-04-03]
             }
           ]
  end

  test "marks a natural-person registration so it cannot become a legal entity" do
    assert {:ok, bundle} = OpenData.fetch_enterprise("0474521965")
    assert bundle.entity.entity_type == :natural_person
  end

  test "fails closed for absent entities and incomplete releases" do
    assert {:error, :not_found} = OpenData.fetch_enterprise("0123456789")

    directory = Application.fetch_env!(:brussels_wtf, OpenData)[:directory]
    File.rm!(Path.join(directory, "denomination.csv"))

    assert {:error, {:invalid_cbe_open_data_release, :missing_denomination_csv}} =
             OpenData.fetch_enterprise("0123456749")
  end
end
