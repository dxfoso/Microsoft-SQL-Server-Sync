# Test Progress

## Current

- Live server: `92e0e124`, ready, `compile_errors=0`.
- Live client manifest: `1.0.115+119`; ZIP endpoint returns HTTP 200.
- Local client tests: 85 passed; backend contract tests: 23 passed; TRU validation passed.
- `c1`: installed `1.0.112+116`, offline after automatic restart; target `1.0.114+118` queued for next heartbeat.
- `c2`: installed `1.0.112+116`, offline after automatic restart; target `1.0.114+118` queued for next heartbeat.
- Diagnostics remain uploaded; the two client machines are not reachable from this host over ICMP, SMB, or WinRM.
- Root cause found: the client decoded even-length UTF-8 `sqlcmd` output as UTF-16, corrupting Chinese text and causing oversized `agents_heartbeat.database` errors. Fixed with a regression test and redeployed.

## Remaining

- Relaunch `c1` and `c2` on their machines, then verify fresh heartbeats, minimized state, client `1.0.115+119`, and a completed sync.
- Run a controlled network interruption/client-stop test after both clients are online.
