# Microsoft SQL Server Sync

This repository contains the active SQL Server sync product:

- `frontend`: Flutter web control plane
- `backend`: upstream `tru` runtime submodule
- `business`: project-owned TRU API and sync orchestration logic
- `sync_windows_agent`: Flutter Windows client

## Run Locally

Use the single local launcher from the repo root:

```powershell
.\run.ps1 -SkipGet
```

That starts:

- local Postgres for the TRU backend
- the backend from `backend/` with `business/tru.json`
- the web control plane
- the Windows client

## Repo Layout

```text
frontend/            web control plane
backend/             TRU runtime submodule
business/            project-owned TRU files
sync_windows_agent/  Windows client
deployment/          Helm chart and deployment files
scripts/             build, publish, and deploy scripts
```

## Current System

The live system uses the project-owned TRU control plane plus the Windows client snapshot relay flow.
Old sync-engine compatibility paths and obsolete bootstrap code have been removed from this repo.

## Docker Sync Tests

The single repeatable local test entry point is:

```powershell
.\tests\run_local_test_standard.ps1
```

It runs the standard gate in a hidden background process and retains logs and
machine-readable results under `workspace/tests/local-standard/`. The complete
test matrix and safety rules are documented in `docs/local-testing.md`.

Run the standardized three-client SQL Server scenario suite before publishing a
Windows client:

```powershell
.\tests\docker-sync\run.ps1
```

See `tests/docker-sync/README.md` for covered scenarios and the optional,
copy-only database export workflow.

For the complete atomicity, chaos, concurrency, fuzz, scale, soak, and SQL
Server compatibility gates, run:

```powershell
.\tests\run_sync_verification.ps1 -Profile Standard
```

Use `-Profile All` for the SQL Server 2017/2019/2022 matrix. The same suite is
registered in Action Server as **Sync Verification**, with task status,
results, per-step results, logs, and a stable text summary retained under
`workspace/tests/sync-verification/`.
