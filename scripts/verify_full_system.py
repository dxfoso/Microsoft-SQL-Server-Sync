#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path


DEFAULT_EXPECTED_VERSION = "1.0.105+109"
DEFAULT_EXPECTED_COMMIT = "6b8b76bcf084c3f4b80088d9749f3fcfc5d1be36"


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def script_path(name: str) -> str:
    return str((Path(__file__).resolve().parent / name).resolve())


def decode_output(value: bytes | str | None) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return value.decode("utf-8", errors="replace")


def build_verification_commands(
    expected_commit: str,
    expected_version: str,
    include_recovery: bool = False,
) -> list[dict]:
    root = repo_root()
    commands = [
        {
            "name": "python_contracts",
            "command": [
                sys.executable,
                "-m",
                "pytest",
                "tests\\test_control_plane_contracts.py",
                "tests\\test_sync_contracts.py",
                "tests\\test_live_verifier_scripts.py",
                "tests\\test_heartbeat_contracts.py",
                "deployment\\chart\\tests\\test_chart_contracts.py",
                "-q",
            ],
            "workdir": str(root),
        },
        {
            "name": "flutter_agent_tests",
            "command": ["powershell", "-NoProfile", "-Command", "flutter test"],
            "workdir": str(root / "sync_windows_agent"),
        },
        {
            "name": "live_system",
            "command": [
                sys.executable,
                script_path("verify_live_system.py"),
                "--expected-commit",
                expected_commit,
                "--expected-version",
                expected_version,
            ],
            "workdir": str(root),
        },
    ]
    if include_recovery:
        commands.append(
            {
                "name": "live_state_recovery",
                "command": [
                    sys.executable,
                    script_path("verify_live_state_recovery.py"),
                    "--expected-commit",
                    expected_commit,
                    "--expected-version",
                    expected_version,
                ],
                "workdir": str(root),
            }
        )
    return commands


def run_command(command: list[str], workdir: str) -> dict:
    try:
        completed = subprocess.run(
            command,
            cwd=workdir,
            capture_output=True,
            text=False,
            check=False,
        )
        return {
            "command": command,
            "workdir": workdir,
            "returncode": completed.returncode,
            "stdout": decode_output(completed.stdout),
            "stderr": decode_output(completed.stderr),
        }
    except OSError as exc:
        return {
            "command": command,
            "workdir": workdir,
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
                "name": str(result.get("name") or "").strip(),
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
        description="Run local and live verification for the current sync system.",
    )
    parser.add_argument("--expected-commit", default=DEFAULT_EXPECTED_COMMIT)
    parser.add_argument("--expected-version", default=DEFAULT_EXPECTED_VERSION)
    parser.add_argument(
        "--include-recovery",
        action="store_true",
        help="Include the live saved-state reset and recovery cycle.",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    commands = build_verification_commands(
        args.expected_commit,
        args.expected_version,
        include_recovery=args.include_recovery,
    )
    results = []
    for item in commands:
        result = run_command(item["command"], item["workdir"])
        results.append({"name": item["name"], **result})
        print(
            f"step={item['name']} workdir={json.dumps(item['workdir'])} "
            f"command={json.dumps(item['command'])} returncode={result['returncode']}"
        )
        print_result_output(result, args.verbose)
        if result["returncode"] != 0:
            print(f"full-system verification failed at step {item['name']}", file=sys.stderr)
            return 1

    summary = summarize_results(results)
    print(f"full_system_summary={json.dumps(summary, sort_keys=True)}")
    if args.verbose:
        print(f"full_system_results={json.dumps(results, sort_keys=True)}")
    print(
        f"full_system_ok steps={len(results)} "
        f"passed={sum(1 for item in summary if item.get('ok'))} "
        f"failed={sum(1 for item in summary if not item.get('ok'))}"
    )
    return 0


def run_cli() -> int:
    try:
        return main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
