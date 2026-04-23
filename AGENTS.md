# AGENTS Rules

## Workflow Rule

- When a `.dart` file is changed in the workspace, restart the Windows Flutter app automatically using `agent.ps1`.
- When any file under `sync_admin_web/` changes, redeploy the website automatically using the current redeploy link from `deployment/chart/.env`.

Use this from the repository root:

```powershell
.\agent.ps1 -SkipGet
```

This ensures the app is relaunched with the updated Dart code.

## Deployment Rule

- When redeploying to the cloud, use the deployment links stored in `deployment/chart/.env`.
- Treat `deployment/chart/.env` as the source of truth for the current redeploy URL, deployment debug URL, and namespace resource URL.
- Do not rely on old redeploy links or tokens copied from chat if `deployment/chart/.env` is available.
- Before triggering any remote redeploy, read `deployment/chart/.env` and use the URLs from that file only.
- If `deployment/chart/.env` is available, deployments must be triggered only through the redeploy link in that file.
- Do not deploy through direct cluster access, `kubectl apply`, `helm upgrade`, SSH deployment commands, or any manual server-side rollout path when the `.env` redeploy link is available.
- Direct cluster access may be used for inspection, debugging, and verification only, not as the deployment mechanism.
- Cloud redeployments must preserve the control-plane state database at `/app/data/state.json`; do not remove the Helm PVC, `/app/data` volume mount, or `STATE_FILE` wiring without replacing them with an equivalent persistent storage mechanism.
