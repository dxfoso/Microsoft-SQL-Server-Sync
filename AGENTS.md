# AGENTS Rules

## Workflow Rule

- Use `run.ps1` as the single local launcher for `frontend/`, `sync_windows_agent/`, `backend/`, and `business/`.
- Keep the repo layout aligned to the current structure:
  - `frontend/` is the web control plane
  - `backend/` is only the `tru` submodule
  - `business/` is the only root location for app-specific backend `.tru` logic

Use this from the repository root:

```powershell
.\run.ps1 -SkipGet
```

Use the launcher when a local stack restart is actually needed.

## Issue Documentation and Regression Rule

- Every discovered defect, production incident, failed deployment, unexpected client behavior, or synchronization safety gap must be documented in the root `issue.md` incident matrix before the work is considered complete.
- When any issue is discovered during development, testing, monitoring, deployment, or live verification, do not merely report it: document it in `issue.md`, implement the long-term fix, and add automated regression coverage before considering the task complete. If a safe fix requires missing authority or is outside the authorized scope, document the issue and report the exact blocker instead of ignoring it or applying an unsafe workaround.
- Each `issue.md` entry must record the observed symptom, root cause, required long-term behavior, implemented resolution, and exact automated regression coverage.
- Every issue fix must add or extend an automated unit, contract, integration, or isolated fake-client regression test that fails for the original defect and passes with the fix. A manual check alone is not sufficient.
- Register new regression tests in the appropriate repository test runner, including `tests/run_sync_verification.ps1` when the issue affects the synchronization architecture or its safety invariants, so the defect is checked in future standard runs.
- Keep `tests/test_incident_regressions.py` aligned with the complete `issue.md` incident ID sequence and coverage references. Do not remove an incident or its regression coverage merely because the implementation has changed.
- Never use active production client databases to reproduce an issue. Use unit tests, disposable local Docker clients, or explicitly isolated fake live clients.

## Windows Background Execution Rule

- Never run long tests, builds, deployment scripts, Docker suites, update helpers, or repeated native child processes in a visible Windows console. They must not steal focus or interrupt the person using the PC.
- Start long-running Windows work with `Start-Process -WindowStyle Hidden`, redirect standard output and standard error to repository log files, retain the process ID, and monitor the process and logs from the existing agent session.
- Keep quick read-only commands in the existing hidden agent shell. Open a visible process only when the user explicitly requests an interactive window.
- Start Windows client verification hidden or minimized, collect its startup log, and close only the verification instance after the required checks. Do not disrupt an existing user-run client instance.

## Windows Client Rule

- After any shipped `sync_windows_agent/` client change, update `sync_windows_agent/pubspec.yaml` `version:` and publish a new Windows client update before considering the change deployed.
- After any shipped `sync_windows_agent/` change, automatically run the client contract/build checks, publish the update, start the generated portable client for startup verification, and confirm the live client manifest points to the new version; do not wait for a separate client-update request.
- When a `sync_windows_agent/` change is completed, automatically apply the fix, publish the new client, update/restart eligible live clients as required, and verify their update status without asking for separate approval. If the live artifact upload or client update target is unavailable, stop before claiming deployment and report the exact missing prerequisite.
- Build and publish client updates with `scripts/publish_windows_client_update.ps1`; this must produce `latest.json`, `update.ps1`, a versioned ZIP, and `sync_windows_agent_latest.zip` under the live `/client/` update endpoint.
- Do not leave live clients depending on an old portable ZIP after client sync logic changes. The app must be able to read `/client/latest.json` and show whether an update is available.
- Before publishing a Windows client update, run the sync contract tests that guard the live control-plane URL and stale AOT cleanup. The packaged client must be built with `BACKEND_BASE_URL=https://sync.velvet-leaf.com/call`; never ship a client that logs or calls `http://127.0.0.1:6006/call` or `http://127.0.0.1:6006/client/latest.json`.
- Before publishing sync logic changes, run `.\tests\docker-sync\run.ps1`. This three-client SQL Server container suite must pass inserts, updates, primary-key changes, deletes, conflicts, Arabic/Unicode data, offline catch-up, large batches, idempotent retries, and Change Tracking origin filtering.
- For sync transaction, recovery, concurrency, or transport changes, run `.\tests\run_sync_verification.ps1 -Profile Standard`. This extended gate must preserve atomic rollback under injected SQL faults, connection loss, and SQL restart; idempotency after committed-response loss; convergence under overlapping writers; relational integrity; seeded fuzz invariants; scale; and bounded soak recovery. Use `-Profile All` when changing SQL-version-sensitive syntax or behavior.
- Windows release builds must clear `sync_windows_agent/.dart_tool/flutter_build` before packaging. Do not recover/package a release from a stale `app.so` produced by an older local-dev build.
- After publishing a Windows client update, start the generated portable client once and check `sync_windows_agent_startup.log`. It must show `Checking shell client update manifest: https://sync.velvet-leaf.com/client/latest.json` and must not show `127.0.0.1:6006`.
- If `sync_windows_agent.exe` closes immediately, first check Windows Event Log for an `Application Error` or `Windows Error Reporting` entry for `sync_windows_agent.exe`.
- Treat exception code `0xc0000005` with `Faulting module name: unknown` during startup as a native Windows runner crash, not a Dart/Flutter screen error.
- Make sure the client is rebuilt from a commit that includes guarded Windows theme API handling in `sync_windows_agent/windows/runner/win32_window.cpp` (`DwmSetWindowAttribute` must be loaded dynamically and called only when available).
- Do not validate a downloaded portable build after this crash without rebuilding or replacing it from the latest source; older portable builds can still contain the unguarded startup crash.

## Explicit Delete Sync Rule

- Synchronize a deletion only when SQL Server Change Tracking reports an explicit `D` operation for a complete primary key. A user deletion and an Al-Ameen application deletion have the same meaning and must become a durable, versioned server tombstone.
- Apply an explicit tombstone atomically to the exact primary-key row on the other participating clients. Preserve the `SQLSYNC` Change Tracking context so an agent-applied delete is not uploaded again.
- Never infer deletion from snapshot absence, row-count differences, incomplete uploads, an offline client, authoritative reconciliation, unique-key conflicts, or comparison results. Full snapshots and union/bootstrap jobs may insert or update rows only and must never reduce the target row count.
- For a SQL unique/business-key conflict between different primary keys, use the durable latest-change-wins register. Replace only the older conflicting identity, atomically and with `SQLSYNC` Change Tracking context; never remove an unrelated row. If ordering metadata or the unique-key definition is unavailable, stop atomically instead of guessing.
- Keep tombstones durable and deterministically ordered so retries, connection loss, client restarts, and concurrent updates cannot resurrect an older value or apply a stale delete.
- Every sync logic change must include fake three-client coverage proving explicit deletes converge, missing snapshot rows are preserved, target-only rows survive bootstrap/reconciliation, agent-origin changes are filtered, and interrupted retries remain atomic and idempotent.
- Never exercise synchronization changes against real client databases during verification. Keep real clients and automatic scheduling paused; use local Docker clients and explicitly isolated live fake clients until the user starts real synchronization from the web UI.

## Backend Rule

- Run the backend from the `backend/` submodule against the root `business/tru.json` config.
- Keep TRU runtime files, build logic, and server internals inside the `backend/` submodule.
- Keep app API logic, DB API logic, and project-owned `.tru` files only under the root `business/` directory.

## Deployment Rule

- This repository owns image builds and `deployment/chart`; a source push or CI run alone is not a deployment.
- Deploy directly through the configured SSH alias `velvet-leaf-1` (`dxfoso@75.119.136.143`, identity file `C:\Users\adnan\.ssh\velvet-leaf-1`).
- Do not use Cloud deployment APIs, Cloud deployment tokens, action-server deployment sessions, deployment UI triggers, or old Cloud runbooks.
- Work only in namespace `velvet-sql-server-sync`. Every remote `kubectl` command must include `-n velvet-sql-server-sync`; never use or modify workloads in another namespace.
- Build and push immutable `backend` and `frontend` images locally with Docker from the exact pushed commit. Do not build production images on the SSH target. Push the exact immutable tags to the registry locally, then deploy those references through the SSH target. Never deploy mutable tags such as `latest` or `dev`.
- Update only `deployment/sql-sync-back` and `deployment/sql-sync-front` to the exact immutable image references, then wait for both rollouts to complete.
- Preserve the live frontend client-update files when building a new frontend image. The deployed `/client/latest.json`, differential package, updater, and portable ZIP must remain available.
- Treat Helm lint/template failure, cluster-scoped resources, wrong-node rendering, registry pulls, workload readiness, ingress/DNS/TLS, health, or any nonzero `compile_errors` as deployment failure.
- After success, verify `https://sync.velvet-leaf.com/admin/health` reports the pushed commit with `ready=true` and `compile_errors=0`, verify the public web app, and repeat the checks after a short stability wait.
- Preserve `task-status.json`, `task-results.json`, `task-step-results.json`, and a stable text summary for every repository test/build task, with supported trigger metadata.
- When a change includes Windows client work, complete both the server deployment and Windows client publication/verification before reporting success.
- Keep the public backend `/admin/health` readable without admin credentials and keep `business/tru.json` aligned with that compile gate.

## Cloud Tests

- This repository owns its test source of truth under `.cloud-ci/`: settings, workflow YAML, task scripts, services, timeouts, schedules, and artifacts. Do not put repository-specific test commands in Cloud.
- Cloud only validates those definitions, assigns isolated matching workers, records logs/results, and renders one standard UI. Action Server is not part of the test path.
- Keep tests separate from deployment: test tasks must not run Helm, change DNS/ingress, push release images, mutate deployment state, or use deployment credentials.
- Use only `push`, `pull_request`, `workflow_dispatch`, and `schedule` triggers. Pull requests must run every required job and publish `Cloud Tests / required`; protect `master` from merging unless it succeeds.
- Every task must persist `task-status.json`, `task-results.json`, `task-summary.txt`, and `task-step-results.json` for multi-step work, including trigger metadata and a stable `latestPublicUrl` for shareable artifacts.
