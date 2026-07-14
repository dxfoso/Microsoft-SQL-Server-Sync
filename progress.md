# Multi-Writer Sync Progress
Progress: 90%

- Multi-writer scheduling now uploads online client deltas before releasing the download barrier; both clients can write, and offline clients are excluded.
- Correctness protections are implemented: CAS/retry handling, stale-batch rejection, cursor paging, bounded 25-row client chunks, 4 MB chunk and 128 MB batch limits, and cancellation cleanup for staged relay data.
- Local validation: control-plane contracts `28/28`; Windows client tests `86/86`; exact TRU compile validation `objects=10 functions=205 indexes=40`.
- Production is live on commit `579fae5`, `ready=true`, `compile_errors=0`, with the backend recovered to about `66-148 MB` and no new restart after cleanup deployment.
- Client manifest is `1.0.135+139` from commit `da38a4818ce9`; C1 and C2 were verified online, SQL-connected, diagnostics-uploaded, minimized, and current.
- A live large-delta test exposed a remaining production edge case: retaining the full changed-row set in JSON staging can still grow runtime memory and cause 503/restarts. The current byte limits fail safely, but final sign-off requires a disk/blob-backed chunk relay and a successful large-delta convergence test.
