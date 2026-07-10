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

        self.assertIn("function heartbeat_persist_interval_minutes", control_plane)
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


if __name__ == "__main__":
    unittest.main()
