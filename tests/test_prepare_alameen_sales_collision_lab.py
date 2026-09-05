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
            lambda table, value: calls.append((table, value)),
            target_names=["alshallan2", "velvet factory"],
            database="AmnDb048_SyncLab",
            wanted_tables={"ac000"},
        )

        self.assertEqual(passes, 3)
        self.assertEqual(
            calls,
            [
                ("AmnDb048_SyncLab::stale_first", False),
                ("AmnDb048_SyncLab::stale_later", False),
            ],
        )
        self.assertEqual(set(enabled), {"alshallan2", "velvet factory"})

    @staticmethod
    def _state(local_tables):
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
                        for table in local_tables
                    ],
                }
                for name in ("alshallan2", "velvet factory")
            ]
        }


if __name__ == "__main__":
    unittest.main()
