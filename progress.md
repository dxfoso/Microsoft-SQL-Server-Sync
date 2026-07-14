# Multi-Writer Sync Progress
Progress: 95%

- Production policy implemented: SQL Server Change Tracking commit time is used as the UTC conflict timestamp; arrival order is used only when the commit DMV is unavailable or timestamps are missing.
- Client `1.0.145+149` is published from commit `fa78c80654cd`; live manifest and ZIP hash match, and the ZIP opens and contains the executable.
- Local Flutter verification passed: `93/93` tests.
- C2 is online, server-connected, SQL-connected, minimized, and current on `1.0.145+149`.
- C1 acknowledged the same version and is SQL-connected, but its heartbeat stopped at `2026-07-14T06:36:25Z`; it must be restarted/recovered before live multi-writer end-to-end proof is complete.
- No server redeploy is required for this client-only change. The remaining risk is C1 process/startup recovery, not the conflict-selection implementation or package integrity.
