defmodule BrusselsWtf.Identity do
  @moduledoc """
  Private mention, identity, CBE enrichment, and sourced-fact behavior.

  The interface requires explicit identifiers or corroborating evidence. It never
  turns a name match, management record, tender notice, or missing fact into a
  relationship claim.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  resources do
    resource BrusselsWtf.Identity.CbeRelease do
      define :record_cbe_release, action: :record
    end

    resource BrusselsWtf.Identity.LegalEntity do
      define :get_legal_entity, action: :read, get_by: [:id]
      define :get_legal_entity_by_number, action: :read, get_by: [:enterprise_number]
      define :upsert_legal_entity, action: :upsert
    end

    resource BrusselsWtf.Identity.LegalEntityName do
      define :record_legal_entity_name, action: :record
    end

    resource BrusselsWtf.Identity.EstablishmentUnit do
      define :upsert_establishment_unit, action: :upsert
    end

    resource BrusselsWtf.Identity.Mention do
      define :get_mention, action: :read, get_by: [:id]
      define :record_mention, action: :record
      define :resolve_mention_to_legal_entity, action: :resolve_legal_entity
      define :resolve_mention_to_person, action: :resolve_person
      define :mark_mention_ambiguous, action: :mark_ambiguous
    end

    resource BrusselsWtf.Identity.Person do
      define :get_person, action: :read, get_by: [:id]
      define :record_person, action: :record
      define :retire_person, action: :retire
    end

    resource BrusselsWtf.Identity.IdentityAction do
      define :record_identity_action, action: :record
    end

    resource BrusselsWtf.Identity.SourcedFact do
      define :get_sourced_fact, action: :read, get_by: [:id]
      define :record_fact, action: :record
    end

    resource BrusselsWtf.Identity.EnrichmentRequest do
      define :get_enrichment_request, action: :read, get_by: [:id]
      define :queue_enrichment_request, action: :queue
      define :complete_enrichment_request, action: :complete
    end
  end

  @mandates_per_page 25

  @doc """
  Lists one page of verified public mandates for the selected communes and
  name search.

  Returns `%{mandates: relationships, more?: boolean}` where `more?` reports
  whether another page follows. `page` starts at 1.
  """
  def list_public_mandates!(communes, search \\ "", page \\ 1) when is_integer(page) do
    offset = (Kernel.max(page, 1) - 1) * @mandates_per_page

    commune_ids =
      BrusselsWtf.Ingestion.list_communes!()
      |> Enum.filter(&(&1.slug in communes))
      |> Enum.map(& &1.id)

    BrusselsWtf.Identity.PublicProjection.mandate_page!(
      commune_ids,
      String.downcase(search),
      offset,
      @mandates_per_page
    )
  end

  def request_cbe_enrichment!(mention_id, enterprise_number, generation \\ "automatic") do
    mention = get_mention!(mention_id)
    enterprise_number = normalize_enterprise_number!(enterprise_number)

    unless normalize_optional_number(mention.explicit_identifier) == enterprise_number do
      raise ArgumentError, "CBE enrichment requires the mention's explicit enterprise number"
    end

    request =
      queue_enrichment_request!(%{
        mention_id: mention.id,
        enterprise_number: enterprise_number,
        generation: generation
      })

    %{request_id: request.id}
    |> BrusselsWtf.Workers.EnrichMention.new()
    |> Oban.insert!()

    request
  end

  def complete_cbe_enrichment(request_id, attempt, max_attempts) do
    request = get_enrichment_request!(request_id) |> Ash.load!(:mention)

    case BrusselsWtf.CBE.fetch_enterprise(request.enterprise_number) do
      {:ok, bundle} -> import_cbe_bundle(request, bundle)
      {:error, reason} when attempt < max_attempts -> {:error, reason}
      {:error, reason} -> fail_enrichment(request, reason)
    end
  end

  def resolve_person!(mention_id, attrs) when is_map(attrs) do
    mention = get_mention!(mention_id)
    legal_name = attrs |> fetch_value!(:legal_name) |> String.trim()
    explicit_identifier = optional_value(attrs, :explicit_identifier)
    corroborating_facts = optional_value(attrs, :corroborating_facts) || %{}

    resolution_basis =
      cond do
        is_binary(explicit_identifier) and String.trim(explicit_identifier) != "" and
            mention.explicit_identifier == explicit_identifier ->
          :explicit_identifier

        mention.text == legal_name and map_size(corroborating_facts) > 0 ->
          :corroborated_name

        true ->
          raise ArgumentError,
                "person resolution requires an explicit identifier or exact name plus a corroborating fact"
      end

    transaction!(fn ->
      {person, person_notifications} =
        record_person!(
          %{
            legal_name: legal_name,
            explicit_identifier: explicit_identifier,
            resolution_basis: resolution_basis,
            corroborating_facts: corroborating_facts
          },
          return_notifications?: true
        )

      {_mention, mention_notifications} =
        resolve_mention_to_person!(mention, %{resolved_person_id: person.id},
          return_notifications?: true
        )

      {person, person_notifications ++ mention_notifications}
    end)
  end

  def mark_person_ambiguous!(mention_id, candidates, generation \\ "automatic")
      when is_list(candidates) do
    mention = get_mention!(mention_id)

    transaction!(fn ->
      {_mention, mention_notifications} =
        mark_mention_ambiguous!(mention, return_notifications?: true)

      {review_case, case_notifications} =
        BrusselsWtf.Review.open_review_case!(
          %{
            kind: :normalization,
            affected_record_id: mention.id,
            affected_record_type: "mention",
            source_version_id: mention.source_version_id,
            processing_generation: "identity:#{generation}",
            urgency: :normal,
            summary: "Person identity is ambiguous and requires review",
            normalized_content: %{"candidates" => candidates},
            diagnostics: %{"classification" => "ambiguous_person_identity"}
          },
          return_notifications?: true
        )

      {review_case, mention_notifications ++ case_notifications}
    end)
  end

  def merge_people!(source_id, target_id, note, actor) when source_id != target_id do
    source = get_person!(source_id)
    target = get_person!(target_id)

    transaction!(fn ->
      {_retired, retire_notifications} =
        retire_person!(source, %{retired_into_id: target.id}, return_notifications?: true)

      {action, action_notifications} =
        record_identity_action!(
          %{
            action: :merge,
            subject_person_id: source.id,
            target_person_id: target.id,
            note: note,
            details: %{}
          },
          actor: actor,
          return_notifications?: true
        )

      {action, retire_notifications ++ action_notifications}
    end)
  end

  def split_person!(person_id, attrs, note, actor) do
    person = get_person!(person_id)

    transaction!(fn ->
      {created, person_notifications} =
        record_person!(attrs, return_notifications?: true)

      {_action, action_notifications} =
        record_identity_action!(
          %{
            action: :split,
            subject_person_id: person.id,
            created_person_id: created.id,
            note: note,
            details: %{}
          },
          actor: actor,
          return_notifications?: true
        )

      {created, person_notifications ++ action_notifications}
    end)
  end

  def record_sourced_fact!(attrs) when is_map(attrs) do
    validate_sourced_fact_attributes!(attrs)

    transaction!(fn ->
      {fact, notifications} = record_fact!(attrs, return_notifications?: true)
      BrusselsWtf.Identity.IxellesPublicMandateProcessor.enqueue_if_eligible!(fact)

      BrusselsWtf.Identity.IxellesMandateDeclarationProcessor.enqueue_if_eligible!(fact)

      BrusselsWtf.Identity.GazetteManagementProcessor.enqueue_if_eligible!(fact)

      {fact, notifications}
    end)
  end

  def verify_sourced_fact!(fact_id, verifier_id, processing_run_id)
      when is_binary(processing_run_id) do
    case Ecto.UUID.cast(processing_run_id) do
      {:ok, processing_run_id} ->
        BrusselsWtf.Identity.TrustedVerifier.verify!(fact_id, verifier_id, processing_run_id)

      :error ->
        raise ArgumentError, "verification requires a persisted processing run"
    end
  end

  def verify_sourced_fact!(_fact_id, _verifier_id, _processing_run_id) do
    raise ArgumentError, "verification requires a persisted processing run"
  end

  def list_public_relationships!(filter \\ %{}) do
    BrusselsWtf.Identity.PublicProjection.list!(filter)
  end

  def get_public_company_profile(enterprise_number) do
    with true <- canonical_enterprise_number?(enterprise_number),
         {:ok, company} <- get_legal_entity_by_number(enterprise_number),
         company <- Ash.load!(company, :cbe_release),
         %{source_kind: :open_data, published_on: %Date{}, sha256: sha256} = release <-
           company.cbe_release,
         true <- valid_public_checksum?(sha256) do
      {:ok,
       %BrusselsWtf.Identity.PublicProfile.Company{
         entity_id: company.id,
         registered_name: company.registered_name,
         enterprise_number: company.enterprise_number,
         status: company.status,
         cbe: %BrusselsWtf.Identity.PublicProfile.CbeCitation{
           published_on: release.published_on,
           sha256: release.sha256
         },
         relationships: public_relationships_for(:legal_entity, company.id)
       }}
    else
      _ -> {:error, :not_found}
    end
  rescue
    Ash.Error.Invalid -> {:error, :not_found}
  end

  def get_public_person_profile(id) do
    with {:ok, canonical_id} <- Ecto.UUID.cast(id),
         {:ok, person} <- get_person(canonical_id) do
      case person do
        %{status: :retired, retired_into_id: target_id} when not is_nil(target_id) ->
          with true <- BrusselsWtf.Identity.PublicProjection.ever_public_person?(person.id),
               {:ok, _profile} <- public_person_profile(target_id) do
            {:redirect,
             %BrusselsWtf.Identity.PublicProfile.Redirect{kind: :person, target_id: target_id}}
          else
            _ -> {:error, :not_found}
          end

        %{status: :active} ->
          public_person_profile(person.id)

        _ ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp public_person_profile(person_id) do
    person = get_person!(person_id)

    case public_relationships_for(:person, person.id) do
      [] ->
        {:error, :not_found}

      relationships ->
        {:ok,
         %BrusselsWtf.Identity.PublicProfile.Person{
           id: person.id,
           legal_name: person.legal_name,
           relationships: relationships
         }}
    end
  end

  defp canonical_enterprise_number?(value) when is_binary(value) do
    Regex.match?(~r/\A[0-9]{10}\z/, value) and normalize_enterprise_number!(value) == value
  rescue
    ArgumentError -> false
  end

  defp canonical_enterprise_number?(_value), do: false

  defp valid_public_checksum?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/i, value)

  defp valid_public_checksum?(_value), do: false

  defp public_relationships_for(type, id) do
    subject = list_public_relationships!(%{subject_type: type, subject_id: id})
    object = list_public_relationships!(%{object_type: type, object_id: id})

    history =
      BrusselsWtf.Identity.PublicProjection.history!(%{subject_type: type, subject_id: id}) ++
        BrusselsWtf.Identity.PublicProjection.history!(%{object_type: type, object_id: id})

    (subject ++ object ++ history)
    |> Enum.uniq_by(& &1.fact_id)
    |> Enum.sort_by(&{&1.effective_from || ~D[0001-01-01], &1.fact_id}, :desc)
  end

  def normalize_enterprise_number!(value) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")

    with true <- byte_size(digits) == 10,
         {base, ""} <- Integer.parse(binary_part(digits, 0, 8)),
         {check, ""} <- Integer.parse(binary_part(digits, 8, 2)),
         true <- 97 - rem(base, 97) == check do
      digits
    else
      _ -> raise ArgumentError, "invalid CBE enterprise number"
    end
  end

  def normalize_enterprise_number!(_value),
    do: raise(ArgumentError, "invalid CBE enterprise number")

  defp import_cbe_bundle(request, bundle) do
    entity = fetch_value!(bundle, :entity)
    release_data = fetch_value!(bundle, :release)
    number = normalize_enterprise_number!(fetch_value!(entity, :enterprise_number))

    unless number == request.enterprise_number do
      raise ArgumentError, "CBE response enterprise number does not match the request"
    end

    unless fetch_value!(entity, :entity_type) in [:legal_person, "legal_person"] do
      raise ArgumentError, "a natural-person CBE registration cannot create a legal entity"
    end

    transaction!(fn ->
      {release, release_notifications} =
        record_cbe_release!(
          %{
            release_key: fetch_value!(release_data, :release_key),
            published_on: date_value!(release_data, :published_on),
            sha256: fetch_value!(release_data, :sha256),
            source_kind: :open_data
          },
          return_notifications?: true
        )

      {legal_entity, entity_notifications} =
        upsert_legal_entity!(
          %{
            enterprise_number: number,
            registered_name: fetch_value!(entity, :registered_name),
            status: atom_value!(entity, :status, [:active, :inactive]),
            cbe_release_id: release.id
          },
          return_notifications?: true
        )

      name_notifications =
        Enum.flat_map(list_value(bundle, :names), fn name ->
          {_name, notifications} =
            record_legal_entity_name!(
              %{
                legal_entity_id: legal_entity.id,
                cbe_release_id: release.id,
                name: fetch_value!(name, :name),
                kind: atom_value!(name, :kind, [:registered, :abbreviated, :trading]),
                language: optional_value(name, :language),
                effective_from: optional_date_value(name, :effective_from)
              },
              return_notifications?: true
            )

          notifications
        end)

      unit_notifications =
        Enum.flat_map(list_value(bundle, :establishment_units), fn unit ->
          {_unit, notifications} =
            upsert_establishment_unit!(
              %{
                unit_number: fetch_value!(unit, :unit_number),
                legal_entity_id: legal_entity.id,
                cbe_release_id: release.id,
                name: optional_value(unit, :name),
                status: atom_value!(unit, :status, [:active, :inactive]),
                started_on: optional_date_value(unit, :started_on)
              },
              return_notifications?: true
            )

          notifications
        end)

      {_mention, mention_notifications} =
        resolve_mention_to_legal_entity!(
          request.mention,
          %{resolved_legal_entity_id: legal_entity.id},
          return_notifications?: true
        )

      {_request, request_notifications} =
        complete_enrichment_request!(
          request,
          %{
            status: :succeeded,
            legal_entity_id: legal_entity.id,
            cbe_release_id: release.id,
            diagnostics: %{"source" => "CBE Open Data"},
            completed_at: BrusselsWtf.Clock.utc_now()
          },
          return_notifications?: true
        )

      notifications =
        release_notifications ++
          entity_notifications ++
          name_notifications ++
          unit_notifications ++ mention_notifications ++ request_notifications

      {{:ok, legal_entity}, notifications}
    end)
  end

  defp fail_enrichment(request, reason) do
    transaction!(fn ->
      {_request, request_notifications} =
        complete_enrichment_request!(
          request,
          %{
            status: :failed,
            diagnostics: %{"classification" => safe_classification(reason)},
            completed_at: BrusselsWtf.Clock.utc_now()
          },
          return_notifications?: true
        )

      {_review_case, case_notifications} =
        BrusselsWtf.Review.open_review_case!(
          %{
            kind: :evidence,
            affected_record_id: request.mention_id,
            affected_record_type: "mention",
            source_version_id: request.mention.source_version_id,
            processing_generation: "cbe:#{request.id}",
            urgency: :normal,
            summary: "CBE enrichment failed repeatedly and requires review",
            diagnostics: %{"classification" => safe_classification(reason)}
          },
          return_notifications?: true
        )

      {:ok, request_notifications ++ case_notifications}
    end)
  end

  def validate_sourced_fact_attributes!(attrs) do
    kind = fetch_value!(attrs, :kind)
    evidence_kind = fetch_value!(attrs, :evidence_kind)
    excerpt = fetch_value!(attrs, :evidence_excerpt)
    location = fetch_value!(attrs, :evidence_location)

    if optional_value(attrs, :source_version_id) in [nil, ""] and
         optional_value(attrs, :authoritative_url) in [nil, ""] do
      raise ArgumentError, "a sourced fact requires authoritative evidence"
    end

    if String.trim(excerpt) == "" or String.trim(location) == "" do
      raise ArgumentError, "a sourced fact requires an evidence excerpt and location"
    end

    if kind in [:ownership, "ownership"] and
         evidence_kind not in [:ownership_register, :official_act, :declared_ownership] do
      raise ArgumentError, "management or absence of data cannot establish ownership"
    end

    if kind in [:contract, "contract"] and evidence_kind == :tender_notice do
      raise ArgumentError, "a tender notice cannot establish a contract award"
    end

    from = optional_date_value(attrs, :effective_from)
    to = optional_date_value(attrs, :effective_to)

    if kind in [
         :public_mandate,
         :office_holding,
         :management,
         "public_mandate",
         "office_holding",
         "management"
       ] and
         is_nil(from) do
      raise ArgumentError, "a public mandate or office-holding fact requires its applicable date"
    end

    if from && to && Date.compare(to, from) == :lt do
      raise ArgumentError, "effective_to cannot precede effective_from"
    end
  end

  defp normalize_optional_number(nil), do: nil
  defp normalize_optional_number(value), do: normalize_enterprise_number!(value)
  defp list_value(map, key), do: optional_value(map, key) || []
  defp fetch_value!(map, key), do: Map.get(map, key) || Map.fetch!(map, Atom.to_string(key))
  defp optional_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp atom_value!(map, key, allowed) do
    case optional_value(map, key) do
      value when is_binary(value) ->
        value
        |> String.to_existing_atom()
        |> then(&if(&1 in allowed, do: &1, else: raise(ArgumentError, "invalid #{key}")))

      value ->
        if value in allowed, do: value, else: raise(ArgumentError, "invalid #{key}")
    end
  rescue
    ArgumentError -> raise ArgumentError, "invalid #{key}"
  end

  defp date_value!(map, key) do
    case optional_date_value(map, key) do
      %Date{} = date -> date
      _ -> raise ArgumentError, "invalid #{key}"
    end
  end

  defp optional_date_value(map, key) do
    case optional_value(map, key) do
      nil -> nil
      %Date{} = date -> date
      value when is_binary(value) -> Date.from_iso8601!(value)
    end
  end

  defp safe_classification(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_classification({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_classification(_reason), do: "cbe_enrichment_failure"

  defp transaction!(fun) do
    case BrusselsWtf.Repo.transaction(fun) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        result

      {:error, reason} ->
        raise reason
    end
  end
end
