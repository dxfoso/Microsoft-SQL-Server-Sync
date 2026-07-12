# Deployment Runbook

This repository deploys the web control plane and backend through the Cloud deployment links stored in `deployment/chart/.env`.

## Preflight

Run from the repository root in PowerShell:

```powershell
git status --short --branch
git log -1 --oneline

try {
    $instructions = Invoke-WebRequest -UseBasicParsing `
        -Uri 'https://cloud.divclouds.com/deployment-instructions.txt' `
        -TimeoutSec 30
    "status=$($instructions.StatusCode)"
} catch {
    "error=$($_.Exception.Message)"
}

Get-Content deployment\chart\.env -Raw |
    Select-String -Pattern 'Namespace:|latest-debug|latest-redeploy'
```

The instructions URL currently returns `404`; deployment still uses the repository-provided links in `deployment/chart/.env`.

## Push The Release

Frontend changes must pass the relevant checks before deployment:

```powershell
Push-Location frontend
dart format lib\<changed-file>.dart
flutter analyze
flutter test
flutter build web --release
Pop-Location

python -m unittest tests.test_sync_contracts.SyncContractsTests.test_web_workspace_has_dashboard_and_client_log_navigation
git diff --check
git add <changed-files>
git commit -m "<release message>"
git push origin master
```

## Start One Redeploy

`latest-redeploy` is an action endpoint. Call it once with `GET`; do not poll it and do not call it with `POST`.

```powershell
$text = Get-Content deployment\chart\.env -Raw
$repositoryId = [regex]::Match(
    $text,
    'repositories/([0-9a-f-]{36})'
).Groups[1].Value
$authToken = [regex]::Match(
    ($text -replace '\s', ''),
    'authToken=([0-9a-f-]{36})'
).Groups[1].Value
$namespace = 'velvet-sql-server-sync'
$redeployUrl = (
    'https://cloud.divclouds.com/call/repositories/{0}/deployments/' +
    'latest-redeploy?authToken={1}&namespaceName={2}'
    -f $repositoryId, $authToken, $namespace
)

$deployment = Invoke-WebRequest -UseBasicParsing `
    -Uri $redeployUrl -Method Get -TimeoutSec 60
$deployment.Content |
    ConvertFrom-Json |
    Select-Object id, status, commitHash, startedAt, errorMessage |
    ConvertTo-Json -Compress
```

## Monitor Safely

Use `latest-debug` for monitoring. This endpoint does not start a deployment.

```powershell
$debugUrl = (
    'https://cloud.divclouds.com/call/repositories/{0}/deployments/' +
    'latest-debug?authToken={1}&namespaceName={2}'
    -f $repositoryId, $authToken, $namespace
)

for ($poll = 1; $poll -le 12; $poll++) {
    $body = (Invoke-WebRequest -UseBasicParsing `
        -Uri $debugUrl -TimeoutSec 60).Content
    $id = if ($body -match 'runner_deployment_id=([^\r\n]+)') {
        $matches[1]
    } else { '' }
    $status = if ($body -match 'runner_status=([^\r\n]+)') {
        $matches[1]
    } else { 'unknown' }
    $stage = if ($body -match 'runner_stage=([^\s\r\n]+)') {
        $matches[1]
    } else { 'unknown' }
    "poll=$poll id=$id status=$status stage=$stage"
    if ($status -in @('success', 'failed', 'error', 'completed')) {
        break
    }
    Start-Sleep -Seconds 15
}
```

Do not start another redeploy while the runner is at `starting`, `helm_upgrade`, or target-node preflight. Cloud may temporarily report old public pods while the new pods are being replaced.

## Verify Live

The release is deployed only when the public health commit matches the pushed commit:

```powershell
$health = Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://sync.velvet-leaf.com/admin/health' -TimeoutSec 60
$healthJson = $health.Content | ConvertFrom-Json
[pscustomobject]@{
    commit = $healthJson.build.git_commit
    ready = $healthJson.ready
    errors = $healthJson.compile_errors
    warnings = $healthJson.compile_warnings
} | ConvertTo-Json -Compress
```

Check compile warnings and runtime logs:

```powershell
$logs = Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://sync.velvet-leaf.com/admin/logs?compileLimit=20&runtimeLimit=5&limit=1' `
    -TimeoutSec 60
$logs.Content | ConvertFrom-Json | Select-Object compile | ConvertTo-Json -Depth 5
```

For a frontend change, verify the deployed bundle contains feature markers:

```powershell
$bundle = (Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://sync.velvet-leaf.com/main.dart.js' -TimeoutSec 60).Content
[pscustomobject]@{
    clients = $bundle.Contains('Clients')
    changedFeature = $bundle.Contains('<feature marker>')
} | ConvertTo-Json -Compress
```

Never report a deployment as complete while `/admin/health` still reports an older commit or while the rollout is still pending.
