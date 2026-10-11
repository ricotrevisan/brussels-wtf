defmodule BrusselsWtf.IdentityPublicMandatesTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Identity
  alias BrusselsWtf.MunicipalInstallationArchiveFixture, as: Fixture
  alias Identity.MunicipalInstallation
  alias Identity.PublicProjection

  @slugs ~w(ixelles uccle forest city-of-brussels)

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    :ok
  end

  test "mandate pages slice the full projection without overlap or loss" do
    seed_mandates!()
    commune_ids = commune_ids!(@slugs)

    %{mandates: full, more?: false} = PublicProjection.mandate_page!(commune_ids, "", 0, 100)
    assert length(full) >= 7

    pages = slice_pages!(commune_ids, "", 5)
    assert length(pages) > 1
    assert Enum.all?(Enum.slice(pages, 0..-2//1), &(length(&1.mandates) == 5))

    sliced = Enum.flat_map(pages, fn page -> Enum.map(page.mandates, & &1.fact_id) end)
    assert sliced == Enum.map(full, & &1.fact_id)
  end

  test "search filters every page and commune ids bound the results" do
    seed_mandates!()
    commune_ids = commune_ids!(@slugs)

    %{mandates: full} = PublicProjection.mandate_page!(commune_ids, "", 0, 100)

    needle =
      full
      |> hd()
      |> Map.fetch!(:subject_name)
      |> String.downcase()
      |> String.slice(0, 4)

    searched =
      commune_ids
      |> slice_pages!(needle, 2)
      |> Enum.flat_map(& &1.mandates)

    assert searched != []
    assert length(searched) < length(full)

    assert Enum.all?(searched, &String.contains?(String.downcase(&1.subject_name), needle))

    [forest_id] = commune_ids!(["forest"])

    %{mandates: forest_only, more?: false} =
      PublicProjection.mandate_page!([forest_id], "", 0, 100)

    assert forest_only != []
    assert Enum.all?(forest_only, &(&1.object_name == "Forest"))
  end

  test "the directory returns one default-size page and clamps page numbers" do
    seed_mandates!()

    %{mandates: first_page, more?: more?} = Identity.list_public_mandates!(@slugs)
    assert first_page != []
    assert length(first_page) < 25
    refute more?

    assert %{mandates: [], more?: false} = Identity.list_public_mandates!(@slugs, "", 2)

    assert %{mandates: mandates_again, more?: false} =
             Identity.list_public_mandates!(@slugs, "", 0)

    assert Enum.map(mandates_again, & &1.fact_id) == Enum.map(first_page, & &1.fact_id)

    named = Identity.list_public_mandates!(@slugs, "nobody-named-this")
    assert named.mandates == []
    refute named.more?
  end

  defp seed_mandates! do
    for slug <- @slugs, do: Fixture.load!(slug)

    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    assert {:ok, reports} =
             MunicipalInstallation.publish(@slugs, actor: actor, max_facts_per_commune: 3)

    assert Enum.all?(reports, &(&1.published_new >= 2))
  end

  defp commune_ids!(slugs) do
    slugs
    |> Enum.map(&BrusselsWtf.Ingestion.get_commune_by_slug!(&1))
    |> Enum.map(& &1.id)
  end

  defp slice_pages!(commune_ids, search, per_page) do
    slice_pages!(commune_ids, search, 0, per_page, [])
  end

  defp slice_pages!(commune_ids, search, offset, per_page, acc) do
    page = PublicProjection.mandate_page!(commune_ids, search, offset, per_page)

    cond do
      page.mandates == [] -> Enum.reverse(acc)
      page.more? -> slice_pages!(commune_ids, search, offset + per_page, per_page, [page | acc])
      true -> Enum.reverse([page | acc])
    end
  end
end
