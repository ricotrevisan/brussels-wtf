"""File-backed Poppler/qpdf/OCR subprocess envelope. Numeric stdout only.

Called by FileProcessor with fixed executables/flags; run() also permits hostile
programs solely for the independent resource contract tests. No shell is used.
"""
import ctypes
import errno
import math
import os
import resource
import select
import selectors
import signal
import stat
import subprocess
import sys
import time


def reap_adopted_children():
    # Linux subreaper adoption covers descendants that escape the original
    # process group via setsid(). This wrapper is single-threaded and owns no
    # unrelated subprocesses. Kill/reap each generation until the tree is empty.
    while True:
        with open('/proc/self/task/' + str(os.getpid()) + '/children') as f:
            children = [int(pid) for pid in f.read().split()]
        if not children:
            return
        for pid in children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for pid in children:
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass


def workspace_quota(path, maximum):
    """Require the caller's workspace itself to be a dedicated tmpfs mount.

    A free-space preflight is not a quota. The kernel size limit covers all
    descendants' files concurrently; no directory-monitor polling race.
    """
    path = os.path.abspath(path)
    if os.path.realpath(path) != path or os.stat(path).st_mode & 0o777 != 0o700:
        return False
    with open('/proc/self/mountinfo') as f:
        mounts = f.read(1048576).splitlines()
    for line in mounts:
        fields = line.split()
        separator = fields.index('-')
        mountpoint = fields[4]
        # Reject escaped mount names rather than accidentally comparing them.
        if mountpoint == path and fields[separator + 1] == 'tmpfs':
            options = set(fields[5].split(','))
            stat = os.statvfs(path)
            return ('rw' in options and 'nosuid' in options and 'nodev' in options
                    and 0 < stat.f_blocks * stat.f_frsize <= maximum)
    return False


def run(argv, stdout_path, stderr_path, wall_ms, cpu, memory, file_cap, diag_cap, scratch_dir=None, caller_stdin=False):
    try:
        return _run(argv, stdout_path, stderr_path, wall_ms, cpu, memory, file_cap, diag_cap, scratch_dir, caller_stdin)
    except OSError as error:
        if error.errno not in (errno.ENOSPC, errno.EDQUOT):
            raise
        # The quota may also prevent writing/flushing diagnostics. Still emit
        # only a tiny numeric resource result; _run's finally reaps the tree.
        return {'status': -1, 'limit': 4, 'stdout_bytes': 0, 'stderr_bytes': 0,
                'duration_ms': 0, 'peak_rss_kib': 0, 'cpu_ms': 0}


def run_budget(argv, stdout_path, stderr_path, wall_ms, cpu, memory, file_cap,
               diag_cap, scratch_dir=None, budget_path=None, caller_stdin=False):
    """Private invocation ledger, locked across probes and processing stages.

    Debit ceil-rounded wait-accounted CPU exactly once. Kernel per-process CPU
    is rounded DOWN to remaining whole seconds; fail before spawning when less
    than one remains. The owned-tree watchdog additionally stops child chains.
    No process-global invocation state; deleting the private dir ends its scope.
    """
    import fcntl
    assert budget_path is not None
    with open(os.open(budget_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), 'r+') as ledger:
        fcntl.flock(ledger, fcntl.LOCK_EX)
        text = ledger.read(64)
        used = int(text or '0')
        remaining = (cpu * 1000 - used) // 1000
        if remaining < 1:
            return {'status': -1, 'limit': 5, 'stdout_bytes': 0, 'stderr_bytes': 0,
                    'duration_ms': 0, 'peak_rss_kib': 0, 'cpu_ms': 0}
        result = run(argv, stdout_path, stderr_path, wall_ms, remaining, memory,
                     file_cap, diag_cap, scratch_dir, caller_stdin)
        ledger.seek(0)
        ledger.write(str(used + result['cpu_ms']))
        ledger.truncate()
        ledger.flush()
        return result


def owned_cpu_seconds():
    """Unreaped owned roots + live descendants + their waited descendant CPU.

    Never poll/wait the Popen root while sampling: keeping its zombie preserves
    cutime/cstime until final wait. Subreaper roots include escaped sessions.
    This single-threaded wrapper has no unrelated children. Read all task child
    lists because OCR libraries may spawn subprocesses from non-main threads.
    """
    pending = [os.getpid()]
    seen = set()
    ticks = 0
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            with open('/proc/' + str(pid) + '/stat') as f:
                fields = f.read().rsplit(')', 1)[1].split()
            if pid != os.getpid():
                ticks += sum(int(fields[i]) for i in (11, 12, 13, 14))
            for task in os.listdir('/proc/' + str(pid) + '/task'):
                with open('/proc/' + str(pid) + '/task/' + task + '/children') as f:
                    pending.extend(int(x) for x in f.read().split())
        except (FileNotFoundError, ProcessLookupError):
            pass  # Reparent/wait race; final wait accounting is authoritative.
    return ticks / os.sysconf('SC_CLK_TCK')


def _run(argv, stdout_path, stderr_path, wall_ms, cpu, memory, file_cap, diag_cap, scratch_dir=None, caller_stdin=False):
    # System.cmd keeps this FIFO open only while its port owner is alive.
    # No input bytes belong to this liveness-only protocol. Fail before spawn
    # on any other fd type rather than silently disabling cancellation.
    if caller_stdin and not stat.S_ISFIFO(os.fstat(0).st_mode):
        raise OSError('caller stdin must be a pipe')
    if caller_stdin and select.select([0], [], [], 0)[0]:
        return {'status': -1, 'limit': 6, 'stdout_bytes': 0, 'stderr_bytes': 0,
                'duration_ms': 0, 'peak_rss_kib': 0, 'cpu_ms': 0}
    # PR_SET_CHILD_SUBREAPER is unprivileged and inherited across the exact
    # image's capability-drop/no-new-privileges contract. Fail before spawning
    # when adoption is unavailable, rather than leaving escaped descendants.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError('subreaper unavailable')
    started = time.monotonic()
    baseline = resource.getrusage(resource.RUSAGE_CHILDREN)
    baseline_cpu = baseline.ru_utime + baseline.ru_stime
    self_baseline = resource.getrusage(resource.RUSAGE_SELF)
    # Fresh CLI process: charge interpreter/bootstrap too. Imported test seam
    # uses deltas so previous commands in the same supervisor aren't recharged.
    self_cpu = 0 if __name__ == '__main__' else self_baseline.ru_utime + self_baseline.ru_stime
    counts = [0, 0]
    status = -1
    limit = 0
    process = None
    # Exclusive private files: do not follow a pre-created symlink.
    with open(os.open(stdout_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as out, \
         open(os.open(stderr_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as err:
        try:
            process = subprocess.Popen(
                ['/usr/bin/prlimit', '--cpu=' + str(cpu), '--as=' + str(memory),
                 '--fsize=' + str(file_cap), '--core=0', '--'] + argv,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True, umask=0o077,
                env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8',
                     **({'TMPDIR': scratch_dir, 'TMP': scratch_dir, 'TEMP': scratch_dir,
                         'HOME': scratch_dir} if scratch_dir else {})})
            assert process.stdout is not None and process.stderr is not None
            selector = selectors.DefaultSelector()
            for i, pipe in enumerate([process.stdout, process.stderr]):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, (i, [out, err][i]))
            if caller_stdin:
                selector.register(0, selectors.EVENT_READ, None)
            while True:
                supervisor = resource.getrusage(resource.RUSAGE_SELF)
                supervisor_cpu = supervisor.ru_utime + supervisor.ru_stime - self_cpu
                if owned_cpu_seconds() + supervisor_cpu >= max(0, cpu - 0.05):
                    limit = 5
                    break
                remaining = wall_ms / 1000 - (time.monotonic() - started)
                if remaining <= 0:
                    limit = 1
                    break
                for key, _ in selector.select(min(remaining, 0.01)):
                    if key.data is None:
                        # EOF or unexpected input: cancel, never pass it to tools.
                        os.read(key.fd, 1)
                        limit = 6
                        break
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    i, dest = key.data
                    if sum(counts) + len(data) > diag_cap:
                        limit = 2
                        break
                    counts[i] += len(data)
                    dest.write(data)
                if limit:
                    break
                # Closed pipes do not imply exit. Inspect without wait/poll,
                # retaining zombie usage for the aggregate accounting above.
                if not any(key.data is not None for key in selector.get_map().values()):
                    with open('/proc/' + str(process.pid) + '/stat') as f:
                        state = f.read().rsplit(')', 1)[1].split()[0]
                    if state == 'Z':
                        break
            selector.close()
            # Even a parent that exits successfully must not leave descendants.
            if not limit:
                try:
                    process.wait(timeout=max(0.001, wall_ms / 1000 - (time.monotonic() - started)))
                except subprocess.TimeoutExpired:
                    limit = 1
        except OSError:
            limit = 3
        finally:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                status = process.wait()
                reap_adopted_children()
                process.stdout.close()
                process.stderr.close()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    supervisor = resource.getrusage(resource.RUSAGE_SELF)
    supervisor_cpu = supervisor.ru_utime + supervisor.ru_stime - self_cpu

    cpu_ms = math.ceil((usage.ru_utime + usage.ru_stime - baseline_cpu + supervisor_cpu) * 1000)
    if cpu_ms >= cpu * 1000 or status == -24 or (status == -9 and cpu_ms >= int(cpu) * 1000):
        limit = 5
    return {'status': status, 'limit': limit, 'stdout_bytes': counts[0],
            'stderr_bytes': counts[1], 'duration_ms': int((time.monotonic() - started) * 1000),
            'peak_rss_kib': usage.ru_maxrss,
            'cpu_ms': cpu_ms}


if __name__ == '__main__':
    try:
        if sys.argv[1] == '--workspace-quota':
            print('1' if workspace_quota(sys.argv[2], int(sys.argv[3])) else '0')
            sys.exit(0)
        out, err, wall, cpu, memory, files, diag = sys.argv[1:8]
        argv = sys.argv[8:]
        caller_stdin = bool(argv and argv[0] == '--caller-stdin')
        if caller_stdin:
            argv = argv[1:]
        budget = None
        if argv[0] == '--budget':
            budget, argv = argv[1], argv[2:]
        scratch = None
        if argv[0] == '--scratch':
            scratch, argv = argv[1], argv[2:]
        runner = run_budget if budget else run
        result = runner(argv, out, err, *map(int, [wall, cpu, memory, files, diag]),
                        scratch_dir=scratch, caller_stdin=caller_stdin, **({'budget_path': budget} if budget else {}))
        print(' '.join(str(result[k]) for k in ['status', 'limit', 'stdout_bytes',
                    'stderr_bytes', 'duration_ms', 'peak_rss_kib', 'cpu_ms']))
    except OSError as error:
        print('-1 4 0 0 0 0 0' if error.errno in (errno.ENOSPC, errno.EDQUOT)
              else '-1 3 0 0 0 0 0')
        sys.exit(1)
    except Exception:
        # No private paths, source text or exception strings in the protocol.
        print('-1 3 0 0 0 0 0')
        sys.exit(1)
