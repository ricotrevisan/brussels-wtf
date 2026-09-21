defmodule BrusselsWtf.Identity.MunicipalInstallation do
  @moduledoc "Bounded, evidence-gated admission of the approved municipal installation records."
  alias BrusselsWtf.{Identity, Repo}
  alias __MODULE__.{Evidence, Resolver, Source, Verifier}
  require Ash.Query

  @doc "Privately inspect eligible source-ordered events; never creates people or facts."
  def preview(slugs, opts \\ []) do
    authorize!(slugs, opts, [:actor, :reviewer])
    {:ok, Enum.map(slugs, &inspect_commune/1)}
  end

  @doc "Admit source-ordered events up to the persisted verified v1 fact cap per commune (1..100)."
  def publish(slugs, opts \\ []) do
    authorize!(slugs, opts, [:actor, :reviewer, :max_facts_per_commune])
    cap = Keyword.fetch!(opts, :max_facts_per_commune)
    unless is_integer(cap) and cap in 1..100, do: raise(ArgumentError, "cap must be in 1..100")
    {:ok, Enum.map(slugs, &publish_commune(&1, cap))}
  end

  defp inspect_commune(slug) do
    bundle = Evidence.load!(slug)

    %{
      slug: slug,
      eligible: length(bundle.candidates),
      out_of_scope: bundle.excluded,
      candidates:
        Enum.map(
          bundle.candidates,
          &Map.take(&1, [:legal_name, :role_key, :effective_from, :effective_to])
        )
    }
  rescue
    e in [ArgumentError, MatchError, Postgrex.Error, DBConnection.ConnectionError] ->
      %{slug: slug, eligible: 0, error: failure_code(e)}
  end

  defp publish_commune(slug, cap) do
    bundle = Evidence.load!(slug)

    initial = %{
      slug: slug,
      eligible: length(bundle.candidates),
      published_new: 0,
      published_existing: verified_count!(bundle.installation.commune.id),
      out_of_scope: bundle.excluded,
      rejected: []
    }

    Enum.reduce_while(bundle.candidates, initial, fn candidate, report ->
      case admit(bundle, candidate, cap) do
        {:ok, {:capacity_reached, count}} ->
          {:halt, %{report | published_existing: count - report.published_new}}

        {:ok, {result, count}} when result in [:new, :existing] ->
          new = report.published_new + if(result == :new, do: 1, else: 0)
          {:cont, %{report | published_new: new, published_existing: count - new}}

        {:error, reason} ->
          {:cont,
           Map.update!(
             report,
             :rejected,
             &(&1 ++ [%{role_key: candidate.role_key, reason: reason}])
           )}
      end
    end)
  rescue
    e in [ArgumentError, MatchError, Postgrex.Error, DBConnection.ConnectionError] ->
      %{
        slug: slug,
        eligible: 0,
        published_new: 0,
        published_existing: 0,
        error: failure_code(e)
      }
  end

  defp admit(bundle, candidate, cap) do
    Repo.transaction(
      fn ->
        commune_id = bundle.installation.commune.id
        # Capacity and admission share one transaction. Always lock commune before
        # Resolver's person lock, and do not create even a private person when full.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "municipal-installation-capacity:#{commune_id}"
        ])

        count = verified_count!(commune_id)

        if count >= cap do
          {{:capacity_reached, count}, []}
        else
          {result, notifications} = verify_candidate!(bundle, candidate)
          count = count + if(result == :new, do: 1, else: 0)
          {{result, count}, notifications}
        end
      end,
      timeout: 120_000
    )
    |> case do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, result}

      {:error, _reason} ->
        {:error, :transaction_failed}
    end
  rescue
    e in [ArgumentError, MatchError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, failure_code(e)}
  end

  defp verified_count!(commune_id) do
    verifier = Verifier.id()

    Identity.SourcedFact
    |> Ash.Query.filter(
      object_type == :commune and object_id == ^commune_id and
        verified_by == ^verifier and verification_status == :verified
    )
    |> Ash.count!(authorize?: false)
  end

  defp verify_candidate!(bundle, candidate) do
    {person, person_notifications} = Resolver.resolve!(bundle, candidate)
    attrs = fact_attributes(bundle, candidate, person)
    # The evidence identity includes the stable role key; different offices do not collide.
    {fact, fact_notifications} = Identity.record_fact!(attrs, return_notifications?: true)
    notifications = person_notifications ++ fact_notifications

    if fact.verification_status == :verified do
      unless Identity.TrustedVerifier.trusted_fact?(fact),
        do: raise(ArgumentError, "existing fact is no longer trusted")

      {:existing, notifications}
    else
      {run, run_notifications} = Verifier.persist!(fact, person, bundle, candidate)
      Identity.verify_sourced_fact!(fact.id, Verifier.id(), run.id)
      mention_notifications = Resolver.link_mentions!(person, bundle, candidate)
      {:new, notifications ++ run_notifications ++ mention_notifications}
    end
  end

  # Reports are private but must not echo processor bodies, SQL parameters or excerpts.
  # Unknown programming exceptions are deliberately not caught as successful admission.
  defp failure_code(%MatchError{}), do: :unexpected_evidence_result
  defp failure_code(%Postgrex.Error{}), do: :database_error
  defp failure_code(%DBConnection.ConnectionError{}), do: :database_unavailable

  defp failure_code(%ArgumentError{message: message}) do
    Map.get(
      %{
        "ambiguous existing full name" => :ambiguous_person,
        "ambiguous or conflicting person context" => :conflicting_person_context,
        "missing or ambiguous approved installation source" => :installation_source_missing,
        "missing or ambiguous approved corroboration source" => :corroboration_source_missing,
        "accepted native extraction is required" => :native_extraction_required,
        "municipal installation evidence chain mismatch" => :evidence_chain_mismatch,
        "existing fact is no longer trusted" => :existing_fact_untrusted,
        "fact does not exactly match an independently parsed installation" => :unsupported_claim,
        "installation verifier provenance mismatch" => :provenance_mismatch,
        "exactly one relationship claim artifact required" => :relationship_artifact_required
      },
      message,
      :invalid_evidence
    )
  end

  @doc false
  def fact_attributes(bundle, candidate, person) do
    %{
      subject_type: :person,
      subject_id: person.id,
      object_type: :commune,
      object_id: bundle.installation.commune.id,
      object_label: candidate.role_key,
      kind: :public_mandate,
      effective_from: candidate.effective_from,
      effective_to: nil,
      source_version_id: bundle.installation.version.id,
      authoritative_url: bundle.contract.installation.url,
      source_authority: :municipal_decision,
      evidence_kind: :official_decision,
      evidence_excerpt: candidate.evidence_excerpt,
      evidence_location: candidate.evidence_location
    }
  end

  defp authorize!(slugs, opts, allowed) do
    actor = opts[:actor] || opts[:reviewer]

    unless match?(
             %BrusselsWtf.Review.Actor{role: :reviewer, id: id} when is_binary(id) and id != "",
             actor
           ),
           do: raise(ArgumentError, "authenticated reviewer required")

    unless Keyword.keys(opts) -- allowed == [] and is_list(slugs) and length(slugs) in 1..4 and
             Enum.uniq(slugs) == slugs and
             Enum.all?(slugs, &match?({:ok, _}, Source.contract(&1))),
           do:
             raise(
               ArgumentError,
               "explicit supported commune allowlist and bounded options required"
             )
  end
end
