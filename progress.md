# Progress

Overall: **94% complete - safe low-bandwidth Sales delta export implementation in progress**

| Step | Status | Progress |
|---|---|---:|
| Restricted laboratory and verified `AmnDb048` rollback backup | Done | 100% |
| Screenshot capture and fixed invoice-menu discovery | Done | 100% |
| Build, test, publish, and deploy owned-window capture release `1.0.313+317` / `88cc3026c94d3026c77e9bbbcd9b9bb7bec27105` | Done | 100% |
| Update and reconnect `alshallan2` with synchronization disabled | Done | 100% |
| Capture the user-opened Sales dialog without input | Done after delayed command delivery | 100% |
| Record the first manual Sales operation and compare its database effects | In progress | 35% |
| Replace full-backup transfer with bounded Change Tracking delta export | In progress | 82% |
| Prove full database rollback | Not started | 0% |

Current state: `alshallan2` is online on `DESKTOP-ALDNHIH`, connected to `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`, running `1.0.313+317`, synchronization disabled, and zero active sync jobs. `velvet home` remains ignored while disabled. The verified rollback backup remains 140,455,424 bytes with SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`.

## Resolved command delay and safety evidence

Prior semantic-accessibility blocker: **confirmed; visual-only fallback was explicitly authorized and remains fixed-action guarded**.

The new release passed its local startup, contract, Flutter, Docker, Standard verification, immutable deployment, public health, and portable-manifest checks. The targeted update request `5eb93493-e6ac-4d1b-aafc-4d681ab5fa73` completed, and a fresh healthy heartbeat confirmed `1.0.313+317` with both server and SQL connectivity.

The read-only owned-window capture request `f2dee5f9-750e-441d-bf5f-25b426fa0d66` and diagnostic request `d3116b6a-c565-4958-a4c1-c98dbcfaba20` were initially delayed across multiple healthy heartbeats. After the user restarted the client, both completed: the capture reported one separate process-owned window and diagnostics reported zero failed tables and zero active jobs. The prior fixed Sales probe had passed the exact `Amn32.exe`, `Afx:00400000:0`, 1382x744 window and popup guards, then closed it with Escape, and changed no database record.

The command-delivery blocker is cleared for this experiment. No automated Al-Ameen input, restore, or synchronization was performed; the only database mutation now in scope is the one Sales record the user subsequently created manually.

## Current controlled change

- Device/database: `alshallan2` on `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`.
- Before-state: verified backup `artifacts/alshallan2-pre-input-backup-20260903/YWxzaGFsbGFuMg-AmnDb048.bak`, SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`; isolated restore passed `DBCC CHECKDB`, contains 562 tables / 78,398 allocated rows, and records Change Tracking version `5754`.
- User-reported action: on 2026-09-03, the user manually created and saved exactly **one Sales record** in Al-Ameen after the before-state backup was sealed.
- Follow-up observation: Al-Ameen displayed its standard Print dialog after the save; the user was instructed to cancel printing and not add, edit, delete, or save another record.
- Verification status: invoice number, affected tables, primary keys, business keys, row values, and accounting/inventory side effects are **not yet verified**. They will be recorded only from the before/after database comparison.
- Sync status: disabled; this experiment has not been uploaded to another client.
- Low-bandwidth path: client `1.0.314+318` is being built to export only the version-bounded Change Tracking delta after `5754`; the redundant 140 MB transfer will be superseded only after release verification.
- Pre-release safety review caught and fixed upper-bound ordering before any live delta request: the client now captures the upper Change Tracking version before discovery, bounds every row query to it, and publishes no manifest if the ending version differs.
- Final local gates pass: 237 Flutter tests, Flutter static analysis, 551 repository contract/incident tests, and the disposable three-client SQL Server Docker suite including offline recovery, explicit deletes, collisions, retries, Unicode, fuzz, and scale. Production publication and the small live read-only delta remain.
- First immutable backend build stopped safely before push/deployment because TRU rejected two mixed-type optional-value ternaries (INC-399). The mode is now explicitly converted to `string` and the baseline uses an explicitly typed nullable variable; focused regression and the immutable compile gate are being rerun.
