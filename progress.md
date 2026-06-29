Current
- Live backend is deployed and healthy on commit `e195b26`.
- The current public client manifest is wrong: it still points clients to a build that falls back to `http://127.0.0.1:6006`.
- A fresh local portable build against `https://sync.velvet-leaf.com/call` logs in successfully, so the remaining break is the published client artifact.

Doing now
- Publish a corrected Windows client update as version `1.0.37+41`.
- Replace the live `/client/latest.json` and ZIP on the frontend pod.
- Retest auto-update and confirm the client stays on the production backend after restart.

Remaining
- Verify the new public manifest and downloaded ZIP match the corrected build.
- Confirm at least one live client stays online after auto-update.
- Re-run sync checks and inspect live logs/UI behavior for progress and table sync issues.

Summary
- Backend fix is live.
- Client publish is still the blocker for full end-to-end verification.
