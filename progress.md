# Test Progress

## Current

- Live server: `eca74dd`, ready, `compile_errors=0`.
- Live client manifest: `1.0.124+128`; published ZIP passed integrity validation (`30` entries, no bad entries).
- Updater hardening committed as `cec40df`: waits for process exit and verifies every installed payload file before relaunch.
- Local validation: clean Windows release build succeeded; 142 update/control-plane tests passed.
- Both live clients are heartbeating but remain on `1.0.120+124`; server-requested updates remain pending after 120 seconds.
- Controlled c2-to-c1 test completed the upload relay but reported `0` changed rows; c2 and c1 still have divergent row counts. The download test job was cancelled after the client update timeout.

## Remaining

- Bootstrap c1 and c2 onto `1.0.124+128` and verify the updater acknowledgement/relaunch.
- Repeat c2-originated changed-row sync and verify c1 shows the changed rows with nonzero upload/download counts.
