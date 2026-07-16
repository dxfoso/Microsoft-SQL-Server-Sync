# Production Readiness Progress

- Scheduler starvation was found and fixed with oldest-due-first selection.
- Expanded 3-client Docker SQL matrix passes 15 scenarios and 1,208 identical rows.
- Local verification passes: 104 client tests, 8 frontend tests, 237 Python tests, and TRU release compilation.
- Detailed findings, fixes, evidence, and limitations are in `docs/sync-production-readiness.md`.
- Server release `0fa9752d3f803664908cd8184db833292123f5eb` is deployed and healthy with zero new restarts and compile errors.
- Both c1 and c2 are online, current on `1.0.153+157`, SQL-connected, server-connected, and minimized.
- Live c2-to-c1 delta proof completed on 2026-07-16: c2 uploaded the `pt000` delta and c1 applied one changed row.
- Live post-deploy Sync All processed all 11 enabled tables in three bounded waves: 44/44 jobs completed, zero failed, and no residual deltas.
- Final clean Sync All passed: 44/44 jobs completed for 11 tables, exactly four jobs per table, bounded waves `4/4/3`, zero failures, no repeated table, and no residual changed rows.
- Post-sync stale active-phase table labels are normalized to `Completed`; the live verifier now passes with 22/22 enabled client-table states completed and no active or unresolved failed jobs.
- Live deletion diagnosis found c1 tombstones were uploaded but quarantined on c2 because its SQL Server rejects `THROW`; deployed client `1.0.155+159` replaces it with compatible `RAISERROR` and prevents quarantined rows from advancing the checkpoint.
- The three-client Docker suite passed explicit delete, missing-delete idempotency, offline catch-up, large batches, conflicts, Unicode, and rejected-row recovery. Live Sync All then completed all 22 enabled client-table states with zero active or failed jobs, and fresh c2 diagnostics contained no `THROW`, SQL syntax, or quarantine errors.
- The four `cp000` deletions made before this fix cannot be replayed automatically because the old client completed and advanced past that discarded relay batch; a new deletion event or targeted one-time data repair is required for those already-missed rows.
- Full verification local stages passed (250 Python contracts and 104 Flutter tests); its pre-deploy live stage used stale expected commit/version values and was not a valid current-release check.
