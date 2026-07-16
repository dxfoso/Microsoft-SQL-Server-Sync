# Direct SSH Deployment

Deploy only through the configured SSH alias:

```sshconfig
Host velvet-leaf-1
  HostName 75.119.136.143
  User dxfoso
  IdentityFile C:\Users\adnan\.ssh\velvet-leaf-1
```

## Target

- Namespace: `velvet-sql-server-sync`
- Backend deployment: `sql-sync-back`
- Frontend deployment: `sql-sync-front`
- Node: `velvet-leaf-1`
- Public URL: `https://sync.velvet-leaf.com`
- Health URL: `https://sync.velvet-leaf.com/admin/health`
- Registry: `registry.cloud.divclouds.com/microsoft-sql-server-sync`

## Release

1. Push the release commit and record its full SHA.
2. Run repository tests and chart validation.
3. Stage the exact commit source on `velvet-leaf-1`.
4. Preserve the live client-update files in the frontend build context.
5. Build and push immutable images using `sudo docker`:

```text
registry.cloud.divclouds.com/microsoft-sql-server-sync/backend:<commit>
registry.cloud.divclouds.com/microsoft-sql-server-sync/frontend:<commit>
```

6. Update only the scoped workloads:

```powershell
ssh velvet-leaf-1 "kubectl set image deployment/sql-sync-back backend=<backend-image> -n velvet-sql-server-sync"
ssh velvet-leaf-1 "kubectl set image deployment/sql-sync-front frontend=<frontend-image> -n velvet-sql-server-sync"
ssh velvet-leaf-1 "kubectl rollout status deployment/sql-sync-back -n velvet-sql-server-sync --timeout=10m"
ssh velvet-leaf-1 "kubectl rollout status deployment/sql-sync-front -n velvet-sql-server-sync --timeout=10m"
```

## Verification

Require all of the following before reporting success:

- Both deployments and pods are ready on `velvet-leaf-1`.
- Both workloads use the exact immutable release commit.
- Registry pulls and rollouts have no errors.
- `/`, `/clients`, and `/clients/c1` return HTTP 200 without 5xx responses.
- `/admin/health` reports the exact release commit, `ready=true`, and `compile_errors=0`.
- `/client/latest.json` and the current update artifacts remain readable.
- Repeat public health, page, workload, and restart-count checks after at least one minute.

Do not use Cloud deployment APIs, Cloud deployment tokens, action-server deployment sessions, deployment UI triggers, or cross-namespace Kubernetes commands.
