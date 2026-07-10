#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path


DEFAULT_EXPECTED_VERSION = "1.0.105+109"
DEFAULT_EXPECTED_COMMIT = "6b8b76bcf084c3f4b80088d9749f3fcfc5d1be36"


def script_path(name: str) -> str:
    return str((Path(__file__).resolve().parent / name).resolve())


def decode_output(value: bytes | str | None) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return value.decode("utf-8", errors="replace")


def build_verifier_commands(
    expected_commit: str,
    expected_version: str,
) -> list[list[str]]:
    commands = [
        [
            sys.executable,
            script_path("verify_live_bulk_diagnostics.py"),
            "--wait-seconds",
            "90",
            "--poll-seconds",
            "10",
            "--batch-size",
            "5",
            "--expect-commit",
            expected_commit,
        ],
        [
            sys.executable,
            script_path("verify_live_client_update.py"),
            "c1",
            expected_version,
            "--wait-seconds",
            "60",
            "--poll-seconds",
            "10",
            "--expect-commit",
            expected_commit,
        ],
        [
            sys.executable,
            script_path("verify_live_client_update.py"),
            "c2",
            expected_version,
            "--wait-seconds",
            "60",
            "--poll-seconds",
            "10",
            "--expect-commit",
            expected_commit,
        ],
        [
            sys.executable,
            script_path("verify_live_scheduler_stress.py"),
            "--runs",
            "3",
            "--poll-seconds",
            "1",
            "--max-transport-errors",
            "1",
            "--max-avg-ms",
            "9000",
            "--expect-commit",
            expected_commit,
        ],
        [
            sys.executable,
            script_path("verify_live_window_action.py"),
            "--wait-seconds",
            "60",
            "--poll-seconds",
            "10",
            "--action",
            "minimize",
            "--expect-commit",
            expected_commit,
        ],
        [
            sys.executable,
            script_path("verify_live_clients_state.py"),
            "--clients",
            "c1",
            "c2",
            "--expected-version",
            expected_version,
            "--max-heartbeat-age-minutes",
            "5",
            "--require-window-minimized",
            "--expect-commit",
            expected_commit,
        ],
        [
            sys.executable,
            script_path("verify_live_sync_state.py"),
            "--clients",
            "c1",
            "c2",
            "--min-enabled-tables",
            "1",
            "--expect-commit",
            expected_commit,
        ],
    ]
    return commands


def run_command(command: list[str]) -> dict:
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=False,
            check=False,
        )
        return {
            "command": command,
            "returncode": completed.returncode,
            "stdout": decode_output(completed.stdout),
            "stderr": decode_output(completed.stderr),
        }
    except OSError as exc:
        return {
            "command": command,
            "returncode": 1,
            "stdout": "",
            "stderr": str(exc),
        }


def summarize_results(results: list[dict]) -> list[dict]:
    summary = []
    for result in results:
        stdout_lines = [line for line in str(result.get("stdout") or "").splitlines() if line.strip()]
        stderr_lines = [line for line in str(result.get("stderr") or "").splitlines() if line.strip()]
        summary.append(
            {
                "command": result.get("command") or [],
                "returncode": int(result.get("returncode") or 0),
                "ok": int(result.get("returncode") or 0) == 0,
                "stdoutLineCount": len(stdout_lines),
                "stderrLineCount": len(stderr_lines),
                "lastStdoutLine": stdout_lines[-1] if stdout_lines else "",
                "lastStderrLine": stderr_lines[-1] if stderr_lines else "",
            }
        )
    return summary


def print_result_output(result: dict, verbose: bool) -> None:
    if verbose:
        if result.get("stdout"):
            print(str(result["stdout"]).rstrip())
        if result.get("stderr"):
            print(str(result["stderr"]).rstrip(), file=sys.stderr)
        return

    stdout_lines = [line for line in str(result.get("stdout") or "").splitlines() if line.strip()]
    stderr_lines = [line for line in str(result.get("stderr") or "").splitlines() if line.strip()]
    if stdout_lines:
        print(f"stdout_last={stdout_lines[-1]}")
    if stderr_lines:
        print(f"stderr_last={stderr_lines[-1]}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the full live verification suite against the current sync deployment.",
    )
    parser.add_argument("--expected-commit", default=DEFAULT_EXPECTED_COMMIT)
    parser.add_argument("--expected-version", default=DEFAULT_EXPECTED_VERSION)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    commands = build_verifier_commands(args.expected_commit, args.expected_version)
    results = []
    for command in commands:
        result = run_command(command)
        results.append(result)
        print(f"command={json.dumps(command)} returncode={result['returncode']}")
        print_result_output(result, args.verbose)
        if result["returncode"] != 0:
            print(
                f"live verification failed for command: {json.dumps(command)}",
                file=sys.stderr,
            )
            return 1

    print(f"live_system_summary={json.dumps(summarize_results(results), sort_keys=True)}")
    if args.verbose:
        print(f"aggregate_results={json.dumps(results, sort_keys=True)}")
    return 0


def run_cli() -> int:
    try:
        return main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
