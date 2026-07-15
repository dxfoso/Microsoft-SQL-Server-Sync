# Deployment Runbook v1

This repository owns its immutable image builds and `deployment/chart`. Cloud
supplies only the target environment and access scoped to this repository,
server, and namespace.

## Target

- Repository ID: `ebbd5457-3253-46e0-b67d-5668ca1e5225`
- Server ID: `5d40f9d2-c3d5-4bc3-88d8-1de2d9f7a002`
- Namespace: `velvet-sql-server-sync`
- Release: `microsoft-sql-server-sync-velvet-sql-server-sync`
- Chart: `deployment/chart`
- Node: `velvet-leaf-1`
- Domain: `sync.velvet-leaf.com`

## Authorization

Load the one-time-issued v1 credential from `CLOUD_DEPLOYMENT_TOKEN`. Store it
only in a process environment, CI secret, or ignored `.cloud.env`; never put it
in this runbook, `AGENTS.md`, chart values, a URL committed to Git, or task
artifacts.

If the variable is missing or receives `401`, create replacement deployment
access on the Cloud deployment page and replace the external secret. Existing
v1 token plaintext cannot be recovered because Cloud stores only its hash.

```powershell
if ([string]::IsNullOrWhiteSpace($env:CLOUD_DEPLOYMENT_TOKEN)) {
  throw 'CLOUD_DEPLOYMENT_TOKEN is required'
}
```

## Contracts

```powershell
$repositoryId = 'ebbd5457-3253-46e0-b67d-5668ca1e5225'
$serverId = '5d40f9d2-c3d5-4bc3-88d8-1de2d9f7a002'
$namespace = 'velvet-sql-server-sync'
$base = 'https://cloud.divclouds.com'
$token = [uri]::EscapeDataString($env:CLOUD_DEPLOYMENT_TOKEN)

$environment = Invoke-RestMethod -Method Get -Uri (
  "$base/call/repositories/$repositoryId/deployment-v1/environment" +
  "?namespaceName=$namespace&authToken=$token"
)
$chart = Invoke-RestMethod -Method Get -Uri (
  "$base/call/repositories/$repositoryId/deployment-v1/chart-contract" +
  "?namespaceName=$namespace&authToken=$token"
)
```

Build and push immutable backend and frontend images for the exact pushed
commit. Pass their complete references as `runtimeValuesYaml`.

## Start and monitor

```powershell
$commit = (git rev-parse HEAD).Trim()
$runtimeValuesYaml = @"
backend:
  image: registry.cloud.divclouds.com/microsoft-sql-server-sync/backend:$commit
frontend:
  image: registry.cloud.divclouds.com/microsoft-sql-server-sync/frontend:$commit
"@

$startBody = @{
  name = 'api_start_deployment_v1'
  args = @{
    repositoryId = $repositoryId
    namespaceName = $namespace
    commitHash = $commit
    runtimeValuesYaml = $runtimeValuesYaml
    authToken = $env:CLOUD_DEPLOYMENT_TOKEN
  }
} | ConvertTo-Json -Depth 6
$session = Invoke-RestMethod -Method Post -Uri "$base/call" `
  -ContentType 'application/json' -Body $startBody

do {
  Start-Sleep -Seconds 60
  $pollBody = @{
    name = 'api_get_deployment_session_v1'
    args = @{
      repositoryId = $repositoryId
      namespaceName = $namespace
      sessionId = $session.id
      authToken = $env:CLOUD_DEPLOYMENT_TOKEN
    }
  } | ConvertTo-Json -Depth 5
  $session = Invoke-RestMethod -Method Post -Uri "$base/call" `
    -ContentType 'application/json' -Body $pollBody
} while ($session.status -eq 'running')

if ($session.status -ne 'success') {
  throw "Deployment failed: $($session.errorMessage)"
}
```

Verify the scoped namespace-resources endpoint, exact workload images and node,
`https://sync.velvet-leaf.com/`, and
`https://sync.velvet-leaf.com/admin/health`. Success requires `ready=true`,
`compile_errors=0`, and a matching image commit. Repeat the public checks after
a short stability wait.

Do not use `direct-instructions`, `latest-redeploy`, `latest-debug`, or any
token copied from old repository files.
