defmodule BrusselsWtf.IdentityMandateDeclarationTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo
  import Phoenix.ConnTest
  @endpoint BrusselsWtfWeb.Endpoint
  require Ash.Query
  alias BrusselsWtf.Identity
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Identity.{MandateDeclaration, IxellesMandateDeclarationProcessor}

  @minutes_verifier :ixelles_municipal_minutes_public_mandate_v1
  @minutes_url "https://www.ixelles.be/uploads/conseil/pv/267.pdf"
  @declaration_url "https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf"
  @declaration_row "Premier Echevin et Officier de l'Etat Civil (Décembre 2024)"
  @fiscal_page "FISCAL 281.10 tranche 12 345,67 EUR numero national 85.07.23-123.45"

  setup do
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-07 12:00:00Z])
    BrusselsWtf.HTTP.Stub.reset()
    Application.delete_env(:brussels_wtf, :mandate_test_documents)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :mandate_test_documents) end)
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    configured = BrusselsWtf.Communes.configuration!("ixelles")

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: configured.name,
        index_url: configured.index_url
      })

    minutes_locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: @minutes_url,
        parent_index_url: configured.index_url,
        meeting_identifier: "267",
        scheduled_on: ~D[2026-08-19],
        role: :minutes,
        language: :bilingual,
        observed_label: "Proces-verbal",
        discovered_at: ~U[2026-08-19 11:59:00Z]
      })

    minutes_bytes = "%PDF-1.7 official Ixelles minutes fixture"
    {:ok, archived_minutes} = BrusselsWtf.Archive.store(minutes_bytes, :raw)

    minutes_record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: @minutes_url,
        role: :minutes,
        original_language: :bilingual
      })

    minutes_version =
      Ingestion.upsert_source_version!(%{
        source_record_id: minutes_record.id,
        sha256: archived_minutes.sha256,
        byte_size: byte_size(minutes_bytes),
        media_type: "application/pdf",
        object_key: archived_minutes.object_key,
        first_retrieved_at: ~U[2026-08-19 12:00:00Z]
      })

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: ~U[2026-08-19 11:58:00Z],
        kind: :scheduled,
        requester_id: "system",
        target_type: :commune,
        target_id: commune.id,
        check_key: "poll:ixelles-267",
        status: :completed
      })

    Ingestion.record_observation!(%{
      source_locator_id: minutes_locator.id,
      source_version_id: minutes_version.id,
      poll_run_id: poll_run.id,
      check_key: "fetch:ixelles-267",
      observed_at: ~U[2026-08-19 12:00:00Z],
      status: :success,
      http_status: 200,
      sha256: archived_minutes.sha256,
      final_url: @minutes_url
    })

    person =
      Identity.record_person!(%{
        legal_name: "Alex Example",
        explicit_identifier: "municipal-mandate-42",
        resolution_basis: :explicit_identifier
      })

    %{commune: commune, person: person, minutes_version: minutes_version}
  end

  test "approved declaration enters through acquisition and renders its exact dated role in every locale",
       ctx do
    corroborate!(ctx)
    version = acquire!(ctx.commune)
    [fact] = facts(version)
    assert fact.evidence_excerpt == @declaration_row
    assert fact.effective_from == ~D[2024-12-01]
    assert fact.effective_to == ~D[2024-12-31]
    assert fact.mandate_declaration["role"] == "Premier Echevin et Officier de l'Etat Civil"

    assert_enqueued(
      worker: BrusselsWtf.Workers.VerifyIxellesMandateDeclaration,
      queue: :ocr,
      args: %{fact_id: fact.id}
    )

    verify!(fact)
    assert Identity.get_sourced_fact!(fact.id).verification_status == :verified

    for {locale, heading, history} <- [
          {"en", "Verified facts", "Dated history"},
          {"fr", "Faits vérifiés", "Historique daté"},
          {"nl", "Geverifieerde feiten", "Gedateerde geschiedenis"}
        ] do
      html = build_conn() |> get("/people/#{ctx.person.id}?lang=#{locale}") |> html_response(200)
      assert html =~ heading
      assert html =~ history
      assert html =~ "Premier Echevin et Officier de l&#39;Etat Civil"
      assert html =~ "2024-12-01"
      assert html =~ "2024-12-31"
      assert html =~ "declaration 2024 page 2"
      assert html =~ @declaration_url
      refute html =~ "281.10"
      refute html =~ "85.07.23"
      refute html =~ "12 345"
      refute html =~ "Signature"
    end

    for locale <- ~w(en fr nl) do
      updates = feed_updates(ctx.person.id, locale)
      assert Enum.any?(updates, &(&1.factId == fact.id))
      encoded = Jason.encode!(updates)

      for excluded <- ["281.10", "85.07.23", "12 345", "Signature"] do
        refute encoded =~ excluded
      end
    end

    assert length(BrusselsWtf.HTTP.Stub.requests(@declaration_url)) == 1

    for artifact <- Ash.load!(version, :derived_artifacts).derived_artifacts,
        artifact.output_kind in ["native-text", "ocr-text", "relationship-claim-json"] do
      {:ok, bytes} = BrusselsWtf.Archive.get(artifact.object_key)
      refute bytes =~ "281.10"
      refute bytes =~ "85.07.23"
      refute bytes =~ "12 345"
    end

    assert :ok =
             IxellesMandateDeclarationProcessor.enqueue_waiting_for_source_version!(version.id)

    assert length(facts(version)) == 1
    # Changing the independent evidence removes the fact from every public query.
    BrusselsWtf.Repo.query!(
      "UPDATE source_records SET role = 'agenda' WHERE id = $1::text::uuid",
      [ctx.minutes_version.source_record_id]
    )

    assert Identity.list_public_relationships!(%{subject_id: ctx.person.id}) == []
    assert {:error, :not_found} = Identity.get_public_person_profile(ctx.person.id)
    assert build_conn() |> get("/people/#{ctx.person.id}") |> response(404)
    assert feed_updates(ctx.person.id, "en") == []

    refute BrusselsWtf.Follow.TargetEligibility.eligible?(%BrusselsWtf.Follow.Target{
             type: :person,
             identifier: ctx.person.id
           })
  end

  for previous_verifier <- [:v2, :v3] do
    test "a corrected approved version supersedes #{previous_verifier} and preserves dated evidence",
         ctx do
      corroborate!(ctx)
      first = acquire!(ctx.commune)
      [original] = facts(first)

      if unquote(previous_verifier) == :v2 do
        original = BrusselsWtf.Test.LegacyMandateFixture.verify!(original)
        assert original.verified_by == "ixelles_mandate_declaration_v2"
        assert Identity.TrustedVerifier.trusted_fact?(original)
      else
        verify!(original)
      end

      BrusselsWtf.Clock.Controlled.set(~U[2026-09-08 12:00:00Z])

      changed = %{
        document()
        | row: "Premier Echevin (Décembre 2024)",
          role: "Premier Echevin",
          revision: 2,
          role_labels: %{
            "fr" => "Premier Echevin",
            "nl" => "Eerste schepen",
            "en" => "First alderman"
          }
      }

      second = acquire!(ctx.commune, document: changed, text: page_text(changed))
      [correction] = facts(second)
      assert correction.supersedes_id == original.id
      verify!(correction)
      assert Identity.get_sourced_fact!(original.id).verification_status == :superseded
      assert Identity.get_sourced_fact!(correction.id).verification_status == :verified
      assert first.sha256 != second.sha256
      html = build_conn() |> get("/people/#{ctx.person.id}?lang=en") |> html_response(200)
      assert html =~ "Superseded by a corrected declaration"
      assert html =~ "Premier Echevin et Officier"
      assert html =~ "fact-#{original.id}"
      assert html =~ "fact-#{correction.id}"

      assert :ok =
               IxellesMandateDeclarationProcessor.enqueue_waiting_for_source_version!(first.id)

      assert length(facts(first)) == 1
      assert length(facts(second)) == 1
      updates = feed_updates(ctx.person.id, "en")
      assert Enum.any?(updates, &(&1.factId == correction.id))
      refute Enum.any?(updates, &(&1.factId == original.id))
    end
  end

  @tag :browser
  test "a reader discovers the dated declaration and its page citation in every language", ctx do
    corroborate!(ctx)
    version = acquire!(ctx.commune)
    [fact] = facts(version)
    verify!(fact)
    browser_check!(ctx.person.id, fact.id, "Alex Example", 2)
  end

  @tag :external
  test "the actual inspected source resolves the declarant without a fabricated identifier",
       ctx do
    dir = System.fetch_env!("MANDATE_EVIDENCE_DIR")
    minutes_bytes = File.read!(Path.join(dir, "minutes-267.pdf"))
    declaration_bytes = File.read!(Path.join(dir, "mandats-2024.pdf"))
    text = File.read!(Path.join(dir, "mandats-ocr.txt"))
    alias BrusselsWtf.Identity.MandateIdentity
    assert BrusselsWtf.Digest.sha256(minutes_bytes) == MandateIdentity.source_sha()
    sha = BrusselsWtf.Digest.sha256(declaration_bytes)
    assert {:ok, doc} = MandateDeclaration.contract(sha)

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: ctx.commune.id,
        url: @minutes_url,
        parent_index_url: ctx.commune.index_url,
        meeting_identifier: "267",
        scheduled_on: ~D[2026-06-11],
        role: :minutes,
        language: :bilingual,
        observed_label: "Procès-verbal",
        discovered_at: BrusselsWtf.Clock.utc_now()
      })

    poll = mandate_poll!(ctx.commune, "real-independent-minutes")

    BrusselsWtf.HTTP.Stub.put(@minutes_url, %{
      body: minutes_bytes,
      headers: %{"content-type" => "application/pdf"}
    })

    assert :ok = Ingestion.Pipeline.retrieve(locator.id, poll.id, "real-independent-minutes")

    version =
      acquire!(ctx.commune,
        document: doc,
        text: text,
        raw_bytes: declaration_bytes,
        register_contract: false,
        searchable_pdf: File.read!(Path.join(dir, "mandats-ocr.pdf"))
      )

    [fact] = facts(version)
    person = Identity.get_person!(fact.subject_id)
    assert person.legal_name == "Gautier Calomne"
    assert person.resolution_basis == :corroborated_name
    assert person.explicit_identifier == nil
    verify!(fact)
    assert Identity.get_sourced_fact!(fact.id).verification_status == :verified
    assert {:ok, _} = Identity.get_public_person_profile(person.id)
    assert {:ok, same} = MandateIdentity.resolve(doc, ctx.commune.id)
    assert same.id == person.id

    assert :ok =
             IxellesMandateDeclarationProcessor.enqueue_waiting_for_source_version!(version.id)

    assert length(facts(version)) == 1

    for locale <- ~w(fr nl en) do
      html = build_conn() |> get("/people/#{person.id}?lang=#{locale}") |> html_response(200)
      assert html =~ "#page=14"
      assert html =~ "2024-12-01"
      assert html =~ "2024-12-31"

      for private <- [
            "source_version_id",
            "corroborating_facts",
            "281.10",
            "Signature",
            "Numéro national"
          ] do
        refute html =~ private
      end

      homepage = build_conn() |> get("/?lang=#{locale}") |> html_response(200)
      assert homepage =~ "/people/#{person.id}?lang=#{locale}#fact-#{fact.id}"
    end

    if System.get_env("MANDATE_BROWSER") == "1",
      do: browser_check!(person.id, fact.id, person.legal_name, 14)

    # Changing independent context withdraws the public claim everywhere.
    BrusselsWtf.Repo.query!(
      "UPDATE source_records SET role = 'agenda' WHERE id = $1::text::uuid",
      [
        Ingestion.get_source_version!(person.corroborating_facts["source_version_id"]).source_record_id
      ]
    )

    assert {:error, :not_found} = Identity.get_public_person_profile(person.id)
    assert feed_updates(person.id, "en") == []
    refute build_conn() |> get("/?lang=en") |> html_response(200) =~ person.id
  end

  test "a same-name private identity without independent official evidence remains unresolved",
       ctx do
    person =
      Identity.record_person!(%{
        legal_name: "Gautier Calomne",
        resolution_basis: :corroborated_name,
        corroborating_facts: %{"municipality" => "ixelles"}
      })

    {:ok, doc} =
      MandateDeclaration.contract(
        "c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2"
      )

    refute BrusselsWtf.Identity.MandateIdentity.corroborated?(person, ctx.commune.id)

    assert {:error, :uncorroborated_person} =
             BrusselsWtf.Identity.MandateIdentity.resolve(doc, ctx.commune.id)

    assert {:error, :not_found} = Identity.get_public_person_profile(person.id)
    refute build_conn() |> get("/?lang=en") |> html_response(200) =~ person.id
  end

  test "reverted index bytes are evaluated from this observation instead of the newest version",
       ctx do
    corroborate!(ctx)
    index_url = MandateDeclaration.index()
    # First snapshot omits the declaration; second introduces it; third reverts.
    for {key, html} <- [
          {"absent", "<html><a href='/unrelated'>Annual report</a></html>"},
          {"present", ~s(<a href="#{@declaration_url}">Liste des mandats</a>)}
        ] do
      BrusselsWtf.Clock.Controlled.set(
        if key == "absent", do: ~U[2026-09-07 12:00:00Z], else: ~U[2026-09-08 12:00:00Z]
      )

      BrusselsWtf.HTTP.Stub.put(index_url, %{
        body: html,
        headers: %{"content-type" => "text/html"}
      })

      BrusselsWtf.HTTP.Stub.put(@declaration_url, %{status: 403})
      poll = mandate_poll!(ctx.commune, key)
      IxellesMandateDeclarationProcessor.acquire(ctx.commune.id, poll.id)
    end

    requests = length(BrusselsWtf.HTTP.Stub.requests(@declaration_url))

    BrusselsWtf.HTTP.Stub.put(index_url, %{
      body: "<html><a href='/unrelated'>Annual report</a></html>",
      headers: %{"content-type" => "text/html"}
    })

    poll = mandate_poll!(ctx.commune, "reverted")
    assert :ok = IxellesMandateDeclarationProcessor.acquire(ctx.commune.id, poll.id)
    assert length(BrusselsWtf.HTTP.Stub.requests(@declaration_url)) == requests
  end

  for {name, response} <- [
        {"redirected index",
         %{
           body: ~s(<a href="#{@declaration_url}">List</a>),
           final_url: "https://example.org/index"
         }},
        {"comment-only link", %{body: ~s(<!-- <a href="#{@declaration_url}">List</a> -->)}},
        {"script-only link",
         %{body: ~s(<script>const a = '<a href="#{@declaration_url}">List</a>';</script>)}}
      ] do
    test "#{name} cannot authorize declaration discovery", ctx do
      BrusselsWtf.HTTP.Stub.put(
        MandateDeclaration.index(),
        Map.put(unquote(Macro.escape(response)), :headers, %{"content-type" => "text/html"})
      )

      poll = mandate_poll!(ctx.commune, unquote(name))
      assert :ok = IxellesMandateDeclarationProcessor.acquire(ctx.commune.id, poll.id)
      assert BrusselsWtf.HTTP.Stub.requests(@declaration_url) == []
    end
  end

  defp browser_check!(person_id, fact_id, name, source_page) do
    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: 4116, ip: {127, 0, 0, 1})

    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :normal) end)

    {output, status} =
      System.cmd(
        "uv",
        [
          "run",
          "--project",
          "test/browser",
          "--frozen",
          "python",
          "test/browser/mandate_declaration.py",
          "--base",
          "http://127.0.0.1:4116",
          "--person",
          person_id,
          "--fact",
          fact_id,
          "--name",
          name,
          "--source-page",
          to_string(source_page)
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp mandate_poll!(commune, key) do
    Ingestion.start_poll_run!(%{
      commune_id: commune.id,
      started_at: BrusselsWtf.Clock.utc_now(),
      kind: :scheduled,
      requester_id: "system",
      target_type: :commune,
      target_id: commune.id,
      check_key: key,
      status: :completed
    })
  end

  defp feed_updates(person_id, locale) do
    BrusselsWtf.Follow.PublicUpdates.list(
      [%{"type" => "person", "id" => person_id, "importedAt" => "2026-08-01T00:00:00Z"}],
      locale
    )
  end

  test "unresolved, uncorroborated, and ambiguous names create review cases", ctx do
    # No trusted independent minutes evidence.
    version = acquire!(ctx.commune)
    assert facts(version) == []
    assert reviewed?(version)
    assert {:error, :not_found} = Identity.get_public_person_profile(ctx.person.id)
  end

  test "a longer surname never resolves to the existing person", ctx do
    corroborate!(ctx)
    changed = %{document() | family_name: "Exampleson"}
    version = acquire!(ctx.commune, document: changed, text: page_text(changed))
    assert facts(version) == []
    assert reviewed?(version)
  end

  test "multiple exact normalized identities remain ambiguous", ctx do
    corroborate!(ctx)

    Identity.record_person!(%{
      legal_name: "ALEX EXAMPLE",
      explicit_identifier: "second-id",
      resolution_basis: :explicit_identifier
    })

    version = acquire!(ctx.commune)
    assert facts(version) == []
    assert reviewed?(version)
  end

  for {name, transform} <- [
        {"missing section", :section},
        {"missing declarant", :name},
        {"wrong reporting period", :period},
        {"OCR ambiguity", :ocr},
        {"wrong table scope", :scope},
        {"financial data in role", :fiscal},
        {"missing attestation", :attestation},
        {"blank template", :template}
      ] do
    test "#{name} produces a review case and no declaration fact", ctx do
      corroborate!(ctx)
      text = invalid_text(unquote(transform))
      version = acquire!(ctx.commune, text: text)
      assert facts(version) == []
      assert reviewed?(version)
      html = build_conn() |> get("/people/#{ctx.person.id}?lang=en") |> html_response(200)
      refute html =~ "Liste des mandats"
      refute html =~ "281.10"
    end
  end

  test "unsigned and uninspected byte versions cannot inherit an earlier signature", ctx do
    corroborate!(ctx)
    version = acquire!(ctx.commune, document: %{document() | signed?: false})
    assert facts(version) == []
    assert reviewed?(version)
    refute_enqueued(worker: BrusselsWtf.Workers.VerifyIxellesMandateDeclaration)
  end

  test "new identity ambiguity withdraws an already verified declaration", ctx do
    corroborate!(ctx)
    version = acquire!(ctx.commune)
    [fact] = facts(version)
    verify!(fact)

    assert Enum.any?(
             Identity.list_public_relationships!(%{subject_id: ctx.person.id}),
             &(&1.fact_id == fact.id)
           )

    Identity.record_person!(%{
      legal_name: "ALEX EXAMPLE",
      explicit_identifier: "later-id",
      resolution_basis: :explicit_identifier
    })

    refute Enum.any?(
             Identity.list_public_relationships!(%{subject_id: ctx.person.id}),
             &(&1.fact_id == fact.id)
           )

    html = build_conn() |> get("/people/#{ctx.person.id}?lang=en") |> html_response(200)
    refute html =~ "Liste des mandats"
  end

  test "correction acquisition before verification retains its predecessor", ctx do
    corroborate!(ctx)
    first = acquire!(ctx.commune)
    [original] = facts(first)
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-08 12:00:00Z])

    changed = %{
      document()
      | revision: 2,
        row: "Premier Echevin (Décembre 2024)",
        role: "Premier Echevin",
        role_labels: %{
          "fr" => "Premier Echevin",
          "nl" => "Eerste schepen",
          "en" => "First alderman"
        }
    }

    second = acquire!(ctx.commune, document: changed, text: page_text(changed))
    [correction] = facts(second)
    assert correction.supersedes_id == original.id

    assert {:error, :predecessor_pending} =
             IxellesMandateDeclarationProcessor.process(correction.id)

    verify!(original)
    verify!(correction)
    assert Identity.get_sourced_fact!(original.id).verification_status == :superseded
    assert Identity.get_sourced_fact!(correction.id).verification_status == :verified
  end

  test "database rejects rewriting declaration semantics", ctx do
    corroborate!(ctx)
    version = acquire!(ctx.commune)
    [fact] = facts(version)
    verify!(fact)

    assert_raise Postgrex.Error, fn ->
      BrusselsWtf.Repo.query!(
        "UPDATE sourced_facts SET mandate_declaration = '{}'::jsonb WHERE id = $1::text::uuid",
        [fact.id]
      )
    end
  end

  defp document do
    %{
      origin: @declaration_url,
      year: 2024,
      page: 2,
      attestation_page: 5,
      attestation: "Fait à Ixelles, le 30 septembre 2025",
      given_name: "Alex",
      family_name: "Example",
      row: @declaration_row,
      role: "Premier Echevin et Officier de l'Etat Civil",
      role_labels: %{
        "fr" => "Premier Echevin et Officier de l'Etat Civil",
        "nl" => "Eerste schepen en ambtenaar van de burgerlijke stand",
        "en" => "First alderman and civil registrar"
      },
      revision: 1,
      body: "Commune d'Ixelles",
      section: "mandat",
      key: "ixelles-municipal-executive-mandate",
      effective_from: ~D[2024-12-01],
      effective_to: ~D[2024-12-31],
      signed?: true
    }
  end

  defp page_text(doc) do
    Enum.join(
      [
        "ANNEXE 2 — synthetic source fixture, not an authoritative publication",
        "Nom : #{doc.family_name}\nPrénom : #{doc.given_name}\nNuméro national :\nAdresse :\n1. Liste des mandats, fonctions et fonctions dérivées\nMANDATS\n#{doc.row}\nFONCTIONS\nFONCTIONS DÉRIVÉES",
        @fiscal_page,
        "Excluded private activities — no public field may come from this page",
        "#{doc.attestation}\nNombre d'annexes : 17\n#{doc.given_name} #{doc.family_name}\nSignature\nDéclaration pour publication sur le site de la commune selon le formulaire officiel"
      ],
      "\f"
    )
  end

  defp invalid_text(kind) do
    text = page_text(document())

    case kind do
      :section ->
        String.replace(text, "MANDATS", "MISSING HEADER")

      :name ->
        String.replace(text, "Nom : Example", "Nom :")

      :period ->
        String.replace(text, "Décembre 2024", "Décembre 2023")

      :ocr ->
        String.replace(text, "Echevin", "Echev?n")

      :scope ->
        String.replace(text, "MANDATS", "FONCTIONS DÉRIVÉES")

      :fiscal ->
        String.replace(text, @declaration_row, @declaration_row <> " 12 345,67 EUR")

      :attestation ->
        String.replace(text, document().attestation, "Unsigned draft with no dated attestation")

      :template ->
        String.replace(text, @declaration_row, "")
    end
  end

  defp acquire!(commune, opts \\ []) do
    doc = Keyword.get(opts, :document, document())
    text = Keyword.get(opts, :text, page_text(doc))
    # The PDF binary boundary is controlled; fixture layout follows the inspected
    # declaration, with synthetic identity and signature contracts only in tests.
    bytes =
      Keyword.get(
        opts,
        :raw_bytes,
        "%PDF-1.7 synthetic declaration scenario " <>
          BrusselsWtf.Digest.sha256(text <> inspect(doc.signed?))
      )

    sha = BrusselsWtf.Digest.sha256(bytes)
    contracts = Application.get_env(:brussels_wtf, :mandate_test_documents, %{})

    if Keyword.get(opts, :register_contract, true),
      do:
        Application.put_env(:brussels_wtf, :mandate_test_documents, Map.put(contracts, sha, doc))

    BrusselsWtf.HTTP.Stub.put(MandateDeclaration.index(), %{
      body: ~s(<a href="fr/download/transparence/mandats-2024.pdf">Liste des mandats 2024</a>),
      headers: %{"content-type" => "text/html"}
    })

    BrusselsWtf.HTTP.Stub.put(@declaration_url, %{
      body: bytes,
      headers: %{"content-type" => "application/pdf"}
    })

    BrusselsWtf.Processors.Stub.put(sha, %{
      extract: %{
        "text" => "",
        "page_texts" => List.duplicate("", max(doc.page, doc.attestation_page))
      },
      ocr: %{
        "page_texts" => String.split(text, "\f"),
        "searchable_pdf" =>
          Keyword.get(opts, :searchable_pdf, "%PDF synthetic searchable declaration")
      }
    })

    poll =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: BrusselsWtf.Clock.utc_now(),
        kind: :scheduled,
        requester_id: "system",
        target_type: :commune,
        target_id: commune.id,
        check_key: "mandate:#{sha}",
        status: :completed
      })

    assert :ok = IxellesMandateDeclarationProcessor.acquire(commune.id, poll.id)

    version =
      Ingestion.SourceVersion
      |> Ash.Query.filter(sha256 == ^sha)
      |> Ash.read_one!(authorize?: false)

    assert version

    assert_enqueued(
      worker: BrusselsWtf.Workers.ExtractSource,
      args: %{source_version_id: version.id, generation_kind: "automatic"}
    )

    assert :ok = Ingestion.Pipeline.extract(version.id)
    runs = Ash.load!(version, :processing_runs).processing_runs

    if run = Enum.find(runs, &(&1.processor_role == :ocr)) do
      assert run.inputs["pages"] == [doc.page, doc.attestation_page]
      assert :ok = Ingestion.Pipeline.ocr(run.id, 1)
    end

    version
  end

  defp facts(version),
    do:
      Identity.SourcedFact
      |> Ash.Query.filter(source_version_id == ^version.id)
      |> Ash.read!(authorize?: false)

  defp reviewed?(version),
    do:
      BrusselsWtf.Review.Case
      |> Ash.Query.filter(source_version_id == ^version.id and status == :open)
      |> Ash.read!(authorize?: false)
      |> Enum.any?()

  defp verify!(fact),
    do:
      assert(
        :ok =
          perform_job(BrusselsWtf.Workers.VerifyIxellesMandateDeclaration, %{fact_id: fact.id})
      )

  defp corroborate!(ctx) do
    fact =
      record_minutes_mandate!(
        ctx.person,
        ctx.minutes_version,
        "2024-12-01 Alex Example [municipal-mandate-42] is appointed to the Ixelles municipal council.",
        ctx.commune
      )

    verify_minutes!(fact)
  end

  ## Helpers

  defp record_minutes_mandate!(person, source_version, excerpt, commune) do
    Identity.record_sourced_fact!(%{
      subject_type: :person,
      subject_id: person.id,
      object_type: :commune,
      object_id: commune.id,
      kind: :public_mandate,
      effective_from: ~D[2024-12-01],
      source_version_id: source_version.id,
      authoritative_url: @minutes_url,
      source_authority: :municipal_decision,
      evidence_kind: :official_decision,
      evidence_excerpt: excerpt,
      evidence_location: "decision 267"
    })
  end

  defp verify_minutes!(fact) do
    version =
      Ingestion.get_source_version!(fact.source_version_id)
      |> Ash.load!(source_record: [:commune])

    minutes_text = "Official minutes\n#{fact.evidence_excerpt}\n"

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{"text" => minutes_text}
    })

    {:ok, raw_source} = BrusselsWtf.Archive.get(version.object_key)

    {:ok, rerun} =
      BrusselsWtf.PDF.Processor.native(
        %{sha256: version.sha256, media_type: version.media_type},
        raw_source
      )

    {:ok, archived_text} = BrusselsWtf.Archive.store(minutes_text, :derived)

    text_run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        generation_key: "native:relationship-input:#{fact.id}",
        processor_role: :native_extraction,
        inputs: %{"source_sha256" => version.sha256},
        processor_name: "poppler-native-text",
        processor_version: "fixture-poppler-24.02",
        config_hash: "sha256:fixture-pdf-quality-v1",
        status: :succeeded,
        output: %{"classification" => "accepted native text"},
        quality_measurements: rerun.quality_measurements,
        completed_at: ~U[2026-08-19 12:00:30Z]
      })

    text_artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: version.id,
        processing_run_id: text_run.id,
        input_sha256: version.sha256,
        output_sha256: archived_text.sha256,
        processor_name: text_run.processor_name,
        processor_version: text_run.processor_version,
        config_hash: text_run.config_hash,
        output_kind: "native-text",
        object_key: archived_text.object_key,
        media_type: "text/plain; charset=utf-8",
        byte_size: byte_size(minutes_text),
        schema_version: "derived-artifact-v1",
        quality_measurements: rerun.quality_measurements
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: text_run.id,
      derived_artifact_id: text_artifact.id,
      role: :native_output
    })

    contract = BrusselsWtf.Identity.TrustedVerifier.ixelles_contract()
    person = Identity.get_person!(fact.subject_id)
    commune = version.source_record.commune

    claim =
      BrusselsWtf.Identity.TrustedVerifier.ixelles_semantic_payload(
        fact,
        person,
        commune,
        version
      )

    claim_bytes = Jason.encode!(claim)
    {:ok, archived} = BrusselsWtf.Archive.store(claim_bytes, :derived)

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        generation_key: "relationship:#{fact.id}",
        processor_role: :relationship_verification,
        inputs: %{
          "source_version_sha256" => version.sha256,
          "ruleset_version" => contract.ruleset_version,
          "extraction_run_id" => text_run.id,
          "text_artifact_id" => text_artifact.id
        },
        processor_name: contract.processor_name,
        processor_version: contract.processor_version,
        config_hash: contract.config_hash,
        status: :queued,
        output: %{}
      })

    artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: version.id,
        processing_run_id: run.id,
        input_sha256: version.sha256,
        output_sha256: archived.sha256,
        processor_name: contract.processor_name,
        processor_version: contract.processor_version,
        config_hash: contract.config_hash,
        output_kind: contract.artifact_kind,
        object_key: archived.object_key,
        media_type: "application/json",
        byte_size: byte_size(claim_bytes),
        schema_version: contract.ruleset_version,
        quality_measurements: %{"accepted" => true}
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: run.id,
      derived_artifact_id: artifact.id,
      role: :relationship_claim
    })

    run =
      Ingestion.complete_processing_run!(run, %{
        status: :succeeded,
        output: %{
          "schema_version" => contract.ruleset_version,
          "claim_sha256" => artifact.output_sha256
        },
        quality_measurements: %{"accepted" => true},
        started_at: ~U[2026-08-19 12:01:00Z],
        completed_at: ~U[2026-08-19 12:01:00Z],
        duration_ms: 0
      })

    BrusselsWtf.Identity.TrustedVerifier.verify!(fact.id, @minutes_verifier, run.id)
  end
end
