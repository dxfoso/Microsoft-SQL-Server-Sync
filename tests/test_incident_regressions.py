import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
ISSUES = ROOT / "issue.md"


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class IncidentRegressionCatalogTests(unittest.TestCase):
    def test_every_catalog_incident_has_existing_automated_coverage(self):
        document = ISSUES.read_text(encoding="utf-8")
        rows = [line for line in document.splitlines() if line.startswith("| INC-")]
        expected_ids = {f"INC-{number:03d}" for number in range(1, 28)}
        observed_ids = set()

        for row in rows:
            cells = [cell.strip() for cell in row.strip().strip("|").split("|")]
            self.assertEqual(len(cells), 6, row)
            incident_id = cells[0]
            self.assertNotIn(incident_id, observed_ids)
            observed_ids.add(incident_id)

            references = re.findall(r"`([^`]+)`", cells[5])
            self.assertGreater(len(references), 0, incident_id)
            for reference in references:
                path_text, separator, selector = reference.partition("::")
                path = ROOT / path_text
                self.assertTrue(path.is_file(), f"{incident_id}: missing {path_text}")
                if separator:
                    source = path.read_text(encoding="utf-8")
                    self.assertIn(selector, source, f"{incident_id}: missing {reference}")

        self.assertEqual(observed_ids, expected_ids)

    def test_optional_windows_theme_api_is_guarded(self):
        source = read_text("sync_windows_agent/windows/runner/win32_window.cpp")
        body = source.split("void ApplyThemeIfAvailable(", 1)[1].split("\n}", 1)[0]

        self.assertIn('LoadLibraryA("Dwmapi.dll")', body)
        self.assertIn("if (!dwmapi_module)", body)
        self.assertIn('GetProcAddress(dwmapi_module, "DwmSetWindowAttribute")', body)
        self.assertIn("if (set_window_attribute != nullptr)", body)
        self.assertIn("FreeLibrary(dwmapi_module)", body)
        self.assertNotIn("DwmSetWindowAttribute(window", body)

    def test_repo_owned_background_launchers_are_hidden(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        updater = read_text("update.ps1")
        window_settings = read_text("sync_windows_agent/lib/window_settings.dart")
        app = read_text("sync_windows_agent/lib/app.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        document = ISSUES.read_text(encoding="utf-8")

        self.assertIn("-WindowStyle Hidden", supervisor)
        self.assertIn("-WindowStyle Hidden", updater)
        self.assertIn("'-WindowStyle',\n      'Hidden'", window_settings)
        self.assertNotIn("Process.start('cmd.exe'", app)
        self.assertNotIn("Process.start('cmd.exe'", agent)
        self.assertIn("external FlutterFalcon builder", document)
        self.assertIn("Win32_Process.Create", document)
        self.assertIn("must not persist access credentials", document)

    def test_upload_and_backend_execution_memory_are_bounded(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        values = read_text("deployment/chart/values.yaml")
        deployment = read_text("deployment/chart/templates/backend-deployment.yaml")

        self.assertIn("const maxDeltaPayloadBytes = 128000;", agent)
        self.assertIn("const maxDeltaRowsPerChunk = 25;", agent)
        self.assertIn("offset + maxDeltaRowsPerChunk", agent)
        self.assertIn('truExecutionMemoryMaxBytes: "134217728"', values)
        self.assertIn("TRU_EXECUTION_MEMORY_MAX_BYTES", deployment)
        self.assertIn(".Values.backend.env.truExecutionMemoryMaxBytes", deployment)

    def test_local_architecture_commands_and_release_contract_are_documented(self):
        document = ISSUES.read_text(encoding="utf-8")
        runner = read_text("tests/run_sync_verification.ps1")

        self.assertIn(".\\tests\\run_sync_verification.ps1 -Profile Standard", document)
        self.assertIn(".\\tests\\run_sync_verification.ps1 -Profile All", document)
        self.assertIn("three fake Docker clients", document)
        self.assertIn("never justify testing against active production databases", document)
        self.assertIn("tests/test_incident_regressions.py", runner)

    def test_agents_requires_issue_documentation_and_automated_regression(self):
        rules = read_text("AGENTS.md")

        self.assertIn("## Issue Documentation and Regression Rule", rules)
        self.assertIn("must be documented in the root `issue.md` incident matrix", rules)
        self.assertIn("must add or extend an automated unit, contract, integration", rules)
        self.assertIn("A manual check alone is not sufficient", rules)
        self.assertIn("tests/run_sync_verification.ps1", rules)
        self.assertIn("Never use active production client databases to reproduce an issue", rules)


if __name__ == "__main__":
    unittest.main()
