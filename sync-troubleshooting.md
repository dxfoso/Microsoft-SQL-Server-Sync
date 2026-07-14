# Sync Troubleshooting Reference

## Multi-Writer Job Display

### Symptom

The clients page appeared to show two jobs for one sync: an upload and a
download. This was confusing because the user expected one sync operation.

### Cause

The server stores two records for one multi-writer batch so it can track both
phases independently:

1. Every online client uploads its Change Tracking delta.
2. The server waits until all expected uploads arrive.
3. The server merges the deltas.
4. Each client downloads the merged delta.

The upload and download records are not intended to run simultaneously for the
same table. A download with status `waiting` is a barrier record, not an
actively running download. The old summary counted raw job records, so queued
or waiting records made one sync look like multiple active jobs.

### Fix

- The clients list now groups records into one sync operation per batch.
- The client detail view shows the current phase: `Upload`, `Waiting`,
  `Download`, `Completed`, or `Failed`.
- Active-job counts are based on grouped sync batches, not raw direction rows.
- Periodic and manual sync both use the same multi-writer batch flow.
- The scheduler queues up to four tables per cycle and continues automatically.
- The production scheduler CronJob explicitly sets `suspend: false`.

Relevant commits:

- `dedae4f`: periodic sync uses multi-writer batches.
- `ebf9cdb`: keeps the periodic scheduler enabled.
- `f2177f5`: groups sync batches and displays client phases.

## Failure Diagnosis

### Transport Versus Target-Database Failure

An upload/download job can be created and reach the target client while the
target SQL merge still fails. A `Failed` status must therefore be read with
the full error message; it does not automatically mean the clients were
offline.

Observed production examples:

- `cp000`: duplicate key in the target unique index. This is a data conflict
  that requires conflict resolution or deduplication; retrying alone does not
  make the duplicate valid.
- `en000`: the target application rejected changes to a posted entry.
- `ms000`: the target application rejected a change because product balance
  would become negative.
- `multi-writer batch expired`: the batch waited longer than the server batch
  lifetime before the client processed it. The scheduler must create a fresh
  batch after the backlog is drained.

These are target database/application validation failures, not upload protocol
failures. They must remain visible in the job error and client log.

## Verification Checklist

### Local

Run from the repository root:

```powershell
python -m pytest deployment/chart/tests/test_chart_contracts.py tests/test_control_plane_contracts.py
Push-Location frontend
flutter test
flutter analyze
Pop-Location
```

The frontend verification completed with `9/9` tests passing and no analyzer
issues. The chart/control-plane contract verification completed with `46/46`
tests passing.

### Live

Use the live verification helper after login:

```powershell
python scripts/verify_live_sync_state.py
```

For a direct manual batch check, call `jobs_create_all_enabled`. A valid
multi-writer result must contain, for each selected table and online client:

- one `upload` job with a shared `batchId`;
- one `download` job with the same `batchId`, initially `waiting`;
- no error in the upload barrier;
- completed downloads after all uploads finish.

The live Sync All check created a shared multi-writer batch for both C1 and C2
with upload and download records. The live scheduler check created four table
batches, or 16 direction/client records, with no legacy one-way job records.

Production health after deployment:

- `ready=true`
- `compile_errors=0`
- live commit `f2177f5`
- CronJob `sql-sync-auto-tick` has `SUSPEND=False`

## Future Investigation Order

1. Check the batch ID and whether all expected client uploads completed.
2. Check whether the download is `waiting`, `applying`, `completed`, or
   `failed`.
3. Read the complete SQL/application error before retrying.
4. For duplicate keys, compare primary and unique-key values on both clients.
5. For business-rule errors, correct the source data or application state;
   repeated sync attempts will produce the same rejection.
6. For expired batches, confirm the scheduler is enabled and create a fresh
   batch after active backlog jobs finish.
