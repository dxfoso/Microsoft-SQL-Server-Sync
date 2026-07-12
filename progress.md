# Test Progress

## Current

- Live server: `b352fb0c`, ready, `compile_errors=0`.
- Live client manifest: `1.0.115+119`; ZIP endpoint returns HTTP 200.
- Both `c1` and `c2` are online, server-connected, SQL-connected, minimized, and current on `1.0.115+119`.
- Fresh diagnostics uploaded successfully from both clients.
- Local client suite: 86 passed; the UTF-8/UTF-16 decoder regression is covered.
- Root cause found: the client decoded even-length UTF-8 `sqlcmd` output as UTF-16, corrupting Chinese text and causing oversized `agents_heartbeat.database` errors. Fixed and redeployed.
- The only live runtime event is the pre-fix `2026-07-12T21:55:57Z` mojibake error; no post-fix runtime event is present.

## Remaining

- Eleven historical download jobs remain queued from the July 12 outage, while both clients report all 11 enabled tables `Completed` and zero failed jobs. They require a separate stale-job cleanup/repair decision; they are not new client errors.
- A controlled network interruption/client-stop recovery test remains to be run when it can be performed without disrupting the currently healthy clients.
