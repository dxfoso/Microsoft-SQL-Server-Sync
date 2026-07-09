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


def post_json(url: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise ApiError(f"HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ApiError(f"request failed: {exc}") from exc

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ApiError(f"invalid JSON response: {raw[:400]}") from exc
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
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


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


def request_client_update(base_url: str, token: str, client_name: str, target_version: str) -> dict:
    return invoke_function(
        base_url,
        "agent_client_update_request",
        {
            "clientName": client_name,
            "targetVersion": target_version,
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
    return (current - observed).total_seconds() / 60.0


def summarize_client(agent: dict) -> dict:
    client_update = agent.get("clientUpdate") if isinstance(agent, dict) else None
    if not isinstance(client_update, dict):
        client_update = {}
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
        "pending": bool(client_update.get("pending")),
        "requestId": str(client_update.get("requestId") or "").strip(),
        "requestedAt": str(client_update.get("requestedAt") or "").strip(),
        "lastRequestId": str(client_update.get("lastRequestId") or "").strip(),
        "acknowledgedAt": str(client_update.get("acknowledgedAt") or "").strip(),
        "status": str(client_update.get("status") or "").strip(),
        "message": str(client_update.get("message") or "").strip(),
        "targetVersion": str(client_update.get("targetVersion") or "").strip(),
    }


def find_agent_summary(state: dict, client_name: str) -> dict:
    agents = state.get("agents") if isinstance(state, dict) else None
    if not isinstance(agents, list):
        raise ApiError(f"unexpected live_state payload: {state!r}")
    for agent in agents:
        if isinstance(agent, dict) and str(agent.get("clientName") or "").strip() == client_name:
            return summarize_client(agent)
    raise ApiError(f"client not found in live_state: {client_name}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify a live Windows client update rollout against sync.velvet-leaf.com.",
    )
    parser.add_argument("client_name")
    parser.add_argument("target_version")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--wait-seconds", type=int, default=180)
    parser.add_argument("--poll-seconds", type=int, default=10)
    parser.add_argument("--stale-heartbeat-minutes", type=int, default=20)
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

    request_result = request_client_update(args.base_url, token, args.client_name, args.target_version)
    print(f"request={json.dumps(request_result, sort_keys=True)}")

    deadline = time.time() + max(args.wait_seconds, 1)
    last_summary = None
    while time.time() < deadline:
        state = live_state(args.base_url, token)
        summary = find_agent_summary(state, args.client_name)
        last_summary = summary
        print(
            "client={clientName} machine={machineName} online={online} serverConnected={serverConnected} "
            "sqlConnected={sqlConnected} version={version} pending={pending} status={status} "
            "target={targetVersion} requestId={requestId} lastRequestId={lastRequestId} "
            "requestedAt={requestedAt} acknowledgedAt={acknowledgedAt} "
            "heartbeatAgeMinutes={heartbeatAgeMinutes}".format(
                **summary
            )
        )
        if summary["version"] == args.target_version and not summary["pending"]:
            return 0
        time.sleep(max(args.poll_seconds, 1))

    if last_summary is None:
        print("no live state observed", file=sys.stderr)
        return 1

    age = last_summary.get("heartbeatAgeMinutes")
    if age is not None and age >= args.stale_heartbeat_minutes:
        requested_at = last_summary.get("requestedAt") or "unknown"
        acknowledged_at = last_summary.get("acknowledgedAt") or "never"
        print(
            f"timed out waiting for {args.client_name} to update; "
            f"client is offline/stale at {age:.1f} minutes, "
            f"last heartbeat {last_summary.get('lastHeartbeat') or 'unknown'}, "
            f"update requested at {requested_at}, "
            f"last acknowledged at {acknowledged_at}",
            file=sys.stderr,
        )
        return 3

    print(
        f"timed out waiting for {args.client_name} to update; last observed state: {json.dumps(last_summary, sort_keys=True)}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
