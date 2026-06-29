Current
- Heartbeat payload fix is implemented and tested locally.
- Client restart updater now stops older `sync_windows_agent.exe` instances before relaunch.
- Latest clean commit is `e5b389f` (`Harden client restart and bound heartbeat payloads`).

Doing now
- Republish the Windows client update as version `1.0.34+38`.
- Push the commit and redeploy the backend.
- Verify live client heartbeats, sync progress, and `pt000` sync behavior.

Remaining
- Upload the clean client package and confirm `/client/latest.json` shows `1.0.34+38`.
- Redeploy live backend with the bounded heartbeat fix.
- Check live logs for heartbeat/runtime errors.
- Run live sync checks for `c1` and `c2` and confirm progress updates move correctly.

Summary
- Local fixes are done and tests passed.
- Live verification and publish/redeploy are still pending.
