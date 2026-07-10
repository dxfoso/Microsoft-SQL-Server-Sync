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


def find_agent(state: dict, client_name: str) -> dict:
    agents = state.get("agents") if isinstance(state, dict) else None
    if not isinstance(agents, list):
        raise ApiError(f"unexpected live_state payload: {state!r}")
    for agent in agents:
        if isinstance(agent, dict) and str(agent.get("clientName") or "").strip() == client_name:
            return agent
    raise ApiError(f"client not found in live_state: {client_name}")


def parse_timestamp(value: str | None) -> datetime | None:
    normalized = str(value or "").strip()
    if not normalized:
        return None
    try:
        observed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=timezone.utc)
    return observed


def summarize_enabled_tables(agent: dict) -> dict:
    tables = agent.get("tables") if isinstance(agent, dict) else None
    if not isinstance(tables, list):
        tables = []
    enabled = [table for table in tables if isinstance(table, dict) and bool(table.get("enabled"))]
    statuses = {}
    non_completed = []
    for table in enabled:
        status = str(table.get("status") or "").strip()
        statuses[status] = statuses.get(status, 0) + 1
        if status != "Completed":
            non_completed.append(
                {
                    "table": str(table.get("table") or "").strip(),
                    "status": status,
                    "message": str(table.get("message") or "").strip(),
                    "lastSync": str(table.get("lastSync") or "").strip(),
                }
            )
    return {
        "enabledCount": len(enabled),
        "statusCounts": statuses,
        "nonCompleted": non_completed,
    }


def summarize_jobs_for_clients(state: dict, client_names: list[str]) -> dict:
    jobs = state.get("jobs") if isinstance(state, dict) else None
    if not isinstance(jobs, list):
        jobs = []
    visible = []
    active = []
    failed = []
    allowed = {name.strip() for name in client_names}
    for job in jobs:
        if not isinstance(job, dict):
            continue
        client_name = str(job.get("clientName") or "").strip()
        if client_name not in allowed:
            continue
        status = str(job.get("status") or "").strip().lower()
        summary = {
            "id": str(job.get("id") or "").strip(),
            "clientName": client_name,
            "table": str(job.get("table") or "").strip(),
            "direction": str(job.get("direction") or "").strip(),
            "status": status,
            "progress": int(job.get("progress") or 0),
            "message": str(job.get("message") or "").strip(),
            "error": job.get("error"),
            "completedAt": str(job.get("completedAt") or "").strip(),
            "updatedAt": str(job.get("updatedAt") or "").strip(),
        }
        visible.append(summary)
        if status in ("queued", "running", "uploading", "downloading"):
            active.append(summary)
        if status in ("failed", "error"):
            failed.append(summary)
    return {
        "visibleCount": len(visible),
        "active": active,
        "failed": failed,
        "visible": visible,
        "sample": visible[:10],
    }


def unresolved_failed_jobs(summary: dict) -> list[dict]:
    sample = summary.get("sample")
    visible = []
    if isinstance(sample, list):
        visible.extend(item for item in sample if isinstance(item, dict))
    extra_visible = summary.get("visible")
    if isinstance(extra_visible, list):
        visible = [item for item in extra_visible if isinstance(item, dict)]
    latest_completed = {}
    for job in visible:
        status = str(job.get("status") or "").strip().lower()
        if status != "completed":
            continue
        key = (
            str(job.get("clientName") or "").strip(),
            str(job.get("table") or "").strip(),
            str(job.get("direction") or "").strip(),
        )
        completed_at = parse_timestamp(job.get("completedAt") or job.get("updatedAt"))
        previous = latest_completed.get(key)
        if completed_at is not None and (previous is None or completed_at > previous):
            latest_completed[key] = completed_at

    unresolved = []
    failed = summary.get("failed")
    if not isinstance(failed, list):
        return unresolved
    for job in failed:
        if not isinstance(job, dict):
            continue
        key = (
            str(job.get("clientName") or "").strip(),
            str(job.get("table") or "").strip(),
            str(job.get("direction") or "").strip(),
        )
        failed_at = parse_timestamp(job.get("completedAt") or job.get("updatedAt"))
        latest_success = latest_completed.get(key)
        if latest_success is None or failed_at is None or latest_success <= failed_at:
            unresolved.append(job)
    return unresolved


def validate_agent_sync_state(summary: dict, min_enabled_tables: int) -> list[str]:
    failures = []
    enabled_count = int(summary.get("enabledCount") or 0)
    if enabled_count < max(min_enabled_tables, 0):
        failures.append(
            f"enabled table count {enabled_count} is lower than required minimum {min_enabled_tables}"
        )
    if summary.get("nonCompleted"):
        failures.append(f"enabled tables not completed: {json.dumps(summary['nonCompleted'], sort_keys=True)}")
    return failures


def validate_jobs_summary(summary: dict) -> list[str]:
    failures = []
    if summary.get("active"):
        failures.append(f"active jobs present: {json.dumps(summary['active'], sort_keys=True)}")
    unresolved = unresolved_failed_jobs(summary)
    if unresolved:
        failures.append(f"unresolved failed jobs present: {json.dumps(unresolved, sort_keys=True)}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify live sync table and job state invariants against sync.velvet-leaf.com.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--clients", nargs="+", default=["c1", "c2"])
    parser.add_argument("--min-enabled-tables", type=int, default=1)
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
    client_summaries = []
    failures = []
    for client_name in args.clients:
        agent = find_agent(state, client_name)
        summary = summarize_enabled_tables(agent)
        client_summaries.append({"clientName": client_name, **summary})
        client_failures = validate_agent_sync_state(summary, args.min_enabled_tables)
        if client_failures:
            failures.append({"clientName": client_name, "failures": client_failures})

    jobs_summary = summarize_jobs_for_clients(state, args.clients)
    print(f"client_sync_summaries={json.dumps(client_summaries, sort_keys=True)}")
    jobs_summary["visible"] = [
        {
            "id": str(job.get("id") or "").strip(),
            "clientName": str(job.get("clientName") or "").strip(),
            "table": str(job.get("table") or "").strip(),
            "direction": str(job.get("direction") or "").strip(),
            "status": str(job.get("status") or "").strip().lower(),
            "progress": int(job.get("progress") or 0),
            "message": str(job.get("message") or "").strip(),
            "error": job.get("error"),
            "completedAt": str(job.get("completedAt") or "").strip(),
            "updatedAt": str(job.get("updatedAt") or "").strip(),
        }
        for job in (state.get("jobs") if isinstance(state.get("jobs"), list) else [])
        if isinstance(job, dict) and str(job.get("clientName") or "").strip() in {name.strip() for name in args.clients}
    ]
    jobs_failures = validate_jobs_summary(jobs_summary)
    if jobs_failures:
        failures.append({"jobs": jobs_failures})
    print(f"jobs_summary={json.dumps(jobs_summary, sort_keys=True)}")
    if failures:
        print(f"sync state validation failures: {json.dumps(failures, sort_keys=True)}", file=sys.stderr)
        return 1
    print(
        f"sync_state_ok clients={len(client_summaries)} "
        f"enabled_tables={sum(int(item.get('enabledCount') or 0) for item in client_summaries)} "
        f"active_jobs={len(jobs_summary.get('active') or [])} "
        f"unresolved_failed_jobs={len(unresolved_failed_jobs(jobs_summary))}"
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
