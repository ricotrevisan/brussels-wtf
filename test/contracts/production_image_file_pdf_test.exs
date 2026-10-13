defmodule BrusselsWtf.Contracts.ProductionImageFilePdfTest do
  use ExUnit.Case, async: false
  @moduletag :external
  @moduletag timeout: 180_000
  @image System.get_env(
           "PRODUCTION_IMAGE",
           "sha256:3df4c19c385e4e27b667d65d3a2c9356c41acc08c7716baa05655fb30449882c"
         )
  @root Path.expand("../..", __DIR__)
  @fixtures Path.join(@root, "test/support/pdf_contract")

  test "credential-free image applies exact native page quality and file hashes" do
    expectations = [
      {"ixelles-born-digital.pdf", 1, []},
      {"uccle-bilingual.pdf", 1, []},
      {"forest-partial-scan.pdf", 2, [2]},
      {"city-rotated.pdf", 1, [1]},
      {"scanned-bilingual.pdf", 1, [1]}
    ]

    for {file, count, rejected} <- expectations do
      result = contract(file)
      assert result["status"] == "ok"
      assert result["page_count"] == count
      assert result["quality_measurements"]["rejected_pages"] == rejected
      assert result["quality_measurements"]["accepted"] == (rejected == [])
      assert result["text_mode"] == 0o600
      refute result["output_has_text"]
      refute "brussels_wtf" in result["started_applications"]
      assert result["tool_versions"]["pdfinfo"] == "pdfinfo version 22.12.0"

      if file == "ixelles-born-digital.pdf" do
        assert result["text_sha256"] ==
                 "e301cdda675e07ee3a9336846d798b3e4dc58a66dce16132b4156c2e1b01cbd6"
      end
    end
  end

  test "image fails closed for encrypted, malformed and excessive page counts" do
    for {file, expected} <- [
          {"encrypted.pdf", ["authentication_failure", ":encrypted_pdf"]},
          {"malformed.pdf", ["invalid_pdf", ":syntax"]},
          {"oversized-pages.pdf", ["oversized_pdf", ":page_limit"]}
        ] do
      result = contract(file)
      assert result["status"] == "error"
      assert result["classification"] == expected
    end
  end

  test "same image enforces subprocess stdout, stderr, file, CPU, memory and descendant wall caps" do
    args =
      envelope() ++
        [
          "--entrypoint",
          "/usr/bin/env",
          @image,
          "-i",
          "PATH=/usr/bin:/bin",
          "TMPDIR=/tmp",
          "PYTHONDONTWRITEBYTECODE=1",
          "/usr/bin/python3",
          "/code/test/support/pdf_contract/file_command_test.py"
        ]

    {output, status} = docker(args)
    assert status == 0, output
    assert output =~ "Ran 13 tests"
    assert output =~ "OK"
  end

  defp contract(file) do
    out = Path.join(System.tmp_dir!(), "image-file-native-#{System.unique_integer([:positive])}")
    File.mkdir!(out)
    File.chmod!(out, 0o700)

    try do
      path = Path.join(@fixtures, file)
      bytes = File.read!(path)
      hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      args =
        envelope() ++
          [
            "-v",
            "#{out}:/out:rw",
            "--entrypoint",
            "/usr/bin/env",
            @image,
            "-i",
            "PATH=/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE=1",
            "/usr/bin/python3",
            "/code/test/support/pdf_contract/file_native_image.py",
            "/code/test/support/pdf_contract/#{file}",
            hash,
            to_string(byte_size(bytes)),
            "/out"
          ]

      {output, status} = docker(args)
      assert status == 0, output
      envelope = File.read!(Path.join(out, "envelope-receipt.json")) |> Jason.decode!()
      assert envelope["exit"] == 0
      refute envelope["wall_exceeded"]
      refute envelope["cpu_exceeded"]
      assert envelope["stderr_bytes"] == 0
      result = File.read!(Path.join(out, "module-receipt.json")) |> Jason.decode!()
      assert result["input_sha256_after"] == hash
      result
    after
      File.rm_rf!(out)
    end
  end

  defp envelope do
    [
      "run",
      "--rm",
      "--network",
      "none",
      "--read-only",
      "--memory",
      "1g",
      "--memory-swap",
      "1g",
      "--cpus",
      "1",
      "--pids-limit",
      "64",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--ulimit",
      "nofile=1024:1024",
      "--ulimit",
      "core=0",
      "--log-driver",
      "none",
      "--user",
      System.get_env("UID", "1000") <> ":" <> System.get_env("GID", "1000"),
      "--tmpfs",
      "/tmp:rw,noexec,nosuid,size=134217728,mode=1777",
      "-v",
      "#{@root}:/code:ro"
    ]
  end

  defp docker(args) do
    if System.get_env("PDF_CONTRACT_SUDO") == "1" do
      System.cmd("sudo", ["-n", "docker" | args], stderr_to_stdout: true)
    else
      System.cmd("docker", args, stderr_to_stdout: true)
    end
  end
end
