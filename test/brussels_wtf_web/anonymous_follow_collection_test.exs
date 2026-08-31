defmodule BrusselsWtfWeb.AnonymousFollowCollectionTest do
  use BrusselsWtfWeb.ConnCase, async: false
  alias BrusselsWtf.{Council, Follow, Repo}
  alias BrusselsWtf.Test.PublicProfileFixture

  setup do
    fixture = PublicProfileFixture.load!(["Collection Person"])
    %{person: person} = PublicProfileFixture.publish_person!(fixture, "Collection Person", 1)

    company =
      PublicProfileFixture.company!(%{
        enterprise_number: "0123456749",
        release_key: "collection-cbe",
        sha256: String.duplicate("c", 64)
      })

    dossier =
      Council.create_dossier!(%{
        slug: "collection-dossier",
        title: "Collection dossier",
        localized_titles: %{}
      })

    %{
      targets: [
        {"dossier", dossier.slug},
        {"person", person.id},
        {"legal_entity", company.enterprise_number},
        {"commune", fixture.commune.slug}
      ]
    }
  end

  test "browser manages every allowed public resource while the view capability is read-only", %{
    conn: conn,
    targets: targets
  } do
    response = post(conn, "/collections", %{})
    [management_url] = get_resp_header(response, "location")
    secret = management_url |> String.split("/") |> List.last()
    {:ok, collection} = Follow.manage(secret)
    public_url = "/collections/#{collection.view_token}"

    management_html = html_response(get(conn, management_url), 200)
    assert management_html =~ ~s(<form action="" method="post")
    assert management_html =~ ~s(<form action="members" method="post")
    refute management_html =~ secret
    refute management_html =~ "textarea"

    Enum.each(targets, fn {type, identifier} ->
      assert redirected_to(
               post(conn, management_url <> "/members", %{
                 target_type: type,
                 target_identifier: identifier
               })
             ) == management_url
    end)

    public_html = html_response(get(conn, public_url), 200)
    Enum.each(targets, fn {_type, identifier} -> assert public_html =~ to_string(identifier) end)
    refute public_html =~ "Management access"
    refute public_html =~ "notifications" <> " history"

    # A public view capability cannot mutate membership or visibility.
    assert response(
             post(conn, "/collections/manage/#{collection.view_token}/members", %{
               target_type: "commune",
               target_identifier: "ixelles"
             }),
             422
           )

    assert response(
             patch(conn, "/collections/manage/#{collection.view_token}", %{visibility: "public"}),
             422
           )

    assert redirected_to(patch(conn, management_url, %{visibility: "public"})) == management_url
    assert html_response(get(conn, public_url), 200) =~ to_string(Enum.at(targets, 1) |> elem(1))
    assert redirected_to(patch(conn, management_url, %{visibility: "unlisted"})) == management_url
    unlisted = get(conn, public_url)
    assert html_response(unlisted, 200) =~ "collection-dossier"
    assert get_resp_header(unlisted, "x-robots-tag") == ["noindex, nofollow"]
    assert redirected_to(patch(conn, management_url, %{visibility: "private"})) == management_url
    assert response(get(conn, public_url), 404)

    assert redirected_to(patch(conn, management_url, %{visibility: "unlisted"})) == management_url

    Enum.each(targets, fn {type, identifier} ->
      assert redirected_to(
               delete(conn, management_url <> "/members", %{
                 target_type: type,
                 target_identifier: to_string(identifier)
               })
             ) == management_url
    end)

    refute html_response(get(conn, public_url), 200) =~ "collection-dossier"
  end

  test "unused anonymous collections expire deterministically" do
    {:ok, collection, _secret} = Follow.create_collection()
    old = DateTime.add(DateTime.utc_now(), -(366 * 24 * 60 * 60), :second)
    collection |> Ecto.Changeset.change(last_used_at: old) |> Repo.update!()
    assert Follow.expire_unused(DateTime.utc_now()) == 1
    refute Repo.get(BrusselsWtf.Follow.Collection, collection.id)
  end
end
