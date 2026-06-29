Current
- Live backend is deployed and healthy on commit `e195b26`.
- The public Windows client update channel is live on `1.0.38+42`, and the downloaded portable build starts, logs in, and talks to production.
- A sequential live end-to-end sync proof now succeeds on the published client for direct jobs against real tables in the local `velvet` database: source upload completed, target download/apply completed, and the server recorded row counts and snapshot bytes.
- The web `live_state` payload still needs the current backend patch deployed so client list table/progress state is fully populated again.

Doing now
- Deploy the `business/control_plane.tru` `live_state` enrichment fix without turning the live-state query into a heavy full-row scan.
- Recheck production client list/progress behavior after redeploy.

Remaining
- Redeploy the backend fix so the web client list receives table and SymmetricDS data again.
- Re-verify production `live_state` / client list progress after redeploy.
- Bring real `c1` and `c2` back online on the current client version and verify their user-facing sync path, not just the codex sequential proof.

Summary
- Client publishing is no longer the blocker.
- The remaining blockers are production web-state visibility and the real `c1` / `c2` client availability.
