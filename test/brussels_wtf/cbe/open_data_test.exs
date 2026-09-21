defmodule BrusselsWtf.CBE.OpenDataTest do
  use ExUnit.Case, async: false

  alias BrusselsWtf.CBE.OpenData

  setup do
    directory = BrusselsWtf.CBE.OpenDataFixture.write_release()

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

  test "quoted multiline names retain the original line-reader CRLF to LF normalization" do
    directory = Application.fetch_env!(:brussels_wtf, OpenData)[:directory]
    BrusselsWtf.CBE.OpenDataFixture.add_edge_cases(directory)
    assert File.read!(Path.join(directory, "denomination.csv")) =~ "Duplicate registered\r\nwith"

    assert {:ok, bundle} = OpenData.fetch_enterprise("0123456749")
    assert Enum.at(bundle.names, 3).name == "Duplicate registered\nwith \"quotes\""
  end

  test "marks a natural-person registration so it cannot become a legal entity" do
    assert {:ok, bundle} = OpenData.fetch_enterprise("0474521921")
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
