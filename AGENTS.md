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
- Monitor the deployment only through the `latest-debug` link from `deployment/chart/.env` so polling never starts duplicate deployments.
- A frontend change is not considered deployed until public `/admin/health` reports the new commit with `ready: true` and zero compile errors, and the live `main.dart.js` contains the changed feature markers. If rollout is still pending, report it explicitly instead of claiming success.
- Always use the deployment environment located at `[deployment/chart/.env](deployment/chart/.env)` (absolute path: `D:\Microsoft-SQL-Server-Sync\deployment\chart\.env`) for deployment-related steps.
- If deployment behavior regresses, refresh deployment inputs from `deployment/chart/.env` before retrying redeploy.
- Node target must be supplied by Cloud deployment metadata for each deployment/redeploy; do not hardcode a fixed node name in repo files or scripts.
- Before changing or diagnosing any deployment-related item, first check the cloud deployment instructions at `https://cloud.divclouds.com/deployment-instructions.txt` to confirm current expected node/DNS/health behavior.
- Any nonzero compile errors in project-owned TRU files under `business/` must be treated as a failed deployment, even if pods start and other health checks pass.
- Keep the public backend `/admin/health` endpoint readable without admin credentials. Cloud deployment compile gating depends on a public JSON response that includes `ready`, `compile_errors`, and build commit data.
- Keep dashboard and control-plane polling endpoints bounded. If `/admin/health` reports memory pressure or a TRU endpoint hits the WASM epoch deadline, fix the query/payload bounds first; raising pod memory or `TRU_MEMORY_CAP_MB` alone is not the long-term deployment fix.
- Keep `business/tru.json` aligned with that contract. `settings.admin.requireKey`, `admin.requireKey`, and `adminRequireKey` must stay `false` for deployed environments unless the public health gate is intentionally redesigned in Cloud in the same coordinated change.
- Keep `deployment/chart/values.yaml` free of dead admin-auth settings. If the chart no longer consumes an `admin` block, remove it from default values in the same change so redeploy records do not preserve misleading rendered values.
