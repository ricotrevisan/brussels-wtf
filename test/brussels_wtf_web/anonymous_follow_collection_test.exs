defmodule BrusselsWtfWeb.AnonymousFollowCollectionTest do
  use BrusselsWtfWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias BrusselsWtf.{Council, Follow}
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

  test "one-time management capability becomes a clean secure session", %{conn: conn} do
    create = post(conn, "/collections", %{})
    [capability_url] = get_resp_header(create, "location")
    %URI{query: query} = URI.parse(capability_url)
    secret = URI.decode_query(query)["secret"]
    assert get_resp_header(create, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(create, "cache-control") == ["no-store"]

    log =
      capture_log(fn ->
        exchange = get(recycle(create), capability_url)
        assert redirected_to(exchange) == "/collections/manage"
        refute inspect(exchange.resp_headers) =~ secret
        refute exchange.resp_body =~ secret
        assert get_resp_header(exchange, "referrer-policy") == ["no-referrer"]
        assert get_resp_header(exchange, "cache-control") == ["no-store"]

        assert html_response(get(recycle(exchange), "/collections/manage"), 200) =~
                 "Management access"
      end)

    refute log =~ secret
    assert response(get(recycle(create), capability_url), 404)
  end

  test "browser manages every eligible public resource through the clean URL", %{
    conn: conn,
    targets: targets
  } do
    conn = management_session(conn)
    management_html = html_response(get(conn, "/collections/manage"), 200)
    refute management_html =~ "secret="
    refute management_html =~ "textarea"

    conn =
      Enum.reduce(targets, conn, fn {type, identifier}, conn ->
        response =
          post(recycle(conn), "/collections/manage/members", %{
            target_type: type,
            target_identifier: to_string(identifier)
          })

        assert redirected_to(response) == "/collections/manage"
        response
      end)

    manage = get(recycle(conn), "/collections/manage")

    public_url =
      manage.resp_body |> then(&Regex.run(~r/href="(\/collections\/[^"]+)"/, &1)) |> Enum.at(1)

    public_html = html_response(get(recycle(manage), public_url), 200)
    Enum.each(targets, fn {_, identifier} -> assert public_html =~ to_string(identifier) end)
    refute public_html =~ "Management access"

    conn =
      Enum.reduce(targets, manage, fn {type, identifier}, conn ->
        response =
          delete(recycle(conn), "/collections/manage/members", %{
            target_type: type,
            target_identifier: to_string(identifier)
          })

        assert redirected_to(response) == "/collections/manage"
        response
      end)

    refute html_response(get(recycle(conn), public_url), 200) =~ "collection-dossier"
  end

  test "view, invalid session, and another collection cannot mutate", %{
    conn: conn,
    targets: [{type, id} | _]
  } do
    owner_a = management_session(conn)
    owner_b = management_session(build_conn())

    assert redirected_to(
             post(recycle(owner_a), "/collections/manage/members", %{
               target_type: type,
               target_identifier: to_string(id)
             })
           ) == "/collections/manage"

    refute html_response(get(recycle(owner_b), "/collections/manage"), 200) =~ to_string(id)

    assert response(
             post(build_conn(), "/collections/manage/members", %{
               target_type: type,
               target_identifier: to_string(id)
             }),
             422
           )
  end

  test "private and unverified targets fail closed", %{conn: conn} do
    conn = management_session(conn)

    for {type, id} <- [
          {"meeting", "x"},
          {"topic", "x"},
          {"person", Ecto.UUID.generate()},
          {"legal_entity", "0123456749-not-canonical"},
          {"dossier", "missing"},
          {"commune", "missing"}
        ] do
      assert response(
               post(recycle(conn), "/collections/manage/members", %{
                 target_type: type,
                 target_identifier: id
               }),
               422
             )
    end
  end

  test "visibility fails closed and every management use refreshes last_used_at", %{conn: conn} do
    conn = management_session(conn)
    first = managed_collection(conn)
    later = DateTime.add(first.last_used_at, 60, :second)
    assert {:ok, touched} = Follow.manage_session(first.id, later)
    assert touched.last_used_at == later

    assert redirected_to(patch(recycle(conn), "/collections/manage", %{visibility: "private"})) ==
             "/collections/manage"

    assert response(get(recycle(conn), "/collections/#{first.view_token}"), 404)
  end

  test "calendar expiry includes the exact twelve-month boundary" do
    now = ~U[2028-02-29 12:00:00.000000Z]
    anniversary = ~U[2029-02-28 12:00:00.000000Z]
    {:ok, before, _} = Follow.create_collection(DateTime.add(now, 1, :day))
    {:ok, boundary, _} = Follow.create_collection(now)
    assert Follow.expire_unused(anniversary) == 1
    assert {:error, :not_found} = Follow.manage_session(boundary.id, anniversary)
    assert {:ok, _} = Follow.manage_session(before.id, anniversary)
  end

  test "unsafe mutation without CSRF is rejected" do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      Plug.Test.conn(
        :post,
        "/collections/manage/members",
        "target_type=commune&target_identifier=ixelles"
      )
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> BrusselsWtfWeb.Endpoint.call([])
    end
  end

  defp management_session(conn) do
    create = post(conn, "/collections", %{})
    exchange = get(recycle(create), redirected_to(create))
    assert redirected_to(exchange) == "/collections/manage"
    recycle(exchange)
  end

  defp managed_collection(conn) do
    html = html_response(get(recycle(conn), "/collections/manage"), 200)
    [_, token] = Regex.run(~r/href="\/collections\/([^"]+)"/, html)
    {:ok, collection} = Follow.view(token)
    collection
  end
end
