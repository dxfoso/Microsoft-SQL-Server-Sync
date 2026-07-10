#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_BASE_URL = "https://sync.velvet-leaf.com"
DEFAULT_USERNAME = "dxfoso@gmail.com"
DEFAULT_PASSWORD = "Admin@123"
DEFAULT_EXPECTED_VERSION = "1.0.105+109"
DEFAULT_EXPECTED_COMMIT = "6b8b76bcf084c3f4b80088d9749f3fcfc5d1be36"


class ApiError(RuntimeError):
    pass


def script_path(name: str) -> str:
    return str((Path(__file__).resolve().parent / name).resolve())


def retryable_transport_error(exc: Exception) -> bool:
    message = str(exc)
    return (
        "WinError 10054" in message
        or "Errno 10054" in message
        or "ConnectionResetError" in message
    )


def read_json_request(request: urllib.request.Request, *, attempts: int = 3) -> dict | list:
    raw = ""
    last_exc = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read().decode("utf-8")
            break
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise ApiError(f"HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            api_error = ApiError(f"request failed: {exc}")
            if attempt >= attempts or not retryable_transport_error(api_error):
                raise api_error from exc
            last_exc = api_error
            time.sleep(1)
    else:
        if last_exc is not None:
            raise last_exc

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ApiError(f"invalid JSON response: {raw[:400]}") from exc


def post_json(url: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    decoded = read_json_request(request)
    if not isinstance(decoded, dict):
        raise ApiError(f"unexpected payload: {decoded!r}")
    return decoded


def invoke_function(base_url: str, name: str, args: dict) -> dict:
    decoded = post_json(
        f"{base_url.rstrip('/')}/call",
        {"name": name, "args": args},
    )
    if isinstance(decoded, dict) and decoded.get("status") == "failed":
        raise ApiError(decoded.get("error") or decoded.get("message") or str(decoded))
    if isinstance(decoded, dict) and decoded.get("status") == "success" and "value" in decoded:
        value = decoded["value"]
        if not isinstance(value, dict):
            raise ApiError(f"unexpected success payload for {name}: {value!r}")
        return value
    if not isinstance(decoded, dict):
        raise ApiError(f"unexpected payload for {name}: {decoded!r}")
    return decoded


def fetch_health(base_url: str) -> dict:
    request = urllib.request.Request(f"{base_url.rstrip('/')}/admin/health", method="GET")
    decoded = read_json_request(request)
    if not isinstance(decoded, dict):
        raise ApiError(f"unexpected health payload: {decoded!r}")
    return decoded


def login(base_url: str, username: str, password: str) -> tuple[str, dict]:
    decoded = invoke_function(
        base_url,
        "auth_login",
        {
            "name": username,
            "email": username,
            "password": password,
            "app": "web",
        },
    )
    token = str(decoded.get("token") or "").strip()
    user = decoded.get("user")
    if not token or not isinstance(user, dict):
        raise ApiError(f"unexpected login payload: {decoded!r}")
    return token, user


def live_state(base_url: str, token: str) -> dict:
    return invoke_function(base_url, "live_state", {"token": token})


def reset_server_saved_data(base_url: str, token: str) -> dict:
    return invoke_function(
        base_url,
        "server_saved_data_reset",
        {
            "resetAgents": True,
            "token": token,
        },
    )


def heartbeat_age_minutes(last_heartbeat: str, now: datetime | None = None) -> float | None:
    normalized = str(last_heartbeat or "").strip()
    if not normalized:
        return None
    current = now or datetime.now(timezone.utc)
    try:
        observed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=timezone.utc)
    return max((current - observed).total_seconds() / 60.0, 0.0)


def summarize_agent(agent: dict) -> dict:
    last_heartbeat = str(agent.get("lastHeartbeat") or "").strip()
    tables = agent.get("tables") if isinstance(agent.get("tables"), list) else []
    return {
        "clientName": str(agent.get("clientName") or "").strip(),
        "version": str(agent.get("clientVersion") or "").strip(),
        "online": bool(agent.get("isOnline")),
        "serverConnected": bool(agent.get("serverConnected")),
        "sqlConnected": bool(agent.get("sqlConnected")),
        "lastHeartbeat": last_heartbeat,
        "heartbeatAgeMinutes": heartbeat_age_minutes(last_heartbeat),
        "tableCount": len(tables),
    }


def summarize_clients(state: dict, client_names: list[str]) -> list[dict]:
    agents = state.get("agents") if isinstance(state, dict) else None
    if not isinstance(agents, list):
        raise ApiError(f"unexpected live_state payload: {state!r}")
    by_name = {}
    for agent in agents:
        if isinstance(agent, dict):
            by_name[str(agent.get("clientName") or "").strip()] = summarize_agent(agent)
    summaries = []
    for client_name in client_names:
        summary = by_name.get(client_name)
        if summary is None:
            summaries.append(
                {
                    "clientName": client_name,
                    "version": "",
                    "online": False,
                    "serverConnected": False,
                    "sqlConnected": False,
                    "lastHeartbeat": "",
                    "heartbeatAgeMinutes": None,
                    "tableCount": 0,
                }
            )
        else:
            summaries.append(summary)
    return summaries


def summary_recovered(
    summary: dict,
    expected_version: str,
    min_table_count: int,
    max_heartbeat_age_minutes: float,
) -> bool:
    if not summary.get("online"):
        return False
    if not summary.get("serverConnected"):
        return False
    if not summary.get("sqlConnected"):
        return False
    if str(summary.get("version") or "").strip() != expected_version:
        return False
    if int(summary.get("tableCount") or 0) < min_table_count:
        return False
    age = summary.get("heartbeatAgeMinutes")
    if age is None or age > max_heartbeat_age_minutes:
        return False
    return True


def decode_output(value: bytes | str | None) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return value.decode("utf-8", errors="replace")


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


def print_result_output(result: dict) -> None:
    stdout_lines = [line for line in str(result.get("stdout") or "").splitlines() if line.strip()]
    stderr_lines = [line for line in str(result.get("stderr") or "").splitlines() if line.strip()]
    if stdout_lines:
        print(f"stdout_last={stdout_lines[-1]}")
    if stderr_lines:
        print(f"stderr_last={stderr_lines[-1]}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify live client recovery after a server-side saved-state reset.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--clients", nargs="+", default=["c1", "c2"])
    parser.add_argument("--expected-version", default=DEFAULT_EXPECTED_VERSION)
    parser.add_argument(
        "--expect-commit",
        "--expected-commit",
        dest="expect_commit",
        default=DEFAULT_EXPECTED_COMMIT,
    )
    parser.add_argument("--wait-seconds", type=int, default=120)
    parser.add_argument("--poll-seconds", type=int, default=5)
    parser.add_argument("--max-heartbeat-age-minutes", type=float, default=5.0)
    parser.add_argument("--min-table-count", type=int, default=1)
    args = parser.parse_args()

    health = fetch_health(args.base_url)
    live_commit = str((((health.get("build") or {}) if isinstance(health, dict) else {}).get("git_commit")) or "")
    print(f"health.ready={health.get('ready')} health.compile_errors={health.get('compile_errors')} build.git_commit={live_commit}")
    if args.expect_commit and live_commit != args.expect_commit:
        print(
            f"expected live commit {args.expect_commit} but found {live_commit}",
            file=sys.stderr,
        )
        return 2

    token, user = login(args.base_url, args.username, args.password)
    print(f"logged_in_as={user.get('username')} role={user.get('role')}")

    reset_result = reset_server_saved_data(args.base_url, token)
    print(f"reset={json.dumps(reset_result, sort_keys=True)}")

    deadline = time.time() + max(args.wait_seconds, 1)
    last_summaries = []
    while time.time() < deadline:
        state = live_state(args.base_url, token)
        summaries = summarize_clients(state, args.clients)
        last_summaries = summaries
        print(f"recovery_summaries={json.dumps(summaries, sort_keys=True)}")
        if all(
            summary_recovered(
                summary,
                args.expected_version,
                args.min_table_count,
                args.max_heartbeat_age_minutes,
            )
            for summary in summaries
        ):
            break
        time.sleep(max(args.poll_seconds, 1))
    else:
        print(
            f"timed out waiting for client state recovery after reset: {json.dumps(last_summaries, sort_keys=True)}",
            file=sys.stderr,
        )
        return 3

    command = [
        sys.executable,
        script_path("verify_live_system.py"),
        "--expected-commit",
        args.expect_commit,
        "--expected-version",
        args.expected_version,
    ]
    result = run_command(command)
    print(f"command={json.dumps(command)} returncode={result['returncode']}")
    print_result_output(result)
    if result["returncode"] != 0:
        print("recovery verification failed during live system verification", file=sys.stderr)
        return 1

    print(f"recovery_ok clients={len(args.clients)}")
    return 0


def run_cli() -> int:
    try:
        return main()
    except ApiError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
