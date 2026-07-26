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
        self.assertIn("sync_table_baseline_plan(table, onlineAgents, ownerPolicies, tableCaches)", jobs_body)
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


if __name__ == "__main__":
    unittest.main()
