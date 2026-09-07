defmodule BrusselsWtf.Contracts.ProductionImagePdfTest do
  use ExUnit.Case, async: false

  @moduletag :external
  @image System.get_env("PRODUCTION_IMAGE", "brussels-wtf:issue21")
  @fixtures Path.expand("../support/pdf_contract", __DIR__)
  @calibration Path.expand("../support/pdf_calibration", __DIR__)

  test "real representative PDFs from all four communes match calibrated native labels" do
    manifest = @calibration |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    assert MapSet.new(Enum.map(manifest["fixtures"], & &1["commune"])) ==
             MapSet.new(["ixelles", "uccle", "forest", "city-of-brussels"])

    for fixture <- manifest["fixtures"] do
      bytes = File.read!(Path.join(@calibration, fixture["file"]))
      assert BrusselsWtf.Digest.sha256(bytes) == fixture["sha256"]

      result = contract(fixture["file"], fixture_root: @calibration)
      assert result["status"] == "ok"
      assert result["page_count"] == fixture["expected_page_count"]
      assert result["quality_measurements"]["accepted"]
      assert result["quality_measurements"]["rejected_pages"] == []
      assert result["text_sha256"] == fixture["expected_text_sha256"]
    end
  end

  test "pinned production image applies calibrated native decisions for all four communes" do
    manifest = @fixtures |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    for fixture <- manifest["fixtures"] do
      bytes = File.read!(Path.join(@fixtures, fixture["file"]))
      assert BrusselsWtf.Digest.sha256(bytes) == fixture["sha256"]
    end

    ixelles = contract("ixelles-born-digital.pdf")
    uccle = contract("uccle-bilingual.pdf")
    forest = contract("forest-partial-scan.pdf")
    city = contract("city-rotated.pdf")
    scanned = contract("scanned-bilingual.pdf")
    malformed = contract("malformed.pdf")
    encrypted = contract("encrypted.pdf")
    unsupported_ocr_input = contract("malformed.pdf", mode: "ocr", pages: "1")

    assert ixelles["process_role"] == "app"

    assert ixelles["process_queues"] == %{
             "poll" => 1,
             "fetch" => 2,
             "extract" => 1,
             "normalize" => 1,
             "enrich" => 1,
             "publish" => 1,
             "corpus" => 1,
             "maintenance" => 1
           }

    assert ixelles["oban_plugins_enabled"]
    assert ixelles["ocr_concurrency"] == nil
    assert ixelles["quality_measurements"]["accepted"]
    assert uccle["quality_measurements"]["accepted"]
    assert forest["quality_measurements"]["rejected_pages"] == [2]
    assert city["quality_measurements"]["rejected_pages"] == [1]
    assert scanned["quality_measurements"]["rejected_pages"] == [1]
    assert malformed == %{"status" => "error", "classification" => ["invalid_pdf", "syntax"]}

    assert encrypted == %{
             "status" => "error",
             "classification" => ["authentication_failure", "encrypted_pdf"]
           }

    assert unsupported_ocr_input["status"] == "error"
    assert hd(unsupported_ocr_input["classification"]) == "invalid_content"

    assert ixelles["tool_versions"]["tesseract"] =~ "tesseract 5."
    assert ixelles["tool_versions"]["tesseract_languages"] == "fra,nld,osd"
    assert ixelles["tool_versions"]["pdfinfo"] =~ "pdfinfo version"

    assert ixelles["text_sha256"] ==
             "e301cdda675e07ee3a9336846d798b3e4dc58a66dce16132b4156c2e1b01cbd6"
  end

  test "partially scanned input OCRs only the rejected page with fra+nld" do
    result =
      contract("forest-partial-scan.pdf",
        mode: "ocr",
        pages: "2",
        env: %{"PROCESS_ROLE" => "ocr"},
        docker_options: ["--cpus", "1", "--memory", "1g"]
      )

    assert result["status"] == "ok"
    assert result["process_role"] == "ocr"
    assert result["process_queues"] == %{"ocr" => 1}
    refute result["oban_plugins_enabled"]
    assert result["ocr_concurrency"] == 1
    assert result["quality_measurements"]["accepted"]
    assert result["quality_measurements"]["rejected_pages"] == []
    assert is_binary(result["pdf_sha256"])
    assert is_binary(result["text_sha256"])

    rotated = contract("city-rotated.pdf", mode: "ocr", pages: "1")
    assert rotated["status"] == "ok"
    assert rotated["quality_measurements"]["accepted"]
  end

  test "byte and wall-time limits fail with safe deterministic classifications" do
    tmp =
      Path.join(System.tmp_dir!(), "brussels-wtf-oversized-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    source = File.read!(Path.join(@fixtures, "ixelles-born-digital.pdf"))

    File.write!(
      Path.join(tmp, "oversized.pdf"),
      source <> :binary.copy(<<0>>, 25 * 1_024 * 1_024)
    )

    assert contract("oversized.pdf", fixture_root: tmp) == %{
             "status" => "error",
             "classification" => ["oversized_pdf", "byte_limit"]
           }

    assert contract("oversized-pages.pdf") == %{
             "status" => "error",
             "classification" => ["oversized_pdf", "page_limit"]
           }

    assert contract("scanned-bilingual.pdf",
             mode: "ocr",
             pages: "1",
             env: %{"PDF_OCR_CPU_SECONDS" => "1"}
           ) == %{"status" => "error", "classification" => ["ocr_limit", "cpu_memory_or_kill"]}

    assert contract("scanned-bilingual.pdf",
             mode: "ocr",
             pages: "1",
             env: %{"PDF_OCR_MEMORY_BYTES" => "67108864"}
           ) == %{"status" => "error", "classification" => ["ocr_limit", "memory"]}

    assert contract("scanned-bilingual.pdf",
             mode: "ocr",
             pages: "1",
             env: %{"PDF_OCR_WALL_TIME_MS" => "1"}
           ) == %{"status" => "error", "classification" => ["ocr_limit", "wall_time"]}
  end

  defp contract(file, options \\ []) do
    root = Keyword.get(options, :fixture_root, @fixtures)
    mode = Keyword.get(options, :mode, "native")
    pages = Keyword.get(options, :pages)
    extra_env = Keyword.get(options, :env, %{})
    docker_options = Keyword.get(options, :docker_options, [])

    environment =
      %{
        "REVIEW_USERNAME" => "contract",
        "REVIEW_PASSWORD" => "contract-password-long",
        "DATABASE_URL" => "ecto://unused:unused@127.0.0.1/unused",
        "SECRET_KEY_BASE" => String.duplicate("x", 64),
        "PROCESS_ROLE" => "app",
        "PDF_CONTRACT_PATH" => "/fixtures/#{file}",
        "PDF_CONTRACT_MODE" => mode
      }
      |> maybe_put("PDF_CONTRACT_PAGES", pages)
      |> Map.merge(extra_env)

    args =
      ["run", "--rm"] ++
        docker_options ++
        ["-v", "#{root}:/fixtures:ro"] ++
        Enum.flat_map(environment, fn {key, value} -> ["-e", "#{key}=#{value}"] end) ++
        [
          "--entrypoint",
          "/app/bin/brussels_wtf",
          @image,
          "eval",
          "BrusselsWtf.PDF.Contract.print_from_env()"
        ]

    {output, 0} = System.cmd("docker", args, stderr_to_stdout: true)

    line =
      output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "PDF_CONTRACT_JSON="))

    line |> String.replace_prefix("PDF_CONTRACT_JSON=", "") |> Jason.decode!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
