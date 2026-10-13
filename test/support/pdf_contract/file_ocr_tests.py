"""Exact-image clean VM; whole cgroup CPU monitor, no app/DB/network."""
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
cover = '--cover' in sys.argv
if cover:
    code = 'Code.eval_file("/code/test/support/pdf_contract/file_ocr_image.exs"); System.halt(0)'
else:
    code = '''
{:ok, [config]} = :file.consult(~c"/app/releases/0.1.0/sys.config")
Application.put_env(:brussels_wtf, :pdf_quality_thresholds, config |> Keyword.fetch!(:brussels_wtf) |> Keyword.fetch!(:pdf_quality_thresholds))
Code.compile_file("/code/lib/brussels_wtf/pdf/file_quality.ex")
Code.compile_file("/code/lib/brussels_wtf/pdf/file_processor.ex")
ExUnit.start()
Code.eval_file("/code/test/brussels_wtf/pdf/file_processor_test.exs")
Code.eval_file("/code/test/brussels_wtf/pdf/file_quality_test.exs")
Code.eval_file("/code/test/support/pdf_contract/file_ocr_tests.exs")
false = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :brussels_wtf))
failures = ExUnit.run().failures
System.halt(if failures == 0, do: 0, else: 1)
'''
expr = "application:ensure_all_started(elixir), 'Elixir.Code':eval_string(<<" + json.dumps(code) + ">>)."
cmd = [glob.glob('/app/erts-*/bin/erl')[0], '+S', '1:1', '+A', '1', '-boot', '/app/releases/0.1.0/start_clean', '-boot_var', 'RELEASE_LIB', '/app/lib', '-noshell', '-pa'] + glob.glob('/app/lib/*/ebin') + ['/ex_unit/ebin', '-eval', expr]

def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (90, 90))
    resource.setrlimit(resource.RLIMIT_FSIZE, (67108864, 67108864))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

def cpu_usec():
    return int(dict(line.split() for line in pathlib.Path('/sys/fs/cgroup/cpu.stat').read_text().splitlines())['usage_usec'])

started = time.monotonic()
cpu_started = cpu_usec()
if not cover:
    resource_test = subprocess.run(['/usr/bin/python3', '/code/test/support/pdf_contract/file_command_test.py'],
        capture_output=True, timeout=30,
        env={'PATH':'/usr/bin:/bin', 'TMPDIR':'/tmp', 'PYTHONDONTWRITEBYTECODE':'1'})
    pathlib.Path('/out/resource-tests.private').write_bytes(resource_test.stdout + resource_test.stderr)
    print((resource_test.stdout + resource_test.stderr).decode())
    if resource_test.returncode:
        raise SystemExit(resource_test.returncode)
stop = None
with open('/out/beam.stdout.private', 'wb') as stdout, open('/out/beam.stderr.private', 'wb') as stderr:
    p = subprocess.Popen(cmd, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=limits,
        env={'PATH':'/usr/bin:/bin', 'LC_ALL':'C.UTF-8', 'TMPDIR':'/tmp', 'ERL_CRASH_DUMP':'/dev/null'})
    while p.poll() is None:
        if time.monotonic() - started > (125 if cover else 180):
            stop = 'wall_time'
        elif cpu_usec() - cpu_started > 90000000:
            stop = 'cumulative_cpu'
        elif sum(os.path.getsize('/out/' + name) for name in ['beam.stdout.private', 'beam.stderr.private']) > 1048576:
            stop = 'diagnostics'
        if stop:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            break
        time.sleep(0.02)
receipt = {'exit': p.returncode, 'stop': stop, 'elapsed_seconds': round(time.monotonic() - started, 3),
    'cgroup_cpu_seconds': round((cpu_usec() - cpu_started) / 1000000, 6),
    'memory_peak_bytes': int(pathlib.Path('/sys/fs/cgroup/memory.peak').read_text()),
    'memory_events': pathlib.Path('/sys/fs/cgroup/memory.events').read_text(),
    'stdout_bytes': os.path.getsize('/out/beam.stdout.private'), 'stderr_bytes': os.path.getsize('/out/beam.stderr.private')}
pathlib.Path('/out/envelope-receipt.json').write_text(json.dumps(receipt, indent=2))
print(pathlib.Path('/out/beam.stdout.private').read_text())
print(pathlib.Path('/out/beam.stderr.private').read_text())
print(json.dumps(receipt))
raise SystemExit(0 if p.returncode == 0 and stop is None else 1)
