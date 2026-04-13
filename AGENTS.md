# AGENTS Rules

## Workflow Rule

- When a `.dart` file is changed in the workspace, restart the Windows Flutter app automatically using `agent.ps1`.

Use this from the repository root:

```powershell
.\agent.ps1 -SkipGet
```

This ensures the app is relaunched with the updated Dart code.

## Deployment Rule

- When redeploying to the cloud, use the deployment links stored in `deployment/chart/.env`.
- Treat `deployment/chart/.env` as the source of truth for the current redeploy URL, deployment debug URL, and namespace resource URL.
- Do not rely on old redeploy links or tokens copied from chat if `deployment/chart/.env` is available.
