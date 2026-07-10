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


if __name__ == "__main__":
    unittest.main()
