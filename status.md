# Current Status

Updated: 2026-08-07 23:31 Europe/Berlin

**Progress: 90% complete**

- The requested one-time live Sync All finished in 4m 35s. Automatic scheduling is paused; no second live sync will be started during verification.
- 25 runnable tables completed. `Connections` converged on both clients. Three stale-baseline delta batches (`BPOptions000`, `BPOptionsDetails000`, and `BillRel000`) were rejected atomically before upload/apply.
- Both clients are healthy with zero active or failed local tables. The three affected tables now have identical row counts and checksums on both clients, so no partial data or divergence was left behind.
- Long-term fix: non-empty tables cannot treat a newly discovered SQL cursor as a synchronized baseline. Missing/expired cursors now cancel safely and return to the same durable operation for an automatic all-client, insert/update-only union replan.
- INC-050 and focused client/control-plane regressions are implemented and passing. Windows client version is bumped to `1.0.245+249`.
- The hidden Standard safety gate passed in 634 seconds: all repository contracts, 180 Windows tests, 24 three-client Docker scenarios, 11 robustness/fault scenarios, 5,000-row scale, and a 60-second soak passed.
- Commit `1dcbed48f6eb` is pushed. Windows client `1.0.245+249` is published, its live manifest and portable startup were verified, and it uses only `https://sync.velvet-leaf.com` endpoints.
- Current work: production deployment stopped safely before changing the server because the backend image gate found an invalid nullable/string ternary in `jobs_fail`. The failure path is corrected, and validate-only now prints exact file, line, and message details. INC-051 records the incident and regression.
- Remaining: rerun the compiler and required safety tests, build/push exact immutable images locally, deploy through `velvet-leaf-1`, verify public health and client update state. Real-client sync remains stopped.
