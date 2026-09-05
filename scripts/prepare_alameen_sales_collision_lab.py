#!/usr/bin/env python3
"""Narrow disabled isolated Al-Ameen clients to the proven Sales graph."""

import argparse
import os

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
    max_passes=20,
):
    """Iterate because the bounded live-state window can reveal tables in waves."""
    normalized_targets = {name.strip().lower() for name in target_names}
    normalized_wanted = {name.strip().lower() for name in wanted_tables}
    for pass_number in range(1, max_passes + 1):
        targets = _target_agents(fetch_state(), normalized_targets, database)
        enabled_by_client = {
            name: _enabled_tables(agent) for name, agent in targets.items()
        }
        unwanted = sorted(
            {
                table
                for enabled in enabled_by_client.values()
                for table in enabled
                if table.split("::")[-1].lower() not in normalized_wanted
            },
            key=str.lower,
        )
        present_wanted = {
            table.split("::")[-1].lower()
            for enabled in enabled_by_client.values()
            for table in enabled
            if table.split("::")[-1].lower() in normalized_wanted
        }
        missing = sorted(normalized_wanted - present_wanted)
        if not unwanted and not missing:
            expected = normalized_wanted
            for name, enabled in enabled_by_client.items():
                observed = {table.split("::")[-1].lower() for table in enabled}
                if observed != expected:
                    break
            else:
                return pass_number, enabled_by_client
        for table in unwanted:
            set_policy(table, False)
        for local_table in missing:
            set_policy(f"{database}::{local_table}", True)
    raise RuntimeError(
        f"table scope did not converge after {max_passes} bounded-state passes"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--clients", nargs="+", required=True)
    parser.add_argument("--database", default="AmnDb048_SyncLab")
    parser.add_argument("--base-url", default="https://sync.velvet-leaf.com")
    parser.add_argument("--max-passes", type=int, default=20)
    args = parser.parse_args()
    username = os.environ.get("SQL_SYNC_ADMIN_USERNAME", "")
    password = os.environ.get("SQL_SYNC_ADMIN_PASSWORD", "")
    if not username or not password:
        raise RuntimeError("administrator credentials are required through environment variables")
    token, _ = login(args.base_url, username, password)
    policy_client = args.clients[0]

    def fetch_state():
        return live_state(args.base_url, token)

    def set_policy(table, enabled):
        result = invoke_function(
            args.base_url,
            "table_sync_policy_set",
            {
                "table": table,
                "enabled": enabled,
                "cascadeRelated": False,
                "clientName": policy_client,
                "token": token,
            },
        )
        if result.get("ok") is not True:
            raise RuntimeError(f"policy update failed for {table}")

    passes, enabled_by_client = narrow_table_scope(
        fetch_state,
        set_policy,
        target_names=args.clients,
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
