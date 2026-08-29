defmodule BrusselsWtfWeb.SuggestionHTTPTest do
  use BrusselsWtfWeb.ConnCase, async: false

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Review.Suggestion
  alias BrusselsWtf.Suggestions

  @number "0123456749"
  @secret String.duplicate("http-suggestion-secret-", 2)

  setup %{conn: conn} do
    previous = Application.fetch_env!(:brussels_wtf, :suggestions)

    Application.put_env(:brussels_wtf, :suggestions,
      enabled: true,
      rate_limit_secret: @secret,
      trusted_proxies: [],
      rate_limit_window_seconds: 3_600,
      rate_limit_max_submissions: 2,
      body_min_length: 10,
      body_max_bytes: 10_000,
      body_retention_days: 365,
      contact_retention_days: 90,
      decided_contact_retention_days: 30,
      anti_abuse_retention_seconds: 172_800,
      fingerprint_retention_days: 730,
      decision_note_retention_days: 365,
      purge_batch_size: 100,
      purge_max_batches_per_job: 10
    )

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-29 12:00:00Z])
    company = create_company!()
    on_exit(fn -> Application.put_env(:brussels_wtf, :suggestions, previous) end)
    {:ok, conn: %{conn | remote_ip: {203, 0, 113, 40}}, company: company}
  end

  test "enabled form is bound to an eligible profile and contains the hidden honeypot", %{
    conn: conn
  } do
    body = conn |> get("/companies/#{@number}") |> html_response(200)
    assert body =~ "Eligible HTTP Company"
    assert body =~ ~s(action="/companies/#{@number}/suggestions/ownership")
    assert body =~ ~s(name="website")
    assert body =~ ~s(class="sr-only")
    refute body =~ @secret

    assert conn
           |> recycle()
           |> get("/companies/#{@number}/suggestions/ownership")
           |> html_response(404)
  end

  test "real, invalid, duplicate, honeypot, and rate-limited posts have one generic response", %{
    conn: conn
  } do
    paths_and_params = [
      {"/companies/#{@number}/suggestions/ownership",
       %{"body" => "A real lead", "contact" => "private@example.test", "website" => ""}},
      {"/companies/0000000097/suggestions/ownership",
       %{"body" => "Invalid subject", "website" => ""}},
      {"/companies/#{@number}/suggestions/ownership",
       %{"body" => "bot", "website" => "https://spam.test"}},
      {"/companies/#{@number}/suggestions/ownership",
       %{"body" => "A real lead", "website" => ""}},
      {"/companies/#{@number}/suggestions/ownership",
       %{"body" => "Second lead", "website" => ""}},
      {"/companies/#{@number}/suggestions/ownership",
       %{"body" => "Rate limited", "website" => ""}}
    ]

    responses =
      Enum.map(paths_and_params, fn {path, params} ->
        response = post(recycle(conn), path, params)
        {response.status, response.resp_body}
      end)

    assert length(Enum.uniq(responses)) == 1
    assert [{202, body}] = Enum.uniq(responses)
    assert body =~ "Thank you"
    refute body =~ "private@example.test"
    refute body =~ "A real lead"

    french =
      post(recycle(conn), "/companies/#{@number}/suggestions/ownership?lang=fr", %{
        "body" => "A French lead",
        "website" => ""
      })

    assert french.status == 202
    assert french.resp_body =~ "Merci"
    refute french.resp_body =~ "Thank you"
  end

  test "disabled feature returns not found for form and intake", %{conn: conn} do
    put_config(enabled: false)
    profile = get(conn, "/companies/#{@number}")
    body = html_response(profile, 200)
    refute body =~ "<form"

    assert response(
             post(recycle(conn), "/companies/#{@number}/suggestions/ownership", %{
               "body" => "lead"
             }),
             404
           ) == "Not found"
  end

  test "intake rejects a browser post without CSRF", %{conn: conn} do
    form = get(conn, "/companies/#{@number}")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      form
      |> recycle()
      |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
      |> post("/companies/#{@number}/suggestions/ownership", %{"body" => "lead"})
    end
  end

  test "client address ignores spoofed forwarding and uses a trusted right-to-left chain", %{
    conn: conn
  } do
    spoofed = put_req_header(conn, "x-forwarded-for", "198.51.100.1")
    assert BrusselsWtfWeb.SuggestionClientAddress.get(spoofed) == "203.0.113.40"

    put_config(trusted_proxies: ["203.0.113.40", "203.0.113.41"])
    trusted = put_req_header(conn, "x-forwarded-for", "198.51.100.9, 203.0.113.41")
    assert BrusselsWtfWeb.SuggestionClientAddress.get(trusted) == "198.51.100.9"

    malformed = put_req_header(recycle(conn), "x-forwarded-for", "not-an-ip")
    assert BrusselsWtfWeb.SuggestionClientAddress.get(malformed) == "203.0.113.40"
  end

  test "review panel is authenticated, shows private values, omits generic lifecycle actions, and rejects",
       %{conn: conn} do
    assert {:ok, :accepted} =
             Suggestions.submit(
               %{
                 kind: :ownership,
                 subject_type: :legal_entity,
                 subject_reference: @number,
                 body: "Panel private body",
                 contact: "panel@example.test",
                 website: ""
               },
               client_address: "192.0.2.55"
             )

    suggestion = only_suggestion!()
    path = "/review/cases/#{suggestion.review_case_id}"
    assert redirected_to(get(conn, path)) == "/review/login"

    actor = %Actor{id: "rico", role: :reviewer}
    reviewer = conn |> init_test_session(%{}) |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
    panel = get(reviewer, path)
    body = html_response(panel, 200)
    assert body =~ "Panel private body"
    assert body =~ "panel@example.test"
    assert body =~ "Reject lead"
    refute body =~ "Retry uses"
    refute body =~ ~s(action="/review/cases/#{suggestion.review_case_id}/notes")
    refute body =~ suggestion.rate_limit_key

    response =
      post(recycle(panel), "#{path}/suggestion/reject", %{
        "reason_code" => "unsupported",
        "note" => "No source"
      })

    assert redirected_to(response) == path
    assert {:ok, private} = Suggestions.get_for_review_case(suggestion.review_case_id, actor)
    assert private.status == :rejected
    assert Review.get_review_case!(suggestion.review_case_id, actor: actor).status == :resolved
  end

  defp create_company! do
    release =
      Identity.record_cbe_release!(%{
        release_key: "suggestion-http",
        published_on: ~D[2026-08-29],
        sha256: String.duplicate("b", 64),
        source_kind: :open_data
      })

    Identity.upsert_legal_entity!(%{
      enterprise_number: @number,
      registered_name: "Eligible HTTP Company",
      status: :active,
      cbe_release_id: release.id
    })
  end

  defp only_suggestion!,
    do:
      Suggestion
      |> Ash.Query.for_read(:read)
      |> Ash.read!(actor: %Actor{id: "rico", role: :reviewer}, domain: Review)
      |> List.first()

  defp put_config(overrides),
    do:
      Application.put_env(
        :brussels_wtf,
        :suggestions,
        Keyword.merge(Application.fetch_env!(:brussels_wtf, :suggestions), overrides)
      )
end
