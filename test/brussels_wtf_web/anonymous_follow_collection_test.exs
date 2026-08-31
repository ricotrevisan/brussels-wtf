defmodule BrusselsWtfWeb.AnonymousFollowCollectionTest do
  use BrusselsWtfWeb.ConnCase, async: false
  alias BrusselsWtf.{Follow, Repo}

  test "view and management capabilities are separate and private fails closed", %{conn: conn} do
    response = post(conn, "/collections", %{})
    [location] = get_resp_header(response, "location")
    secret = location |> String.split("/") |> List.last()
    {:ok, collection} = Follow.manage(secret)

    refute collection.management_secret_hash == secret

    assert html_response(get(conn, "/collections/#{collection.view_token}"), 200) =~
             "no read state"

    assert {:ok, private} = Follow.set_visibility(secret, :private)
    assert private.visibility == :private
    assert response(get(conn, "/collections/#{collection.view_token}"), 404)

    assert response(
             patch(conn, "/collections/manage/not-the-secret", %{visibility: "public"}),
             422
           )
  end

  test "unused anonymous collections expire deterministically" do
    {:ok, collection, _secret} = Follow.create_collection()
    old = DateTime.add(DateTime.utc_now(), -(366 * 24 * 60 * 60), :second)
    collection |> Ecto.Changeset.change(last_used_at: old) |> Repo.update!()
    assert Follow.expire_unused(DateTime.utc_now()) == 1
    refute Repo.get(BrusselsWtf.Follow.Collection, collection.id)
  end
end
