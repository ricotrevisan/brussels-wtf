defmodule BrusselsWtf.Corpus.ManifestTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Corpus.Manifest

  test "the recorded corpus is exactly eight real meetings and 24 varied anchored items" do
    manifest = Manifest.load!()
    meetings = manifest["meetings"]

    assert length(meetings) == 8

    assert meetings |> Enum.map(& &1["commune"]) |> MapSet.new() ==
             MapSet.new(~w(ixelles uccle forest city-of-brussels))

    assert Enum.frequencies_by(meetings, & &1["commune"]) == %{
             "ixelles" => 2,
             "uccle" => 2,
             "forest" => 2,
             "city-of-brussels" => 2
           }

    items = Enum.flat_map(meetings, & &1["items"])
    assert length(items) == 24
    assert length(Enum.uniq_by(items, &{&1["key"], &1["source_wording"]})) == 24

    assert Enum.count(
             meetings,
             &Enum.any?(&1["items"], fn item -> item["state"] == "decision" end)
           ) >= 2

    refute Enum.any?(meetings, &String.starts_with?(&1["municipal_identifier"], "demo-"))
  end

  test "every approved source hash normalizes only when its markers are present" do
    for meeting <- Manifest.load!()["meetings"], source <- meeting["sources"] do
      evidence =
        meeting["items"]
        |> Enum.filter(&(&1["source"] == source["name"]))
        |> Enum.map(fn item ->
          if item["state"] == "proposal",
            do: item["proposal"]["excerpt"],
            else: item["decision"]["excerpt"]
        end)

      text = Enum.join(source["markers"] ++ evidence, "\n")

      assert {:ok, normalized} =
               Manifest.normalize(%{"sha256" => source["sha256"], "text" => text})

      assert normalized["meeting_identifier"] == meeting["municipal_identifier"]
      assert normalized["items"] != []

      assert {:error, {:normalization_ambiguity, _details}} =
               Manifest.normalize(%{"sha256" => source["sha256"], "text" => "changed bytes"})
    end

    assert {:error, :processor_unimplemented} =
             Manifest.normalize(%{"sha256" => String.duplicate("0", 64), "text" => "unknown"})
  end

  test "recorded coverage requires the exact complete claim contract and returns all locales" do
    for meeting <- Manifest.load!()["meetings"] do
      input = publication_input(meeting)
      assert {:ok, canonical} = Manifest.recorded_bundle(input, "fr")

      assert MapSet.new(Map.keys(canonical["items"])) ==
               MapSet.new(Enum.map(meeting["items"], & &1["key"]))

      assert {:ok, nl} = Manifest.recorded_translation(canonical, "nl")
      assert {:ok, en} = Manifest.recorded_translation(canonical, "en")
      assert nl["page"]["title"] == meeting["coverage"]["nl"]["title"]
      assert en["page"]["title"] == meeting["coverage"]["en"]["title"]

      changed = put_in(input, ["items", Access.at(0), "claims", Access.at(0), "text"], "changed")
      assert {:error, :recorded_coverage_not_available} = Manifest.recorded_bundle(changed, "fr")
    end
  end

  test "bundle paths cannot escape the sealed release directory" do
    assert_raise ArgumentError, ~r/escapes the sealed bundle/, fn ->
      Manifest.bundle_path!(%{"bundle_path" => "sources/../../config/runtime.exs"})
    end
  end

  test "the release-owned source bundle matches every pinned authoritative byte sequence" do
    for meeting <- Manifest.load!()["meetings"], source <- meeting["sources"] do
      bytes = source |> Manifest.bundle_path!() |> File.read!()
      assert byte_size(bytes) == source["byte_size"]
      assert BrusselsWtf.Digest.sha256(bytes) == source["sha256"]
    end
  end

  test "the dossier linkage uses one exact municipal identifier across two City meetings" do
    assert [dossier] = Manifest.load!()["dossiers"]
    assert dossier["slug"] == "city-opp-2026-185-fritkot-socles"

    assert Enum.map(dossier["links"], & &1["meeting"]) ==
             ["city-2026-06-08", "city-2026-06-29"]

    assert dossier["link_basis"] =~ "OPP/2026/185"
    assert dossier["titles"]["fr"] =~ "Socles"
    assert dossier["titles"]["nl"] =~ "Sokkels"
    assert dossier["titles"]["en"] =~ "Bases"
  end

  defp publication_input(meeting) do
    sources = Map.new(meeting["sources"], &{&1["name"], &1})

    %{
      "commune_slug" => meeting["commune"],
      "meeting_identifier" => meeting["municipal_identifier"],
      "scheduled_on" => meeting["scheduled_on"],
      "items" =>
        Enum.map(meeting["items"], fn item ->
          source = Map.fetch!(sources, item["source"])
          claim = if item["state"] == "proposal", do: item["proposal"], else: item["decision"]
          kind = item["state"]

          normalized_claim = %{
            "key" => "#{kind}:#{item["key"]}:#{source["sha256"]}",
            "kind" => kind,
            "text" => if(kind == "decision", do: claim["statement"], else: claim["text"]),
            "evidence" => [
              %{
                "citation_url" => source["url"],
                "excerpt" => claim["excerpt"],
                "location" => claim["location"],
                "retrieved_at" => "2026-08-21T14:00:00Z",
                "source_sha256" => source["sha256"],
                "source_origin_url" => source["url"],
                "synthetic" => false
              }
            ]
          }

          normalized_claim =
            if kind == "decision" do
              normalized_claim
              |> Map.put("disposition", claim["disposition"])
              |> Map.put("vote", nil)
            else
              normalized_claim
            end

          %{
            "key" => item["key"],
            "item_number" => item["item_number"],
            "procedural_state" => kind,
            "outcome" => if(kind == "decision", do: claim["disposition"], else: "unknown"),
            "source_wording" => item["source_wording"],
            "claims" => [normalized_claim]
          }
        end)
    }
  end
end
