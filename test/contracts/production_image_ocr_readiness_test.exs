defmodule BrusselsWtf.Contracts.ProductionImageOcrReadinessTest do
  use ExUnit.Case, async: false

  @moduletag :external
  @moduletag timeout: 180_000
  @image System.get_env("PRODUCTION_IMAGE", "brussels-wtf:issue21")
  @postgres_image System.get_env("OCR_CONTRACT_POSTGRES_IMAGE", "postgres:17-alpine")
  @fixtures Path.expand("../support/ocr_readiness_contract", __DIR__)

  setup_all do
    suffix = "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
    network = "ocr-readiness-contract-#{suffix}"
    database = "#{network}-db"
    migrator = "#{network}-migrate"

    on_exit(fn ->
      docker(["rm", "-f", "-v", migrator, database])
      docker(["network", "rm", network])
    end)

    docker!(["network", "create", "--internal", network])

    docker!([
      "run",
      "-d",
      "--name",
      database,
      "--network",
      network,
      "--network-alias",
      "database",
      "-e",
      "POSTGRES_USER=contract",
      "-e",
      "POSTGRES_PASSWORD=contract",
      "-e",
      "POSTGRES_DB=contract",
      @postgres_image
    ])

    eventually(fn ->
      {_output, status} =
        docker(["exec", database, "pg_isready", "-U", "contract", "-d", "contract"])

      status == 0
    end)

    docker!(
      ["run", "--rm", "--name", migrator, "--network", network, "--ulimit", "nofile=65536:65536"] ++
        environment() ++ ["--entrypoint", "/app/bin/migrate", @image]
    )

    # Execute the image's actual health command, not an independently recreated
    # assertion about what Dockerfile text ought to contain.
    command =
      docker!([
        "image",
        "inspect",
        @image,
        "--format",
        "{{range .Config.Healthcheck.Test}}{{println .}}{{end}}"
      ])
      |> String.split("\n", trim: true)
      |> health_command()

    {:ok, network: network, command: command}
  end

  test "image health follows dependency readiness, actual queue state, and runtime role",
       context do
    container = start_release(context)
    assert_healthy(container, context.command)
    assert {_, 0} = health(container, ["/app/bin/ocr_ready"])

    rpc!(
      container,
      "Agent.update(BrusselsWtf.OcrReadinessContract.Checks, fn _ -> {:error, :archive_unavailable} end)"
    )

    eventually(fn ->
      rpc(container, "BrusselsWtf.Readiness.Monitor.status()") == "{:error, :not_ready}"
    end)

    assert_unhealthy(container, context.command)

    rpc!(container, "Agent.update(BrusselsWtf.OcrReadinessContract.Checks, fn _ -> :ok end)")
    assert_healthy(container, context.command)

    rpc!(container, "Oban.pause_queue(queue: :ocr, local_only: true)")
    eventually(fn -> rpc(container, "Oban.check_queue(queue: :ocr).paused") == "true" end)
    assert_unhealthy(container, context.command)

    rpc!(container, "Oban.resume_queue(queue: :ocr, local_only: true)")
    assert_healthy(container, context.command)

    rpc!(container, "Oban.scale_queue(queue: :ocr, limit: 2, local_only: true)")
    eventually(fn -> rpc(container, "Oban.check_queue(queue: :ocr).limit") == "2" end)
    assert_unhealthy(container, context.command)

    rpc!(container, "Oban.scale_queue(queue: :ocr, limit: 1, local_only: true)")
    assert_healthy(container, context.command)

    # Docker still has PROCESS_ROLE=ocr. The running node, not a fresh eval VM
    # reading that environment, must decide whether this is an OCR consumer.
    rpc!(container, "Application.put_env(:brussels_wtf, :process_role, :app)")
    assert_unhealthy(container, context.command)
    assert rpc(container, "Application.get_env(:brussels_wtf, :process_role)") == ":app"
  end

  test "consumer crash makes a live container unhealthy until supervision recovers", context do
    container = start_release(context)
    assert_healthy(container, context.command)

    # Hold automatic restart only while observing the failure. This kills the
    # real queue producer; it does not replace readiness or Oban's state.
    rpc!(container, """
    supervisor = Oban.Registry.whereis(Oban, {:queue, "ocr"})
    :ok = :sys.suspend(supervisor)
    producer = Oban.Registry.whereis(Oban, {:producer, "ocr"})
    ref = Process.monitor(producer)
    Process.exit(producer, :kill)
    receive do
      {:DOWN, ^ref, :process, ^producer, :killed} -> :ok
    after
      2_000 -> raise "OCR consumer did not crash"
    end
    """)

    assert rpc(container, "BrusselsWtf.Readiness.Monitor.status()") == ":ok"
    assert {_, 0} = docker(["exec", container, "sh", "-c", "kill -0 1"])
    assert_unhealthy(container, context.command)
    eventually(fn -> state(container, "{{.State.Health.Status}}") == "unhealthy" end)

    rpc!(container, ":sys.resume(Oban.Registry.whereis(Oban, {:queue, \"ocr\"}))")
    assert_healthy(container, context.command)
    eventually(fn -> state(container, "{{.State.Health.Status}}") == "healthy" end)
  end

  test "health is bounded when the running readiness monitor stops responding", context do
    container = start_release(context)
    assert_healthy(container, context.command)
    rpc!(container, ":sys.suspend(BrusselsWtf.Readiness.Monitor)")

    started = System.monotonic_time(:millisecond)
    assert_unhealthy(container, context.command)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert rpc(container, "Application.get_env(:brussels_wtf, :process_role)") == ":ocr"

    rpc!(container, ":sys.resume(BrusselsWtf.Readiness.Monitor)")
    assert_healthy(container, context.command)
  end

  test "a live PID 1 without a release node never passes OCR health", context do
    container = start_container(context, ["--entrypoint", "tail"], ["-f", "/dev/null"])
    assert {_, 0} = docker(["exec", container, "sh", "-c", "kill -0 1"])

    started = System.monotonic_time(:millisecond)
    assert_unhealthy(container, context.command)
    assert System.monotonic_time(:millisecond) - started < 5_000
    eventually(fn -> state(container, "{{.State.Health.Status}}") == "unhealthy" end)
  end

  test "default OCR startup fails validation before a worker can report healthy", context do
    # No source archive settings are supplied. Migrations are already up in the
    # disposable database, so the real default entrypoint reaches archive validation.
    container = start_container(context)
    eventually(fn -> state(container, "{{.State.Status}}") == "exited" end)

    refute state(container, "{{.State.ExitCode}}") == "0"
    refute state(container, "{{.State.Health.Status}}") == "healthy"
    logs = docker!(["logs", container])

    assert logs =~ "Database migration validation passed",
           "validation did not reach the archive: #{state(container, "{{json .State}}")}\n#{logs}"

    assert logs =~ "source archive validation failed"
    refute logs =~ "contract-password-long"
    refute logs =~ "ecto://contract:contract@database/contract"
  end

  test "default OCR entrypoint validates real dependencies and starts a healthy consumer",
       context do
    archive_environment = start_archive(context)
    container = start_container(context, archive_environment)

    eventually(fn ->
      running = state(container, "{{.State.Running}}")
      assert running == "true", "configured startup failed:\n#{docker!(["logs", container])}"
      state(container, "{{.State.Health.Status}}") == "healthy"
    end)

    assert {_, 0} = health(container, context.command)
    assert rpc(container, "Application.get_env(:brussels_wtf, :process_role)") == ":ocr"

    worker_pid = rpc(container, "System.pid()")
    memory_before = container |> rpc(":erlang.memory(:total)") |> String.to_integer()

    for _ <- 1..5 do
      assert {_, 0} = health(container, context.command)
    end

    memory_after = container |> rpc(":erlang.memory(:total)") |> String.to_integer()
    assert rpc(container, "System.pid()") == worker_pid
    assert memory_after <= memory_before + 32 * 1_024 * 1_024

    IO.puts(
      "OCR_HEALTH_STABILITY pid=#{worker_pid} " <>
        "memory_before_bytes=#{memory_before} memory_after_bytes=#{memory_after} probes=5"
    )

    assert rpc(
             container,
             "{Oban.check_queue(queue: :ocr).limit, Oban.check_queue(queue: :ocr).paused}"
           ) == "{1, false}"

    # The OCR role serves no HTTP endpoint, even though its actual consumer is ready.
    assert rpc(
             container,
             ":gen_tcp.connect(~c\"127.0.0.1\", 3000, [:binary, active: false], 500)"
           ) == "{:error, :econnrefused}"

    logs = docker!(["logs", container])
    assert logs =~ "Database migration validation passed"
    assert logs =~ "Source archive validation passed"
    assert logs =~ "PDF toolchain validation passed"
    assert logs =~ "Automatic transcription is disabled"
    refute logs =~ "contract-archive-secret-long"
  end

  defp start_archive(context) do
    archive = "#{context.network}-archive"
    client = "#{context.network}-archive-client"

    on_exit(fn -> docker(["rm", "-f", "-v", client, archive]) end)

    # Only this test owns this service and its anonymous data volume. Neither
    # existing estate services nor credentials from the host are consulted.
    docker!([
      "run",
      "-d",
      "--name",
      archive,
      "--network",
      context.network,
      "--network-alias",
      "archive",
      "--cpus",
      "1",
      "--memory",
      "512m",
      "-e",
      "RUSTFS_ACCESS_KEY=contract-archive-access",
      "-e",
      "RUSTFS_SECRET_KEY=contract-archive-secret-long",
      "-e",
      "RUSTFS_OBS_LOG_DIRECTORY=",
      System.get_env("OCR_CONTRACT_RUSTFS_IMAGE", "rustfs/rustfs:latest")
    ])

    eventually(fn ->
      assert state(archive, "{{.State.Running}}") == "true",
             "disposable archive failed:\n#{docker!(["logs", archive])}"

      {_output, status} =
        docker([
          "run",
          "--rm",
          "--name",
          client,
          "--network",
          context.network,
          "--cpus",
          "1",
          "--memory",
          "128m",
          "-e",
          "MC_HOST_contract=http://contract-archive-access:contract-archive-secret-long@archive:9000",
          System.get_env("OCR_CONTRACT_MC_IMAGE", "minio/mc:latest"),
          "mb",
          "--ignore-existing",
          "contract/ocr-readiness-contract"
        ])

      status == 0
    end)

    [
      "-e",
      "SOURCE_ARCHIVE_S3_ENDPOINT=http://archive:9000",
      "-e",
      "SOURCE_ARCHIVE_S3_BUCKET=ocr-readiness-contract",
      "-e",
      "SOURCE_ARCHIVE_S3_REGION=us-east-1",
      "-e",
      "SOURCE_ARCHIVE_S3_ACCESS_KEY_ID=contract-archive-access",
      "-e",
      "SOURCE_ARCHIVE_S3_SECRET_ACCESS_KEY=contract-archive-secret-long"
    ]
  end

  defp start_release(context) do
    container =
      start_container(
        context,
        [
          "--mount",
          "type=bind,source=#{@fixtures},target=/contract,readonly",
          "--entrypoint",
          "/app/bin/brussels_wtf"
        ],
        ["eval", "Code.require_file(\"/contract/boot.exs\")"]
      )

    eventually(fn ->
      {output, status} = docker(["logs", container])

      assert state(container, "{{.State.Running}}") == "true",
             "release boot failed: #{state(container, "{{json .State}}")}\n#{docker!(["logs", container])}"

      status == 0 and String.contains?(output, "OCR_CONTRACT_BOOTED")
    end)

    eventually(fn ->
      rpc(
        container,
        "{BrusselsWtf.Readiness.Monitor.status(), Oban.check_queue(queue: :ocr).limit}"
      ) == "{:ok, 1}"
    end)

    container
  end

  defp start_container(context, options \\ [], arguments \\ []) do
    container = "#{context.network}-#{System.unique_integer([:positive])}"
    on_exit(fn -> docker(["rm", "-f", container]) end)

    # Some Docker daemons inherit a billion-descriptor nofile limit. OTP sizes
    # its port table from that limit and can OOM before loading any application.
    docker!(
      [
        "run",
        "-d",
        "--name",
        container,
        "--network",
        context.network,
        "--cpus",
        "1",
        "--memory",
        "1g",
        "--pids-limit",
        "512",
        "--ulimit",
        "nofile=65536:65536",
        "--health-interval",
        "1s",
        "--health-start-period",
        "1s",
        "--health-retries",
        "1"
      ] ++
        environment() ++ options ++ [@image] ++ arguments
    )

    container
  end

  defp environment do
    Enum.flat_map(
      %{
        "PROCESS_ROLE" => "ocr",
        "REVIEW_USERNAME" => "contract",
        "REVIEW_PASSWORD" => "contract-password-long",
        "DATABASE_URL" => "ecto://contract:contract@database/contract",
        "SECRET_KEY_BASE" => String.duplicate("x", 64),
        "ERL_FLAGS" => "+S 2:2 +SDcpu 1 +SDio 1",
        "POOL_SIZE" => "2",
        "COVERAGE_GENERATION_MODE" => "disabled"
      },
      fn {key, value} -> ["-e", "#{key}=#{value}"] end
    )
  end

  defp health_command(["CMD-SHELL" | command]), do: ["/bin/sh", "-c", Enum.join(command, "\n")]
  defp health_command(["CMD" | command]), do: command

  defp health(container, command), do: docker(["exec", container | command])

  defp assert_healthy(container, command) do
    eventually(fn ->
      {_output, status} = health(container, command)
      status == 0
    end)
  end

  defp assert_unhealthy(container, command) do
    {output, status} = health(container, command)
    assert status != 0, "OCR health incorrectly succeeded: #{output}"
    # 124 here would be the test harness's outer timeout, not a bounded probe.
    refute status == 124, "OCR health exceeded the outer Docker command timeout"
  end

  defp rpc!(container, expression) do
    docker!(["exec", container, "/app/bin/brussels_wtf", "rpc", expression])
  end

  defp rpc(container, expression) do
    {output, status} =
      docker(["exec", container, "/app/bin/brussels_wtf", "rpc", "IO.inspect(#{expression})"])

    if status == 0, do: String.trim(output), else: {:rpc_failed, output}
  end

  defp state(container, template),
    do: docker!(["inspect", container, "--format", template]) |> String.trim()

  defp docker!(arguments) do
    {output, status} = docker(arguments)
    assert status == 0, "docker #{Enum.join(arguments, " ")} failed (#{status}):\n#{output}"
    output
  end

  defp docker(arguments) do
    System.cmd("timeout", ["--kill-after=1s", "45s", "docker" | arguments],
      stderr_to_stdout: true
    )
  end

  defp eventually(check, timeout \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_condition(check, deadline)
  end

  defp await_condition(check, deadline) do
    if check.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "container condition did not become true"

      Process.sleep(100)
      await_condition(check, deadline)
    end
  end
end
