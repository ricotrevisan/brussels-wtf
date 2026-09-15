defmodule BrusselsWtf.TED.CorrectionChainTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.TED.CorrectionChain

  test "orders explicit predecessors and keeps a later cancellation terminal" do
    first = notice("first", nil, :awarded)
    second = notice("second", "first-01", :not_awarded)
    assert {:ok, %{latest: ^second, history: [^first]}} = CorrectionChain.select([second, first])
    assert {:ok, %{latest: ^first, history: []}} = CorrectionChain.select([first])
  end

  test "gaps, forks, cycles, duplicate identities and procedure drift fail closed" do
    first = notice("first", nil, :awarded)
    second = notice("second", "first-01", :awarded)

    for notices <- [
          [],
          [second],
          [first, first],
          [first, second, notice("third", "first-01", :awarded)],
          [%{first | correction_of: "second-01"}, second],
          [first, %{second | procedure_id: "different"}],
          [first, %{second | lot_id: "LOT-9999"}],
          [first, %{second | published_on: ~D[2025-01-01]}],
          [first, %{second | publication_number: first.publication_number}],
          [first, %{second | buyer: %{raw_identifier: "another"}}],
          [%{}]
        ] do
      assert {:error, :incomplete_or_ambiguous_correction_chain} = CorrectionChain.select(notices)
    end
  end

  test "versions increase for the same UUID even when publication dates increase" do
    first = notice("same-uuid", nil, :awarded)

    later = %{
      first
      | version: "02",
        publication_number: "later",
        published_on: ~D[2026-09-02],
        correction_of: "same-uuid-01"
    }

    assert {:ok, %{latest: ^later}} = CorrectionChain.select([later, first])

    for version <- ["00", "01", "invalid"] do
      prior = %{first | version: "02"}
      regression = %{later | version: version, correction_of: "same-uuid-02"}
      assert {:error, _} = CorrectionChain.select([prior, regression])
    end
  end

  @tag :external
  test "retained Ixelles correction replaces a no-winner result without discarding history" do
    directory = System.fetch_env!("TED_EVIDENCE_DIR")

    notices =
      for id <- ["181194-2026", "22171-2026"] do
        {:ok, notice} =
          BrusselsWtf.TED.AwardNotice.parse(
            File.read!(Path.join(directory, id <> ".xml")),
            "LOT-0002"
          )

        notice
      end

    assert {:ok, %{latest: latest, history: [previous]}} = CorrectionChain.select(notices)
    assert latest.status == :awarded
    assert previous.status == :not_awarded
  end

  defp notice(id, previous, status) do
    %{
      notice_id: id,
      version: "01",
      publication_number: id,
      procedure_id: "procedure",
      lot_id: "LOT-0001",
      buyer: %{raw_identifier: "0207401341"},
      published_on: ~D[2026-09-01],
      correction_of: previous,
      status: status
    }
  end
end
