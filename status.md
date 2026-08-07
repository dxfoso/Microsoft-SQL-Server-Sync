# Current Status

Updated: 2026-08-08 00:08 Europe/Berlin

**Progress: 100% complete**

- The requested one-time live Sync All finished in 4m 35s. Automatic scheduling is paused; no second live sync will be started during verification.
- 25 runnable tables completed. `Connections` converged on both clients. Three stale-baseline delta batches (`BPOptions000`, `BPOptionsDetails000`, and `BillRel000`) were rejected atomically before upload/apply.
- Both clients are healthy with zero active or failed local tables. The three affected tables now have identical row counts and checksums on both clients, so no partial data or divergence was left behind.
- Long-term fix: non-empty tables cannot treat a newly discovered SQL cursor as a synchronized baseline. Missing/expired cursors now cancel safely and return to the same durable operation for an automatic all-client, insert/update-only union replan.
- INC-050 and focused client/control-plane regressions are implemented and passing. Windows client version is bumped to `1.0.245+249`.
- The hidden Standard safety gate passed in 634 seconds: all repository contracts, 180 Windows tests, 24 three-client Docker scenarios, 11 robustness/fault scenarios, 5,000-row scale, and a 60-second soak passed.
- Commit `1dcbed48f6eb` is pushed. Windows client `1.0.245+249` is published, its live manifest and portable startup were verified, and it uses only `https://sync.velvet-leaf.com` endpoints.
- INC-051 is resolved: the invalid nullable/string ternary in `jobs_fail` is removed, and validate-only now prints exact compiler file, line, and message details. Its targeted Rust regression passes.
- The corrected commit passed production TRU validation and the full Standard safety gate in 843 seconds: 24 three-client SQL scenarios, 11 fault/robustness scenarios, 5,000-row scale, and a 60-second soak all passed.
- Immutable backend/frontend commit `49c7e236c52d027047c1ba809250dde2bf9fc507` is deployed. Public health reports `ready=true`, `compile_errors=0`, and the exact commit; both Kubernetes deployments are ready.
- Live verification: `alshallan2` and `velvet factory` have 67 enabled tables in `Completed`, zero active jobs, and zero unresolved failed jobs. All real clients report Windows version `1.0.245+249`.
- Automatic synchronization remains paused as intended. No second real Sync All was started.
- Remaining: none for this change. A future sync begins only when the user starts it from the web UI.
