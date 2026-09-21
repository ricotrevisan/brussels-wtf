defmodule BrusselsWtfWeb.MunicipalInstallationOpsTest do
  use BrusselsWtf.DataCase, async: false
  import ExUnit.CaptureIO

  alias BrusselsWtf.Identity

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    :ok
  end

  test "helper reveals only counts until verified public URLs exist; cap is cumulative" do
    BrusselsWtf.MunicipalInstallationArchiveFixture.load!("forest")

    preview = run(operation: :preview, communes: ["forest"])
    assert preview =~ "eligible: 3"
    refute preview =~ "/people/"
    assert Identity.list_public_relationships!() == []

    first = run(operation: :publish, communes: ["forest"], max_facts_per_commune: 2)
    assert first =~ "published_new: 2"
    assert length(Identity.list_public_relationships!()) == 2

    again = run(operation: :publish, communes: ["forest"], max_facts_per_commune: 2)
    assert again =~ "published_new: 0"
    assert again =~ "published_existing: 2"

    next = run(operation: :publish, communes: ["forest"], max_facts_per_commune: 3)
    assert next =~ "published_new: 1"
    assert next =~ "published_existing: 2"
    assert length(Identity.list_public_relationships!()) == 3

    for role <- Identity.list_public_relationships!() do
      assert next =~ "/people/#{role.subject_id}?lang=en"
    end

    for output <- [preview, first, again, next],
        private <- [
          "Chloé",
          "Jean-Louis",
          "Zoé",
          "PRIVATE",
          "secret@example.invalid",
          "raw/",
          "object_key",
          "candidates",
          "source_version_id"
        ] do
      refute output =~ private
    end
  end

  test "missing evidence reports a safe failure rather than private diagnostics" do
    output = run(operation: :preview, communes: ["forest"])
    assert output =~ "failed: true"
    refute output =~ "error:"
    refute output =~ "/people/"
  end

  test "unknown options, missing or duplicate scope, and non-cumulative bounds are rejected" do
    for options <- [
          [operation: :publish, communes: ["forest"], max_facts_per_commune: 0],
          [operation: :publish, communes: ["forest"], max_facts_per_commune: 101],
          [operation: :publish, communes: ["forest"], max_facts_per_commune: "2"],
          [operation: :publish, communes: ["forest"]],
          [operation: :acquire, communes: []],
          [operation: :acquire, communes: ["forest", "forest"]],
          [operation: :acquire, communes: ["elsewhere"]],
          [operation: :preview, communes: ["forest"], names: ["PRIVATE"]],
          [operation: :drain, communes: ["forest"]]
        ] do
      assert run(options) =~ "invalid_options"
    end

    assert Identity.list_public_relationships!() == []
  end

  defp run(options) do
    capture_io(fn ->
      assert {:ok, returned_bindings} =
               Code.eval_string(File.read!("priv/ops/municipal_installations.exs"), options)

      assert Map.new(returned_bindings) == Map.new(options)
    end)
  end
end
