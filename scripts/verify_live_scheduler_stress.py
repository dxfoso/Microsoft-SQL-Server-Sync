#!/usr/bin/env python3
import argparse
import json
import sys
import time
import urllib.error
import urllib.request


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


def fetch_perf(base_url: str) -> list[dict]:
    request = urllib.request.Request(f"{base_url.rstrip('/')}/admin/perf", method="GET")
    decoded = read_json_request(request)
    if not isinstance(decoded, list):
        raise ApiError(f"unexpected perf payload: {decoded!r}")
    return decoded


def reset_stats(base_url: str) -> dict:
    request = urllib.request.Request(f"{base_url.rstrip('/')}/admin/stats/reset", data=b"", method="POST")
    decoded = read_json_request(request)
    if not isinstance(decoded, dict):
        raise ApiError(f"unexpected stats reset payload: {decoded!r}")
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


def extract_perf_row(rows: list[dict], name: str) -> dict:
    for row in rows:
        if isinstance(row, dict) and str(row.get("name") or "").strip() == name:
            return row
    return {}


def scheduler_transport_error(exc: Exception) -> bool:
    return retryable_transport_error(exc)


def run_scheduler_stress(
    base_url: str,
    token: str,
    runs: int,
    poll_seconds: int = 0,
) -> dict:
    successes = []
    transport_errors = []
    fatal_errors = []
    for index in range(max(runs, 0)):
        started = time.time()
        try:
            response = invoke_function(base_url, "auto_sync_tick", {"token": token})
            successes.append(
                {
                    "run": index + 1,
                    "elapsedMs": round((time.time() - started) * 1000, 1),
                    "response": response,
                }
            )
        except ApiError as exc:
            if scheduler_transport_error(exc):
                transport_errors.append({"run": index + 1, "error": str(exc)})
            else:
                fatal_errors.append({"run": index + 1, "error": str(exc)})
        if poll_seconds > 0 and index + 1 < runs:
            time.sleep(poll_seconds)
    return {
        "successes": successes,
        "transportErrors": transport_errors,
        "fatalErrors": fatal_errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify repeated live auto_sync_tick execution against sync.velvet-leaf.com.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--poll-seconds", type=int, default=0)
    parser.add_argument("--max-transport-errors", type=int, default=0)
    parser.add_argument("--max-avg-ms", type=int, default=9000)
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

    reset_result = reset_stats(args.base_url)
    print(f"stats_reset={json.dumps(reset_result, sort_keys=True)}")

    token, user = login(args.base_url, args.username, args.password)
    print(f"logged_in_as={user.get('username')} role={user.get('role')}")

    result = run_scheduler_stress(args.base_url, token, args.runs, args.poll_seconds)
    print(f"scheduler_runs={json.dumps(result, sort_keys=True)}")

    perf_rows = fetch_perf(args.base_url)
    scheduler_perf = extract_perf_row(perf_rows, "auto_sync_tick")
    heartbeat_perf = extract_perf_row(perf_rows, "agents_heartbeat")
    post_health = fetch_health(args.base_url)
    print(f"auto_sync_tick_perf={json.dumps(scheduler_perf, sort_keys=True)}")
    print(f"agents_heartbeat_perf={json.dumps(heartbeat_perf, sort_keys=True)}")
    print(
        "post_health.ready={ready} post_health.timeout={timeout} post_health.fail={fail}".format(
            ready=post_health.get("ready"),
            timeout=post_health.get("timeout"),
            fail=post_health.get("fail"),
        )
    )

    fatal_errors = result["fatalErrors"]
    if fatal_errors:
        print(f"fatal scheduler errors observed: {json.dumps(fatal_errors, sort_keys=True)}", file=sys.stderr)
        return 1

    transport_error_count = len(result["transportErrors"])
    if transport_error_count > max(args.max_transport_errors, 0):
        print(
            f"transport errors exceeded limit: observed={transport_error_count} allowed={max(args.max_transport_errors, 0)}",
            file=sys.stderr,
        )
        return 3

    if not scheduler_perf:
        print("auto_sync_tick perf row missing after stress run", file=sys.stderr)
        return 4

    calls = int(scheduler_perf.get("calls") or 0)
    success_count = len(result["successes"])
    if calls < success_count:
        print(
            f"auto_sync_tick perf calls {calls} is lower than successful runs {success_count}",
            file=sys.stderr,
        )
        return 5

    error_count = int(scheduler_perf.get("error_count") or 0)
    if error_count > 0:
        print(f"auto_sync_tick reported {error_count} application errors", file=sys.stderr)
        return 6

    avg_ms = float(scheduler_perf.get("avg_ms") or 0.0)
    if avg_ms > float(max(args.max_avg_ms, 0)):
        print(f"auto_sync_tick avg_ms {avg_ms} exceeded limit {args.max_avg_ms}", file=sys.stderr)
        return 7

    if not post_health.get("ready", False):
        print("post-run health is not ready", file=sys.stderr)
        return 8

    if int(post_health.get("compile_errors") or 0) > 0:
        print("post-run compile errors detected", file=sys.stderr)
        return 9

    return 0


def run_cli() -> int:
    try:
        return main()
    except ApiError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
