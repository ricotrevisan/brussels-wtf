# Authenticated release RPC only. See docs/operations/municipal-installations.md.
# Explicit operations: :acquire, :preview, :publish. No queue draining.
# Keep all private intermediate values inside the function: Code.eval_string/2
# must not return them in its binding, nor print exception messages.
(fn options ->
   alias BrusselsWtf.Identity
   alias Identity.MunicipalInstallation
   alias MunicipalInstallation.{Acquisition, Source}

   result =
     try do
       operation = Map.fetch!(options, :operation)
       slugs = Map.fetch!(options, :communes)
       supported = Enum.map(Source.contracts(), & &1.slug)

       allowed =
         [:operation, :communes] ++
           if(operation == :publish, do: [:max_facts_per_commune], else: [])

       valid =
         Map.keys(options) -- allowed == [] and operation in [:acquire, :preview, :publish] and
           is_list(slugs) and length(slugs) in 1..4 and Enum.uniq(slugs) == slugs and
           Enum.all?(slugs, &(&1 in supported)) and
           (operation != :publish or
              (is_integer(options[:max_facts_per_commune]) and
                 options[:max_facts_per_commune] in 1..100))

       if valid do
         config = Application.fetch_env!(:brussels_wtf, :review_auth)
         actor = %BrusselsWtf.Review.Actor{id: Keyword.fetch!(config, :actor_id), role: :reviewer}

         case operation do
           :acquire ->
             {:ok, report} = Acquisition.acquire(slugs, actor: actor)
             {:ok, Map.take(report, [:reused, :queued, :failures])}

           :preview ->
             {:ok, reports} = MunicipalInstallation.preview(slugs, actor: actor)

             {:ok,
              Enum.map(reports, fn report ->
                %{
                  commune: report.slug,
                  eligible: report.eligible,
                  excluded: length(Map.get(report, :out_of_scope, [])),
                  failed: Map.has_key?(report, :error)
                }
              end)}

           :publish ->
             {:ok, reports} =
               MunicipalInstallation.publish(slugs,
                 actor: actor,
                 max_facts_per_commune: options.max_facts_per_commune
               )

             urls =
               Source.contracts()
               |> Enum.filter(&(&1.slug in slugs))
               |> Enum.map(& &1.installation.url)

             # This projection rechecks trust; never derive URLs from private candidates.
             profiles =
               Identity.list_public_relationships!(%{object_type: :commune})
               |> Enum.filter(&(&1.state == :documented and &1.authoritative_url in urls))
               |> Enum.map(&(BrusselsWtfWeb.Endpoint.url() <> "/people/#{&1.subject_id}?lang=en"))
               |> Enum.uniq()
               |> Enum.sort()

             {:ok,
              %{
                communes:
                  Enum.map(reports, fn report ->
                    %{
                      commune: report.slug,
                      eligible: report.eligible,
                      published_new: report.published_new,
                      published_existing: report.published_existing,
                      rejected: length(Map.get(report, :rejected, [])),
                      failed: Map.has_key?(report, :error)
                    }
                  end),
                public_profiles: profiles
              }}
         end
       else
         {:error, :invalid_options}
       end
     rescue
       _ -> {:error, :operation_failed}
     end

   IO.inspect(result, limit: :infinity, printable_limit: :infinity)
   :ok
 end).(Map.new(binding()))
