defmodule BrusselsWtfWeb.ReviewCasePage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review

  @actions [
    {"retry", "Retry"},
    {"reclassify", "Reclassify"},
    {"relink", "Relink"},
    {"correct", "Correct"},
    {"mark-unsupported", "Mark unsupported"}
  ]

  @dossier_actions [
    {"confirm-dossier-link", "Confirm dossier link"},
    {"remove-dossier-link", "Remove dossier link"},
    {"merge-dossiers", "Merge dossiers"},
    {"split-dossier", "Split dossier"},
    {"relink-dossier", "Relink agenda item"}
  ]

  @impl Dstar.Page
  def mount(conn, %{"id" => id}) do
    actor = conn.assigns.current_review_actor
    review_case = Review.get_review_case!(id, actor: actor)

    locators =
      case {review_case.commune, review_case.source_record} do
        {%Ash.NotLoaded{}, _} ->
          []

        {_, %Ash.NotLoaded{}} ->
          []

        {nil, _} ->
          []

        {_, nil} ->
          []

        {commune, record} ->
          Ingestion.locator_history!(commune.id, record.origin_url)
      end

    source_versions =
      case review_case.source_record do
        %Ash.NotLoaded{} ->
          []

        nil ->
          []

        record ->
          Enum.sort_by(record.versions, & &1.first_retrieved_at, {:desc, DateTime})
      end

    previews =
      source_versions
      |> Enum.filter(&Ingestion.SourceLimits.processing_allowed?/1)
      |> Map.new(fn version ->
        {version.id,
         "/review/artifacts/source-versions/#{version.id}?token=#{BrusselsWtfWeb.ReviewPreview.sign_source_version(version.id)}"}
      end)

    derived_artifacts =
      case review_case.source_version do
        %Ash.NotLoaded{} -> []
        nil -> []
        version -> Enum.flat_map(version.processing_runs, & &1.derived_artifacts)
      end

    artifact_previews =
      Map.new(derived_artifacts, fn artifact ->
        {artifact.id,
         "/review/artifacts/derived/#{artifact.id}?token=#{BrusselsWtfWeb.ReviewPreview.sign_derived_artifact(artifact.id)}"}
      end)

    suggestion =
      if review_case.kind == :suggestion do
        case BrusselsWtf.Suggestions.get_for_review_case(review_case.id, actor) do
          {:ok, suggestion} -> suggestion
          _ -> nil
        end
      end

    assign(conn,
      page_title: "Review case · brussels.wtf",
      review_case: review_case,
      suggestion: suggestion,
      suggestion_approval_available:
        suggestion && BrusselsWtf.Suggestions.approval_available?(suggestion.kind),
      locators: locators,
      source_versions: source_versions,
      oversized_source: oversized_source?(review_case),
      previews: previews,
      derived_artifacts: derived_artifacts,
      artifact_previews: artifact_previews,
      actions:
        case review_case.kind do
          :suggestion ->
            []

          :link_correction ->
            @dossier_actions

          _ ->
            Enum.reject(@actions, fn {action, _} ->
              action == "retry" and oversized_source?(review_case)
            end)
        end,
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <header class="border-b border-base-300">
      <div class="mx-auto max-w-6xl px-4 py-4">
        <a href="/review" class="font-semibold underline">← Review inbox</a>
      </div>
    </header>
    <main class="mx-auto max-w-6xl px-4 py-8">
      <p class="text-sm text-base-content/70">
        {humanize(@review_case.kind)} · {commune_name(@review_case)} · {humanize(@review_case.urgency)} urgency
      </p>
      <h1 class="mt-2 text-3xl font-semibold">{@review_case.summary}</h1>
      <p class="mt-2">
        Status: <strong>{humanize(@review_case.status)}</strong>
        · Generation <code>{@review_case.processing_generation}</code>
      </p>

      <section
        :if={@suggestion}
        class="mt-8 border border-base-300 p-5"
        aria-labelledby="private-suggestion"
      >
        <h2 id="private-suggestion" class="text-2xl font-semibold">Private suggestion</h2>
        <dl class="mt-4 grid gap-2 md:grid-cols-[12rem_1fr]">
          <dt>Kind</dt><dd>{humanize(@suggestion.kind)}</dd>
          <dt>Subject</dt><dd>
            {humanize(@suggestion.subject_type)} · <code>{@suggestion.subject_id}</code>
          </dd>
          <dt>Body</dt><dd class="whitespace-pre-wrap">{@suggestion.body || "Purged"}</dd>
          <dt>Private contact</dt><dd>{@suggestion.contact || "Not supplied or purged"}</dd>
          <dt>Body retention</dt><dd>{DateTime.to_iso8601(@suggestion.body_retention_deadline)}</dd>
          <dt>Contact retention</dt><dd>
            {DateTime.to_iso8601(@suggestion.contact_retention_deadline)}
          </dd>
          <dt>Anti-abuse retention</dt><dd>
            {DateTime.to_iso8601(@suggestion.anti_abuse_retention_deadline)}
          </dd>
          <dt>Fingerprint retention</dt><dd>
            {DateTime.to_iso8601(@suggestion.fingerprint_retention_deadline)}
          </dd>
        </dl>

        <div :if={@suggestion.status == :pending} class="mt-6 grid gap-5 md:grid-cols-2">
          <form
            method="post"
            action={"/review/cases/#{@review_case.id}/suggestion/reject"}
            class="border border-base-300 p-4"
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <h3 class="font-semibold">Reject lead</h3>
            <label class="mt-3 block">
              Reason code
              <input
                name="reason_code"
                required
                maxlength="100"
                class="input input-bordered mt-1 w-full"
              />
            </label>
            <label class="mt-3 block">
              Reviewer note <textarea
                name="note"
                required
                maxlength="2000"
                class="textarea textarea-bordered mt-1 w-full"
              ></textarea>
            </label>
            <button type="submit" class="btn btn-sm mt-3">Reject</button>
          </form>

          <form
            :if={@suggestion.subject_type == :agenda_item}
            method="post"
            action={"/review/cases/#{@review_case.id}/suggestion/address"}
            class="border border-base-300 p-4"
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <h3 class="font-semibold">Mark correction addressed</h3>
            <p class="mt-2 text-sm">
              First publish the correction independently. Reference the current revision of this item's meeting, published after the report.
            </p>
            <label class="mt-3 block">Publication revision UUID<input
              name="publication_revision_id"
              required
              class="input input-bordered mt-1 w-full"
            /></label>
            <label class="mt-3 block">What changed?<textarea
              name="note"
              required
              maxlength="2000"
              class="textarea textarea-bordered mt-1 w-full"
            ></textarea></label>
            <button type="submit" class="btn btn-sm mt-3">Mark addressed</button>
          </form>
          <form
            :if={@suggestion_approval_available and @suggestion.subject_type != :agenda_item}
            method="post"
            action={"/review/cases/#{@review_case.id}/suggestion/approve"}
            class="border border-base-300 p-4"
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <h3 class="font-semibold">Reference verified fact and close lead</h3>
            <label class="mt-3 block">
              Verified fact UUID
              <input name="verified_fact_id" required class="input input-bordered mt-1 w-full" />
            </label>
            <label class="mt-3 block">
              Reviewer note <textarea
                name="note"
                required
                maxlength="2000"
                class="textarea textarea-bordered mt-1 w-full"
              ></textarea>
            </label>
            <button type="submit" class="btn btn-sm mt-3">Approve reference</button>
          </form>
          <p
            :if={!@suggestion_approval_available and @suggestion.subject_type != :agenda_item}
            class="border border-base-300 p-4"
          >
            Approval is unavailable because no trusted verifier supports this fact kind.
          </p>
        </div>

        <h3 class="mt-6 font-semibold">Moderation audit</h3>
        <ol class="mt-2 space-y-2">
          <li :for={decision <- @suggestion.decisions}>
            {humanize(decision.action)} by {decision.actor_id} · {decision.reason_code}
            <p :if={decision.publication_revision_id}>
              Publication revision: <code>{decision.publication_revision_id}</code>
            </p>
            <p>{decision.note || "Reviewer note purged"}</p>
            <time>{DateTime.to_iso8601(decision.inserted_at)}</time>
          </li>
        </ol>
      </section>

      <section :if={is_nil(@suggestion)} class="mt-8" aria-labelledby="source-context">
        <h2 id="source-context" class="text-2xl font-semibold">Immutable source context</h2>
        <dl class="mt-4 grid gap-2 md:grid-cols-[12rem_1fr]">
          <dt>Authoritative origin</dt><dd>
            <a
              :if={source_url(@review_case)}
              href={source_url(@review_case)}
              class="break-all underline"
            >{source_url(@review_case)}</a>
          </dd>
          <dt>SHA-256</dt><dd><code class="break-all">{source_hash(@review_case)}</code></dd>
          <dt>Media type</dt><dd>{source_value(@review_case, :media_type)}</dd>
          <dt>Byte size</dt><dd>{source_value(@review_case, :byte_size)}</dd>
        </dl>
        <p :if={@oversized_source} class="mt-4">
          Extraction is deferred because this source exceeds the processing limit.
          Retry and private preview of this version are unavailable; use the authoritative origin link above.
        </p>
        <h3 class="mt-5 font-semibold">Source versions</h3>
        <ul class="mt-2 space-y-2">
          <li :for={version <- @source_versions}>
            <time>{DateTime.to_iso8601(version.first_retrieved_at)}</time>
            · SHA-256 <code class="break-all">{version.sha256}</code>
            ·
            <a
              :if={@previews[version.id]}
              data-private-artifact
              href={@previews[version.id]}
              class="underline"
            >Private preview (expires in 60 seconds)</a>
            <span :if={!@previews[version.id]}>Private preview unavailable; use the authoritative origin.</span>
          </li>
        </ul>
        <h3 class="mt-5 font-semibold">Derived artifacts</h3>
        <p :if={@derived_artifacts == []} class="mt-2">No derived artifacts are attached.</p>
        <ul class="mt-2 space-y-2">
          <li :for={artifact <- @derived_artifacts}>
            {artifact.output_kind} · SHA-256 <code class="break-all">{artifact.output_sha256}</code>
            · {artifact.media_type} · quality {inspect(artifact.quality_measurements)} ·
            <a
              data-private-artifact
              data-artifact-kind="derived"
              href={@artifact_previews[artifact.id]}
              class="underline"
            >Private artifact preview (expires in 60 seconds)</a>
          </li>
        </ul>
      </section>

      <section :if={is_nil(@suggestion)} class="mt-8" aria-labelledby="locator-history">
        <h2 id="locator-history" class="text-2xl font-semibold">Locator and HTTP history</h2>
        <article :for={locator <- @locators} class="mt-4 border border-base-300 p-4">
          <p class="break-all"><strong>Locator:</strong> {locator.url}</p>
          <p class="break-all"><strong>Parent index:</strong> {locator.parent_index_url}</p>
          <div :for={observation <- locator.observations} class="mt-3 border-t border-base-300 pt-3">
            <p>
              {DateTime.to_iso8601(observation.observed_at)} · {humanize(observation.status)} · HTTP {observation.http_status}
            </p>
            <p class="break-all">Final URL: {observation.final_url}</p>
            <pre class="mt-2 overflow-auto whitespace-pre-wrap text-xs">Redirects: {inspect(observation.redirect_chain)}
    Headers: {inspect(observation.response_headers)}</pre>
          </div>
        </article>
      </section>

      <div :if={is_nil(@suggestion)} class="mt-8 grid gap-6 lg:grid-cols-2">
        <section aria-labelledby="extracted">
          <h2 id="extracted" class="text-2xl font-semibold">Extracted / OCR text</h2><pre class="mt-3 whitespace-pre-wrap border border-base-300 p-4">{@review_case.extracted_text || "—"}</pre>
        </section>
        <section aria-labelledby="normalized">
          <h2 id="normalized" class="text-2xl font-semibold">Normalized content</h2><pre class="mt-3 whitespace-pre-wrap border border-base-300 p-4">{inspect(@review_case.normalized_content, pretty: true)}</pre>
        </section>
      </div>

      <div :if={is_nil(@suggestion)} class="mt-8 grid gap-6 lg:grid-cols-3">
        <.context_map title="Quality measurements" value={@review_case.quality_measurements} />
        <.context_map title="Diagnostics and processor logs" value={diagnostics(@review_case)} />
        <.context_map title="Related evidence" value={@review_case.related_evidence} />
      </div>

      <section :if={is_nil(@suggestion)} class="mt-10" aria-labelledby="actions">
        <h2 id="actions" class="text-2xl font-semibold">Audited actions</h2>
        <div class="mt-4 grid gap-4 md:grid-cols-2">
          <form
            :for={{action, label} <- @actions}
            method="post"
            action={"/review/cases/#{@review_case.id}/actions/#{action}"}
            class="border border-base-300 p-4"
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <h3 class="font-semibold">{label}</h3>
            <label class="mt-3 block">Reviewer note <textarea
              name="note"
              required
              class="textarea textarea-bordered mt-1 w-full"
            ></textarea></label>
            <p :if={action == "retry"} class="mt-3 text-sm opacity-75">
              Retry uses the deployed native PDF processor and its current immutable configuration.
            </p>
            <label :if={action == "reclassify"} class="mt-3 block">
              Source classification
              <select name="classification" required class="select select-bordered mt-1 w-full">
                <option
                  :for={
                    role <- ~w(index agenda project supplement addendum minutes register recording)
                  }
                  value={role}
                >
                  {humanize(role)}
                </option>
              </select>
            </label>
            <div :if={action == "relink"} class="mt-3 grid gap-2">
              <label>Target type
              <select name="target_record_type" required class="select select-bordered w-full"><option value="council_meeting">
                Council meeting
              </option></select></label>
              <label>Target UUID
              <input name="target_record_id" required class="input input-bordered w-full" /></label>
            </div>
            <label :if={action == "correct"} class="mt-3 block">
              Corrected normalized content (JSON) <textarea
                name="corrected_content"
                required
                class="textarea textarea-bordered mt-1 w-full"
              >{Jason.encode!(@review_case.normalized_content)}</textarea>
            </label>
            <label :if={action == "mark-unsupported"} class="mt-3 block">Reason code
            <input name="reason_code" required class="input input-bordered mt-1 w-full" /></label>
            <input
              :if={action in ["confirm-dossier-link", "remove-dossier-link"]}
              type="hidden"
              name="dossier_link_id"
              value={@review_case.normalized_content["dossier_link_id"]}
            />
            <div :if={action == "merge-dossiers"} class="mt-3 grid gap-2">
              <label>Source dossier UUID
              <input
                name="source_dossier_id"
                required
                value={@review_case.normalized_content["source_dossier_id"]}
                class="input input-bordered w-full"
              /></label>
              <label>Target dossier UUID
              <input
                name="target_dossier_id"
                required
                value={@review_case.normalized_content["target_dossier_id"]}
                class="input input-bordered w-full"
              /></label>
            </div>
            <div :if={action == "split-dossier"} class="mt-3 grid gap-2">
              <label>Source dossier UUID
              <input
                name="source_dossier_id"
                required
                value={
                  @review_case.normalized_content["dossier_id"] ||
                    @review_case.normalized_content["source_dossier_id"]
                }
                class="input input-bordered w-full"
              /></label>
              <label>Dossier link UUIDs, comma-separated
              <input
                name="dossier_link_ids"
                required
                value={@review_case.normalized_content["dossier_link_id"]}
                class="input input-bordered w-full"
              /></label>
              <label>New dossier slug
              <input name="new_dossier_slug" required class="input input-bordered w-full" /></label>
              <label>New dossier title
              <input name="new_dossier_title" required class="input input-bordered w-full" /></label>
            </div>
            <div :if={action == "relink-dossier"} class="mt-3 grid gap-2">
              <input
                type="hidden"
                name="dossier_link_id"
                value={@review_case.normalized_content["dossier_link_id"]}
              />
              <label>Target dossier UUID
              <input
                name="target_dossier_id"
                required
                value={@review_case.normalized_content["target_dossier_id"]}
                class="input input-bordered w-full"
              /></label>
            </div>
            <button class="btn btn-sm mt-3" type="submit">{label}</button>
          </form>
        </div>
      </section>

      <section class="mt-10" aria-labelledby="history">
        <h2 id="history" class="text-2xl font-semibold">Notes and prior actions</h2>
        <form
          :if={is_nil(@suggestion)}
          method="post"
          action={"/review/cases/#{@review_case.id}/notes"}
          class="mt-4 border border-base-300 p-4"
        >
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <label>Add note <textarea
            name="body"
            required
            class="textarea textarea-bordered mt-1 w-full"
          ></textarea></label>
          <button type="submit" class="btn btn-sm mt-3">Add note</button>
        </form>
        <ol class="mt-5 space-y-3">
          <li :for={action <- @review_case.actions} class="border-l-4 border-primary pl-3">
            <strong>{humanize(action.action)}</strong>
            by {action.actor_id} · {humanize(action.disposition)} · effect {humanize(action.effect)}
            <p>{action.note}</p>
            <pre class="mt-1 whitespace-pre-wrap text-xs">{inspect(action.details, pretty: true)}</pre>
            <time class="text-sm">{DateTime.to_iso8601(action.inserted_at)}</time>
          </li>
          <li :for={note <- @review_case.notes} class="border-l-4 border-base-300 pl-3">
            <strong>Note by {note.actor_id}</strong><p>{note.body}</p><time class="text-sm">{DateTime.to_iso8601(
              note.inserted_at
            )}</time>
          </li>
        </ol>
        <h3 class="mt-6 font-semibold">Appended revisions</h3>
        <ul class="mt-2 space-y-2">
          <li :for={revision <- @review_case.revisions}>
            {humanize(revision.kind)} · {revision.note}<pre class="whitespace-pre-wrap text-xs">{inspect(revision.details, pretty: true)}</pre>
          </li>
        </ul>
        <h3 class="mt-6 font-semibold">Durable exclusions</h3>
        <ul class="mt-2 space-y-2">
          <li :for={exclusion <- @review_case.exclusions}>
            {exclusion.reason} · generation
            <code>{exclusion.processing_generation}</code><pre class="whitespace-pre-wrap text-xs">{inspect(exclusion.details, pretty: true)}</pre>
          </li>
        </ul>
        <h3 class="mt-6 font-semibold">Dossier revisions</h3>
        <ul class="mt-2 space-y-2">
          <li :for={action <- @review_case.dossier_actions}>
            {humanize(action.action)} by {action.actor_id} · {action.note}<pre class="whitespace-pre-wrap text-xs">{inspect(action.details, pretty: true)}</pre>
          </li>
        </ul>
      </section>
    </main>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true

  defp context_map(assigns) do
    ~H"""
    <section>
      <h2 class="text-xl font-semibold">{@title}</h2><pre class="mt-3 whitespace-pre-wrap border border-base-300 p-4 text-sm">{inspect(@value, pretty: true)}</pre>
    </section>
    """
  end

  defp oversized_source?(%{source_version: %Ash.NotLoaded{}}), do: false
  defp oversized_source?(%{source_version: nil}), do: false

  defp oversized_source?(%{source_version: version}),
    do: not Ingestion.SourceLimits.processing_allowed?(version)

  defp source_url(%{source_record: %Ash.NotLoaded{}}), do: nil
  defp source_url(%{source_record: nil}), do: nil
  defp source_url(%{source_record: record}), do: record.origin_url
  defp source_hash(review_case), do: source_value(review_case, :sha256)
  defp source_value(%{source_version: %Ash.NotLoaded{}}, _field), do: nil
  defp source_value(%{source_version: nil}, _field), do: nil
  defp source_value(%{source_version: version}, field), do: Map.fetch!(version, field)
  defp commune_name(%{commune: %Ash.NotLoaded{}}), do: "No commune"
  defp commune_name(%{commune: nil}), do: "No commune"
  defp commune_name(%{commune: commune}), do: commune.name

  defp diagnostics(review_case) do
    runs =
      case review_case.source_version do
        %Ash.NotLoaded{} -> []
        nil -> []
        version -> Enum.map(version.processing_runs, &processor_run_context/1)
      end

    %{case: review_case.diagnostics, processing_runs: runs}
  end

  defp processor_run_context(run),
    do: BrusselsWtf.Ingestion.ProcessingRun.review_context(run)

  defp humanize(nil), do: "—"

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
