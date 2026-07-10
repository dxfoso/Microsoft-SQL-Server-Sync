Current Status

- Live clients `c1` and `c2` were verified online, SQL-connected, server-connected, and minimized.
- Local verifier coverage is green:
  - `tests/test_live_verifier_scripts.py`: `126 passed`
  - `tests/test_control_plane_contracts.py` + `tests/test_sync_contracts.py`: `77 passed`
  - integrated full wrapper Python contracts: `221 passed`
- Integrated wrapper verification is green:
  - `python contracts`: passed
  - `flutter agent tests`: passed
  - `live system`: passed
  - `live state recovery`: passed
- Live recovery is now proven through the wrapper path:
  - server saved-state reset succeeded
  - both running clients rebuilt state from heartbeats
  - post-recovery live verification passed
  - `verify_full_system.py --include-recovery` finished with `full_system_ok steps=4 passed=4 failed=0`

Latest Changes

- Added `scripts/verify_live_window_action.py`
- Added `scripts/verify_live_state_recovery.py`
- Updated `scripts/verify_live_system.py` to actively verify minimize window actions
- Updated `scripts/verify_full_system.py` to support `--include-recovery`

Doing Now

- Continuing only gap-finding and additional edge-case verification.

Remaining

- Find any additional high-value sync edge cases worth proving beyond the current wrapper and recovery coverage.
