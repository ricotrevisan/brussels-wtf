defmodule BrusselsWtf.SuggestionsTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Review.Suggestion
  alias BrusselsWtf.Review.SuggestionDecision
  alias BrusselsWtf.Suggestions

  @now ~U[2024-01-01 12:00:00Z]
  @secret String.duplicate("suggestion-rate-limit-secret-", 2)
  @reviewer %Actor{id: "rico", role: :reviewer}
  @number "0123456749"

  setup do
    previous = Application.fetch_env!(:brussels_wtf, :suggestions)
    BrusselsWtf.Clock.Controlled.set(@now)
    Application.put_env(:brussels_wtf, :suggestions, suggestion_config())
    company = create_company!()
    on_exit(fn -> Application.put_env(:brussels_wtf, :suggestions, previous) end)
    {:ok, company: company}
  end

  test "intake requires an eligible closed public profile and keeps the case free of private text",
       %{company: company} do
    assert {:error, :invalid_submission} =
             submit("0000000097", "Invalid subject text", "192.0.2.10")

    assert {:error, :invalid_submission} = submit(@number, "short", "192.0.2.10")

    assert {:ok, :accepted} =
             submit(@number, "Private ownership lead", "192.0.2.10", "tip@example.test")

    suggestion = only_suggestion!()
    assert_final_states!()
    assert suggestion.subject_id == company.id
    assert suggestion.body == "Private ownership lead"
    assert suggestion.contact == "tip@example.test"
    assert byte_size(suggestion.rate_limit_key) == 64
    refute suggestion.rate_limit_key =~ "192.0.2.10"
    assert suggestion.anti_abuse_retention_deadline == ~U[2024-01-03 12:00:00.000000Z]

    review_case = Review.get_review_case!(suggestion.review_case_id, actor: @reviewer)
    refute inspect(Map.from_struct(review_case)) =~ suggestion.body
    refute inspect(Map.from_struct(review_case)) =~ suggestion.contact
    assert {:ok, loaded} = Suggestions.get_for_review_case(review_case.id, @reviewer)
    assert loaded.body == suggestion.body
  end

  test "raw inserts must start as complete pending leads with policy-bounded retention", %{
    company: company
  } do
    assert_raise Postgrex.Error, ~r/complete pending private leads/, fn ->
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        """
        INSERT INTO review_suggestions
          (id, kind, subject_type, subject_id, body, rate_limit_key, submission_fingerprint,
           status, decided_by, decided_at, decision_reason_code,
           body_retention_deadline, contact_retention_deadline,
           anti_abuse_retention_deadline, fingerprint_retention_deadline, inserted_at)
        VALUES
          (uuid_generate_v7(), 'ownership', 'legal_entity', $1::text::uuid,
           'A complete raw ownership lead', 'hmac-rate', 'hmac-fingerprint',
           'rejected', 'forger', clock_timestamp(), 'forged',
           clock_timestamp() + interval '365 days', clock_timestamp() + interval '90 days',
           clock_timestamp() + interval '48 hours', clock_timestamp() + interval '730 days',
           clock_timestamp())
        """,
        [company.id]
      )
    end
  end

  test "honeypot is visually hidden and indistinguishably accepted without storage" do
    assert %{class: "sr-only", name: "website", tabindex: "-1"} =
             Suggestions.honeypot_attributes()

    assert {:ok, :accepted} =
             Suggestions.submit(
               %{
                 kind: :ownership,
                 subject_type: :legal_entity,
                 subject_reference: "bad",
                 body: "bad",
                 website: "spam"
               },
               client_address: "not-even-an-ip"
             )

    assert list_suggestions!() == []
  end

  test "rate limiting canonicalizes IPs and stores only rotating HMAC values" do
    assert {:ok, "2001:db8::1"} = Suggestions.canonical_client_address("2001:0db8:0:0:0:0:0:1")

    assert {:error, :invalid_submission} =
             Suggestions.canonical_client_address("forwarded garbage")

    assert {:ok, :accepted} = submit(@number, "ownership one", {203, 0, 113, 8})
    assert {:ok, :accepted} = submit(@number, "ownership two", "203.0.113.8")
    assert {:error, :rate_limited} = submit(@number, "ownership three", "203.0.113.8")
    assert Enum.all?(list_suggestions!(), &(&1.rate_limit_key != "203.0.113.8"))
  end

  test "rejection is one-way, audited, shortens contact retention, resolves its case, and suppresses repeats" do
    assert {:ok, :accepted} =
             submit(@number, "Unsupported owner", "192.0.2.11", "private@example.test")

    suggestion = only_suggestion!()

    assert {:ok, rejected} =
             Suggestions.reject(
               suggestion.id,
               %{reason_code: "unsupported", note: "No official act."},
               @reviewer
             )

    assert rejected.status == :rejected
    assert rejected.contact_retention_deadline == ~U[2024-01-31 12:00:00.000000Z]

    assert Review.get_review_case!(rejected.review_case_id, actor: @reviewer).disposition ==
             :suggestion_rejected

    assert [%{action: :reject, note: "No official act."}] = decisions(rejected.id)
    assert_final_states!()

    assert {:error, :already_decided} =
             Suggestions.reject(rejected.id, %{reason_code: "again", note: "Again"}, @reviewer)

    assert {:ok, :accepted} = submit(@number, "Unsupported owner", "192.0.2.12")
    assert length(list_suggestions!()) == 1
  end

  test "concurrent moderation has one winner and one immutable decision" do
    assert {:ok, :accepted} = submit(@number, "Race ownership lead", "192.0.2.13")
    suggestion = only_suggestion!()

    tasks =
      for actor_id <- ["one", "two"] do
        Task.async(fn ->
          Suggestions.reject(
            suggestion.id,
            %{reason_code: "race", note: "Reviewer #{actor_id}"},
            %Actor{id: actor_id, role: :reviewer}
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_decided})) == 1
    assert length(decisions(suggestion.id)) == 1
  end

  test "a standalone raw decision update fails the deferred final-state invariant" do
    assert {:ok, :accepted} = submit(@number, "Incomplete raw moderation", "192.0.2.17")
    suggestion = only_suggestion!()

    Ecto.Adapters.SQL.query!(
      BrusselsWtf.Repo,
      "UPDATE review_suggestions SET status = 'rejected', decided_by = 'forger', decided_at = clock_timestamp(), decision_reason_code = 'forged' WHERE id = $1::text::uuid",
      [suggestion.id]
    )

    assert_raise Postgrex.Error, ~r/rejected suggestion final state is incomplete/, fn ->
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        "SET CONSTRAINTS review_suggestion_final_state IMMEDIATE",
        []
      )
    end
  end

  test "generic case actions and direct audit mutation cannot bypass suggestion lifecycle" do
    assert {:ok, :accepted} = submit(@number, "Bypass lead", "192.0.2.14")
    suggestion = only_suggestion!()
    review_case = Review.get_review_case!(suggestion.review_case_id, actor: @reviewer)

    assert_raise Ash.Error.Invalid, ~r/retention-aware moderation audit/, fn ->
      Review.add_review_note!(%{review_case_id: review_case.id, body: "unbounded private note"},
        actor: @reviewer
      )
    end

    assert_raise Postgrex.Error, ~r/retention-aware moderation audit/, fn ->
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        "INSERT INTO review_notes (id, actor_id, body, inserted_at, review_case_id) VALUES (uuid_generate_v7(), 'forger', 'raw private note', clock_timestamp(), $1::text::uuid)",
        [review_case.id]
      )
    end

    assert_raise Postgrex.Error, ~r/body can only be redacted/, fn ->
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        "UPDATE review_suggestions SET body = 'Forged semantic replacement' WHERE id = $1::text::uuid",
        [suggestion.id]
      )
    end

    assert_raise Ash.Error.Invalid, ~r/dedicated moderation workflow/, fn ->
      Review.mark_review_case_unsupported!(review_case, %{note: "bypass", reason_code: "x"},
        actor: @reviewer
      )
    end

    assert {:ok, _} =
             Suggestions.reject(suggestion.id, %{reason_code: "no", note: "No"}, @reviewer)

    [decision] = decisions(suggestion.id)

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        "UPDATE review_suggestion_decisions SET reason_code = 'forged' WHERE id = $1::text::uuid",
        [decision.id]
      )
    end

    assert_raise Postgrex.Error, ~r/audit records/, fn ->
      Ecto.Adapters.SQL.query!(
        BrusselsWtf.Repo,
        "DELETE FROM review_suggestions WHERE id = $1::text::uuid",
        [
          suggestion.id
        ]
      )
    end
  end

  test "approval fails closed for missing, unverified, unrelated, or unsupported ownership facts" do
    assert {:ok, :accepted} = submit(@number, "Possible owner", "192.0.2.15")
    suggestion = only_suggestion!()
    assert Suggestions.approval_available?(:ownership) == false

    assert {:error, :fact_not_verified_or_matching} =
             Suggestions.approve(suggestion.id, Ecto.UUID.generate(), "checked", @reviewer)

    assert get_suggestion!(suggestion.id).status == :pending
    assert Identity.list_public_relationships!() == []
  end

  test "scheduled bounded purge removes each private class at its deadline and keeps disposition audit" do
    assert {:ok, :accepted} = submit(@number, "Purge lead", "192.0.2.16", "private@example.test")
    suggestion = only_suggestion!()

    assert {:ok, _} =
             Suggestions.reject(
               suggestion.id,
               %{reason_code: "no", note: "Private note"},
               @reviewer
             )

    BrusselsWtf.Clock.Controlled.set(~U[2026-01-10 12:00:00Z])
    assert :ok = perform_job(BrusselsWtf.Workers.PurgeSuggestions, %{})

    purged = get_suggestion!(suggestion.id)
    assert purged.body == nil
    assert purged.contact == nil
    assert purged.rate_limit_key == nil
    assert purged.submission_fingerprint == nil
    assert purged.private_data_purged_at == ~U[2026-01-10 12:00:00.000000Z]

    assert [%{action: :reject, reason_code: "no", note: nil, note_purged_at: note_time}] =
             decisions(suggestion.id)

    assert note_time
  end

  test "purge worker loops for a bounded number of batches without self-conflicting continuation" do
    put_suggestion_config(purge_batch_size: 1, purge_max_batches_per_job: 2)

    for n <- 1..3 do
      assert {:ok, :accepted} =
               submit(@number, "Bounded purge lead #{n}", "192.0.2.#{100 + n}")
    end

    BrusselsWtf.Clock.Controlled.set(~U[2026-01-10 12:00:00Z])
    assert :ok = perform_job(BrusselsWtf.Workers.PurgeSuggestions, %{})

    assert Enum.count(list_suggestions!(), &(!is_nil(&1.body))) == 1
    assert all_enqueued(worker: BrusselsWtf.Workers.PurgeSuggestions) == []
  end

  test "populated suggestion migration refuses destructive rollback" do
    Code.require_file("priv/repo/migrations/20260829153403_issue_30_private_suggestions.exs")

    assert_raise RuntimeError, ~r/intentionally irreversible/, fn ->
      apply(BrusselsWtf.Repo.Migrations.Issue30PrivateSuggestions, :down, [])
    end
  end

  test "configuration enforces secret and hard privacy maxima" do
    put_suggestion_config(rate_limit_secret: nil)
    assert_raise ArgumentError, ~r/rate limit secret/, &Suggestions.validate_configuration!/0
    put_suggestion_config(rate_limit_secret: @secret, body_min_length: 9)
    assert_raise ArgumentError, ~r/10..10000/, &Suggestions.validate_configuration!/0
    put_suggestion_config(body_min_length: 10, anti_abuse_retention_seconds: 172_801)
    assert_raise ArgumentError, ~r/48 hours/, &Suggestions.validate_configuration!/0
    put_suggestion_config(anti_abuse_retention_seconds: 172_800, body_retention_days: 366)
    assert_raise ArgumentError, ~r/body retention exceeds/, &Suggestions.validate_configuration!/0
    put_suggestion_config(body_retention_days: 365, fingerprint_retention_days: 731)

    assert_raise ArgumentError,
                 ~r/fingerprint retention exceeds/,
                 &Suggestions.validate_configuration!/0

    put_suggestion_config(fingerprint_retention_days: 730, decision_note_retention_days: 366)

    assert_raise ArgumentError,
                 ~r/decision note retention exceeds/,
                 &Suggestions.validate_configuration!/0

    put_suggestion_config(decision_note_retention_days: 365, contact_retention_days: 91)
    assert_raise ArgumentError, ~r/contact retention/, &Suggestions.validate_configuration!/0
  end

  defp create_company! do
    release =
      Identity.record_cbe_release!(%{
        release_key: "suggestions-fixture",
        published_on: ~D[2024-01-01],
        sha256: String.duplicate("a", 64),
        source_kind: :open_data
      })

    Identity.upsert_legal_entity!(%{
      enterprise_number: @number,
      registered_name: "Eligible Company",
      status: :active,
      cbe_release_id: release.id
    })
  end

  defp submit(number, body, address, contact \\ nil) do
    Suggestions.submit(
      %{
        kind: :ownership,
        subject_type: :legal_entity,
        subject_reference: number,
        body: body,
        contact: contact,
        website: ""
      },
      client_address: address
    )
  end

  defp suggestion_config do
    [
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
    ]
  end

  defp list_suggestions!,
    do: Suggestion |> Ash.Query.for_read(:read) |> Ash.read!(actor: @reviewer, domain: Review)

  defp only_suggestion!, do: List.first(list_suggestions!()) || flunk("missing suggestion")

  defp get_suggestion!(id),
    do:
      Suggestion |> Ash.Query.filter(id == ^id) |> Ash.read_one!(actor: @reviewer, domain: Review)

  defp decisions(id),
    do:
      SuggestionDecision
      |> Ash.Query.filter(suggestion_id == ^id)
      |> Ash.read!(actor: @reviewer, domain: Review)

  defp assert_final_states! do
    Ecto.Adapters.SQL.query!(
      BrusselsWtf.Repo,
      "SET CONSTRAINTS review_suggestion_final_state IMMEDIATE",
      []
    )

    Ecto.Adapters.SQL.query!(
      BrusselsWtf.Repo,
      "SET CONSTRAINTS review_suggestion_final_state DEFERRED",
      []
    )

    :ok
  end

  defp put_suggestion_config(overrides),
    do:
      Application.put_env(
        :brussels_wtf,
        :suggestions,
        Keyword.merge(Application.fetch_env!(:brussels_wtf, :suggestions), overrides)
      )
end
