from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ControlPlanePerfContractsTests(unittest.TestCase):
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
        self.assertIn("table_relationships_for_database(agent.tableRelationships ?? [], trimmedDatabase, remaining)", dependency_body)
        self.assertIn(".filter((relationship) =>", bounded_dependency_body)
        self.assertIn("maxCount", bounded_dependency_body)
        self.assertNotIn("for (const relationship of relationships)", dependency_body)

    def test_bulk_job_creation_reuses_owner_and_active_job_caches(self):
        control_plane = read_text("business/control_plane.tru")
        jobs_body = control_plane.split(
            "function jobs_create_all_enabled(", 1
        )[1].split("function reset_all_agent_saved_state", 1)[0]
        create_body = control_plane.split(
            "function create_sync_jobs_for_agent(", 1
        )[1].split("function row_key", 1)[0]

        self.assertIn("const ownerPolicies = list_table_sync_policies_for_scope(ownerUserId);", jobs_body)
        self.assertIn("const completedJobRows = list_completed_scheduler_job_rows(ownerUserId);", jobs_body)
        self.assertIn("const activeTableCaches = ownerAgents.map", jobs_body)
        self.assertIn("preferred_source_client_name_for_agent_table(agent, table, ownerAgents, ownerPolicies, tableCaches, completedJobRows)", jobs_body)
        self.assertIn("create_sync_jobs_for_agent(agent, [table], sourceClientName, activeTableCaches, sourceAgent)", jobs_body)
        self.assertIn("active_job_tables_from_cache", create_body)
        self.assertIn("sourceAgentOverride", create_body)


if __name__ == "__main__":
    unittest.main()
