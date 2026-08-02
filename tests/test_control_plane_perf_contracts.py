from pathlib import Path
import json
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ControlPlanePerfContractsTests(unittest.TestCase):
    def test_server_request_budget_covers_atomic_bulk_preflight(self):
        config = json.loads(read_text("business/tru.json"))
        self.assertGreaterEqual(config["settings"]["requestTimeoutMs"], 30_000)

    def test_generic_agent_list_excludes_large_diagnostics_payload(self):
        control_plane = read_text("business/control_plane.tru")
        list_agent_rows_body = control_plane.split("function list_agent_rows(): array<json> {", 1)[1].split(
            "function list_job_rows(): array<json> {", 1
        )[0]

        self.assertIn("diagnosticSummary", list_agent_rows_body)
        self.assertNotIn("diagnosticPayload", list_agent_rows_body)

    def test_relationship_builders_avoid_nested_self_concat(self):
        control_plane = read_text("business/control_plane.tru")
        bounded_body = control_plane.split(
            "function bounded_table_relationships(", 1
        )[1].split("function table_dependency_payloads_for_database", 1)[0]
        dependency_body = control_plane.split(
            "function table_dependency_payloads_for_database", 1
        )[1].split("function expand_related_table_sync_keys_once", 1)[0]
        bounded_dependency_body = control_plane.split(
            "function table_relationships_for_database", 1
        )[1].split("function expand_related_table_sync_keys_once", 1)[0]

        self.assertIn("let acceptedCount = 0;", bounded_body)
        self.assertIn("acceptedCount >= 1000", bounded_body)
        self.assertNotIn("result = result.concat([normalized])", bounded_body)
        self.assertIn("table_relationships_for_database(agent.tableRelationships ?? [], trimmedDatabase, 1000)", dependency_body)
        self.assertIn(".filter((relationship) =>", bounded_dependency_body)
        self.assertIn("maxCount", bounded_dependency_body)
        self.assertNotIn("for (const relationship of relationships)", dependency_body)

    def test_bulk_job_creation_reuses_owner_and_active_job_caches(self):
        control_plane = read_text("business/control_plane.tru")
        jobs_body = control_plane.split(
            "function jobs_create_all_enabled(", 1
        )[1].split("function reset_all_agent_saved_state", 1)[0]
        self.assertIn("const ownerPolicies = list_table_sync_policies_for_scope(ownerUserId);", jobs_body)
        self.assertIn("const activeTableCaches = onlineAgents.map", jobs_body)
        self.assertEqual(jobs_body.count("active_job_tables_for_client("), 1)
        self.assertIn("active_job_tables_from_cache", jobs_body)
        self.assertIn("const tableCaches = onlineAgents.map", jobs_body)
        self.assertIn("sync_table_baseline_plan(", jobs_body)
        self.assertNotIn("refresh_owner_baseline_table_issues(", jobs_body)
        self.assertIn("!preserveChangeTrackingBaselines", jobs_body)
        self.assertIn("create_multi_writer_batch(", jobs_body)

    def test_baseline_issue_refresh_persists_and_cancels_once_per_owner(self):
        control_plane = read_text("business/control_plane.tru")
        refresh_body = control_plane.split(
            "function refresh_owner_baseline_table_issues(", 1
        )[1].split("function sync_gate_payload_for_owners", 1)[0]

        self.assertIn("let nextIssues = existingIssues;", refresh_body)
        self.assertIn("replace_sync_table_issue_in_values", refresh_body)
        self.assertEqual(refresh_body.count("save_sync_table_issues_for_owner("), 1)
        self.assertEqual(refresh_body.count("cancel_owner_sync_jobs_for_input("), 1)
        self.assertNotIn("raise_sync_table_issue(", refresh_body)
        self.assertIn("const activeOwnerTables = active_job_tables_for_owner(ownerUserId);", refresh_body)
        self.assertIn("!string_array_contains(activeOwnerTables, table)", refresh_body)
        self.assertNotIn("sync_owner_table_has_active_jobs(ownerUserId, table)", refresh_body)

    def test_owner_preflight_cancellation_defers_storage_cleanup_and_bulk_helper_is_bounded(self):
        control_plane = read_text("business/control_plane.tru")
        cancel_body = control_plane.split(
            "function cancel_owner_sync_jobs_for_input(", 1
        )[1].split("function sync_owner_table_has_active_jobs", 1)[0]
        cleanup_body = control_plane.split(
            "function cleanup_multi_writer_batches_storage(", 1
        )[1].split("function cleanup_multi_writer_batch_storage", 1)[0]

        self.assertNotIn("cleanup_multi_writer_batch", cancel_body)
        self.assertNotIn("storage.delete", cancel_body)
        self.assertEqual(cancel_body.count("db.selectMany("), 1)
        self.assertEqual(cancel_body.count("db.updateMany("), 1)
        self.assertEqual(cleanup_body.count("db.selectMany("), 2)
        self.assertEqual(cleanup_body.count("db.deleteMany("), 1)
        self.assertIn("sourceJobId: { in: normalizedBatchIds }", cleanup_body)

    def test_manual_job_creation_reuses_preloaded_baseline_inputs(self):
        control_plane = read_text("business/control_plane.tru")
        jobs_body = control_plane.split(
            "function jobs_create(", 1
        )[1].split("function jobs_bootstrap", 1)[0]

        self.assertIn("const schedulerAgents = list_scheduler_agent_rows();", jobs_body)
        self.assertIn("const ownerPolicies = list_table_sync_policies_for_scope(ownerId);", jobs_body)
        self.assertIn(
            "refresh_owner_baseline_table_issues(ownerId, schedulerAgents, ownerPolicies)",
            jobs_body,
        )
        self.assertIn(
            "const targetAgent = find_agent_row_by_name(ownerAgents, resolvedClientName);",
            jobs_body,
        )
        self.assertNotIn("db.selectOne(Agent", jobs_body)

    def test_change_tracking_preflight_does_not_rebuild_supplied_table_cache(self):
        control_plane = read_text("business/control_plane.tru")
        ready_body = control_plane.split(
            "function scheduler_table_change_tracking_ready(", 1
        )[1].split("function sync_agents_enabled_for_table", 1)[0]

        cache_branch = ready_body.split(
            "if (tableCache != null && tableCache.tables != null)", 1
        )[1]
        self.assertIn("states = tableCache.tables;", cache_branch)
        self.assertIn("} else {", cache_branch)
        self.assertIn("states = scheduler_agent_table_states(agent);", cache_branch)

    def test_blocked_periodic_owner_skips_redundant_baseline_scan(self):
        control_plane = read_text("business/control_plane.tru")
        scheduler_body = control_plane.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit", 1)[0]

        gate_position = scheduler_body.index(
            "if (sync_owner_has_blocking_table_issues(normalizedOwnerUserId))"
        )
        refresh_position = scheduler_body.index(
            "refresh_owner_baseline_table_issues(normalizedOwnerUserId, sourceAgents)"
        )
        self.assertLess(gate_position, refresh_position)

    def test_scheduler_reuses_enabled_table_caches_across_baseline_wave(self):
        control_plane = read_text("business/control_plane.tru")
        cache_body = control_plane.split(
            "function scheduler_agent_table_state_cache(", 1
        )[1].split("function scheduler_agent_table_state_cache_for_agent", 1)[0]
        participants_body = control_plane.split(
            "function sync_agents_enabled_for_table(", 1
        )[1].split("function sync_table_baseline_plan", 1)[0]
        refresh_body = control_plane.split(
            "function refresh_owner_baseline_table_issues(", 1
        )[1].split("function sync_gate_payload_for_owners", 1)[0]
        scheduler_body = control_plane.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit", 1)[0]

        self.assertIn("enabledTables", cache_body)
        self.assertIn("cache.enabledTables", participants_body)
        self.assertIn(
            "sync_agents_enabled_for_table(agents, table, policies, caches)",
            control_plane,
        )
        self.assertIn("candidateTables = candidateTables.concat(cache.enabledTables ?? []);", refresh_body)
        self.assertIn("tableCache.enabledTables", control_plane)
        self.assertIn("cache.enabledTables", scheduler_body)
        due_body = control_plane.split(
            "function due_periodic_sync_tables_for_agent_with_policies(", 1
        )[1].split("function queue_due_periodic_sync_jobs_for_owner", 1)[0]
        cache_branch = due_body.split(
            "if (tableCache != null && tableCache.tables != null)", 1
        )[1]
        self.assertIn("cachedTables = tableCache.tables;", cache_branch)
        self.assertIn("} else {", cache_branch)
        self.assertIn("cachedTables = scheduler_agent_table_states(agent, policies);", cache_branch)

    def test_scheduler_cron_sessions_are_bounded_and_revoked(self):
        control_plane = read_text("business/control_plane.tru")
        cronjob = read_text("deployment/chart/templates/auto-scheduler-cronjob.yaml")
        login_body = control_plane.split(
            "function auth_login(", 1
        )[1].split("function auth_me", 1)[0]

        self.assertIn("session.app == 'scheduler'", control_plane)
        self.assertIn("db.deleteMany(Session, { app: 'scheduler' });", login_body)
        self.assertIn('"app": "scheduler"', cronjob)
        self.assertIn('"name": "auth_logout"', cronjob)

    def test_heartbeat_job_dispatch_filters_history_in_database(self):
        control_plane = read_text("business/control_plane.tru")
        active_jobs_body = control_plane.split(
            "function active_jobs_for_client(", 1
        )[1].split("function unique_string_values", 1)[0]

        self.assertIn(
            "status: { in: ['queued', 'waiting', 'running', 'snapshotting', 'uploading', 'downloading', 'applying'] }",
            active_jobs_body,
        )
        self.assertIn("limit: 250", active_jobs_body)
        self.assertIn("id: { in: activeBatchIds }", active_jobs_body)
        self.assertNotIn("limit: 1000", active_jobs_body)


if __name__ == "__main__":
    unittest.main()
