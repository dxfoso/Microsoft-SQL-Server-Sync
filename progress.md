Current
- Live backend is deployed and healthy on commit `e195b26`.
- The current public client manifest has been corrected once, but that publish reused a stale Windows runner and still crashes on startup.
- The published artifact now contains the production backend URL, but the packaged EXE must be rebuilt cleanly with the right Flutter toolchain.

Doing now
- Guard the portable build script against stale runner reuse.
- Publish a clean Windows client update as version `1.0.38+42` using the installed Flutter toolchain.
- Retest the live artifact and client startup behavior after republish.

Remaining
- Verify the new public manifest and downloaded ZIP match the clean build.
- Confirm the published client starts and stays on the production backend.
- Re-run sync checks and inspect live logs/UI behavior for progress and table sync issues.

Summary
- Backend fix is live.
- Client publish remains the blocker for full end-to-end verification until the republished runner starts cleanly.
