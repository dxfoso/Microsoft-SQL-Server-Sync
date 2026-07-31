#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TASK_ID="sync-verification"
TASK_ROOT="$REPO_ROOT/workspace/tests/$TASK_ID"
RUN_ID="${ACTION_SERVER_RUN_ID:-${GITHUB_RUN_ID:-$(date +%s)}}"
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-' | cut -c1-80)"
IMAGE_TAG="mssql-sync-verification:${SAFE_RUN_ID:-local}"
TRIGGER="${ACTION_SERVER_TRIGGER:-${GITHUB_EVENT_NAME:-manual}}"
PROFILE="${SYNC_VERIFICATION_PROFILE:-Standard}"
START_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
START_EPOCH="$(date +%s)"
SQL_PORT="${SQL_SYNC_TEST_PORT:-$((20000 + RANDOM % 20000))}"
COMPOSE_PROJECT_NAME="sql-sync-${SAFE_RUN_ID:-local}"
SQL_PASSWORD="${SQL_SYNC_TEST_PASSWORD:-SqlSync_Test_2026!}"
SOAK_SECONDS="${SYNC_SOAK_SECONDS:-60}"
FUZZ_ROUNDS="${SYNC_FUZZ_ROUNDS:-30}"
SCALE_ROWS="${SYNC_SCALE_ROWS:-5000}"
STEP_RESULTS=()
EXIT_CODE=0

if [[ "$TRIGGER" == schedule* || "$TRIGGER" == *nightly* ]]; then
  PROFILE="${SYNC_VERIFICATION_PROFILE:-All}"
  SOAK_SECONDS="${SYNC_SOAK_SECONDS:-900}"
  SCALE_ROWS="${SYNC_SCALE_ROWS:-25000}"
fi

mkdir -p "$TASK_ROOT"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

step_id() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9_' '_' \
    | sed 's/^_\\+//; s/_\\+$//'
}

record_step() {
  local name="$1" status="$2" duration="$3" log="$4" detail="$5"
  STEP_RESULTS+=("    {\"id\":\"$(step_id "$name")\",\"name\":\"$(json_escape "$name")\",\"status\":\"$status\",\"durationSeconds\":$duration,\"log\":\"$(json_escape "$log")\",\"detail\":\"$(json_escape "$detail")\"}")
}

run_step() {
  local name="$1"
  shift
  local log="$TASK_ROOT/$(step_id "$name").log"
  local started
  started="$(date +%s)"
  if "$@" >"$log" 2>&1; then
    record_step "$name" passed "$(($(date +%s) - started))" "$log" ok
    return 0
  else
    local code=$?
    record_step "$name" failed "$(($(date +%s) - started))" "$log" "exit $code"
    EXIT_CODE=1
    return "$code"
  fi
}

compose() {
  SQL_SYNC_TEST_PASSWORD="$SQL_PASSWORD" \
  SQL_SYNC_TEST_PORT="$SQL_PORT" \
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
  docker compose -f "$REPO_ROOT/tests/docker-sync/compose.yaml" "$@"
}

start_sql() {
  local image="$1"
  compose down -v >/dev/null 2>&1 || true
  SQL_SYNC_TEST_IMAGE="$image" compose up -d
  local container_id
  container_id="$(compose ps -q sql)"
  if [[ -z "$container_id" ]]; then
    echo "SQL Server container was not created." >&2
    return 1
  fi
  printf '%s' "$container_id" >"$TASK_ROOT/sql-container-id.txt"
}

run_in_test_image() {
  local container_id
  container_id="$(cat "$TASK_ROOT/sql-container-id.txt")"
  docker run --rm \
    --network host \
    -e PYTHONUTF8=1 \
    -e SQL_SYNC_TEST_SERVER="localhost,$SQL_PORT" \
    -e SQL_SYNC_TEST_USER=sa \
    -e SQL_SYNC_TEST_PASSWORD="$SQL_PASSWORD" \
    -e SQL_SYNC_TEST_CONTAINER_ID="$container_id" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$IMAGE_TAG" \
    "$@"
}

run_client_and_contract_tests() {
  run_in_test_image bash -lc '
    set -euo pipefail
    cd /workspace/sync_windows_agent
    flutter analyze
    flutter test
    cd /workspace
    for test_file in \
      tests/test_sync_contracts.py \
      tests/test_control_plane_contracts.py \
      tests/test_control_plane_perf_contracts.py \
      tests/test_docker_sync_harness.py \
      tests/test_heartbeat_contracts.py \
      tests/test_live_verifier_scripts.py
    do
      python3 "$test_file"
    done
  '
}

run_sql_suite() {
  local suite="$1"
  run_in_test_image python3 tests/docker-sync/run_scenarios.py \
    --external \
    --suite "$suite" \
    --soak-seconds "$SOAK_SECONDS" \
    --fuzz-rounds "$FUZZ_ROUNDS" \
    --scale-rows "$SCALE_ROWS"
}

cleanup() {
  compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_step "Build sync verification image" \
  docker build -f "$REPO_ROOT/.action-server/Dockerfile.sync-tests" -t "$IMAGE_TAG" "$REPO_ROOT" || true

if (( EXIT_CODE == 0 )); then
  run_step "Start SQL Server 2022" start_sql mcr.microsoft.com/mssql/server:2022-latest || true
fi
if (( EXIT_CODE == 0 )); then
  run_step "Flutter and repository contracts" run_client_and_contract_tests || true
fi
if (( EXIT_CODE == 0 )); then
  run_step "Standard three-client sync" run_sql_suite standard || true
fi
if (( EXIT_CODE == 0 )) && [[ "$PROFILE" == Standard || "$PROFILE" == All ]]; then
  run_step "Atomic chaos concurrency fuzz and scale" run_sql_suite robustness || true
fi
if (( EXIT_CODE == 0 )) && [[ "$PROFILE" == Standard || "$PROFILE" == Soak || "$PROFILE" == All ]]; then
  run_step "Randomized soak" run_sql_suite soak || true
fi

if (( EXIT_CODE == 0 )) && [[ "$PROFILE" == Matrix || "$PROFILE" == All ]]; then
  for matrix_entry in \
    "2017|mcr.microsoft.com/mssql/server:2017-latest" \
    "2019|mcr.microsoft.com/mssql/server:2019-latest" \
    "2022|mcr.microsoft.com/mssql/server:2022-latest"
  do
    version="${matrix_entry%%|*}"
    image="${matrix_entry#*|}"
    run_step "Start SQL Server $version matrix" start_sql "$image" || break
    run_step "SQL Server $version compatibility" run_sql_suite standard || break
  done
fi

END_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DURATION="$(($(date +%s) - START_EPOCH))"
STATUS="$([[ "$EXIT_CODE" -eq 0 ]] && echo passed || echo failed)"
STEP_JSON=""
if (( ${#STEP_RESULTS[@]} > 0 )); then
  STEP_JSON="$(printf '%s\n' "${STEP_RESULTS[@]}" | sed '$!s/$/,/')"
fi
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
REF="$(git -C "$REPO_ROOT" branch --show-current)"

cat >"$TASK_ROOT/task-status.json" <<JSON
{
  "task": "$TASK_ID",
  "status": "$STATUS",
  "trigger": "$(json_escape "$TRIGGER")",
  "profile": "$(json_escape "$PROFILE")",
  "startedAt": "$START_UTC",
  "finishedAt": "$END_UTC",
  "durationSeconds": $DURATION,
  "runId": "$(json_escape "$RUN_ID")",
  "commit": "$COMMIT",
  "ref": "$(json_escape "$REF")"
}
JSON

cat >"$TASK_ROOT/task-results.json" <<JSON
{
  "task": "$TASK_ID",
  "status": "$STATUS",
  "trigger": "$(json_escape "$TRIGGER")",
  "profile": "$(json_escape "$PROFILE")",
  "startedAt": "$START_UTC",
  "finishedAt": "$END_UTC",
  "durationSeconds": $DURATION,
  "runId": "$(json_escape "$RUN_ID")",
  "commit": "$COMMIT",
  "summary": "Sync verification $STATUS.",
  "steps": [
$STEP_JSON
  ]
}
JSON

cat >"$TASK_ROOT/task-step-results.json" <<JSON
{
  "task": "$TASK_ID",
  "trigger": "$(json_escape "$TRIGGER")",
  "profile": "$(json_escape "$PROFILE")",
  "generatedAt": "$END_UTC",
  "durationSeconds": $DURATION,
  "results": [
$STEP_JSON
  ]
}
JSON

{
  echo "Task: $TASK_ID"
  echo "Status: $STATUS"
  echo "Trigger: $TRIGGER"
  echo "Profile: $PROFILE"
  echo "Commit: $COMMIT"
  echo "Ref: $REF"
  echo "Started: $START_UTC"
  echo "Finished: $END_UTC"
  echo "DurationSeconds: $DURATION"
  echo
  for step in "${STEP_RESULTS[@]}"; do
    echo "$step"
  done
} >"$TASK_ROOT/final-summary.txt"

exit "$EXIT_CODE"
