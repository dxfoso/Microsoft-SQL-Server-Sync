#!/usr/bin/env python3
"""Narrow disabled isolated Al-Ameen clients to the proven Sales graph."""

import argparse
import os
import time

from verify_live_clients_state import invoke_function, live_state, login


DEFAULT_TABLES = {
    "ac000",
    "bi000",
    "bu000",
    "ce000",
    "cp000",
    "en000",
    "er000",
    "ms000",
    "mt000",
    "pt000",
}


def retry_policy_update(operation, *, attempts=5, sleep=time.sleep):
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except Exception as error:
            last_error = error
            if attempt < attempts:
                sleep(attempt)
    raise last_error


def _target_agents(state, target_names, database):
    targets = {
        str(agent.get("clientName", "")).strip().lower(): agent
        for agent in state.get("agents", [])
        if str(agent.get("clientName", "")).strip().lower() in target_names
    }
    if set(targets) != target_names:
        raise RuntimeError(
            f"expected clients {sorted(target_names)}, found {sorted(targets)}"
        )
    for name, agent in targets.items():
        if agent.get("syncEnabled") is not False:
            raise RuntimeError(f"synchronization must remain disabled: {name}")
        if str(agent.get("database", "")).strip() != database:
            raise RuntimeError(
                f"client {name} targets {agent.get('database')}, expected {database}"
            )
    return targets


def _enabled_tables(agent):
    return {
        str(table.get("table", "")).strip()
        for table in agent.get("tables", [])
        if table.get("enabled") is True and str(table.get("table", "")).strip()
    }


def narrow_table_scope(
    fetch_state,
    set_policy,
    *,
    target_names,
    database,
    wanted_tables,
    max_passes=100,
):
    """Iterate because the bounded live-state window can reveal tables in waves."""
    normalized_targets = {name.strip().lower() for name in target_names}
    normalized_wanted = {name.strip().lower() for name in wanted_tables}
    for pass_number in range(1, max_passes + 1):
        targets = _target_agents(fetch_state(), normalized_targets, database)
        enabled_by_client = {
            name: _enabled_tables(agent) for name, agent in targets.items()
        }
        converged = True
        for client_name, enabled in enabled_by_client.items():
            unwanted = sorted(
                (
                    table
                    for table in enabled
                    if table.split("::")[-1].lower() not in normalized_wanted
                ),
                key=str.lower,
            )
            present_wanted = {
                table.split("::")[-1].lower()
                for table in enabled
                if table.split("::")[-1].lower() in normalized_wanted
            }
            missing = sorted(normalized_wanted - present_wanted)
            if unwanted or missing:
                converged = False
            for table in unwanted:
                set_policy(client_name, table, False)
            for local_table in missing:
                set_policy(client_name, f"{database}::{local_table}", True)
        if converged:
            return pass_number, enabled_by_client
    raise RuntimeError(
        f"table scope did not converge after {max_passes} bounded-state passes"
    )


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", action="append", dest="client_names")
    parser.add_argument("--clients", nargs="+", dest="legacy_client_names")
    parser.add_argument("--database", default="AmnDb048_SyncLab")
    parser.add_argument("--base-url", default="https://sync.velvet-leaf.com")
    parser.add_argument("--max-passes", type=int, default=100)
    return parser


def parse_client_names(args):
    names = args.client_names or args.legacy_client_names or []
    if not names:
        raise RuntimeError("at least one --client is required")
    return names


def main():
    args = build_parser().parse_args()
    client_names = parse_client_names(args)
    username = os.environ.get("SQL_SYNC_ADMIN_USERNAME", "")
    password = os.environ.get("SQL_SYNC_ADMIN_PASSWORD", "")
    if not username or not password:
        raise RuntimeError("administrator credentials are required through environment variables")
    token, _ = login(args.base_url, username, password)
    def fetch_state():
        return live_state(args.base_url, token)

    def set_policy(client_name, table, enabled):
        result = retry_policy_update(
            lambda: invoke_function(
                args.base_url,
                "table_sync_policy_set",
                {
                    "table": table,
                    "enabled": enabled,
                    "cascadeRelated": False,
                    "clientName": client_name,
                    "token": token,
                },
            )
        )
        if result.get("ok") is not True:
            raise RuntimeError(f"policy update failed for {table}")

    passes, enabled_by_client = narrow_table_scope(
        fetch_state,
        set_policy,
        target_names=client_names,
        database=args.database,
        wanted_tables=DEFAULT_TABLES,
        max_passes=args.max_passes,
    )
    for name in sorted(enabled_by_client):
        enabled = sorted(
            table.split("::")[-1].lower() for table in enabled_by_client[name]
        )
        print(
            f"{name}: database={args.database} syncEnabled=false "
            f"passes={passes} enabledTables={','.join(enabled)}"
        )


if __name__ == "__main__":
    main()
