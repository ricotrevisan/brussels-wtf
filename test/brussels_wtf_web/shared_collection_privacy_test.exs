defmodule BrusselsWtfWeb.SharedCollectionPrivacyTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "private collection and owner routes conceal resources without a citizen session", %{
    conn: conn
  } do
    for path <- [
          "/collections/private/collection-id",
          "/citizen/collections/collection-id",
          "/citizen/collection-transfers/raw-capability"
        ] do
      response = get(recycle(conn), path)
      assert response.status == 404

      assert get_resp_header(response, "cache-control")
             |> List.first()
             |> String.contains?("no-store")

      assert get_resp_header(response, "x-robots-tag") == ["noindex, nofollow"]
      refute response.resp_body =~ "collection-id"
      refute response.resp_body =~ "raw-capability"
    end
  end

  test "deletion resolution requires authentication and remains private", %{conn: conn} do
    response = get(conn, "/citizen/account/deletion?lang=fr")
    assert response.status == 401

    assert get_resp_header(response, "cache-control")
           |> List.first()
           |> String.contains?("no-store")

    assert get_resp_header(response, "content-language") == ["fr"]
  end

  test "all owner mutations reject an absent citizen session without leaking identifiers", %{
    conn: conn
  } do
    requests = [
      {:post, "/citizen/collections/secret-id/grants", %{"recipient_id" => "other-id"}},
      {:delete, "/citizen/collections/secret-id/grants/grant-id", %{}},
      {:post, "/citizen/collections/secret-id/transfer-offers", %{"recipient_id" => "other-id"}},
      {:delete, "/citizen/collections/secret-id/transfer-offers/offer-id", %{}},
      {:delete, "/citizen/collections/secret-id", %{}},
      {:post, "/citizen/collection-transfers/raw-token/accept", %{}},
      {:post, "/citizen/collection-transfers/raw-token/reject", %{}}
    ]

    for {method, path, params} <- requests do
      response = send_request(recycle(conn), method, path, params)
      assert response.status == 404
      refute response.resp_body =~ "secret-id"
      refute response.resp_body =~ "raw-token"
      refute response.resp_body =~ "other-id"
    end
  end

  defp send_request(conn, :post, path, params), do: post(conn, path, params)
  defp send_request(conn, :delete, path, params), do: delete(conn, path, params)
end
