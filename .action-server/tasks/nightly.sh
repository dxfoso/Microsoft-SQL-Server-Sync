#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TASK_ID="nightly"
TASK_ROOT="$REPO_ROOT/workspace/tests/$TASK_ID"
IMAGE_TAG="mssql-sync-backend-ci:nightly"

mkdir -p "$TASK_ROOT"

START_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
START_EPOCH="$(date +%s)"
RUN_ID="${ACTION_SERVER_RUN_ID:-${GITHUB_RUN_ID:-$START_EPOCH}}"
TRIGGER="${ACTION_SERVER_TRIGGER:-${GITHUB_EVENT_NAME:-manual}}"

NETWORK_NAME="mssql-sync-nightly-${TASK_ID}-${RUN_ID}"
PG_CONTAINER="mssql-sync-pg-${TASK_ID}-${RUN_ID}"
DB_NAME="tru_ci"
DB_USER="postgres"
DB_PASSWORD="postgres"
DB_URL="postgresql://$DB_USER:$DB_PASSWORD@$PG_CONTAINER:5432/$DB_NAME"

STEP_RESULTS=()
EXIT_CODE=0

json_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/\\n}"
  raw="${raw//$'\r'/\\r}"
  raw="${raw//$'\t'/\\t}"
  printf "%s" "$raw"
}

step_id_from_name() {
  local name="$1"
  local id
  id="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_' | sed 's/^_\\+//' | sed 's/_\\+$//')"
  if [[ -z "$id" ]]; then
    id="step"
  fi
  printf "%s" "$id"
}

record_step() {
  local name="$1"
  local status="$2"
  local duration="$3"
  local log_file="$4"
  local detail="${5:-}"
  local id
  id="$(step_id_from_name "$name")"
  STEP_RESULTS+=("    {\"id\":\"$id\",\"name\":\"$(json_escape "$name")\",\"status\":\"$status\",\"durationSeconds\":$duration,\"log\":\"$(json_escape "$log_file")\",\"detail\":\"$(json_escape "$detail")\"}")
}

run_step() {
  local name="$1"
  shift
  local -a cmd=("$@")
  local log_file="$TASK_ROOT/$(step_id_from_name "$name").log"
  local start="$(date +%s)"

  if "${cmd[@]}" >"$log_file" 2>&1; then
    local end="$(date +%s)"
    local duration=$((end - start))
    record_step "$name" "passed" "$duration" "$log_file" "ok"
    return 0
  else
    local end="$(date +%s)"
    local duration=$((end - start))
    record_step "$name" "failed" "$duration" "$log_file" "failed"
    return 1
  fi
}

emit_status() {
  local status="$1"
  local end_utc="$2"
  local duration_seconds="$3"
  local detail="$4"
  cat > "$TASK_ROOT/task-status.json" <<JSON
{
  "task": "$TASK_ID",
  "status": "$status",
  "trigger": "$TRIGGER",
  "startedAt": "$START_UTC",
  "finishedAt": "$end_utc",
  "durationSeconds": $duration_seconds,
  "runId": "$RUN_ID",
  "detail": "$(json_escape "$detail")"
}
JSON
}

emit_results() {
  local status="$1"
  local end_utc="$2"
  local duration_seconds="$3"
  local summary="$4"
  local step_json=""
  if (( ${#STEP_RESULTS[@]} > 0 )); then
    step_json="$(printf '%s\n' "${STEP_RESULTS[@]}" | sed '$!s/$/,/')"
  fi
  cat > "$TASK_ROOT/task-results.json" <<JSON
{
  "task": "$TASK_ID",
  "status": "$status",
  "trigger": "$TRIGGER",
  "startedAt": "$START_UTC",
  "finishedAt": "$end_utc",
  "durationSeconds": $duration_seconds,
  "runId": "$RUN_ID",
  "summary": "$(json_escape "$summary")",
  "steps": [
${step_json}
  ]
}
JSON
}

emit_step_results() {
  local end_utc="$1"
  local duration_seconds="$2"
  local step_json=""
  if (( ${#STEP_RESULTS[@]} > 0 )); then
    step_json="$(printf '%s\n' "${STEP_RESULTS[@]}" | sed '$!s/$/,/')"
  fi
  cat > "$TASK_ROOT/task-step-results.json" <<JSON
{
  "task": "$TASK_ID",
  "generatedAt": "$end_utc",
  "durationSeconds": $duration_seconds,
  "results": [
${step_json}
  ]
}
JSON
}

write_text_summary() {
  local status="$1"
  local end_utc="$2"
  local duration_seconds="$3"
  {
    echo "Task: $TASK_ID"
    echo "Status: $status"
    echo "Trigger: $TRIGGER"
    echo "Started: $START_UTC"
    echo "Finished: $end_utc"
    echo "DurationSeconds: $duration_seconds"
    echo "RunId: $RUN_ID"
    echo
    for i in "${STEP_RESULTS[@]}"; do
      local name
      local status_label
      name="$(echo "$i" | sed -n 's/.*\"name\":\"\\([^\"]*\\)\",.*/\\1/p')"
      status_label="$(echo "$i" | sed -n 's/.*\"status\":\"\\([^\"]*\\)\",.*/\\1/p')"
      if [[ -n "$name" && -n "$status_label" ]]; then
        echo " - $name: $status_label"
      fi
    done
  } > "$TASK_ROOT/final-summary.txt"
}

run_backend_tests_in_docker() {
  docker run --rm \
    --name "${PG_CONTAINER}-runner" \
    --network "$NETWORK_NAME" \
    -e TRU_ALLOW_ROOT_TESTS=1 \
    -e TRU_TEST_POSTGRESQL_URL="$DB_URL" \
    -e TRU_POSTGRESQL_URL="$DB_URL" \
    -e TRU_PG_DUMP_PATH="/workspace/backend/scripts/pg_dump_wrapper.sh" \
    -e TRU_PG_RESTORE_PATH="/workspace/backend/scripts/pg_restore_wrapper.sh" \
    -e TRU_TEST_RETRY_COUNT=1 \
    -e TRU_STRESS_MIN_MAX_NO_FAIL=1 \
    -e PATH="/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace/backend \
    "$IMAGE_TAG" \
    bash -c "python3 -m unittest scripts.tests.test_repo_layout scripts.tests.test_prod_ready scripts.tests.test_production_canary_check -v"
}

run_backend_smoke_in_docker() {
  docker run --rm \
    --name "${PG_CONTAINER}-runner-smoke" \
    --network "$NETWORK_NAME" \
    -e TRU_ALLOW_ROOT_TESTS=1 \
    -e TRU_TEST_POSTGRESQL_URL="$DB_URL" \
    -e TRU_POSTGRESQL_URL="$DB_URL" \
    -e PATH="/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace/backend \
    "$IMAGE_TAG" \
    bash -c "python3 -m unittest scripts.tests.test_update_test_perf_summary.UpdateTestPerfSummaryTests.test_badge_markdown_uses_static_v1_query_params scripts.tests.test_update_test_perf_summary.UpdateTestPerfSummaryTests.test_coverage_badge_uses_gate_floor_before_red -v"
}

cleanup() {
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "${PG_CONTAINER}-runner" >/dev/null 2>&1 || true
  docker rm -f "${PG_CONTAINER}-runner-smoke" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! run_step "Create nightly network" docker network create "$NETWORK_NAME"; then
  EXIT_CODE=1
fi

if (( EXIT_CODE == 0 )); then
  if ! run_step "Build or reuse nightly test image" docker build -f "$REPO_ROOT/.action-server/Dockerfile.ci" -t "$IMAGE_TAG" "$REPO_ROOT/.action-server"; then
    EXIT_CODE=1
  fi
fi

if (( EXIT_CODE == 0 )); then
  if ! run_step "Start PostgreSQL service" \
    docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e POSTGRES_DB="$DB_NAME" \
    postgres:16-alpine; then
    EXIT_CODE=1
  fi
fi

if (( EXIT_CODE == 0 )); then
  if ! run_step "Wait for PostgreSQL readiness" bash -lc "
for attempt in \$(seq 1 90); do
  if docker exec \"$PG_CONTAINER\" pg_isready -U \"$DB_USER\" -d \"$DB_NAME\" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done
echo \"postgres did not become ready\" >&2
docker logs \"$PG_CONTAINER\" >&2 || true
exit 1
"; then
    EXIT_CODE=1
  fi
fi

if (( EXIT_CODE == 0 )); then
  if ! run_step "Run nightly stress test pipeline" run_backend_tests_in_docker; then
    EXIT_CODE=1
  fi
fi

if (( EXIT_CODE == 0 )); then
  if ! run_step "Run performance smoke" run_backend_smoke_in_docker; then
    EXIT_CODE=1
  fi
fi

END_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

if (( EXIT_CODE == 0 )); then
  write_text_summary "passed" "$END_UTC" "$DURATION"
  emit_status "passed" "$END_UTC" "$DURATION" "All nightly steps passed."
  emit_results "passed" "$END_UTC" "$DURATION" "Nightly pipeline completed successfully."
else
  write_text_summary "failed" "$END_UTC" "$DURATION"
  emit_status "failed" "$END_UTC" "$DURATION" "Nightly pipeline failed."
  emit_results "failed" "$END_UTC" "$DURATION" "Nightly pipeline failed."
fi
emit_step_results "$END_UTC" "$DURATION"

exit "$EXIT_CODE"
