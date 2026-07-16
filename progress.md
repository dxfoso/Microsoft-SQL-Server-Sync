# Production Readiness Progress

- Scheduler starvation was found and fixed with oldest-due-first selection.
- Expanded 3-client Docker SQL matrix passes 15 scenarios and 1,208 identical rows.
- Local verification passes: 104 client tests, 8 frontend tests, 237 Python tests, and TRU release compilation.
- Detailed findings, fixes, evidence, and limitations are in `docs/sync-production-readiness.md`.
- Server release `37592f2d49fa8875f835d61072df914df121b5e1` is deployed and stable with zero restarts and compile errors.
- Both c1 and c2 are online, current on `1.0.153+157`, SQL-connected, server-connected, and minimized.
- Live c2-to-c1 delta proof completed on 2026-07-16: c2 uploaded the `pt000` delta and c1 applied one changed row.
- A manual Sync All deferred-wave delay and an incomplete verifier active-status set were found and fixed; deployment verification is pending.
