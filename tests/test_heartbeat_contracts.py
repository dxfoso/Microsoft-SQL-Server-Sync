import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class HeartbeatContractsTests(unittest.TestCase):
    def test_heartbeat_write_throttling_stays_server_owned(self):
        control_plane = read_text("business/control_plane.tru")
        heartbeat_body = control_plane.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick(", 1
        )[0]

        self.assertIn("function heartbeat_persist_interval_ms", control_plane)
        self.assertIn("function agent_online_timeout_ms", control_plane)
        self.assertIn("return 60 * 1000;", control_plane)
        self.assertIn("function heartbeat_write_due", control_plane)
        self.assertIn("function lightweight_agent_heartbeat_state_changed", control_plane)
        self.assertIn(
            "autoSyncIntervalMinutes: clamp_auto_sync_interval(agent.autoSyncIntervalMinutes)",
            heartbeat_body,
        )
        self.assertNotIn(
            "autoSyncIntervalMinutes: clamp_auto_sync_interval(autoSyncIntervalMinutes)",
            heartbeat_body,
        )
        self.assertIn(
            "else if (lightweightHeartbeatChanged || heartbeat_write_due(agent)) {",
            heartbeat_body,
        )
        self.assertIn("const lightweightHeartbeatChanged = lightweight_agent_heartbeat_state_changed(", heartbeat_body)
        self.assertIn("lastHeartbeat: now_iso(),", heartbeat_body)

    def test_public_client_status_is_server_owned_and_ready_is_terminal(self):
        control_plane = read_text("business/control_plane.tru")
        frontend_models = read_text("frontend/lib/models.dart")
        clients_page = read_text("frontend/lib/clients_page.dart")

        self.assertIn("function client_runtime_status_payload(", control_plane)
        self.assertIn("status: runtimeStatus", control_plane)
        self.assertIn("status: { in: ['queued', 'waiting', 'running'", control_plane)
        self.assertIn("code: 'catching_up'", control_plane)
        self.assertIn("code: 'catchup_paused'", control_plane)
        self.assertIn("label: 'Catch-up pending (sync paused)'", control_plane)
        self.assertIn("automatic_sync_is_paused_for_owner", control_plane)
        self.assertIn("code: 'ready'", control_plane)
        self.assertIn("ready: true", control_plane)
        self.assertIn("runtimeStatusLabel", frontend_models)
        self.assertIn("agent.runtimeStatusLabel.trim()", clients_page)


if __name__ == "__main__":
    unittest.main()
