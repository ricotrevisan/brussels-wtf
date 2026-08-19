defmodule BrusselsWtfWeb.OcrPrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "page-selective OCR fallback can traverse normalization and atomic publication", %{
    conn: conn
  } do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    agenda = scenario.sources.agenda
    native = agenda.outputs.extract

    BrusselsWtf.Processors.Stub.put(agenda.sha256, %{
      extract: native |> Map.put("text", "") |> Map.put("page_texts", [""]),
      ocr: %{
        "page_texts" => [native["text"]],
        "searchable_pdf" => "%PDF recorded searchable agenda"
      },
      normalize: agenda.outputs.normalize,
      locales: agenda.outputs.locales
    })

    assert :ok = BrusselsWtf.Ingestion.poll_now(scenario.commune.slug)
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert page.publication_status == :published

    assert html_response(get(conn, "/meetings/ixelles/268?lang=en"), 200) =~
             "Proposed grant for a screening"

    history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, agenda.url)
    [version] = history.versions
    runs = Ash.load!(version, processing_runs: [:derived_artifacts]).processing_runs
    native_run = Enum.find(runs, &(&1.processor_role == :native_extraction))
    ocr_run = Enum.find(runs, &(&1.processor_role == :ocr))

    assert native_run.quality_measurements["rejected_pages"] == [1]
    assert ocr_run.status == :succeeded

    assert MapSet.new(Enum.map(native_run.derived_artifacts, & &1.output_kind)) ==
             MapSet.new(["native-text"])

    assert MapSet.new(Enum.map(ocr_run.derived_artifacts, & &1.output_kind)) ==
             MapSet.new(["ocr-pdf", "ocr-text"])
  end
end
