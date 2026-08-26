#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export CLOUD_CI_TASK_ID=nightly
export SYNC_VERIFICATION_PROFILE=All
exec "$SCRIPT_DIR/sync-verification.sh"
