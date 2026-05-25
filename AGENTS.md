# AGENTS Rules

## Workflow Rule

- When a `.dart` file is changed in the workspace, restart the Windows Flutter app automatically using `agent.ps1`.
- Keep the repo layout aligned to the current structure:
  - `frontend/` is the web control plane
  - `backend/` is only the `tru` submodule
  - `business/` is the only root location for app-specific backend `.tru` logic

Use this from the repository root:

```powershell
.\agent.ps1 -SkipGet
```

This ensures the app is relaunched with the updated Dart code.

## Backend Rule

- Run the backend from the `backend/` submodule against the root `business/tru.json` config.
- Keep TRU runtime files, build logic, and server internals inside the `backend/` submodule.
- Keep app API logic, DB API logic, and project-owned `.tru` files only under the root `business/` directory.

## Deployment Rule

- Always use the deployment environment located at `[deployment/chart/.env](deployment/chart/.env)` (absolute path: `D:\Microsoft-SQL-Server-Sync\deployment\chart\.env`) for deployment-related steps.
- If deployment behavior regresses, refresh deployment inputs from `deployment/chart/.env` before retrying redeploy.
