#!/usr/bin/env python3
import argparse
import json
import sys
import time
from pathlib import Path

from verify_live_sync_state import (
    ApiError,
    DEFAULT_BASE_URL,
    DEFAULT_PASSWORD,
    DEFAULT_USERNAME,
    find_agent,
    invoke_function,
    live_state,
    login,
)


TERMINAL_STATUSES = {"completed", "failed", "cancelled"}


def enabled_table_state(agent: dict, table_name: str) -> dict:
    tables = agent.get("tables")
    if not isinstance(tables, list):
        raise ApiError(f"client {agent.get('clientName')} has no table state")
    for table in tables:
        if (
            isinstance(table, dict)
            and str(table.get("table") or "").strip() == table_name
            and bool(table.get("enabled"))
        ):
            return table
    raise ApiError(
        f"enabled table {table_name} was not reported by {agent.get('clientName')}"
    )


def table_fingerprint(agent: dict, table_name: str) -> dict:
    table = enabled_table_state(agent, table_name)
    checksum = str(table.get("tableChecksum") or "").strip()
    if not checksum:
        raise ApiError(
            f"client {agent.get('clientName')} has not reported a fingerprint for {table_name}"
        )
    return {
        "rowCount": int(table.get("rowCount") or 0),
        "tableChecksum": checksum,
    }


def require_ready_agent(state: dict, client_name: str) -> dict:
    agent = find_agent(state, client_name)
    if not (
        bool(agent.get("isOnline"))
        and bool(agent.get("serverConnected"))
        and bool(agent.get("sqlConnected"))
    ):
        raise ApiError(f"client must be online and SQL-connected: {client_name}")
    return agent


def job_map(state: dict) -> dict[str, dict]:
    jobs = state.get("jobs")
    if not isinstance(jobs, list):
        return {}
    return {
        str(job.get("id") or "").strip(): job
        for job in jobs
        if isinstance(job, dict) and str(job.get("id") or "").strip()
    }


def wait_for_jobs(
    base_url: str,
    token: str,
    job_ids: list[str],
    timeout_seconds: int,
) -> dict:
    deadline = time.time() + timeout_seconds
    last_observed = {}
    while time.time() < deadline:
        state = live_state(base_url, token)
        visible = job_map(state)
        last_observed = {
            job_id: {
                "status": str((visible.get(job_id) or {}).get("status") or "").lower(),
                "message": str((visible.get(job_id) or {}).get("message") or ""),
                "error": (visible.get(job_id) or {}).get("error"),
            }
            for job_id in job_ids
        }
        if all(
            observed["status"] in TERMINAL_STATUSES
            for observed in last_observed.values()
        ):
            failed = {
                job_id: observed
                for job_id, observed in last_observed.items()
                if observed["status"] != "completed"
            }
            if failed:
                raise ApiError(
                    f"authoritative reconciliation jobs failed: {json.dumps(failed, sort_keys=True)}"
                )
            return state
        time.sleep(3)
    raise ApiError(
        f"timed out waiting for authoritative reconciliation jobs: "
        f"{json.dumps(last_observed, sort_keys=True)}"
    )


def wait_for_fingerprints(
    base_url: str,
    token: str,
    source_client: str,
    target_clients: list[str],
    tables: list[str],
    expected: dict,
    timeout_seconds: int,
) -> dict:
    deadline = time.time() + timeout_seconds
    last = {}
    while time.time() < deadline:
        state = live_state(base_url, token)
        source = require_ready_agent(state, source_client)
        observed_source = {
            table: table_fingerprint(source, table) for table in tables
        }
        if observed_source != expected:
            raise ApiError(
                "authoritative source changed while reconciliation was running: "
                f"expected={json.dumps(expected, sort_keys=True)} "
                f"observed={json.dumps(observed_source, sort_keys=True)}"
            )
        last = {}
        converged = True
        for target_client in target_clients:
            target = require_ready_agent(state, target_client)
            last[target_client] = {
                table: table_fingerprint(target, table) for table in tables
            }
            if last[target_client] != expected:
                converged = False
        if converged:
            return {"state": state, "targets": last}
        time.sleep(3)
    raise ApiError(
        "timed out waiting for target fingerprints to match the source: "
        f"{json.dumps(last, sort_keys=True)}"
    )


def queue_reconcile(
    base_url: str,
    token: str,
    source_client: str,
    target_clients: list[str],
    tables: list[str],
) -> list[str]:
    result = invoke_function(
        base_url,
        "jobs_reconcile_authoritative",
        {
            "sourceClientName": source_client,
            "targetClientNames": target_clients,
            "tables": tables,
            "token": token,
        },
    )
    jobs = result.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise ApiError(f"reconciliation did not create jobs: {result!r}")
    job_ids = [
        str(job.get("id") or "").strip()
        for job in jobs
        if isinstance(job, dict) and str(job.get("id") or "").strip()
    ]
    if len(job_ids) != len(jobs):
        raise ApiError(f"reconciliation returned malformed jobs: {result!r}")
    return job_ids


def write_result(path: str, result: dict) -> None:
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Repair live target clients from one authoritative client and verify exact, retry-safe convergence."
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--username", default=DEFAULT_USERNAME)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--source", default="c1")
    parser.add_argument("--targets", nargs="+", default=["c2"])
    parser.add_argument("--tables", nargs="+", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--skip-idempotent-retry", action="store_true")
    parser.add_argument("--result-path", default="")
    args = parser.parse_args()

    token, user = login(args.base_url, args.username, args.password)
    pause = invoke_function(
        args.base_url,
        "automatic_sync_control_set",
        {"paused": True, "token": token},
    )
    if pause.get("automaticSyncPaused") is not True:
        raise ApiError("the control plane did not confirm that automatic sync is paused")

    state = live_state(args.base_url, token)
    source = require_ready_agent(state, args.source)
    for target in args.targets:
        require_ready_agent(state, target)
    expected = {
        table: table_fingerprint(source, table) for table in args.tables
    }

    first_job_ids = queue_reconcile(
        args.base_url,
        token,
        args.source,
        args.targets,
        args.tables,
    )
    wait_for_jobs(
        args.base_url,
        token,
        first_job_ids,
        args.timeout_seconds,
    )
    first = wait_for_fingerprints(
        args.base_url,
        token,
        args.source,
        args.targets,
        args.tables,
        expected,
        args.timeout_seconds,
    )

    retry_job_ids = []
    retry = first
    if not args.skip_idempotent_retry:
        retry_job_ids = queue_reconcile(
            args.base_url,
            token,
            args.source,
            args.targets,
            args.tables,
        )
        wait_for_jobs(
            args.base_url,
            token,
            retry_job_ids,
            args.timeout_seconds,
        )
        retry = wait_for_fingerprints(
            args.base_url,
            token,
            args.source,
            args.targets,
            args.tables,
            expected,
            args.timeout_seconds,
        )

    result = {
        "ok": True,
        "loggedInAs": user.get("username"),
        "automaticSyncPaused": True,
        "sourceClientName": args.source,
        "targetClientNames": args.targets,
        "tables": args.tables,
        "sourceFingerprints": expected,
        "targetFingerprints": retry["targets"],
        "firstJobIds": first_job_ids,
        "retryJobIds": retry_job_ids,
        "idempotentRetryVerified": not args.skip_idempotent_retry,
    }
    write_result(args.result_path, result)
    print(json.dumps(result, sort_keys=True))
    return 0


def run_cli() -> int:
    try:
        return main()
    except ApiError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
