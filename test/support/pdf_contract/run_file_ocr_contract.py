"""Host launcher: pinned image, offline, clean VM and quota-backed OCR scratch.

Default: focused native/quality/OCR tests. --cover-source runs ONLY the approved
FR diagnostic cover, verified against its recorded SHA/size; no DB/queue calls.
Receipts and private artifacts live outside the repository. No image rebuild.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
IMAGE = 'sha256:3df4c19c385e4e27b667d65d3a2c9356c41acc08c7716baa05655fb30449882c'
parser = argparse.ArgumentParser()
parser.add_argument('--cover-source', type=pathlib.Path)
parser.add_argument('--out', type=pathlib.Path)
args = parser.parse_args()
os.umask(0o077)
out = args.out or pathlib.Path(tempfile.mkdtemp(prefix='file-ocr-contract-', dir=os.environ.get('TMPDIR', '/home/rico/.hermes/cache/scratch')))
out.mkdir(mode=0o700, parents=True, exist_ok=True)
assert out.stat().st_mode & 0o777 == 0o700
assert not any(out.iterdir()), 'receipt target must be empty'
source = args.cover_source
if source:
    # The receipt directory must never put private OCR artifacts in the repo.
    assert out.resolve() != ROOT and ROOT not in out.resolve().parents
    assert source.is_file() and not source.is_symlink()
    with source.open('rb') as f:
        assert hashlib.file_digest(f, 'sha256').hexdigest() == 'fe44ef01655dad208af23c2284ad1ced161e3f9fe6040f4963490100a7b0579b'
    assert source.stat().st_size == 44148957
ex_unit = subprocess.check_output(['elixir', '-e', 'IO.puts(:code.lib_dir(:ex_unit))'], text=True).strip()
docker = ['sudo', '-n', 'docker']
uid, gid = os.getuid(), os.getgid()
cmd = docker + ['create', '--network', 'none', '--read-only', '--memory', '1g', '--memory-swap', '1g', '--cpus', '1', '--pids-limit', '64', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--ulimit', 'nofile=1024:1024', '--ulimit', 'core=0', '--log-driver', 'none', '--user', f'{uid}:{gid}', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=134217728,mode=1777', '--tmpfs', f'/scratch:rw,noexec,nosuid,nodev,size=536870912,mode=0700,uid={uid},gid={gid}', '--tmpfs', f'/tiny:rw,noexec,nosuid,nodev,size=4194304,mode=0700,uid={uid},gid={gid}', '--tmpfs', f'/inodes:rw,noexec,nosuid,nodev,size=4194304,nr_inodes=4,mode=0700,uid={uid},gid={gid}', '-v', str(ROOT)+':/code:ro', '-v', str(out)+':/out:rw', '-v', ex_unit+':/ex_unit:ro']
if source:
    cmd += ['-v', str(source.resolve())+':/input/source.pdf:ro']
cmd += ['--entrypoint', '/usr/bin/env', IMAGE, '-i', 'PATH=/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE=1', '/usr/bin/python3', '/code/test/support/pdf_contract/file_ocr_tests.py']
if source:
    cmd += ['--cover']
cid = subprocess.check_output(cmd, text=True).strip()
try:
    (out/'container-inspect-before.json').write_bytes(subprocess.check_output(docker+['inspect', cid]))
    result = subprocess.run(docker+['start', '-a', cid], timeout=240)
    (out/'container-inspect-after.json').write_bytes(subprocess.check_output(docker+['inspect', cid]))
    hashes = {}
    for relative in ['lib/brussels_wtf/pdf/file_processor.ex', 'lib/brussels_wtf/pdf/file_quality.ex', 'priv/pdf/bounded_command.py', 'test/support/pdf_contract/file_ocr_image.exs', 'test/support/pdf_contract/file_ocr_tests.exs', 'test/support/pdf_contract/file_ocr_tests.py', 'test/support/pdf_contract/run_file_ocr_contract.py']:
        hashes[relative] = hashlib.sha256((ROOT/relative).read_bytes()).hexdigest()
    (out/'source-code-hashes.json').write_text(json.dumps(hashes, indent=2))
    print('RECEIPTS=' + str(out), flush=True)
finally:
    subprocess.run(docker+['rm', '-f', cid], check=True, stdout=subprocess.DEVNULL)
raise SystemExit(result.returncode)
