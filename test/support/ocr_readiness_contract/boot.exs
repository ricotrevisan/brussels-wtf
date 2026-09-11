# Mounted only into disposable contract containers. Production modules are not replaced.
defmodule BrusselsWtf.OcrReadinessContract.Checks do
  def check do
    Agent.get(__MODULE__, & &1)
  end
end

# `eval` loads the production release without starting its application. Start the
# same distributed node used by `start`, then boot the real application supervisor.
[epmd] = Path.wildcard("/app/erts-*/bin/epmd")
{_, 0} = System.cmd(epmd, ["-daemon"])
{:ok, _} = Node.start(:brussels_wtf, :shortnames)
{:ok, _} = Agent.start_link(fn -> :ok end, name: BrusselsWtf.OcrReadinessContract.Checks)

Application.put_env(:brussels_wtf, BrusselsWtf.Readiness.Monitor,
  checks: BrusselsWtf.OcrReadinessContract.Checks,
  interval: 100,
  stale_after: 2_000,
  timeout: 1_000
)

# Archive I/O is outside this health-command contract. The real startup-validation
# test deliberately omits this fixture and must reject an unconfigured archive.
Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)

{:ok, _} = Application.ensure_all_started(:brussels_wtf)
IO.puts("OCR_CONTRACT_BOOTED")
Process.sleep(:infinity)
