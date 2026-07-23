# Sync Production Readiness

Date: 2026-07-22

## Result

The synthetic multi-client sync path is release-ready for the covered
scenarios. The server scheduler starvation defect found during this audit is
fixed. The SQL integration suite now verifies exact values, not only equality
between clients.

This report does not claim that every possible SQL Server schema or external
failure can be simulated. The remaining limitations are listed explicitly
below.

## Protocol V2 Incompatible Reset

Protocol v2 removes multi-client full-snapshot anti-entropy. A multi-writer
batch accepts Change Tracking deltas only; a full snapshot must be an explicit
one-source bootstrap into an empty or deliberately replaceable target. The
server rejects v1 uploads, non-delta multi-writer payloads, and requests from a
stale sync epoch.

Every server-data reset rotates the durable sync epoch. Windows clients persist
that epoch and clear their Change Tracking cursors when it changes. A nonempty
database without a valid cursor fails closed with a bootstrap-required error;
it is never converted into a full-table multi-writer upload.

The current relay has one outbound cursor per client/table rather than a
durable per-subscriber operation log. Therefore scheduling uses an all-client
barrier: if any registered peer is offline, the table is deferred and no
client cursor advances. This preserves offline catch-up without losing deltas.
Decommissioned clients must be removed or disabled so they do not hold the
barrier indefinitely.

## Authoritative Reconciliation

Protocol v2 has a separate repair operation for historical divergence. It is
not part of ordinary multi-writer sync:

1. Pause automatic sync.
2. Keep the trusted source and every repair target online and SQL-connected.
3. In **Clients**, choose **Reconcile from Source**.
4. Select the authoritative source, target clients, and enabled tables.
5. Confirm the target replacement warning.

The source client reads a complete, primary-key-ordered snapshot and verifies
that its fingerprint did not change during extraction. Each target stages the
complete snapshot, updates/inserts source rows, deletes target-only rows, and
commits that replacement atomically with business triggers restored. The
target then compares its row count and full writable-column fingerprint with
the source snapshot before advancing its local Change Tracking baseline.

This operation is deliberately fail-closed: the control plane rejects it while
automatic sync is running, when any participant is busy/offline, when clients
belong to different owners, or when a requested table is not enabled on every
participant. A retry of the same authoritative snapshot is idempotent.

For a scripted live proof, including an automatic idempotent retry:

```powershell
python .\scripts\verify_live_authoritative_reconcile.py `
  --source c1 --targets c2 `
  --tables AmnDb028::en000 AmnDb028::mt000 AmnDb028::pt000
```

## Verification Evidence

| Layer | Result |
| --- | --- |
| Windows agent tests | 104 passed |
| Frontend tests | 8 passed |
| Repository Python tests | 237 passed |
| Focused sync wrapper | 14 Dart and 90 contract tests passed |
| Docker SQL matrix | 15 scenarios passed across 3 independent databases |
| Docker final state | 1,208 rows identical on all 3 databases |
| TRU release validation | 2 files, 10 objects, 209 functions compiled |
| Frontend analysis | Clean |
| Windows agent analysis | 6 existing warnings, no errors |

Run the main database readiness gate from the repository root:

```powershell
.\tests\docker-sync\run.ps1
```

## Covered Scenarios

- Insert, update, primary-key change, alternate unique-key matching, and delete.
- Empty deltas and idempotent deletion of an already-missing row.
- Multiple clients writing different rows in the same synchronization wave.
- Newest database commit wins when clients change the same identity.
- Exact Arabic, emoji, and CJK preservation, verified from SQL Server UTF-16 bytes.
- Null, binary, decimal, and datetime value preservation.
- Offline client catch-up after multiple online-client changes.
- A 1,200-row delta and idempotent retry.
- Transaction rollback after a rejected value and successful next-transaction recovery.
- Change Tracking origin context, preventing downloaded rows from being uploaded again.
- Transient HTTP/database retries, resumed chunks, malformed payload rejection,
  payload limits, stale batches, and client update contracts through unit tests.

## Findings And Fixes

### Scheduler table starvation

**Finding:** Periodic scheduling traversed enabled tables in fixed order and
returned when the per-wave table limit was reached. If the interval elapsed
before a wave completed, early tables could repeatedly be selected while later
tables never ran.

**Fix:** `due_periodic_sync_tables_for_agent_with_policies` now ranks due tables
by time since their last successful sync. Tables with no valid last-sync value
receive the highest priority. Bounded waves therefore drain the oldest work
first instead of configuration order.

**Regression protection:** The control-plane contract requires age-based
candidate selection and prevents the old early return inside the configured
table loop.

### Unicode verification ambiguity

**Finding:** The Docker suite compared database snapshots to each other, so the
same encoding corruption on every client could still pass.

**Fix:** SQL command input/output now explicitly uses UTF-8 code page 65001.
The suite also reads the stored `nvarchar` value as hexadecimal UTF-16 and
compares it with the exact expected Arabic, emoji, and CJK code points.

### UTF-8 SQL test input

**Finding:** Combining `sqlcmd -f 65001` with a UTF-8 BOM caused SQL Server to
parse the BOM as an unexpected character.

**Fix:** Generated SQL files are now BOM-free UTF-8 while `sqlcmd` explicitly
uses code page 65001.

### Manual Sync All deferred-table delay

**Finding:** Manual Sync All bounded the first wave correctly, but deferred
tables were handed back to the periodic scheduler without preserving the manual
request. Recently synced tables then waited for the normal auto-sync interval,
so one manual operation could take roughly ten minutes longer than necessary.

**Fix:** Deferred manual table names are persisted per owner in
`PeriodicSyncState`. After each bounded upload/download wave finishes, the
scheduler prioritizes the next manual tables without applying the periodic
interval. Client work remains sequential and bounded.

**Follow-up:** Live verification showed that a scheduler tick while the current
wave was active could consume the ordinary one-minute owner cooldown. Owners
with persisted manual tables now bypass that cooldown, so every minute tick can
queue the next wave as soon as the previous wave is terminal. Normal periodic
scheduling keeps the cooldown.

**Runtime regression found during verification:** The first implementation used
`bool.from(...)`, which compiled but is not a TRU runtime symbol. The production
tick failed before scheduling. The condition now uses the established nullable
boolean comparison (`bypassCooldown != true`), and contract coverage rejects
the invalid conversion call.

**Final-wave regression found during verification:** When fewer than four
manual tables remained, ordinary periodic candidates could pad the wave and
repeat a table already processed by the same Sync All operation. While manual
pending tables exist, scheduler candidate selection is now limited to that
pending list. Normal periodic selection resumes only after the manual list is
empty.

**Final live evidence (2026-07-16):** A clean Sync All on online c1 and c2
created exactly 44 jobs for 11 enabled tables. Every table had one upload and
one download job per client, the bounded wave sizes were `4/4/3`, all 44 jobs
completed, no table repeated, no job failed, and no residual changed rows
remained.

**Stale terminal display state:** Post-sync verification found table heartbeat
records still labeled `Applying` even though their jobs were completed and
their message said they were waiting for the next sync. Server-side table
normalization now treats stale `snapshotting` and `applying` labels like the
other active phases when no matching active job exists, returning `Completed`
without changing job history.

### SQL Server compatibility blocked explicit deletes

**Finding:** Live c1 deletion tombstones reached c2, but every generated delete
statement was quarantined because the target SQL Server rejected `THROW` with
`Incorrect syntax near 'THROW'`. Sync jobs still completed because row-level
isolation quarantined the failed deletes.

**Fix:** Explicit delta-delete SQL now captures `ERROR_MESSAGE()` and rethrows
with `RAISERROR`, matching the compatibility-safe pattern already used by the
staged merge path. Contract coverage requires `RAISERROR` and rejects `THROW`
in generated delete SQL.

Rejected multi-writer rows are now copied into an atomic per-client outbox
before the download job completes or its Change Tracking checkpoint advances.
Valid rows in the batch complete normally. Missing-dependency and transient
rows retry individually on later table cycles; permanent posted-entry conflicts
remain quarantined until a newer source change for the same primary key
supersedes them. The server job records the rejected count and classification
summary, and the client log shows that quarantine without marking the whole
table failed. Legacy non-multi-writer snapshots retain fail-fast behavior.

### Failed tables retried faster than the configured interval

**Finding:** Periodic eligibility used only the client's last successful table
sync. A target SQL rejection left that timestamp unchanged, so the one-minute
scheduler tick immediately queued the failed table again even when the web
setting was 20 minutes.

**Fix:** The server now persists the latest scheduled/terminal attempt per owner
and table. Periodic work must satisfy the affected client's configured web
interval from that timestamp, including after failure. Manual Sync All remains
an explicit override and continues draining its bounded table waves without an
interval delay.

### Live verifier missed active apply phases

**Finding:** `verify_live_sync_state.py` did not classify `waiting`,
`snapshotting`, or `applying` jobs as active, allowing an incomplete operation
to appear terminal.

**Fix:** The verifier now uses the complete production active-status set and
has regression coverage for all three phases.

### Previously resolved sync defects

- Existing rows are reconciled by primary or alternate unique identity instead
  of being duplicated when a key changes (`aa944f6`).
- Sync-applied writes use `WITH CHANGE_TRACKING_CONTEXT`, preventing echo loops
  and false outbound deltas (`d8a91b4`).
- Multi-client SQL semantics are standardized in an isolated Docker harness
  that executes SQL generated by production Dart code (`8c93582`).

## Remaining Limitations

- Clients `c1` and `c2` were offline during the final live verification.
  Offline catch-up is proven locally, but a live two-client proof requires both
  clients to be running and heartbeating. At verification time, c1's heartbeat
  was about 327 minutes old and c2's was about 52 minutes old; both still
  reported client version `1.0.153+157` and SQL connectivity in their saved
  server state.
- The Docker suite uses synthetic production-shaped data. A copy of `c2`
  `AmnDb028` has not been imported because the client has no remote backup
  channel and database backups may contain sensitive data. On the c2 machine,
  create a verified copy-only backup with:

```powershell
.\scripts\export_sync_test_database.ps1 -Database AmnDb028
```

- Windows GUI startup, tray behavior, and self-update cannot run inside the
  Linux SQL container. They remain covered by Windows unit, build, startup-log,
  manifest, and live-client checks when client code changes.
- The client analyzer has six non-fatal existing warnings: three unnecessary
  null assertions, one unused private declaration, one unnecessary test cast,
  and one unused test local.
- Schema-specific behavior for unsupported SQL types, triggers with external
  side effects, row-level security, encrypted columns, and databases without
  Change Tracking requires a schema-specific acceptance test before enabling
  those tables.

## Production Gate

Before each sync-logic release:

1. Run the Docker sync wrapper and the complete frontend/client test suites.
2. Run TRU release validation and require zero compile errors.
3. Deploy immutable images for the exact commit.
4. Require backend/frontend readiness, public page HTTP 200, and
   `/admin/health` with the exact commit, `ready=true`, and `compile_errors=0`.
5. Repeat health, workload, and restart-count checks after at least one minute.
6. When Windows client code changed, publish the versioned update and verify
   the live manifest, portable startup log, and eligible live-client update.

## Deployment Verification

Server release `3ff8fad06c7a36e86672300946b31c424b06954f` was deployed through
the scoped direct-SSH workflow on 2026-07-16.

- Backend and frontend deployments reached `1/1` ready on `velvet-leaf-1`.
- Both workloads use immutable images tagged with the full release commit.
- New backend and frontend pods had zero restarts after the stability wait.
- `/`, `/clients`, and `/clients/c1` returned HTTP 200.
- `/admin/health` reported the exact commit, `ready=true`,
  `compile_errors=0`, `fail=0`, and `timeout=0`.
- Three live scheduler stress calls completed without transport or function
  errors; observed elapsed time was 65.6-90.9 ms.
- The client update endpoint remained on `1.0.153+157`; its ZIP SHA-256 stayed
  `f8131c7afa9df4d64fe7ed37b31627ea472909d255e01aa9da80bf3d3d44d80e`
  with size `13,603,512` bytes.
- The full live-client gate remained incomplete only because both configured
  clients were offline; no visible online clients were available for a live
  database-to-database synchronization.
