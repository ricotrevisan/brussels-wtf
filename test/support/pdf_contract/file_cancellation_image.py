"""Live System.cmd owner/VM death receipts in the imported release image.

No application startup. Real Poppler is SIGSTOP'd only after exec to make owner
loss deterministic; escaped-session/closed-pipe hostility uses the wrapper seam.
The outer unprivileged subreaper proves wrapper disappearance, including zombies.
"""
import ctypes
import glob
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import time

os.umask(0o077)
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
ROOT = pathlib.Path('/code')
OUT = pathlib.Path('/out')
WRAPPER = ROOT / 'priv/pdf/bounded_command.py'
watched = '"--caller-stdin"' in (ROOT / 'lib/brussels_wtf/pdf/file_processor.ex').read_text()

def until(fn, seconds=10.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = fn()
        if value:
            return value
        time.sleep(.001)
    raise AssertionError('bounded wait expired')

def descendants(pid):
    result = []
    pending = [pid]
    while pending:
        parent = pending.pop()
        try:
            children = [int(x) for x in pathlib.Path(f'/proc/{parent}/task/{parent}/children').read_text().split()]
        except FileNotFoundError:
            continue
        result.extend(children)
        pending.extend(children)
    return result

def reap():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
            if not pid:
                return
        except ChildProcessError:
            return

def gone(pids):
    reap()
    return all(not pathlib.Path(f'/proc/{p}').exists() for p in pids)

def beam(code, d):
    expr = "application:ensure_all_started(elixir), 'Elixir.Code':eval_string(<<" + json.dumps(code) + ">>)."
    cmd = [glob.glob('/app/erts-*/bin/erl')[0], '+S', '1:1', '+A', '1', '-boot', '/app/releases/0.1.0/start_clean', '-boot_var', 'RELEASE_LIB', '/app/lib', '-noshell', '-pa'] + glob.glob('/app/lib/*/ebin') + ['-eval', expr]
    return subprocess.Popen(cmd, stdout=open(d/'beam.stdout.private', 'wb'), stderr=open(d/'beam.stderr.private', 'wb'), env={'PATH':'/usr/bin:/bin','HOME':'/tmp','TMPDIR':'/tmp','ERL_CRASH_DUMP':'/dev/null'})

# Valid file-backed PDF, with enough actual text work to observe Poppler exec.
stream = b'BT /F1 10 Tf 10 700 Td ' + b'(Municipal council supporting evidence document 2026.) Tj 0 -1 Td '*4000 + b'ET'
objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Count 100 /Kids [' + b' '.join(f'{4+2*i} 0 R'.encode() for i in range(100)) + b'] >>', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
for i in range(100):
    objects += [f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 800] /Resources << /Font << /F1 3 0 R >> >> /Contents {5+2*i} 0 R >>'.encode(), b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream']
pdf = bytearray(b'%PDF-1.4\n')
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
xref = len(pdf)
pdf.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
pdf.extend(b''.join(f'{offset:010} 00000 n \n'.encode() for offset in offsets[1:]))
pdf.extend(f'trailer << /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
source = OUT/'source.pdf'
source.write_bytes(pdf)
source.chmod(0o400)
source_hash = hashlib.sha256(pdf).hexdigest()
receipts = []
failures = []
for kind in ['wrapper', 'native']:
    for death in ['task', 'vm']:
        d = OUT/(kind+'-'+death)
        d.mkdir(mode=0o700)
        if kind == 'wrapper':
            hostile = ('import os,subprocess,time,pathlib; '
                       'p=subprocess.Popen(["/usr/bin/python3","-c","import os,time; os.setsid(); os.close(1); os.close(2); time.sleep(120)"]); '
                       f'pathlib.Path({str(d/"pids")!r}).write_text(str(os.getppid())+" "+str(os.getpid())+" "+str(p.pid)); '
                       'os.close(1); os.close(2); time.sleep(120)')
            argv = [str(WRAPPER),str(d/'out'),str(d/'err'),'120000','90','1073741824','67108864','1048576'] + (['--caller-stdin'] if watched else []) + ['/usr/bin/python3','-c',hostile]
            call = 'System.cmd("/usr/bin/python3", '+json.dumps(argv)+', stderr_to_stdout: true)'
            setup = ''
        else:
            setup = '''{:ok, [config]} = :file.consult(~c"/app/releases/0.1.0/sys.config")
Application.put_env(:brussels_wtf, :pdf_quality_thresholds, config |> Keyword.fetch!(:brussels_wtf) |> Keyword.fetch!(:pdf_quality_thresholds))
Code.compile_file("/code/lib/brussels_wtf/pdf/file_quality.ex")
Code.compile_file("/code/lib/brussels_wtf/pdf/file_processor.ex")
'''
            call = f'BrusselsWtf.PDF.FileProcessor.native(%{{media_type: "application/pdf", sha256: "{source_hash}", byte_size: {len(pdf)}}}, "{source}", "{d}")'
        code = setup + f'''
false = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :brussels_wtf))
t = Task.async(fn -> {call} end)
wait = fn wait -> if File.exists?("{d}/cancel"), do: :ok, else: (Process.sleep(1); wait.(wait)) end
wait.(wait)
Process.unlink(t.pid)
Process.exit(t.pid, :kill)
File.write!("{d}/owner-dead", "dead")
Process.sleep(:infinity)
'''
        p = beam(code, d)
        pids = []
        started = None
        try:
            if kind == 'wrapper':
                until(lambda: (d/'pids').exists())
                pids = [int(x) for x in (d/'pids').read_text().split()]
                until(lambda: pathlib.Path(f'/proc/{pids[-1]}/stat').read_text().split()[5] == str(pids[-1]))
                until(lambda: all(not pathlib.Path(f'/proc/{pid}/fd/{fd}').exists()
                                  for pid in pids[1:] for fd in [1, 2]))
            else:
                def poppler():
                    for pid in descendants(p.pid):
                        try:
                            if pathlib.Path(f'/proc/{pid}/comm').read_text().strip() == 'pdftotext':
                                os.kill(pid, signal.SIGSTOP)
                                parent = int(pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[1])
                                return [parent,pid]
                        except (ProcessLookupError, FileNotFoundError):
                            pass
                    return None
                pids = until(poppler)
            observed = [{'pid':pid, 'comm':pathlib.Path(f'/proc/{pid}/comm').read_text().strip(),
                         'stat':pathlib.Path(f'/proc/{pid}/stat').read_text()} for pid in pids]
            (d/'observed-pids.json').write_text(json.dumps(observed,indent=2))
            started = time.monotonic_ns()
            if death == 'task':
                (d/'cancel').touch()
                until(lambda: (d/'owner-dead').exists())
            else:
                os.kill(p.pid, signal.SIGKILL)
                p.wait(timeout=2)
            until(lambda: gone(pids), .5)
            elapsed = (time.monotonic_ns()-started)/1e6
            receipts.append({'kind':kind,'death':death,'pids':pids,'observed':observed,'cancel_monotonic_ns':started,'gone_monotonic_ns':time.monotonic_ns(),'elapsed_ms':elapsed,'all_proc_absent':True})
        except Exception as error:
            failures.append({'kind':kind,'death':death,'pids':pids,'alive':[pid for pid in pids if pathlib.Path(f'/proc/{pid}').exists()],'error':str(error)})
        finally:
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if p.poll() is None:
                p.kill()
                p.wait()
            reap()
assert hashlib.sha256(source.read_bytes()).hexdigest() == source_hash
result = {'watched':watched,'source_sha256':source_hash,'source_bytes':len(pdf),'receipts':receipts,'failures':failures,'memory_peak_bytes':int(pathlib.Path('/sys/fs/cgroup/memory.peak').read_text()),
          'memory_events':pathlib.Path('/sys/fs/cgroup/memory.events').read_text(),
          'cpu_stat':pathlib.Path('/sys/fs/cgroup/cpu.stat').read_text()}
(OUT/'cancellation-receipt.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result),flush=True)
raise SystemExit(1 if failures else 0)
