"""Offline imported-image cancellation contract; no release rebuild or DB."""
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
IMAGE = 'sha256:3df4c19c385e4e27b667d65d3a2c9356c41acc08c7716baa05655fb30449882c'
os.umask(0o077)
out = pathlib.Path(tempfile.mkdtemp(prefix='file-cancellation-', dir=os.environ['TMPDIR']))
uid, gid = os.getuid(), os.getgid()
docker = ['sudo','-n','docker']
cmd = docker + ['create','--network','none','--read-only','--memory','1g','--memory-swap','1g','--cpus','1','--pids-limit','64','--cap-drop','ALL','--security-opt','no-new-privileges','--ulimit','nofile=1024:1024','--ulimit','core=0','--log-driver','none','--user',f'{uid}:{gid}','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=134217728,mode=1777','--tmpfs',f'/scratch:rw,noexec,nosuid,nodev,size=536870912,mode=0700,uid={uid},gid={gid}','-v',str(ROOT)+':/code:ro','-v',str(out)+':/out:rw','--entrypoint','/usr/bin/env',IMAGE,'-i','PATH=/usr/bin:/bin','PYTHONDONTWRITEBYTECODE=1','/usr/bin/python3','/code/test/support/pdf_contract/file_cancellation_image.py']
cid = subprocess.check_output(cmd,text=True).strip()
try:
    (out/'container-inspect-before.json').write_bytes(subprocess.check_output(docker+['inspect',cid]))
    result = subprocess.run(docker+['start','-a',cid],timeout=120)
    (out/'container-inspect-after.json').write_bytes(subprocess.check_output(docker+['inspect',cid]))
    paths = ['lib/brussels_wtf/pdf/file_processor.ex','lib/brussels_wtf/pdf/file_quality.ex','priv/pdf/bounded_command.py','test/support/pdf_contract/file_cancellation_image.py','test/support/pdf_contract/run_file_cancellation_contract.py']
    (out/'source-code-hashes.json').write_text(json.dumps({p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},indent=2))
    print('RECEIPTS='+str(out),flush=True)
finally:
    subprocess.run(docker+['rm','-f',cid],check=True,stdout=subprocess.DEVNULL)
raise SystemExit(result.returncode)
