defmodule BrusselsWtf.Suggestions do
  @moduledoc """
  Private anonymous intake and one-way reviewer moderation for ownership and corrections.

  Suggestion text is only a lead. Approval references a current fact that was
  independently verified by the trusted verifier registry. It never verifies,
  publishes, or marks content human-reviewed.
  """

  require Ash.Query

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.SourcedFact
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Suggestion
  alias BrusselsWtf.Review.SuggestionDecision

  @accepted {:ok, :accepted}
  @default_batch_size 100

  def honeypot_attributes do
    %{
      name: "website",
      class: "sr-only",
      aria_hidden: "true",
      tabindex: "-1",
      autocomplete: "off"
    }
  end

  def enabled?, do: config!()[:enabled] == true
  def approval_available?(:ownership), do: Identity.TrustedVerifier.available_for?(:ownership)
  def approval_available?(:correction), do: Identity.TrustedVerifier.available?()
  def approval_available?(_kind), do: false

  def get_for_review_case(case_id, actor) do
    with :ok <- reviewer(actor),
         {:ok, case_id} <- cast_uuid(case_id) do
      Suggestion
      |> Ash.Query.filter(review_case_id == ^case_id)
      |> Ash.Query.load(:decisions)
      |> Ash.read_one(actor: actor, domain: Review)
      |> case do
        {:ok, nil} -> {:error, :not_found}
        result -> result
      end
    end
  end

  @doc "Accept an anonymous suggestion without returning its private record."
  def submit(attrs, opts) when is_map(attrs) and is_list(opts) do
    config = config!()

    with :ok <- enabled(config) do
      if filled?(value(attrs, :website)) do
        @accepted
      else
        with :ok <- validate_configuration(config),
             {:ok, input} <- normalize_input(attrs),
             {:ok, client_address} <- canonical_client_address(Keyword.get(opts, :client_address)) do
          store_submission(input, client_address, config)
        end
      end
    end
  end

  @doc "Return a canonical IP literal or reject non-IP input."
  def canonical_client_address({_, _, _, _} = address),
    do: {:ok, address |> :inet.ntoa() |> to_string()}

  def canonical_client_address({_, _, _, _, _, _, _, _} = address),
    do: {:ok, address |> :inet.ntoa() |> to_string()}

  def canonical_client_address(address) when is_binary(address) do
    address
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, parsed} -> canonical_client_address(parsed)
      {:error, _} -> {:error, :invalid_submission}
    end
  end

  def canonical_client_address(_), do: {:error, :invalid_submission}

  @doc "Reject through the authenticated, append-only moderation workflow."
  def reject(id, attrs, actor) when is_map(attrs) do
    with :ok <- reviewer(actor),
         {:ok, reason_code} <- required_text(value(attrs, :reason_code), 100),
         {:ok, note} <- required_text(value(attrs, :note), 2_000) do
      moderate(id, :reject, nil, reason_code, note, actor)
    end
  end

  @doc "Close a lead by referencing an independently verified, matching fact."
  def approve(id, verified_fact_id, note, actor) do
    with :ok <- reviewer(actor),
         {:ok, fact_id} <- cast_uuid(verified_fact_id),
         {:ok, note} <- required_text(note, 2_000) do
      moderate(id, :approve, fact_id, "verified_fact_referenced", note, actor)
    end
  end

  @doc "Close an item correction by referencing its independently published corrected revision."
  def address(id, publication_revision_id, note, actor) do
    with :ok <- reviewer(actor),
         {:ok, revision_id} <- cast_uuid(publication_revision_id),
         {:ok, note} <- required_text(note, 2_000) do
      moderate(id, :address, revision_id, "addressed_in_publication_revision", note, actor)
    end
  end

  @doc "Purge all due private values from one suggestion and its decision note."
  def purge_expired(id) do
    now = BrusselsWtf.Clock.utc_now()

    case BrusselsWtf.Repo.transaction(fn ->
           with {:ok, suggestion} <- lock_suggestion(id) do
             {purged, notifications} = purge_suggestion!(suggestion, now)
             note_notifications = purge_decision_note_for!(suggestion.id, now)
             {purged, notifications ++ note_notifications}
           else
             error -> BrusselsWtf.Repo.rollback(error)
           end
         end) do
      {:ok, {suggestion, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, suggestion}

      {:error, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Purge a bounded due batch for scheduled maintenance."
  def purge_due(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)
    now = BrusselsWtf.Clock.utc_now()

    if not is_integer(limit) or limit < 1 or limit > 1_000 do
      raise ArgumentError, "suggestion purge limit must be between 1 and 1000"
    end

    case BrusselsWtf.Repo.transaction(fn ->
           ids = lock_due_suggestion_ids(now, limit)

           {suggestion_notifications, suggestion_count} =
             Enum.reduce(ids, {[], 0}, fn id, {notifications, count} ->
               {:ok, suggestion} = fetch_suggestion(id)
               {_suggestion, current} = purge_suggestion!(suggestion, now)
               {notifications ++ current, count + 1}
             end)

           remaining = limit - suggestion_count
           decisions = if remaining > 0, do: lock_due_decisions(now, remaining), else: []

           decision_notifications =
             Enum.flat_map(decisions, fn decision -> purge_decision_note!(decision, now) end)

           {suggestion_count + length(decisions),
            suggestion_notifications ++ decision_notifications}
         end) do
      {:ok, {count, notifications}} ->
        Ash.Notifier.notify(notifications)
        count

      {:error, reason} ->
        raise reason
    end
  end

  def validate_configuration! do
    case validate_configuration(config!()) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp store_submission(input, client_address, config) do
    now = BrusselsWtf.Clock.utc_now()
    rate_limit_key = rate_limit_key(client_address, now, config)
    fingerprint = fingerprint(input, config)

    attrs =
      Map.merge(input, %{
        rate_limit_key: rate_limit_key,
        submission_fingerprint: fingerprint,
        body_retention_deadline: add_days(now, config[:body_retention_days]),
        contact_retention_deadline: add_days(now, config[:contact_retention_days]),
        anti_abuse_retention_deadline:
          DateTime.add(now, config[:anti_abuse_retention_seconds], :second),
        fingerprint_retention_deadline: add_days(now, config[:fingerprint_retention_days]),
        inserted_at: now
      })

    case BrusselsWtf.Repo.transaction(fn ->
           lock_digest!("rate:" <> rate_limit_key)

           if rate_limit_count(rate_limit_key) >= config[:rate_limit_max_submissions] do
             BrusselsWtf.Repo.rollback(:rate_limited)
           end

           lock_digest!("fingerprint:" <> fingerprint)

           if rejected_fingerprint?(fingerprint) do
             {:suppressed, []}
           else
             store_suggestion_and_case!(attrs)
           end
         end) do
      {:ok, {_result, notifications}} ->
        Ash.Notifier.notify(notifications)
        @accepted

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_suggestion_and_case!(attrs) do
    {suggestion, suggestion_notifications} = create_suggestion!(attrs, true)

    {review_case, case_notifications} =
      Review.open_review_case!(
        %{
          kind: :suggestion,
          affected_record_id: suggestion.id,
          affected_record_type: "private_suggestion",
          processing_generation: "suggestion:#{suggestion.id}",
          urgency: :normal,
          summary: "Private #{suggestion.kind} suggestion requires review",
          normalized_content: %{},
          diagnostics: %{},
          related_evidence: %{}
        },
        authorize?: false,
        return_notifications?: true
      )

    {linked, link_notifications} =
      update!(suggestion, :link_review_case, %{review_case_id: review_case.id}, true)

    {linked, suggestion_notifications ++ case_notifications ++ link_notifications}
  end

  defp moderate(id, action, fact_id, reason_code, note, actor) do
    now = BrusselsWtf.Clock.utc_now()
    config = config!()

    case BrusselsWtf.Repo.transaction(fn ->
           with {:ok, suggestion} <- lock_pending_suggestion(id),
                :ok <- lock_open_suggestion_case(suggestion),
                {:ok, verified_fact_id} <- moderation_fact(action, fact_id, suggestion) do
             contact_deadline =
               min_datetime(
                 suggestion.contact_retention_deadline,
                 add_days(now, config[:decided_contact_retention_days])
               )

             {decided, suggestion_notifications} =
               update!(
                 suggestion,
                 :decide,
                 %{
                   status: %{reject: :rejected, approve: :approved, address: :addressed}[action],
                   decided_by: actor.id,
                   decided_at: now,
                   decision_reason_code: reason_code,
                   approved_fact_id: verified_fact_id,
                   contact_retention_deadline: contact_deadline
                 },
                 true
               )

             note_deadline = add_days(now, config[:decision_note_retention_days])

             {_decision, decision_notifications} =
               SuggestionDecision
               |> Ash.Changeset.for_create(
                 :record,
                 %{
                   suggestion_id: suggestion.id,
                   review_case_id: suggestion.review_case_id,
                   action: action,
                   reason_code: reason_code,
                   note: note,
                   verified_fact_id: verified_fact_id,
                   publication_revision_id: if(action == :address, do: fact_id),
                   note_retention_deadline: note_deadline,
                   inserted_at: now
                 },
                 actor: actor
               )
               |> Ash.create!(actor: actor, domain: Review, return_notifications?: true)

             review_case =
               Ash.get!(Review.Case, suggestion.review_case_id, authorize?: false, domain: Review)

             {_closed_case, case_notifications} =
               review_case
               |> Ash.Changeset.for_update(:close_suggestion, %{
                 disposition:
                   %{
                     reject: :suggestion_rejected,
                     approve: :suggestion_approved,
                     address: :suggestion_addressed
                   }[action]
               })
               |> Ash.update!(authorize?: false, domain: Review, return_notifications?: true)

             {decided, suggestion_notifications ++ decision_notifications ++ case_notifications}
           else
             {:error, reason} -> BrusselsWtf.Repo.rollback(reason)
           end
         end) do
      {:ok, {decided, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, decided}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_pending_suggestion(id) do
    with {:ok, id} <- cast_uuid(id),
         %{rows: [["pending"]]} <-
           BrusselsWtf.Repo.query!(
             "SELECT status FROM review_suggestions WHERE id = $1::text::uuid FOR UPDATE",
             [id]
           ),
         {:ok, suggestion} <- fetch_suggestion(id) do
      {:ok, suggestion}
    else
      %{rows: [[_status]]} -> {:error, :already_decided}
      %{rows: []} -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp lock_suggestion(id) do
    with {:ok, id} <- cast_uuid(id),
         %{num_rows: 1} <-
           BrusselsWtf.Repo.query!(
             "SELECT id FROM review_suggestions WHERE id = $1::text::uuid FOR UPDATE",
             [id]
           ),
         {:ok, suggestion} <- fetch_suggestion(id) do
      {:ok, suggestion}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_open_suggestion_case(suggestion) do
    case BrusselsWtf.Repo.query!(
           "SELECT kind, status, affected_record_id::text FROM review_cases WHERE id = $1::text::uuid FOR UPDATE",
           [suggestion.review_case_id]
         ).rows do
      [["suggestion", "open", affected_id]] when affected_id == suggestion.id -> :ok
      _ -> {:error, :invalid_review_case}
    end
  end

  defp moderation_fact(
         :address,
         revision_id,
         %{kind: :correction, subject_type: :agenda_item} = suggestion
       ) do
    with {:ok, item} <-
           Ash.get(BrusselsWtf.Council.AgendaItem, suggestion.subject_id,
             load: [council_meeting: :meeting_page]
           ),
         %{publication_status: :published, current_revision_id: ^revision_id} = page <-
           item.council_meeting.meeting_page,
         {:ok, revision} <- Ash.get(BrusselsWtf.Council.PublicationRevision, revision_id),
         true <- revision.meeting_page_id == page.id,
         true <- DateTime.compare(revision.published_at, suggestion.inserted_at) != :lt do
      {:ok, nil}
    else
      _ -> {:error, :revision_not_published_or_matching}
    end
  end

  defp moderation_fact(:address, _revision_id, _suggestion), do: {:error, :invalid_submission}

  defp moderation_fact(:reject, nil, _suggestion), do: {:ok, nil}

  defp moderation_fact(:approve, fact_id, suggestion) do
    BrusselsWtf.Repo.query!(
      "SELECT id FROM sourced_facts WHERE id = $1::text::uuid FOR SHARE",
      [fact_id]
    )

    with {:ok, %SourcedFact{} = fact} <-
           Ash.get(SourcedFact, fact_id, authorize?: false, domain: Identity),
         true <- Identity.TrustedVerifier.trusted_fact?(fact),
         true <- current_matching_fact?(fact, suggestion) do
      {:ok, fact.id}
    else
      _ -> {:error, :fact_not_verified_or_matching}
    end
  end

  defp current_matching_fact?(fact, suggestion) do
    subject_matches =
      (fact.subject_type == suggestion.subject_type and fact.subject_id == suggestion.subject_id) or
        (fact.object_type == suggestion.subject_type and fact.object_id == suggestion.subject_id)

    kind_matches = suggestion.kind != :ownership or fact.kind == :ownership
    subject_matches and kind_matches and fact.verification_status == :verified
  end

  defp purge_suggestion!(suggestion, now) do
    attrs =
      %{}
      |> due_redaction(:body, suggestion.body, suggestion.body_retention_deadline, now)
      |> due_redaction(:contact, suggestion.contact, suggestion.contact_retention_deadline, now)
      |> due_redaction(
        :rate_limit_key,
        suggestion.rate_limit_key,
        suggestion.anti_abuse_retention_deadline,
        now
      )
      |> due_redaction(
        :submission_fingerprint,
        suggestion.submission_fingerprint,
        suggestion.fingerprint_retention_deadline,
        now
      )

    if map_size(attrs) == 0 do
      {suggestion, []}
    else
      all_purged? =
        Enum.all?([:body, :contact, :rate_limit_key, :submission_fingerprint], fn field ->
          Map.get(attrs, field, Map.get(suggestion, field)) == nil
        end)

      attrs =
        if all_purged? and is_nil(suggestion.private_data_purged_at),
          do: Map.put(attrs, :private_data_purged_at, now),
          else: attrs

      update!(suggestion, :purge_private_data, attrs, true)
    end
  end

  defp purge_decision_note_for!(suggestion_id, now) do
    SuggestionDecision
    |> Ash.Query.filter(suggestion_id == ^suggestion_id and not is_nil(note))
    |> Ash.read!(authorize?: false, domain: Review)
    |> Enum.flat_map(fn decision -> purge_decision_note!(decision, now) end)
  end

  defp purge_decision_note!(%{note: nil}, _now), do: []

  defp purge_decision_note!(decision, now) do
    if DateTime.compare(now, decision.note_retention_deadline) in [:eq, :gt] do
      {_decision, notifications} =
        decision
        |> Ash.Changeset.for_update(:purge_note, %{note: nil, note_purged_at: now})
        |> Ash.update!(authorize?: false, domain: Review, return_notifications?: true)

      notifications
    else
      []
    end
  end

  defp lock_due_suggestion_ids(now, limit) do
    BrusselsWtf.Repo.query!(
      """
      SELECT id::text
        FROM review_suggestions
       WHERE (contact IS NOT NULL AND contact_retention_deadline <= $1)
          OR (body IS NOT NULL AND body_retention_deadline <= $1)
          OR (rate_limit_key IS NOT NULL AND anti_abuse_retention_deadline <= $1)
          OR (submission_fingerprint IS NOT NULL AND fingerprint_retention_deadline <= $1)
       ORDER BY inserted_at, id
       LIMIT $2
       FOR UPDATE SKIP LOCKED
      """,
      [now, limit]
    ).rows
    |> List.flatten()
  end

  defp lock_due_decisions(now, limit) do
    ids =
      BrusselsWtf.Repo.query!(
        """
        SELECT id::text
          FROM review_suggestion_decisions
         WHERE note IS NOT NULL AND note_retention_deadline <= $1
         ORDER BY inserted_at, id
         LIMIT $2
         FOR UPDATE SKIP LOCKED
        """,
        [now, limit]
      ).rows
      |> List.flatten()

    SuggestionDecision
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false, domain: Review)
  end

  defp create_suggestion!(attrs, return_notifications?) do
    Suggestion
    |> Ash.Changeset.for_create(:intake, attrs)
    |> Ash.create!(
      authorize?: false,
      domain: Review,
      return_notifications?: return_notifications?
    )
  end

  defp update!(suggestion, action, attrs, return_notifications?) do
    suggestion
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update!(
      authorize?: false,
      domain: Review,
      return_notifications?: return_notifications?
    )
  end

  defp fetch_suggestion(id) do
    case Ash.get(Suggestion, id, authorize?: false, domain: Review) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, suggestion} -> {:ok, suggestion}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp rate_limit_count(key) do
    Suggestion
    |> Ash.Query.filter(rate_limit_key == ^key)
    |> Ash.read!(authorize?: false, domain: Review)
    |> length()
  end

  defp rejected_fingerprint?(fingerprint) do
    Suggestion
    |> Ash.Query.filter(submission_fingerprint == ^fingerprint and status == :rejected)
    |> Ash.read!(authorize?: false, domain: Review)
    |> Enum.any?()
  end

  defp lock_digest!(digest) do
    BrusselsWtf.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [digest])
    :ok
  end

  defp rate_limit_key(client_address, now, config) do
    bucket = div(DateTime.to_unix(now), config[:rate_limit_window_seconds])
    hmac(config[:rate_limit_secret], "rate:v1\0#{bucket}\0#{client_address}")
  end

  defp fingerprint(input, config) do
    canonical =
      [input.kind, input.subject_type, input.subject_id, String.downcase(input.body)]
      |> Enum.map_join("\0", &to_string/1)

    hmac(config[:rate_limit_secret], "fingerprint:v1\0" <> canonical)
  end

  defp hmac(secret, value) do
    :crypto.mac(:hmac, :sha256, secret, value) |> Base.encode16(case: :lower)
  end

  defp normalize_input(attrs) do
    with {:ok, kind} <- enum(value(attrs, :kind), [:ownership, :correction]),
         {:ok, subject_type} <-
           enum(value(attrs, :subject_type), [:legal_entity, :person, :agenda_item]),
         {:ok, subject_id} <-
           resolve_subject(kind, subject_type, value(attrs, :subject_reference)),
         {:ok, body} <- open_text(value(attrs, :body), config!()),
         {:ok, contact} <- optional_text(value(attrs, :contact), 500) do
      {:ok,
       %{
         kind: kind,
         subject_type: subject_type,
         subject_id: subject_id,
         body: body,
         contact: contact
       }}
    else
      _ -> {:error, :invalid_submission}
    end
  end

  defp resolve_subject(:correction, :agenda_item, reference) when is_binary(reference) do
    with {:ok, id} <- cast_uuid(reference),
         {:ok, %{published?: true} = item} <-
           Ash.get(BrusselsWtf.Council.AgendaItem, id, load: [council_meeting: :meeting_page]),
         %{publication_status: :published} <- item.council_meeting.meeting_page do
      {:ok, item.id}
    else
      _ -> {:error, :invalid}
    end
  end

  defp resolve_subject(:ownership, :person, _reference), do: {:error, :invalid}

  defp resolve_subject(_kind, :legal_entity, reference) when is_binary(reference) do
    case Identity.get_public_company_profile(reference) do
      {:ok, %{entity_id: id}} -> {:ok, id}
      _ -> {:error, :invalid}
    end
  end

  defp resolve_subject(_kind, :person, reference) when is_binary(reference) do
    case Identity.get_public_person_profile(reference) do
      {:ok, %{id: id}} -> {:ok, id}
      _ -> {:error, :invalid}
    end
  end

  defp resolve_subject(_, _, _), do: {:error, :invalid}

  defp enum(value, allowed) when is_atom(value),
    do: if(value in allowed, do: {:ok, value}, else: {:error, :invalid})

  defp enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid}
      found -> {:ok, found}
    end
  end

  defp enum(_, _), do: {:error, :invalid}

  defp open_text(value, config) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) >= config[:body_min_length] and
         byte_size(value) <= config[:body_max_bytes],
       do: {:ok, value},
       else: {:error, :invalid}
  end

  defp open_text(_value, _config), do: {:error, :invalid}

  defp required_text(value, max) when is_binary(value) do
    value = String.trim(value)
    if value != "" and byte_size(value) <= max, do: {:ok, value}, else: {:error, :invalid}
  end

  defp required_text(_, _), do: {:error, :invalid}
  defp optional_text(nil, _max), do: {:ok, nil}
  defp optional_text("", _max), do: {:ok, nil}
  defp optional_text(value, max), do: required_text(value, max)

  defp reviewer(%{id: id, role: :reviewer}) when is_binary(id) and id != "", do: :ok
  defp reviewer(_), do: {:error, :forbidden}
  defp enabled(config), do: if(config[:enabled], do: :ok, else: {:error, :disabled})

  defp cast_uuid(id),
    do:
      case(Ecto.UUID.cast(id),
        do: (
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        )
      )

  defp due_redaction(attrs, _field, nil, _deadline, _now), do: attrs

  defp due_redaction(attrs, field, _value, deadline, now),
    do:
      if(DateTime.compare(now, deadline) in [:eq, :gt],
        do: Map.put(attrs, field, nil),
        else: attrs
      )

  defp add_days(datetime, days), do: DateTime.add(datetime, days * 86_400, :second)

  defp min_datetime(left, right),
    do: if(DateTime.compare(left, right) == :gt, do: right, else: left)

  defp filled?(nil), do: false
  defp filled?(""), do: false
  defp filled?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled?(_value), do: true
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp config!, do: Application.fetch_env!(:brussels_wtf, :suggestions)

  defp validate_configuration(config) do
    cond do
      not is_boolean(config[:enabled]) ->
        {:error, "suggestion feature gate must be boolean"}

      config[:enabled] and
          (not is_binary(config[:rate_limit_secret]) or byte_size(config[:rate_limit_secret]) < 32) ->
        {:error, "suggestion rate limit secret must contain at least 32 bytes"}

      not positive_integer?(config[:rate_limit_window_seconds]) or
          not positive_integer?(config[:rate_limit_max_submissions]) ->
        {:error, "suggestion rate limit values must be positive integers"}

      config[:body_min_length] != 10 or config[:body_max_bytes] != 10_000 ->
        {:error, "suggestion body limits must match the 10..10000 storage contract"}

      Enum.any?(
        [
          :body_retention_days,
          :contact_retention_days,
          :decided_contact_retention_days,
          :anti_abuse_retention_seconds,
          :fingerprint_retention_days,
          :decision_note_retention_days
        ],
        &(not positive_integer?(config[&1]))
      ) ->
        {:error, "suggestion retention values must be positive integers"}

      config[:body_retention_days] > 365 ->
        {:error, "suggestion body retention exceeds 365 days"}

      config[:contact_retention_days] > 90 or config[:decided_contact_retention_days] > 30 ->
        {:error, "suggestion contact retention exceeds the privacy policy"}

      config[:fingerprint_retention_days] > 730 ->
        {:error, "suggestion fingerprint retention exceeds 730 days"}

      config[:decision_note_retention_days] > 365 ->
        {:error, "suggestion decision note retention exceeds 365 days"}

      config[:anti_abuse_retention_seconds] > 172_800 ->
        {:error, "suggestion anti-abuse retention exceeds 48 hours"}

      not is_integer(config[:purge_batch_size]) or config[:purge_batch_size] < 1 or
          config[:purge_batch_size] > 1_000 ->
        {:error, "suggestion purge batch size must be between 1 and 1000"}

      not is_integer(config[:purge_max_batches_per_job]) or
        config[:purge_max_batches_per_job] < 1 or config[:purge_max_batches_per_job] > 100 ->
        {:error, "suggestion purge batches per job must be between 1 and 100"}

      not is_list(config[:trusted_proxies]) or
          Enum.any?(config[:trusted_proxies], fn proxy ->
            match?({:error, _}, canonical_client_address(proxy))
          end) ->
        {:error, "suggestion trusted proxies must be canonical IP addresses"}

      true ->
        :ok
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
