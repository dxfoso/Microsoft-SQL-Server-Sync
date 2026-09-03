# Progress

Overall: **86% complete - stopped safely at a confirmed Al-Ameen control blocker**

| Step | Status | Progress |
|---|---|---:|
| Restricted test laboratory and rollback gates | Done | 100% |
| Pre-input `AmnDb048` backup and independent hash verification | Done | 100% |
| Screenshot capture and fixed invoice-menu probe | Done | 100% |
| Client tests, three-client Docker gate, Standard robustness and soak gate | Done | 100% |
| Publish Windows client `1.0.311+315` and deploy production commit `51ed56bd39a4b4f6cf22e2b8fc4bd2f6510bb8f0` | Done | 100% |
| Update and reconnect `alshallan2` with synchronization disabled | Done | 100% |
| Inspect the opened invoice popup for semantic controls | Done - no controls exposed | 100% |
| Open Sales, record business operations, and prove database rollback | Blocked - not started | 0% |

Current result: `alshallan2` is online on `DESKTOP-ALDNHIH`, connected to `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`, running client `1.0.311+315`, synchronization disabled, and zero active sync jobs. The verified rollback backup remains 140,455,424 bytes with SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`.

The final fixed probe request `f055c30d-5c4a-4532-95a3-b7de60054b10` opened the invoice menu, proved 14,638 changed samples, captured one process-owned `XTPPopupBar` at relative bounds `1099,56 / 234x299`, closed it with Escape, and changed no database record. The diagnostic image hash is `b291650b8f9fdd400907a8e098c5c3e8c8c17e6400f8fd0dc1ad7e54136236dc`.

## Blocker and stop reason

Prior semantic-accessibility blocker: **confirmed and not solvable safely with the currently exposed controls**.

Al-Ameen 8.1 (`Amn32.exe`, root class `Afx:00400000:0`) exposes the opened Codejock popup window but returns `menuControlCount: 0` and `menuControls: []`. Therefore there is no stable semantic identity for the Sales command. Continuing would require coordinate-only clicks on accounting screens, which cannot prove the intended command or field and could mutate the wrong financial record.

Work is stopped before opening Sales or entering data, as required. Safe continuation needs at least one of:

- a vendor-supported API or automation interface;
- a stable, independently verified MSAA/Win32 command identifier for this exact Al-Ameen build; or
- authorization for a coordinate-based adapter plus an isolated disposable environment where every action and full rollback can be proven without risking this database.

`velvet home` remains ignored while disabled. No synchronization was started.
