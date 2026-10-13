"""One synthetic OCR page + new aggregate accounting, offline pinned image only.

This never invokes native suites, production actions, or application/DB startup.
"""
import glob
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
IMAGE = "sha256:3df4c19c385e4e27b667d65d3a2c9356c41acc08c7716baa05655fb30449882c"
DOCKER = ["sudo", "-n", "docker"]
os.umask(0o077)
out = Path(tempfile.mkdtemp(prefix="ocr-accounting-", dir=os.environ["TMPDIR"]))
code = 'Code.eval_file("/code/test/support/pdf_contract/ocr_accounting_image.exs")'
expr = "application:ensure_all_started(elixir), 'Elixir.Code':eval_string(<<" + json.dumps(code) + ">>)."
inner = "import glob,subprocess; cmd=[glob.glob('/app/erts-*/bin/erl')[0],'+S','1:1','+A','1','-boot','/app/releases/0.1.0/start_clean','-boot_var','RELEASE_LIB','/app/lib','-noshell','-pa']+glob.glob('/app/lib/*/ebin')+['-eval'," + repr(expr) + "]; raise SystemExit(subprocess.run(cmd,timeout=130,env={'PATH':'/usr/bin:/bin','LC_ALL':'C.UTF-8','TMPDIR':'/tmp','ERL_CRASH_DUMP':'/dev/null'}).returncode)"
cmd = DOCKER + ["create", "--network", "none", "--read-only", "--memory", "1g", "--memory-swap", "1g", "--cpus", "1", "--pids-limit", "64", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--ulimit", "nofile=1024:1024", "--ulimit", "core=0", "--log-driver", "none", "--user", "65534:65534", "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=134217728,mode=1777", "--tmpfs", "/scratch:rw,noexec,nosuid,nodev,size=536870912,mode=0700,uid=65534,gid=65534", "-v", str(ROOT)+":/code:ro", "--entrypoint", "/usr/bin/python3", IMAGE, "-c", inner]
cid = subprocess.check_output(cmd, text=True).strip()
try:
    (out / "container-inspect-before.json").write_bytes(subprocess.check_output(DOCKER+["inspect", cid]))
    result = subprocess.run(DOCKER+["start", "-a", cid], capture_output=True, timeout=140)
    (out / "stdout.private").write_bytes(result.stdout)
    (out / "stderr.private").write_bytes(result.stderr)
    (out / "container-inspect-after.json").write_bytes(subprocess.check_output(DOCKER+["inspect", cid]))
    hashes = {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ["lib/brussels_wtf/pdf/file_processor.ex", "lib/brussels_wtf/pdf/file_quality.ex", "priv/pdf/bounded_command.py", "test/support/pdf_contract/ocr_accounting_image.exs", "test/support/pdf_contract/run_ocr_accounting_contract.py"]}
    (out / "source-hashes.json").write_text(json.dumps(hashes, indent=2))
    print(result.stdout.decode())
    print(result.stderr.decode())
    print("RECEIPTS=" + str(out))
finally:
    subprocess.run(DOCKER+["rm", "-f", cid], check=True, stdout=subprocess.DEVNULL)
raise SystemExit(result.returncode)
