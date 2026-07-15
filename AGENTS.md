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

- This repository owns image builds and `deployment/chart`; a source push or CI run alone is not a deployment.
- Use the Cloud repository deployment contract v1 from `https://cloud.divclouds.com/repositories/ebbd5457-3253-46e0-b67d-5668ca1e5225/deployments`. Never commit its scoped token.
- Load the scoped credential only from `CLOUD_DEPLOYMENT_TOKEN` in the process environment, a CI secret, or ignored `.cloud.env`. Do not read credentials from `deploy.md`, `deployment/chart/.env`, committed URLs, or previous chat messages. A `401` requires replacing the external secret with newly created v1 access; existing v1 plaintext cannot be recovered.
- The v1 target is server `velvet-leaf-1` (`75.119.136.143`), namespace `velvet-sql-server-sync`, release `microsoft-sql-server-sync-velvet-sql-server-sync`, chart `deployment/chart`, node `velvet-leaf-1`, domain `sync.velvet-leaf.com`, and TLS secret `sync-velvet-leaf-com-letsencrypt-tls`.
- Load both the v1 environment contract and chart contract before deploying. Cloud owns target variables and named secret references; this repository must consume them through Helm without copying secret values into source.
- Build and push immutable `backend` and `frontend` images for the exact pushed commit. Pass those full image references as `runtimeValuesYaml` to `api_start_deployment_v1`.
- Start exactly one v1 session, then poll `api_get_deployment_session_v1` and the scoped namespace-resources link. Do not use the removed v13 `latest-debug` deployment trigger and do not start duplicate sessions while one is running.
- Treat Helm lint/template failure, cluster-scoped resources, wrong-node rendering, registry pulls, workload readiness, ingress/DNS/TLS, health, or any nonzero `compile_errors` as deployment failure.
- After success, verify `https://sync.velvet-leaf.com/admin/health` reports the pushed commit with `ready=true` and `compile_errors=0`, verify the public web app, and repeat the checks after a short stability wait.
- Preserve `task-status.json`, `task-results.json`, `task-step-results.json`, and a stable text summary for every repository test/build task, with supported trigger metadata.
- When a change includes Windows client work, complete both the server deployment and Windows client publication/verification before reporting success.
- Keep the public backend `/admin/health` readable without admin credentials and keep `business/tru.json` aligned with that compile gate.
