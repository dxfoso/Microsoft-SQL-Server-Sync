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

## Windows Client Rule

- After any shipped `sync_windows_agent/` client change, update `sync_windows_agent/pubspec.yaml` `version:` and publish a new Windows client update before considering the change deployed.
- After any shipped `sync_windows_agent/` change, automatically run the client contract/build checks, publish the update, start the generated portable client for startup verification, and confirm the live client manifest points to the new version; do not wait for a separate client-update request.
- When a `sync_windows_agent/` change is completed, automatically apply the fix, publish the new client, update/restart eligible live clients as required, and verify their update status without asking for separate approval. If the live artifact upload or client update target is unavailable, stop before claiming deployment and report the exact missing prerequisite.
- Build and publish client updates with `scripts/publish_windows_client_update.ps1`; this must produce `latest.json`, `update.ps1`, a versioned ZIP, and `sync_windows_agent_latest.zip` under the live `/client/` update endpoint.
- Do not leave live clients depending on an old portable ZIP after client sync logic changes. The app must be able to read `/client/latest.json` and show whether an update is available.
- Before publishing a Windows client update, run the sync contract tests that guard the live control-plane URL and stale AOT cleanup. The packaged client must be built with `BACKEND_BASE_URL=https://sync.velvet-leaf.com/call`; never ship a client that logs or calls `http://127.0.0.1:6006/call` or `http://127.0.0.1:6006/client/latest.json`.
- Windows release builds must clear `sync_windows_agent/.dart_tool/flutter_build` before packaging. Do not recover/package a release from a stale `app.so` produced by an older local-dev build.
- After publishing a Windows client update, start the generated portable client once and check `sync_windows_agent_startup.log`. It must show `Checking shell client update manifest: https://sync.velvet-leaf.com/client/latest.json` and must not show `127.0.0.1:6006`.
- If `sync_windows_agent.exe` closes immediately, first check Windows Event Log for an `Application Error` or `Windows Error Reporting` entry for `sync_windows_agent.exe`.
- Treat exception code `0xc0000005` with `Faulting module name: unknown` during startup as a native Windows runner crash, not a Dart/Flutter screen error.
- Make sure the client is rebuilt from a commit that includes guarded Windows theme API handling in `sync_windows_agent/windows/runner/win32_window.cpp` (`DwmSetWindowAttribute` must be loaded dynamically and called only when available).
- Do not validate a downloaded portable build after this crash without rebuilding or replacing it from the latest source; older portable builds can still contain the unguarded startup crash.

## Backend Rule

- Run the backend from the `backend/` submodule against the root `business/tru.json` config.
- Keep TRU runtime files, build logic, and server internals inside the `backend/` submodule.
- Keep app API logic, DB API logic, and project-owned `.tru` files only under the root `business/` directory.

## Deployment Rule

- After any shipped `frontend/` web change, automatically run the relevant frontend and contract tests, commit and push the change, and trigger one Cloud redeploy using the `latest-redeploy` link from `deployment/chart/.env`; do not wait for a separate redeploy request.
- After any shipped `backend/` or root `business/` server change, automatically run the relevant server/control-plane contract checks, commit and push the change, and trigger one Cloud redeploy using the `latest-redeploy` link from `deployment/chart/.env`; do not wait for a separate redeploy request.
- When a change includes both server and Windows client work, complete both actions before reporting success: Cloud redeploy for the server and client update publication/verification for the Windows app.
- Monitor the deployment only through the `latest-debug` link from `deployment/chart/.env` so polling never starts duplicate deployments.
- After starting a redeploy, wait at least 2 minutes before the first rollout assessment, then poll `latest-debug` every 15 seconds until the Cloud runner reaches a terminal state or the monitoring window expires. After the runner reports success, verify `/admin/health` reports the pushed commit, `ready: true`, and zero compile errors; report the deployment as pending or failed when any check is not satisfied.
- After every deploy, wait a few minutes and perform a post-deployment verification: confirm the pushed commit is live, `/admin/health` is ready with zero compile errors, the web endpoint loads, and connected clients remain online and healthy. Never report deployment success until these checks pass.
- A frontend change is not considered deployed until public `/admin/health` reports the new commit with `ready: true` and zero compile errors, and the live `main.dart.js` contains the changed feature markers. If rollout is still pending, report it explicitly instead of claiming success.
- Always use the deployment environment located at `[deployment/chart/.env](deployment/chart/.env)` (absolute path: `D:\Microsoft-SQL-Server-Sync\deployment\chart\.env`) for deployment-related steps.
- If deployment behavior regresses, refresh deployment inputs from `deployment/chart/.env` before retrying redeploy.
- Node target must be supplied by Cloud deployment metadata for each deployment/redeploy; do not hardcode a fixed node name in repo files or scripts.
- Before changing or diagnosing any deployment-related item, always use the canonical Cloud direct-instructions URL: `https://cloud.divclouds.com/call/deployments/direct-instructions?authToken=f722c074-2acb-4bb8-8a5f-ef1ff78e0aba&controlPlaneBaseUrl=https%3A%2F%2Fcloud.divclouds.com`. Do not use any other deployment-instruction URL.
- Any nonzero compile errors in project-owned TRU files under `business/` must be treated as a failed deployment, even if pods start and other health checks pass.
- Keep the public backend `/admin/health` endpoint readable without admin credentials. Cloud deployment compile gating depends on a public JSON response that includes `ready`, `compile_errors`, and build commit data.
- Keep dashboard and control-plane polling endpoints bounded. If `/admin/health` reports memory pressure or a TRU endpoint hits the WASM epoch deadline, fix the query/payload bounds first; raising pod memory or `TRU_MEMORY_CAP_MB` alone is not the long-term deployment fix.
- Keep `business/tru.json` aligned with that contract. `settings.admin.requireKey`, `admin.requireKey`, and `adminRequireKey` must stay `false` for deployed environments unless the public health gate is intentionally redesigned in Cloud in the same coordinated change.
- Keep `deployment/chart/values.yaml` free of dead admin-auth settings. If the chart no longer consumes an `admin` block, remove it from default values in the same change so redeploy records do not preserve misleading rendered values.

--------- Cloud repo instruction ------------
Direct deployment instructions:
https://cloud.divclouds.com/call/deployments/direct-instructions?authToken=0cedfba0-7e39-4ca1-b5aa-71ebe15957b8&controlPlaneBaseUrl=https%3A%2F%2Fcloud.divclouds.com

Repository-owned deployment instructions

The repository owns deployment. Use the repository deployment workflow under .action-server/workflows/ and its task scripts.
Do not use the Cloud deployment UI, latest-redeploy, old deployment runbooks, or generic deployment guide pages.

Repository: Microsoft-SQL-Server-Sync
Repository URL: git@github.com:dxfoso/Microsoft-SQL-Server-Sync.git
Namespace: velvet-sql-server-sync
Server: velvet-leaf-1
Commit: 7972da4f04a9024338b1814feb407b0f25e40113
Server ID: 5d40f9d2-c3d5-4bc3-88d8-1de2d9f7a002
Server address: 75.119.136.143
DNS sync: disabled
Public app URL: https://sync.velvet-leaf.com
Admin health URL: https://sync.velvet-leaf.com/admin/health

Verification URLs:
- Debug log: https://cloud.divclouds.com/call/repositories/ebbd5457-3253-46e0-b67d-5668ca1e5225/deployments/latest-debug?authToken=0cedfba0-7e39-4ca1-b5aa-71ebe15957b8&namespaceName=velvet-sql-server-sync
- Namespace resources: https://cloud.divclouds.com/call/servers/5d40f9d2-c3d5-4bc3-88d8-1de2d9f7a002/kubectl/namespaces/velvet-sql-server-sync/resources?authToken=0cedfba0-7e39-4ca1-b5aa-71ebe15957b8

Execution requirements:
- Trigger deployment from the repository workflow by pushing the release commit or using its supported manual dispatch event.
- Treat the repository workflow result and persisted task-status.json/task-results.json files as the deployment record.
- After triggering a deployment, monitor the active deployment until it reaches a terminal result. Do not treat the trigger response alone as a successful deployment.
- Keep polling, investigating, and retrying until the newest deployment row reaches success. Do not stop after an intermediate failure or an older successful deployment; stop only for a concrete blocker that requires new user authority or an external change.
- Work only in namespace velvet-sql-server-sync.
- Use the namespace resources link for scoped Kubernetes access; it injects the selected namespace and rejects cross-namespace flags.
- Never use an unrestricted local kubeconfig or copy credentials from this link.
- Keep the release pinned to the selected target node when one is specified.
- Verify the live app reports commit 7972da4f04a9024338b1814feb407b0f25e40113.
- When an admin health endpoint is available, require ready = true and compile_errors = 0 before treating the deploy as successful.
- Check the newest deployment row, workflow, debug log, live commit, readiness, and compile errors about once per minute. Investigate and fix any concrete issue, then retry until the newest deployment row reaches success.
- Confirm to the user that the deployment is complete and successful only after the newest deployment row succeeds and the one-minute public checks agree; report it as not successful if the deployment rolls back or health regresses.

Repository workflow files:
- .action-server/workflows/push.yaml
- .action-server/workflows/nightly.yaml
- .action-server/tasks/ci.sh
- .action-server/tasks/nightly.sh

The push workflow is the supported release trigger. Its persisted CI artifacts are workspace/tests/ci/task-status.json, workspace/tests/ci/task-results.json, workspace/tests/ci/task-step-results.json, and workspace/tests/ci/final-summary.txt.
---------------------------------------------
