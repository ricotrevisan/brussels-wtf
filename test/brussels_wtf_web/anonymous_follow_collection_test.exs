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

    unpublished_person =
      BrusselsWtf.Identity.record_person!(%{
        legal_name: "Unpublished Collection Person",
        explicit_identifier: "private-collection-person",
        resolution_basis: :explicit_identifier,
        corroborating_facts: %{}
      })

    unpublished_company =
      PublicProfileFixture.company!(%{
        enterprise_number: "0123456848",
        release_key: "unpublished-cbe",
        sha256: "not-a-public-checksum"
      })

    %{
      unpublished_person: unpublished_person,
      unpublished_company: unpublished_company,
      targets: [
        {"dossier", dossier.slug},
        {"person", person.id},
        {"legal_entity", company.enterprise_number},
        {"commune", fixture.commune.slug}
      ]
    }
  end

  test "fragment management capability is reusable and becomes a clean secure session", %{
    conn: conn
  } do
    create = post(conn, "/collections", %{})
    create_body = html_response(create, 200)
    saved_url = Regex.run(~r/id="management-link" href="([^"]+)"/, create_body) |> Enum.at(1)
    assert get_resp_header(create, "location") == []
    %URI{path: bootstrap_path, fragment: "capability=" <> encoded_secret} = URI.parse(saved_url)
    secret = URI.decode_www_form(encoded_secret)
    refute saved_url =~ "?"
    assert get_resp_header(create, "referrer-policy") == ["no-referrer"]

    log =
      capture_log(fn ->
        page = get(recycle(create), bootstrap_path)
        body = html_response(page, 200)
        refute page.request_path =~ secret
        refute body =~ secret
        assert body =~ "history.replaceState"
        assert body =~ ~s(credentials: "same-origin")
        csrf = Regex.run(~r/"x-csrf-token": "([^"]+)"/, body) |> Enum.at(1)

        exchange =
          page
          |> recycle()
          |> put_req_header("x-csrf-token", csrf)
          |> put_req_header("x-follow-capability", secret)
          |> post(bootstrap_path, %{})

        assert response(exchange, 204) == ""
        assert get_resp_header(exchange, "referrer-policy") == ["no-referrer"]

        assert html_response(get(recycle(exchange), "/collections/manage"), 200) =~
                 "Management access"

        # A saved fragment URL restores management after the session cookie is lost.
        second_page = get(build_conn(), bootstrap_path)

        second_csrf =
          Regex.run(~r/"x-csrf-token": "([^"]+)"/, second_page.resp_body) |> Enum.at(1)

        restored =
          second_page
          |> recycle()
          |> put_req_header("x-csrf-token", second_csrf)
          |> put_req_header("x-follow-capability", secret)
          |> post(bootstrap_path, %{})

        assert response(restored, 204) == ""

        assert html_response(get(recycle(restored), "/collections/manage"), 200) =~
                 "Management access"
      end)

    refute log =~ secret
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

  test "private and unverified targets fail closed", %{
    conn: conn,
    unpublished_person: person,
    unpublished_company: company
  } do
    conn = management_session(conn)

    for {type, id} <- [
          {"meeting", "x"},
          {"topic", "x"},
          {"person", Ecto.UUID.generate()},
          {"person", person.id},
          {"legal_entity", company.enterprise_number},
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

  test "Ash policies deny generic reads and require system authority for expiry" do
    {:ok, collection, _secret} = Follow.create_collection(~U[2027-01-01 00:00:00.000000Z])

    assert {:error, %Ash.Error.Forbidden{}} =
             BrusselsWtf.Follow.Collection
             |> Ash.Query.for_read(:read)
             |> Ash.read(authorize?: true, domain: Follow)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.destroy(collection, action: :expire, authorize?: true, domain: Follow)

    assert Follow.expire_unused(~U[2028-01-01 00:00:00.000000Z]) == 1
  end

  test "capability validation is enforced by the Ash exchange action" do
    {:ok, _collection, _secret} = Follow.create_collection()
    assert {:error, :not_found} = Follow.exchange("wrong-capability")
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
    create_body = html_response(create, 200)
    saved_url = Regex.run(~r/id="management-link" href="([^"]+)"/, create_body) |> Enum.at(1)
    uri = URI.parse(saved_url)
    secret = uri.fragment |> String.replace_prefix("capability=", "") |> URI.decode_www_form()
    page = get(recycle(create), uri.path)
    csrf = Regex.run(~r/"x-csrf-token": "([^"]+)"/, page.resp_body) |> Enum.at(1)

    page
    |> recycle()
    |> put_req_header("x-csrf-token", csrf)
    |> put_req_header("x-follow-capability", secret)
    |> post(uri.path, %{})
    |> recycle()
  end

  defp managed_collection(conn) do
    html = html_response(get(recycle(conn), "/collections/manage"), 200)
    [_, token] = Regex.run(~r/href="\/collections\/([^"]+)"/, html)
    {:ok, collection} = Follow.view(token)
    collection
  end
end
