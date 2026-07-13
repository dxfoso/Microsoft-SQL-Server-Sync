# Test Progress

## Verified

- Live server: `d642354`, ready, `compile_errors=0`.
- Both `c1` and `c2`: online, server-connected, SQL-connected, minimized, current on `1.0.124+128`.
- Both clients: 11 enabled tables, all `Completed`; active job count is `0`.
- c2-originated E2E sync for `AmnDb028::bi000` succeeded:
  - c2 uploaded `2,092` rows.
  - c1 applied `2,092` changed rows.
  - c1 then reported a `2,092`-row snapshot, proving the local database was updated.
  - c1 and c2 checksums match: `2092:3b2f8631b2f3fe18`.
- Production fix deployed: `jobs_cancel_active` now includes `waiting` relay jobs; 9 stale waiting jobs were cleaned up.
- Windows updater hardening is live in client `1.0.124+128`; update payload verification and restart behavior passed local tests.

## Historical Records

- Failed jobs remain in history from intentionally invalid table-name probes and one cancelled reverse-direction chunk test. They are not active and do not affect the successful E2E result.
