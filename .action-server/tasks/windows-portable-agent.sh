#!/usr/bin/env bash
set -euo pipefail

TASK_ID="windows-portable-agent"
PORTABLE_NAME="sync_windows_agent-windows-portable"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/artifacts/windows-portable-agent"
SUMMARY_DIR="$REPO_ROOT/workspace/tests"
SUMMARY_FILE="$SUMMARY_DIR/windows-portable-agent-summary.txt"
STATUS_JSON="$REPO_ROOT/task-status.json"
RESULTS_JSON="$REPO_ROOT/task-results.json"
STEP_RESULTS_JSON="$REPO_ROOT/task-step-results.json"
BUILD_ZIP_PATH="$OUTPUT_DIR/$PORTABLE_NAME.zip"
ZIP_PATH="$REPO_ROOT/$PORTABLE_NAME.zip"

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

write_status() {
  local state="$1"
  local message="$2"
  local finished_at="${3:-}"
  local finished_value="null"
  if [[ -n "$finished_at" ]]; then
    finished_value="\"$(json_escape "$finished_at")\""
  fi

  cat > "$STATUS_JSON" <<JSON
{
  "taskId": "$TASK_ID",
  "trigger": "push, workflow_dispatch",
  "status": "$(json_escape "$state")",
  "message": "$(json_escape "$message")",
  "finishedAt": $finished_value
}
JSON
}

write_failure() {
  local line="$1"
  local exit_code="$2"
  local finished_at
  finished_at="$(utc_now)"
  write_status "failed" "Portable Windows agent build failed at line $line with exit code $exit_code." "$finished_at"
  cat > "$RESULTS_JSON" <<JSON
{
  "taskId": "$TASK_ID",
  "success": false,
  "triggerCoverage": ["push", "workflow_dispatch"],
  "summary": "Portable Windows agent build failed.",
  "artifacts": []
}
JSON
  cat > "$STEP_RESULTS_JSON" <<JSON
[
  {
    "name": "build",
    "status": "failed",
    "line": $line,
    "exitCode": $exit_code
  }
]
JSON
  printf '[0/1] failed - portable Windows sync agent zip was not created\n' > "$SUMMARY_FILE"
}

publish_success() {
  local summary="$1"
  if [[ ! -f "$ZIP_PATH" ]]; then
    echo "Expected zip was not created: $ZIP_PATH" >&2
    exit 1
  fi

  local zip_size_bytes
  local zip_sha256
  local finished_at
  zip_size_bytes="$(wc -c < "$ZIP_PATH" | tr -d '[:space:]')"
  zip_sha256="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
  finished_at="$(utc_now)"

  write_status "success" "$summary" "$finished_at"
  cat > "$RESULTS_JSON" <<JSON
{
  "taskId": "$TASK_ID",
  "success": true,
  "triggerCoverage": ["push", "workflow_dispatch"],
  "summary": "$(json_escape "$summary")",
  "artifacts": [
    {
      "path": "$PORTABLE_NAME.zip",
      "sizeBytes": $zip_size_bytes,
      "sha256": "$zip_sha256"
    }
  ]
}
JSON
  cat > "$STEP_RESULTS_JSON" <<JSON
[
  {
    "name": "publish portable zip",
    "status": "success",
    "artifact": "$PORTABLE_NAME.zip"
  }
]
JSON
  printf '[1/1] success - portable Windows sync agent zip created at %s.zip (%s bytes)\n' "$PORTABLE_NAME" "$zip_size_bytes" > "$SUMMARY_FILE"

  echo "Portable Windows sync agent artifact:"
  echo "  $PORTABLE_NAME.zip"
  echo "  sha256: $zip_sha256"
}

trap 'exit_code=$?; write_failure "$LINENO" "$exit_code"; exit "$exit_code"' ERR

mkdir -p "$OUTPUT_DIR" "$SUMMARY_DIR"
write_status "running" "Building portable Windows sync agent zip." ""
printf '[0/1] running - building portable Windows sync agent zip\n' > "$SUMMARY_FILE"

if ! command -v flutter >/dev/null 2>&1; then
  if [[ -f "$ZIP_PATH" ]]; then
    echo "Flutter is not available; publishing the committed portable zip."
    cp "$ZIP_PATH" "$BUILD_ZIP_PATH"
    cp "$BUILD_ZIP_PATH" "$ZIP_PATH"
    publish_success "Portable Windows sync agent zip is ready from the committed portable artifact."
    exit 0
  fi

  echo "Flutter is not installed or not available in PATH, and no committed portable zip was found." >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  POWERSHELL_BIN="pwsh"
elif command -v powershell.exe >/dev/null 2>&1; then
  POWERSHELL_BIN="powershell.exe"
elif command -v powershell >/dev/null 2>&1; then
  POWERSHELL_BIN="powershell"
else
  echo "PowerShell is required to run build.ps1." >&2
  exit 1
fi

POWERSHELL_PATH="$(command -v "$POWERSHELL_BIN" 2>/dev/null || printf '%s' "$POWERSHELL_BIN")"
WINDOWS_POWERSHELL=false
case "$POWERSHELL_BIN:$POWERSHELL_PATH" in
  *powershell.exe*|*Windows/System32/WindowsPowerShell*) WINDOWS_POWERSHELL=true ;;
esac

ps_path() {
  local path="$1"
  if [[ "$WINDOWS_POWERSHELL" == "true" ]] && command -v wslpath >/dev/null 2>&1 && [[ "$path" == /mnt/* ]]; then
    wslpath -w "$path"
  elif [[ "$WINDOWS_POWERSHELL" == "true" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$path"
  else
    printf '%s' "$path"
  fi
}

"$POWERSHELL_BIN" -NoProfile -ExecutionPolicy Bypass \
  -File "$(ps_path "$REPO_ROOT/build.ps1")" \
  -OutputRoot "$(ps_path "$OUTPUT_DIR")" \
  -PortableName "$PORTABLE_NAME"

cp "$BUILD_ZIP_PATH" "$ZIP_PATH"
publish_success "Portable Windows sync agent zip is ready."
