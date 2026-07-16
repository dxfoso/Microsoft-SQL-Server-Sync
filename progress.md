# Production Readiness Progress

- Scheduler starvation was found and fixed with oldest-due-first selection.
- Expanded 3-client Docker SQL matrix passes 15 scenarios and 1,208 identical rows.
- Local verification passes: 104 client tests, 8 frontend tests, 237 Python tests, and TRU release compilation.
- Detailed findings, fixes, evidence, and limitations are in `docs/sync-production-readiness.md`.
- Server release `3ff8fad06c7a36e86672300946b31c424b06954f` is deployed and stable with zero restarts and compile errors.
- Remaining external check: live two-client proof waits for both offline clients, c1 and c2, to heartbeat again.
