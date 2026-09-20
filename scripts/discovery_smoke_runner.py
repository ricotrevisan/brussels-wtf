#!/usr/bin/env python3
"""One opt-in private file→DockerRunner→file smoke call; no machine credential.

Used by test/contracts/discovery_codex_live_test.exs. Never retries inference.
--capture-invalid PATH explicitly retains only input + parsed invalid result in
an owner-only file/private directory for short-lived offline diagnosis. It never
retains auth, lease tokens, raw Codex events, stderr or chain-of-thought. The
operator must remove this private capture after diagnosis/review.
--replay PATH validates a capture offline: no opt-in, Docker or provider call.
Only fixed validation codes, zero-based indexes, counts and usage are printed.
"""

import argparse
import os
from pathlib import Path
import re
import signal
import sys

from discovery_worker import (
    DockerRunner, MAX_HTTP, RunFailure, Stop, VERSION, ValidationFailure, atomic_json, decode,
    interrupted, locked_state, private_dir, read_private, validate_job, validate_result,
)


def main(argv=None, runner_factory=DockerRunner):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("job", "result", "auth", "state", "capture-invalid", "replay"):
        parser.add_argument("--" + name, type=Path)
    parser.add_argument("--model")
    args = parser.parse_args(argv)
    try:
        os.umask(0o077)
        if args.replay is not None:
            capture = decode(read_private(args.replay, MAX_HTTP * 2))
            result = validate_result(capture["result"], capture["input"])
            print("validation_valid count=" + str(len(result["mentions"])))
            return 0
        if os.environ.get("DISCOVERY_CODEX_LIVE") != "1":
            raise Stop("opt-in required")
        if any(getattr(args, key) is None for key in ("job", "result", "auth", "state", "model")):
            raise Stop("live arguments required")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.model):
            raise Stop("invalid model")
        with locked_state(args.state):
            # Prevent stale output/captures being mistaken for a fresh call.
            if args.result.exists() or args.result.parent.resolve() != args.state.resolve():
                raise Stop("fresh private result path required")
            if args.capture_invalid is not None:
                private_dir(args.capture_invalid.parent)
                if args.capture_invalid.exists() or args.capture_invalid.is_symlink():
                    raise Stop("fresh private capture path required")
            job = decode(read_private(args.job, MAX_HTTP))
            validate_job(job)
            runner = runner_factory(args.auth, args.state, args.model,
                                    "discovery-codex:0.155.0", timeout=90)
            parsed = runner.run(job)
            try:
                result = validate_result(parsed, job["input"])
            except ValidationFailure as error:
                if args.capture_invalid is not None:
                    atomic_json(args.capture_invalid, {
                        "input": job["input"], "result": parsed, "diagnostic": error.diagnostic(),
                    })
                raise
            atomic_json(args.result, {
                "lease_token": job["lease_token"],
                "result": result,
                "processor": {"name": "codex-cli", "version": VERSION, "model": args.model},
            })
        return 0
    except ValidationFailure as error:
        print("validation_failure " + " ".join(f"{key}={value}" for key, value in error.diagnostic().items()),
              file=sys.stderr)
        print("smoke_failure=invalid_output", file=sys.stderr)
        return 1
    except RunFailure as error:
        print("smoke_failure=" + error.reason, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("smoke_stopped", file=sys.stderr)
        return 130
    except Exception:
        # Exception messages/tracebacks can contain private input or credentials.
        print("smoke_failure=configuration_or_contract", file=sys.stderr)
        return 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
