defmodule BrusselsWtfWeb.PrincipalSeamTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "an Ixelles source fixture reaches a published meeting page", %{conn: conn} do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")

    assert :ok = BrusselsWtf.Ingestion.poll_now(scenario.commune.slug)
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    conn = get(conn, scenario.expected.path <> "?lang=en")
    html = html_response(conn, 200)

    assert html =~ scenario.expected.title_en
    assert html =~ scenario.expected.citation_url
    assert html =~ "Proposal"
    assert html =~ "Rico Trevisan"
    assert html =~ "Ixelles"
    refute html =~ "What they decided"
  end
end
