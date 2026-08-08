# Current Status

Updated: 2026-08-08 02:24 Europe/Berlin

**Progress: 100% complete for the requested one-time run and production fix**

- One production Sync All ran exactly once from 01:45:58 to 01:53:04 (7m 6s). Automatic scheduling remained paused and no second sync was started.
- All 31 eligible tables drained, with zero active jobs and zero pending decisions afterward.
- Two large winner uploads (`BillRel000` and `POSOrder000`) reached the backend's 128 MiB execution-memory limit and were rejected atomically before apply. No partial write or deletion occurred; one source-only row in each table remains for a later user-started sync.
- INC-052 bounds compressed uploads and winner identity projections to 100 rows. INC-053 makes future Sync All operations report `Completed with errors` when any table batch fails.
- Commit `9eb967af85be56e37bab681d8bb3649be801300e` is pushed and deployed as immutable backend and frontend images. Both Kubernetes rollouts are ready.
- Windows client `1.0.246+250` is published and installed on `alshallan2`, `velvet factory`, and `velvet home`; all are online and SQL-connected with no update pending.
- The final Standard safety gate passed in 653 seconds: 24 three-client Docker scenarios, 11 fault/recovery scenarios, 5,000-row scale, and the bounded soak all passed.
- Public health reports `ready=true`, `compile_errors=0`, and the exact deployed commit. The web client page and update manifest are available.
- Sync remains paused. The next manually started Sync All will use the smaller packages to transfer the two pending rows; it was intentionally not run as part of this one-time request.
