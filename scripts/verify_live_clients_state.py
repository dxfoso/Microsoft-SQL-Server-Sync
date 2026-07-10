#!/usr/bin/env python3
import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


DEFAULT_BASE_URL = "https://sync.velvet-leaf.com"
DEFAULT_USERNAME = "dxfoso@gmail.com"
DEFAULT_PASSWORD = "Admin@123"


class ApiError(RuntimeError):
    pass


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
    diagnostics = agent.get("diagnostics") if isinstance(agent, dict) else None
    if not isinstance(diagnostics, dict):
        diagnostics = {}
    client_update = agent.get("clientUpdate") if isinstance(agent, dict) else None
    if not isinstance(client_update, dict):
        client_update = {}
    window_action = agent.get("windowAction") if isinstance(agent, dict) else None
    if not isinstance(window_action, dict):
        window_action = {}
    last_heartbeat = str(agent.get("lastHeartbeat") or "").strip()
    return {
        "clientName": str(agent.get("clientName") or "").strip(),
        "machineName": str(agent.get("machineName") or "").strip(),
        "version": str(agent.get("clientVersion") or "").strip(),
        "online": bool(agent.get("isOnline")),
        "serverConnected": bool(agent.get("serverConnected")),
        "sqlConnected": bool(agent.get("sqlConnected")),
        "lastHeartbeat": last_heartbeat,
        "heartbeatAgeMinutes": heartbeat_age_minutes(last_heartbeat),
        "diagnosticsStatus": str(diagnostics.get("status") or "").strip(),
        "diagnosticsUploadedAt": str(diagnostics.get("uploadedAt") or "").strip(),
        "clientUpdateStatus": str(client_update.get("status") or "").strip(),
        "clientUpdatePending": bool(client_update.get("pending")),
        "clientUpdateTargetVersion": str(client_update.get("targetVersion") or "").strip(),
        "windowActionStatus": str(window_action.get("status") or "").strip(),
        "windowActionPending": bool(window_action.get("pending")),
        "windowActionName": str(window_action.get("action") or "").strip(),
    }


def find_agent_summary(state: dict, client_name: str) -> dict:
    agents = state.get("agents") if isinstance(state, dict) else None
    if not isinstance(agents, list):
        raise ApiError(f"unexpected live_state payload: {state!r}")
    for agent in agents:
        if isinstance(agent, dict) and str(agent.get("clientName") or "").strip() == client_name:
            return summarize_agent(agent)
    raise ApiError(f"client not found in live_state: {client_name}")


def validate_summary(
    summary: dict,
    expected_version: str,
    max_heartbeat_age_minutes: float,
    require_window_minimized: bool,
) -> list[str]:
    failures = []
    if not summary.get("online"):
        failures.append("client offline")
    if not summary.get("serverConnected"):
        failures.append("server not connected")
    if not summary.get("sqlConnected"):
        failures.append("sql not connected")
    if str(summary.get("version") or "").strip() != expected_version:
        failures.append(
            f"version mismatch: observed={summary.get('version')} expected={expected_version}"
        )
    age = summary.get("heartbeatAgeMinutes")
    if age is None:
        failures.append("missing heartbeat")
    elif age > max_heartbeat_age_minutes:
        failures.append(
            f"heartbeat stale: observed={age:.2f} minutes limit={max_heartbeat_age_minutes}"
        )
    if str(summary.get("diagnosticsStatus") or "").strip() != "uploaded":
        failures.append(f"diagnostics status is {summary.get('diagnosticsStatus')}")
    if not str(summary.get("diagnosticsUploadedAt") or "").strip():
        failures.append("diagnostics uploadedAt missing")
    if bool(summary.get("clientUpdatePending")):
        failures.append("client update still pending")
    if str(summary.get("clientUpdateStatus") or "").strip() not in ("current", "updated"):
        failures.append(f"client update status is {summary.get('clientUpdateStatus')}")
    if require_window_minimized:
        if bool(summary.get("windowActionPending")):
            failures.append("window action still pending")
        if str(summary.get("windowActionName") or "").strip() != "minimize":
            failures.append(f"window action is {summary.get('windowActionName')}")
        if str(summary.get("windowActionStatus") or "").strip() != "completed":
            failures.append(f"window action status is {summary.get('windowActionStatus')}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify live client state invariants against sync.velvet-leaf.com.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--clients", nargs="+", default=["c1", "c2"])
    parser.add_argument("--expected-version", default="1.0.105+109")
    parser.add_argument("--max-heartbeat-age-minutes", type=float, default=5.0)
    parser.add_argument("--require-window-minimized", action="store_true")
    parser.add_argument("--expect-commit", default="")
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

    state = live_state(args.base_url, token)
    failures = []
    summaries = []
    for client_name in args.clients:
        summary = find_agent_summary(state, client_name)
        summaries.append(summary)
        client_failures = validate_summary(
            summary,
            args.expected_version,
            args.max_heartbeat_age_minutes,
            args.require_window_minimized,
        )
        if client_failures:
            failures.append({"clientName": client_name, "failures": client_failures})

    print(f"client_summaries={json.dumps(summaries, sort_keys=True)}")
    if failures:
        print(f"client validation failures: {json.dumps(failures, sort_keys=True)}", file=sys.stderr)
        return 1
    print(
        f"client_state_ok clients={len(summaries)} "
        f"online={sum(1 for item in summaries if item.get('online'))} "
        f"minimized={sum(1 for item in summaries if item.get('windowActionStatus') == 'completed')}"
    )
    return 0


def run_cli() -> int:
    try:
        return main()
    except ApiError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
