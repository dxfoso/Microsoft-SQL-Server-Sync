# Multi-Writer Sync Progress

Progress: 20%

- Verified current production baseline: server `0c3603b` is ready with zero compile errors; c1/c2 are online on client `1.0.125+129`.
- Confirmed current limitation: sync is pairwise full-snapshot relay; c1/c2 local changes are protected by conflict checks, but there is no server merge journal or batch barrier.
- Confirmed available foundation: clients already capture SQL Change Tracking operations (`I`, `U`, `D`) and can send resumable compressed batches.
- Remaining: add batch IDs and a server change journal, include primary-key metadata, merge all client deltas deterministically, fan out one merged batch, then test offline/reconnect, concurrent edits, conflicts, deletes, retries, and production rollout.
- No multi-writer implementation has been deployed yet.
