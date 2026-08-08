# Current Status

Updated: 2026-08-08 01:56 Europe/Berlin

**Progress: 80% complete**

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
- The requested production Sync All ran once from 01:45:58 to 01:53:04 Berlin time (7m 6s). It drained all eligible work with no active jobs or decisions, while automatic scheduling stayed paused.
- INC-052 found two atomically rejected uploads (`BillRel000` and `POSOrder000`) at the 128 MiB backend execution-memory limit. No partial apply or deletion occurred. Packages are now bounded to 100 rows/winner identities instead of 250/500; focused regressions pass.
- INC-053 found that the operation summary incorrectly said `completed` despite those failures. Finalization now records `completed_errors`, and the web shows `Completed with errors` beside the total duration.
- Remaining: the full Standard gate is running against both fixes; then publish client `1.0.246+250`, deploy immutable server images, verify health/client updates, and keep real sync paused. No second live Sync All will be started.
