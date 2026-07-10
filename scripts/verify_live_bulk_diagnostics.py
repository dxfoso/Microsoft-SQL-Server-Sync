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


def request_all_diagnostics(base_url: str, token: str, batch_size: int = 0) -> dict:
    args = {"token": token}
    if batch_size > 0:
        args["batchSize"] = batch_size
    return invoke_function(base_url, "agent_diagnostics_request_all", args)


def parse_diagnostics_request_result(request_result: dict) -> tuple[str, list[str]]:
    if not isinstance(request_result, dict):
        raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")

    request_id = str(request_result.get("requestId") or "").strip()
    if not request_id:
        raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")

    raw_names = request_result.get("requestedClientNames")
    if not isinstance(raw_names, list):
        raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")

    requested_names = []
    for item in raw_names:
        name = str(item or "").strip()
        if not name:
            raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")
        requested_names.append(name)

    if len(set(requested_names)) != len(requested_names):
        raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")

    requested_count = request_result.get("requestedClientCount")
    if requested_count is not None:
        if not isinstance(requested_count, (int, float)):
            raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")
        if int(requested_count) != len(requested_names):
            raise ApiError(f"unexpected diagnostics request payload: {request_result!r}")

    return request_id, requested_names


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


def summarize_progress(state: dict, request_id: str, requested_names: list[str]) -> tuple[list[str], list[str]]:
    agents = state.get("agents") if isinstance(state, dict) else None
    if not isinstance(agents, list):
        raise ApiError(f"unexpected live_state payload: {state!r}")

    by_name = {}
    for agent in agents:
        if isinstance(agent, dict):
            by_name[str(agent.get("clientName") or "").strip()] = agent

    pending = []
    uploaded = []
    for name in requested_names:
        agent = by_name.get(name)
        diagnostics = agent.get("diagnostics") if isinstance(agent, dict) else None
        last_request_id = ""
        uploaded_at = ""
        if isinstance(diagnostics, dict):
            last_request_id = str(diagnostics.get("lastRequestId") or "").strip()
            uploaded_at = str(diagnostics.get("uploadedAt") or "").strip()
        if last_request_id == request_id and uploaded_at:
            uploaded.append(name)
        else:
            pending.append(name)
    return pending, uploaded


def summarize_pending_clients(state: dict, pending_names: list[str]) -> list[dict]:
    agents = state.get("agents") if isinstance(state, dict) else None
    if not isinstance(agents, list):
        raise ApiError(f"unexpected live_state payload: {state!r}")

    by_name = {}
    for agent in agents:
        if isinstance(agent, dict):
            by_name[str(agent.get("clientName") or "").strip()] = agent

    summaries = []
    for name in pending_names:
        agent = by_name.get(name)
        if not isinstance(agent, dict):
            summaries.append(
                {
                    "clientName": name,
                    "online": False,
                    "lastHeartbeat": "",
                    "heartbeatAgeMinutes": None,
                    "diagnosticsStatus": "",
                    "lastRequestId": "",
                    "uploadedAt": "",
                }
            )
            continue
        diagnostics = agent.get("diagnostics") if isinstance(agent.get("diagnostics"), dict) else {}
        last_heartbeat = str(agent.get("lastHeartbeat") or "").strip()
        summaries.append(
            {
                "clientName": str(agent.get("clientName") or "").strip(),
                "online": bool(agent.get("isOnline")),
                "lastHeartbeat": last_heartbeat,
                "heartbeatAgeMinutes": heartbeat_age_minutes(last_heartbeat),
                "diagnosticsStatus": str(diagnostics.get("status") or "").strip(),
                "lastRequestId": str(diagnostics.get("lastRequestId") or "").strip(),
                "uploadedAt": str(diagnostics.get("uploadedAt") or "").strip(),
            }
        )
    return summaries


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the live bulk diagnostics flow against sync.velvet-leaf.com.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--wait-seconds", type=int, default=120)
    parser.add_argument("--poll-seconds", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=5)
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

    request_result = request_all_diagnostics(args.base_url, token, args.batch_size)
    request_id, requested_names = parse_diagnostics_request_result(request_result)
    print(
        f"request_id={request_id} requested_client_count={request_result.get('requestedClientCount')} requested_clients={requested_names}"
    )
    if not requested_names:
        print("no visible clients were returned by the live control plane")
        return 0

    deadline = time.time() + max(args.wait_seconds, 1)
    last_pending = requested_names
    last_state = None
    while time.time() < deadline:
        state = live_state(args.base_url, token)
        last_state = state
        pending, uploaded = summarize_progress(state, request_id, requested_names)
        print(f"uploaded={uploaded} pending={pending}")
        if not pending:
            return 0
        last_pending = pending
        time.sleep(max(args.poll_seconds, 1))

    if last_state is not None:
        pending_summaries = summarize_pending_clients(last_state, last_pending)
        all_stale = True
        for summary in pending_summaries:
            age = summary.get("heartbeatAgeMinutes")
            if summary.get("online") or age is None or age < args.stale_heartbeat_minutes:
                all_stale = False
                break
        if pending_summaries and all_stale:
            print(
                f"timed out waiting for diagnostics uploads; pending clients are offline/stale: {json.dumps(pending_summaries, sort_keys=True)}",
                file=sys.stderr,
            )
            return 3

    print(f"timed out waiting for diagnostics uploads; still pending: {last_pending}", file=sys.stderr)
    return 1


def run_cli() -> int:
    try:
        return main()
    except ApiError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
