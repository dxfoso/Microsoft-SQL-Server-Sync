import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "prepare_alameen_sales_collision_lab.py"
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("prepare_alameen_sales_collision_lab", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrepareAlameenSalesCollisionLabTests(unittest.TestCase):
    def test_default_pass_budget_covers_large_alameen_catalog(self):
        args = MODULE.build_parser().parse_args(["--client", "alshallan2"])

        self.assertEqual(args.max_passes, 100)

    def test_policy_update_retries_a_transient_api_failure(self):
        calls = []

        def operation():
            calls.append("attempt")
            if len(calls) == 1:
                raise RuntimeError("connection closed or database unavailable")
            return {"ok": True}

        result = MODULE.retry_policy_update(operation, sleep=lambda _seconds: None)

        self.assertEqual(result, {"ok": True})
        self.assertEqual(calls, ["attempt", "attempt"])

    def test_repeatable_client_option_preserves_names_with_spaces(self):
        args = MODULE.build_parser().parse_args(
            ["--client", "alshallan2", "--client", "velvet factory"]
        )

        self.assertEqual(
            MODULE.parse_client_names(args), ["alshallan2", "velvet factory"]
        )

    def test_bounded_table_window_is_drained_until_exact_scope(self):
        snapshots = [
            self._state(["ac000", "stale_first"]),
            self._state(["ac000", "stale_later"]),
            self._state(["ac000"]),
        ]
        calls = []

        def fetch_state():
            return snapshots.pop(0)

        passes, enabled = MODULE.narrow_table_scope(
            fetch_state,
            lambda client, table, value: calls.append((client, table, value)),
            target_names=["alshallan2", "velvet factory"],
            database="AmnDb048_SyncLab",
            wanted_tables={"ac000"},
        )

        self.assertEqual(passes, 3)
        self.assertEqual(
            calls,
            [
                ("alshallan2", "AmnDb048_SyncLab::stale_first", False),
                ("velvet factory", "AmnDb048_SyncLab::stale_first", False),
                ("alshallan2", "AmnDb048_SyncLab::stale_later", False),
                ("velvet factory", "AmnDb048_SyncLab::stale_later", False),
            ],
        )
        self.assertEqual(set(enabled), {"alshallan2", "velvet factory"})

    def test_each_client_policy_is_updated_in_its_own_owner_scope(self):
        snapshots = [
            self._state_by_client(
                {"alshallan2": ["ac000"], "velvet factory": ["ac000", "vf_only"]}
            ),
            self._state_by_client(
                {"alshallan2": ["ac000"], "velvet factory": ["ac000"]}
            ),
        ]
        calls = []

        MODULE.narrow_table_scope(
            lambda: snapshots.pop(0),
            lambda client, table, value: calls.append((client, table, value)),
            target_names=["alshallan2", "velvet factory"],
            database="AmnDb048_SyncLab",
            wanted_tables={"ac000"},
        )

        self.assertEqual(
            calls,
            [("velvet factory", "AmnDb048_SyncLab::vf_only", False)],
        )

    @staticmethod
    def _state(local_tables):
        return PrepareAlameenSalesCollisionLabTests._state_by_client(
            {name: local_tables for name in ("alshallan2", "velvet factory")}
        )

    @staticmethod
    def _state_by_client(tables_by_client):
        return {
            "agents": [
                {
                    "clientName": name,
                    "database": "AmnDb048_SyncLab",
                    "syncEnabled": False,
                    "tables": [
                        {
                            "table": f"AmnDb048_SyncLab::{table}",
                            "enabled": True,
                        }
                        for table in tables_by_client[name]
                    ],
                }
                for name in tables_by_client
            ]
        }


if __name__ == "__main__":
    unittest.main()
