# Deployment Runbook

This repository deploys the web control plane and backend through the Cloud deployment links stored in `deployment/chart/.env`.

The only deployment-instruction source is the Cloud direct-instructions URL below. Do not use any other deployment-instruction URL.

```text
https://cloud.divclouds.com/call/deployments/direct-instructions?authToken=0cedfba0-7e39-4ca1-b5aa-71ebe15957b8&controlPlaneBaseUrl=https%3A%2F%2Fcloud.divclouds.com
```

## Preflight

Run from the repository root in PowerShell:

```powershell
git status --short --branch
git log -1 --oneline

$instructionsUrl = 'https://cloud.divclouds.com/call/deployments/direct-instructions?authToken=0cedfba0-7e39-4ca1-b5aa-71ebe15957b8&controlPlaneBaseUrl=https%3A%2F%2Fcloud.divclouds.com'
$instructions = Invoke-WebRequest -UseBasicParsing -Uri $instructionsUrl -TimeoutSec 60
"status=$($instructions.StatusCode)"

Get-Content deployment\chart\.env -Raw |
    Select-String -Pattern 'Namespace:|latest-debug|resources|direct-instructions'
```

## Prepare The Release

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
```

## Deployment Trigger

No automatic deployment trigger is currently configured in this repository. Pushing `master` runs CI only and must not be reported as a deployment. Before releasing, configure or obtain access to a deployment mechanism that creates a new Cloud deployment row for the selected commit.

## Monitor Safely

Use `latest-debug` for monitoring. This endpoint does not start a deployment.

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
