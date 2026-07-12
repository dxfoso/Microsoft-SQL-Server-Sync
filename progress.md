# Test Progress

## Current

- Live server: `92e0e124`, ready, `compile_errors=0`.
- Live client manifest: `1.0.114+118`; ZIP endpoint returns HTTP 200.
- Local client tests: 85 passed; backend contract tests: 23 passed; TRU validation passed.
- `c1`: installed `1.0.112+116`, offline after automatic restart; target `1.0.114+118` queued for next heartbeat.
- `c2`: installed `1.0.112+116`, offline after automatic restart; target `1.0.114+118` queued for next heartbeat.
- Diagnostics remain uploaded; the two client machines are not reachable from this host over ICMP, SMB, or WinRM.

## Remaining

- Relaunch `c1` and `c2` on their machines, then verify fresh heartbeats, minimized state, and a completed sync.
- Run a controlled network interruption/client-stop test after both clients are online.
