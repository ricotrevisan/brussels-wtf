"""Exact-image standalone BEAM boot; private receipts, no app/DB/network."""
import glob
import json
import os
import pathlib
import resource
import signal
import subprocess
import sys
import time

os.umask(0o077)
source, expected_hash, expected_bytes, out = sys.argv[1:5]
workspace = out + '/workspace'
os.mkdir(workspace, 0o700)
receipt = out + '/module-receipt.json'
expr = ('application:ensure_all_started(elixir), '
        "'Elixir.System':argv([" + ','.join('<<' + json.dumps(s) + '>>' for s in
        [source, expected_hash, expected_bytes, workspace, receipt]) + ']), '
        "'Elixir.Code':eval_file(<<\"/code/test/support/pdf_contract/file_native_image.exs\">>), init:stop().")
erts = glob.glob('/app/erts-*/bin/erl')
assert len(erts) == 1
cmd = [erts[0], '+S', '1:1', '+A', '1', '-boot', '/app/releases/0.1.0/start_clean',
       '-boot_var', 'RELEASE_LIB', '/app/lib', '-noshell', '-pa']
cmd += glob.glob('/app/lib/*/ebin') + ['-eval', expr]
def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (90, 90))
    resource.setrlimit(resource.RLIMIT_FSIZE, (67108864, 67108864))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
started = time.monotonic()
wall = False
cpu_limit = False
def cpu_usec():
    return int(dict(line.split() for line in pathlib.Path('/sys/fs/cgroup/cpu.stat').read_text().splitlines())['usage_usec'])
cpu_started = cpu_usec()
with open(out + '/beam.stdout.private', 'wb') as stdout, open(out + '/beam.stderr.private', 'wb') as stderr:
    p = subprocess.Popen(cmd, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=limits,
        env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8', 'HOME': '/tmp', 'TMPDIR': '/tmp', 'ERL_CRASH_DUMP': '/dev/null'})
    while p.poll() is None:
        wall = time.monotonic() - started > 125
        cpu_limit = cpu_usec() - cpu_started > 90000000
        if wall or cpu_limit:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            break
        time.sleep(0.02)
result = {'exit': p.returncode, 'wall_exceeded': wall, 'cpu_exceeded': cpu_limit,
          'elapsed_seconds': round(time.monotonic() - started, 3),
          'cgroup_cpu_seconds': round((cpu_usec() - cpu_started) / 1000000, 6),
          'memory_peak_bytes': int(pathlib.Path('/sys/fs/cgroup/memory.peak').read_text()),
          'memory_events': pathlib.Path('/sys/fs/cgroup/memory.events').read_text(),
          'stdout_bytes': os.path.getsize(out + '/beam.stdout.private'),
          'stderr_bytes': os.path.getsize(out + '/beam.stderr.private')}
pathlib.Path(out + '/envelope-receipt.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
sys.exit(0 if p.returncode == 0 else 1)
