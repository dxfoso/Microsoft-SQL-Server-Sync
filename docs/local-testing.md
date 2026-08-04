# Local synchronization test standard

This repository's supported local verification uses `tests/run_local_test_standard.ps1`
and disposable Docker SQL
Server clients. It never connects to the live control plane or to real client
databases.

## One command

From the repository root, run:

```powershell
.\tests\run_local_test_standard.ps1
```

The launcher starts the long-running work in a hidden Windows process so it
does not flash command prompts or interrupt the workstation. It waits for the
result and stores logs and machine-readable artifacts in:

```text
workspace/tests/local-standard/
```

The launcher writes `task-status.json`, `task-results.json`,
`task-step-results.json`, `final-summary.txt`, `launcher.log`, and
`launcher-error.log`. The hidden process ID is recorded temporarily in
`launcher.pid` while a run is active.

## Test profiles

| Profile | What it runs | Typical use |
| --- | --- | --- |
| `Quick` | Unit/Flutter tests, repository contracts, updater paths, standard Docker scenarios | Fast pre-commit check |
| `Standard` | Quick checks plus rollback/chaos, concurrency, fuzzing, 5,000-row scale, and bounded soak | Required local architecture gate |
| `Matrix` | SQL Server 2017, 2019, and 2022 Docker compatibility scenarios | SQL-version-sensitive changes |
| `Soak` | Randomized offline/reconnect synchronization soak | Reliability investigation |
| `All` | Standard plus the SQL-version matrix | Release or protocol changes |

Examples:

```powershell
.\tests\run_local_test_standard.ps1 -Profile Quick
.\tests\run_local_test_standard.ps1 -Profile Standard -SoakSeconds 300
.\tests\run_local_test_standard.ps1 -Profile All -SoakSeconds 300
```

The lower-level runner remains available for CI and advanced troubleshooting:

```powershell
.\tests\run_sync_verification.ps1 -Profile Standard
```

## Coverage

The standard includes Flutter unit/widget tests, Python repository contract
tests, Windows updater path tests, and a three-client SQL Server harness. The
Docker scenarios cover inserts, updates, primary-key changes, explicit
deletes, unique-key conflicts, Unicode and binary values, foreign keys,
offline catch-up, duplicate/reordered delivery, idempotent retries, atomic
rollback, connection loss, SQL Server restart, concurrency, randomized fuzz,
large batches, and a bounded soak.

The test invariants are:

- Every client can upload changes; the server merges them; every client can
  download the merged result.
- A missing snapshot row never implies deletion.
- Only an explicit Change Tracking delete with a complete primary key can
  delete a row.
- Applies and cursor advancement are atomic and retry-safe.
- An offline client does not corrupt or block online peers.
- Duplicate operations are idempotent and cannot resurrect durable deletes.
- Test data is disposable and isolated from production.

Any newly discovered defect must be added to `issue.md` and must receive an
automated regression test registered in the appropriate test runner.

## Cleanup and safety

The Docker harness owns only its disposable SQL Server volume. Do not use
`-External` or restore a production backup unless the database is explicitly
approved, isolated, and read-only. Real client synchronization must remain
paused while local verification runs.
