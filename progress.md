# Test Progress

## Done

- Root Python tests: PASS, `220`.
- Windows client Flutter tests: PASS, `77`.
- Frontend Flutter tests: PASS, `4`.
- Backend helper/guardrail tests: PASS, `126`; `32` expected skips.
- Backend Rust library tests: PASS, `344`.
- Backend Rust integration tests: PASS, including aggregate, CRUD, atomic rollback, restart, malformed requests, memory, readiness, and production-readiness suites.
- Backend bug found and fixed: dynamic `db.aggregate` type inference no longer panics; aggregate tests pass `10/10` after the fix.
- Live suite: PASS, all 7 checks; diagnostics, client updates, scheduler, minimize action, client state, and sync state.
- Live recovery: PASS; server state reset and both clients rebuilt 60 tables.
- Final live state: `c1` and `c2` online, minimized, current, diagnostics uploaded, 22 enabled tables completed, zero active/unresolved failed jobs.

## Not Run

- Real network disconnection during an active live transfer: not run because it intentionally disrupts a client.
- Force-stopping a live client during an active sync: not run for the same reason.
- Large-data performance benchmarks: skipped by the backend harness and require an explicit profiling run.
- Local backend aggregate fix is committed but not deployed; live tests verified the currently deployed commit `6b8b76bcf084c3f4b80088d9749f3fcfc5d1be36`.
