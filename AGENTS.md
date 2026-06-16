# AGENTS Rules

## Workflow Rule

- Use `run.ps1` as the single local launcher for `frontend/`, `sync_windows_agent/`, `backend/`, and `business/`.
- When a `.dart` file is changed under `frontend/` or `sync_windows_agent/`, restart the local stack automatically using `run.ps1`.
- If both app trees change, restart both locally through the same launcher.
- Keep the repo layout aligned to the current structure:
  - `frontend/` is the web control plane
  - `backend/` is only the `tru` submodule
  - `business/` is the only root location for app-specific backend `.tru` logic

Use this from the repository root:

```powershell
.\run.ps1 -SkipGet
```

This ensures the affected app is relaunched with the updated Dart code.

## Backend Rule

- Run the backend from the `backend/` submodule against the root `business/tru.json` config.
- Keep TRU runtime files, build logic, and server internals inside the `backend/` submodule.
- Keep app API logic, DB API logic, and project-owned `.tru` files only under the root `business/` directory.

## Deployment Rule

- Always use the deployment environment located at `[deployment/chart/.env](deployment/chart/.env)` (absolute path: `D:\Microsoft-SQL-Server-Sync\deployment\chart\.env`) for deployment-related steps.
- If deployment behavior regresses, refresh deployment inputs from `deployment/chart/.env` before retrying redeploy.
- Node target must be supplied by Cloud deployment metadata for each deployment/redeploy; do not hardcode a fixed node name in repo files or scripts.
- Before changing or diagnosing any deployment-related item, first check the cloud deployment instructions at `https://cloud.divclouds.com/deployment-instructions.txt` to confirm current expected node/DNS/health behavior.
- Any nonzero compile errors in project-owned TRU files under `business/` must be treated as a failed deployment, even if pods start and other health checks pass.
- Keep the public backend `/admin/health` endpoint readable without admin credentials. Cloud deployment compile gating depends on a public JSON response that includes `ready`, `compile_errors`, and build commit data.
- Keep `business/tru.json` aligned with that contract. `settings.admin.requireKey`, `admin.requireKey`, and `adminRequireKey` must stay `false` for deployed environments unless the public health gate is intentionally redesigned in Cloud in the same coordinated change.
- Keep `deployment/chart/values.yaml` free of dead admin-auth settings. If the chart no longer consumes an `admin` block, remove it from default values in the same change so redeploy records do not preserve misleading rendered values.
