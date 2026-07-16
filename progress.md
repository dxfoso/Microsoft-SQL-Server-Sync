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
