Current
- Live backend/frontend were already deployed; remote clients are not heartbeating after updater relaunch, and live `live_state` now marks stale clients offline after five minutes.

Doing now
- Waiting for the real `c1` and `c2` Windows clients to reopen so they can consume the pending `1.0.56+60` update and produce the new updater relaunch diagnostics.

Remaining
- Reopen `c1` and `c2` on their PCs.
- Recheck live client versions/heartbeats after they reopen.
- Re-run live sync diagnostics for both clients.

Summary
- Backend/control-plane sync fixes are in place.
- Update endpoint serves `1.0.56+60`, update-all skips stale clients correctly, and sync-all skips stale clients correctly.
