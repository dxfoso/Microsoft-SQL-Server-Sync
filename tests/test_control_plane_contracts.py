import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ControlPlaneContractsTests(unittest.TestCase):
    def test_diagnostics_progress_contract_is_authenticated_and_bounded(self):
        source = read_text("business/control_plane.tru")
        progress = source.split(
            "function agent_diagnostics_progress", 1
        )[1].split("function agent_diagnostics_upload", 1)[0]
        payload = source.split("function agent_diagnostics_payload", 1)[1].split(
            "function client_update_request_pending", 1
        )[0]

        self.assertIn("current_user_record(token)", progress)
        self.assertIn("authenticated_user_matches_client", progress)
        self.assertIn("safeProgress > 99", progress)
        self.assertIn("diagnosticStage", progress)
        self.assertIn("diagnosticProgressPercent", progress)
        self.assertIn("stage: agent.diagnosticStage", payload)
        self.assertIn("progressPercent: agent.diagnosticProgressPercent", payload)

    def test_heartbeat_preserves_full_selected_database_inventory_for_planning(self):
        source = read_text("business/control_plane.tru")
        bounded = source.split(
            "function bounded_heartbeat_tables(", 1
        )[1].split("function json_payload_changed", 1)[0]
        heartbeat = source.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick", 1
        )[0]

        self.assertIn("function agent_table_payload_limit(): int {\n  return 600;", source)
        self.assertIn("return agent_table_payload_limit();", source)
        self.assertIn("database: string = ''", bounded)
        self.assertIn("tableDatabase.toLowerCase() != selectedDatabase.toLowerCase()", bounded)
        self.assertIn("bounded_heartbeat_tables(nextTables, selectedTable, database)", heartbeat)

    def test_heartbeat_rereads_fresh_command_delivery_state_before_response(self):
        source = read_text("business/control_plane.tru")
        heartbeat = source.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick", 1
        )[0]

        self.assertIn(
            "let deliveryAgent = db.selectOne(Agent, { clientName: resolvedClientName });",
            heartbeat,
        )
        self.assertIn("agent_diagnostics_payload(deliveryAgent, false, true)", heartbeat)
        self.assertIn("agent_client_update_payload(deliveryAgent, true)", heartbeat)
        self.assertIn("agent_window_action_payload(deliveryAgent, true)", heartbeat)
        self.assertIn("agent_data_export_payload(deliveryAgent, true)", heartbeat)
        self.assertNotIn("agent_client_update_payload(nextAgent)", heartbeat)
        self.assertIn(
            "function agent_client_update_payload(agent: map<json>, authenticatedClientPoll: bool = false)",
            source,
        )
        self.assertIn(
            "const waitingForClient = !authenticatedClientPoll && pending_request_awaits_online_client(agent, pending);",
            source,
        )

    def test_eligible_table_auto_enrollment_reactivates_disabled_policies(self):
        source = read_text("business/control_plane.tru")
        body = source.split(
            "function table_sync_policy_auto_enroll(", 1
        )[1].split("function table_dependency_policy_set(", 1)[0]

        self.assertIn("tables: array<string>", body)
        self.assertIn("let inspectedTableCount = 0;", body)
        self.assertIn("for (const table of tables)", body)
        self.assertIn("if (inspectedTableCount >= 600)", body)
        self.assertIn(
            "inspectedTableCount = inspectedTableCount + 1;",
            body,
        )
        self.assertNotIn(".take(", body)
        self.assertIn("list_table_sync_policies_for_scope(ownerUserId)", body)
        self.assertIn("table_sync_policy_for_table_with_policies(", body)
        self.assertIn("if (policy == null)", body)
        self.assertIn("else if (policy.enabled != true)", body)
        self.assertIn("db.upsertMany(TableSyncPolicy, policyRowsToUpsert", body)
        self.assertIn("db.updateMany(TableSyncPolicy", body)
        self.assertNotIn("find_table_sync_policy(", body)
        self.assertNotIn("upsert_table_sync_policy(", body)
        self.assertIn("createdTables", body)
        self.assertIn("reactivatedTables", body)
        self.assertIn("reactivatedTableCount: reactivatedTables.length", body)

    def test_auto_enrollment_database_work_is_bounded_for_large_inventories(self):
        source = read_text("business/control_plane.tru")
        body = source.split(
            "function table_sync_policy_auto_enroll(", 1
        )[1].split("function table_dependency_policy_set(", 1)[0]

        self.assertEqual(body.count("list_table_sync_policies_for_scope(ownerUserId)"), 2)
        self.assertEqual(body.count("db.upsertMany(TableSyncPolicy"), 1)
        self.assertEqual(body.count("db.updateMany(TableSyncPolicy"), 1)
        self.assertNotIn("db.selectOne(", body)
        self.assertNotIn("db.insert(", body)
        self.assertNotIn("db.update(", body)
        self.assertIn("if (inspectedTableCount >= 600)", body)

    def test_public_jobs_expose_authoritative_changed_row_count(self):
        source = read_text("business/control_plane.tru")
        public_payload = source.split("function public_job_payload(", 1)[1].split(
            "function agent_job_payload(", 1
        )[0]
        agent_payload = source.split("function agent_job_payload(", 1)[1].split(
            "function live_state_agent_limit(", 1
        )[0]

        self.assertIn("changedRowCount: job.rowCount", public_payload)
        self.assertIn("changedRowCount: job.rowCount", agent_payload)

    def test_live_state_uses_bounded_payload_helpers(self):
        source = read_text("business/control_plane.tru")
        live_state_match = re.search(
            r"function live_state\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(live_state_match)
        body = live_state_match.group("body")

        self.assertIn("bounded_public_agent_payloads", body)
        self.assertIn("bounded_public_job_payloads", body)
        self.assertIn("live_state_agent_rows_for(current, agentLimit)", body)
        self.assertIn("live_state_job_rows_for(current, jobLimit)", body)
        self.assertIn("const agentRows = live_state_agent_rows_for(current, agentLimit);", body)
        self.assertNotIn("visible_agent_rows_for(current)", body)
        self.assertNotIn("refresh_owner_baseline_table_issues(", body)
        self.assertNotIn("syncEngine:", body)

    def test_live_state_limits_stay_bounded(self):
        source = read_text("business/control_plane.tru")
        limits = {
            name: int(value)
            for name, value in re.findall(
                r"function live_state_(agent|job)_limit\(\): int \{\s+return (\d+);",
                source,
                flags=re.S,
            )
        }

        self.assertEqual(limits["agent"], 100)
        self.assertLessEqual(limits["job"], 50)

    def test_live_state_exposes_bounded_active_client_activity(self):
        source = read_text("business/control_plane.tru")
        helper = source.split(
            "function live_state_client_activity_rows_for(", 1
        )[1].split("function public_client_activity_payloads(", 1)[0]
        live_state = source.split("function live_state(", 1)[1].split(
            "function agents_heartbeat(", 1
        )[0]

        self.assertIn(
            "status: { in: ['queued', 'waiting', 'running', 'snapshotting', 'uploading', 'downloading', 'applying'] }",
            helper,
        )
        self.assertIn("limit: 250", helper)
        self.assertIn("clientActivities,", live_state)
        self.assertIn("live_state_client_activity_rows_for(current)", live_state)

    def test_agent_rows_include_dashboard_fields_without_diagnostic_payload(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function live_state_agent_rows_for\(.*?\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("limit: limit + 1", body)
        self.assertIn("'tables'", body)
        self.assertIn("clientUpdateStatus", body)
        self.assertIn("windowActionStatus", body)
        self.assertNotIn("diagnosticPayload", body)

    def test_public_agent_payload_does_not_refetch_agent_rows(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function public_agent_payload\(agent: map<json>, activeJobs: array<json>\? = null, completedJobs: array<json>\? = null, periodicStates: array<json>\? = null, completedRowTotals: array<json>\? = null\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertNotIn("db.selectOne(Agent", body)
        self.assertIn("list_table_sync_policies_for_scope(agent.ownerUserId)", body)
        self.assertIn("apply_table_sync_policies_with_policies(", body)
        self.assertNotIn("apply_table_sync_policies(agent.ownerUserId", body)
        self.assertIn("agent_client_update_payload(agent)", body)
        self.assertIn("agent_window_action_payload(agent)", body)

    def test_live_state_distinguishes_scheduler_check_from_completed_data_sync(self):
        source = read_text("business/control_plane.tru")
        frontend = read_text("frontend/lib/clients_page.dart")
        models = read_text("frontend/lib/models.dart")
        live_state = source.split(
            "function live_state(token: string? = null): map<json> {", 1
        )[1].split("function agents_heartbeat", 1)[0]
        periodic_rows = source.split(
            "function live_state_manual_sync_rows_for_owner_ids(", 1
        )[1].split("function public_client_activity_payloads", 1)[0]

        self.assertIn("'lastCheckedAt'", periodic_rows)
        self.assertIn("const periodicSyncRows = live_state_manual_sync_rows_for_owner_ids", live_state)
        self.assertEqual(live_state.count("live_state_manual_sync_rows_for_owner_ids"), 1)
        self.assertIn("lastChangeCheckAt: periodic_sync_last_checked_at_for_owner", source)
        self.assertIn("lastChangeCheckAt", models)
        self.assertIn("DataColumn(label: Text('Last change check'))", frontend)
        self.assertIn("DataCell(Text(_formatTimestamp(agent.lastChangeCheckAt)))", frontend)

    def test_command_delivery_uses_recent_heartbeat_not_database_readiness(self):
        source = read_text("business/control_plane.tru")
        self.assertIn("function agent_command_delivery_online(agent: map<json>): bool {", source)
        self.assertIn("return pending && !agent_command_delivery_online(agent);", source)

    def test_job_schema_keeps_only_current_snapshot_fields(self):
        source = read_text("business/control_plane.tru")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("field sourceClientName: string min=0 max=128", source)
        self.assertIn("field subscriberClientName: string min=0 max=128", source)
        self.assertIn("field publisherServer: string min=0 max=256", source)
        self.assertIn("field publisherDatabase: string min=0 max=256", source)
        self.assertIn("field publisherUseWindowsAuth: bool", source)
        self.assertIn("field publisherUser: string min=0 max=256", source)
        self.assertIn("field publisherPassword: string min=0 max=256", source)
        self.assertNotIn("field mergeRole: string min=0 max=32", source)
        self.assertNotIn("field publicationName: string min=0 max=256", source)
        self.assertIn("required this.publisherServer,", client_api)
        self.assertIn("required this.publisherDatabase,", client_api)
        self.assertNotIn("required this.mergeRole,", client_api)
        self.assertNotIn("required this.publicationName,", client_api)
        self.assertNotIn("final String syncMode;", client_api)
        self.assertNotIn("required String direction,", client_api)

    def test_agent_heartbeat_persists_replication_connection_settings(self):
        source = read_text("business/control_plane.tru")
        agent_schema = source.split("class Agent {", 1)[1].split("}", 1)[0]

        self.assertIn("replicationUseWindowsAuth: bool = true", source)
        self.assertIn("replicationUser: string = ''", source)
        self.assertIn("replicationPassword: string = ''", source)
        self.assertIn("field replicationUseWindowsAuth: bool?", agent_schema)
        self.assertIn("field replicationUser: string? min=0 max=256", agent_schema)
        self.assertIn("field replicationPassword: string? min=0 max=256", agent_schema)
        self.assertIn("clientUpdate: agent_client_update_payload(deliveryAgent, true)", source)
        self.assertNotIn("symmetricDsStatus", source)
        self.assertNotIn("agent_symmetricds_status_post", source)

    def test_control_plane_exposes_server_requested_client_updates(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("field clientUpdateRequestId: string? min=0 max=64", source)
        self.assertIn("field clientUpdateStatus: string min=0 max=32", source)
        self.assertIn("function agent_client_update_payload(agent: map<json>, authenticatedClientPoll: bool = false): map<json> {", source)
        self.assertIn("function agent_client_update_request(clientName: string, targetVersion: string? = null, token: string? = null): map<json> {", source)
        self.assertIn("function agent_client_update_request_all(targetVersion: string? = null, token: string? = null): map<json> {", source)
        self.assertIn("function agent_client_update_ack(clientName: string? = null, requestId: string? = null, status: string = 'current', installedVersion: string = '', message: string = '', downloadedBytes: int? = null, totalBytes: int? = null, progressPercent: int? = null, token: string? = null): map<json> {", source)

    def test_control_plane_exposes_server_requested_window_actions(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("field windowActionRequestId: string? min=0 max=64", source)
        self.assertIn("field windowActionName: string? min=0 max=32", source)
        self.assertIn("function agent_window_action_payload(agent: map<json>, authenticatedClientPoll: bool = false): map<json> {", source)
        self.assertIn("function agent_window_action_request_all(action: string = 'minimize', token: string? = null): map<json> {", source)
        self.assertIn("function agent_window_action_ack(clientName: string? = null, requestId: string? = null, action: string = '', status: string = 'completed', message: string = '', token: string? = null): map<json> {", source)

    def test_cancel_active_jobs_includes_waiting_relay_jobs(self):
        source = read_text("business/control_plane.tru")

        self.assertIn(
            "normalized == 'queued' || normalized == 'waiting' || normalized == 'running'",
            source,
        )
        self.assertIn("cleanup_multi_writer_batches_storage(cancelledBatchIds)", source)
        self.assertIn("function jobs_cleanup_multi_writer_batch(", source)

    def test_client_update_payload_and_ack_track_pending_and_last_ack_state(self):
        source = read_text("business/control_plane.tru")

        payload_match = re.search(
            r"function agent_client_update_payload\(agent: map<json>, authenticatedClientPoll: bool = false\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(payload_match)
        payload_body = payload_match.group("body")

        self.assertIn("const pending = client_update_request_pending(agent);", payload_body)
        self.assertIn("const waitingForClient = !authenticatedClientPoll && pending_request_awaits_online_client(agent, pending);", payload_body)
        self.assertIn("pending: pending && !waitingForClient,", payload_body)
        self.assertIn("requestId: agent.clientUpdateRequestId,", payload_body)
        self.assertIn("targetVersion: agent.clientUpdateTargetVersion,", payload_body)
        self.assertIn("lastRequestId: agent.clientUpdateLastRequestId,", payload_body)
        self.assertIn("acknowledgedAt: agent.clientUpdateLastAcknowledgedAt,", payload_body)
        self.assertIn("statusValue = 'client_offline';", payload_body)
        self.assertIn("Waiting for the client to heartbeat before the update request can be delivered.", payload_body)
        self.assertIn("status: statusValue,", payload_body)
        self.assertIn("message: messageValue", payload_body)

        ack_match = re.search(
            r"function agent_client_update_ack\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(ack_match)
        ack_body = ack_match.group("body")

        self.assertIn("if (agent.clientUpdateRequestId != null) {", ack_body)
        self.assertIn(
            "resolvedRequestId = string.from(agent.clientUpdateRequestId).trim();",
            ack_body,
        )
        self.assertNotIn("string.from(requestId)", ack_body)
        self.assertIn("clientUpdateLastRequestId: nextLastRequestId,", ack_body)
        self.assertIn("clientUpdateLastAcknowledgedAt: nextAcknowledgedAt,", ack_body)
        self.assertIn("clientUpdateStatus: nextStatus,", ack_body)
        self.assertIn("clientUpdateMessage: truncate_text(message, 4000),", ack_body)
        self.assertIn("clientVersion: nextClientVersion,", ack_body)

    def test_retryable_client_update_transport_failure_remains_pending(self):
        source = read_text("business/control_plane.tru")
        retry = source.split(
            "function client_update_ack_should_retry(", 1
        )[1].split("function agent_client_update_payload(", 1)[0]
        ack = source.split("function agent_client_update_ack(", 1)[1].split(
            "function agent_window_action_request_all(", 1
        )[0]

        self.assertIn("normalizedStatus == 'retrying'", retry)
        self.assertIn("normalizedStatus == 'downloading'", retry)
        self.assertIn("normalizedStatus == 'installing'", retry)
        self.assertIn(
            "control plane request timed out during checking client update manifest",
            retry,
        )
        self.assertIn("client_update_ack_should_retry(status, message)", ack)
        self.assertIn("nextStatus = 'retrying'", ack)
        self.assertIn("nextLastRequestId = resolvedRequestIdOrNull", ack)
        self.assertNotIn(
            "clientUpdateLastRequestId: resolvedRequestIdOrNull", ack
        )

    def test_client_update_download_phase_is_durable_and_visible(self):
        source = read_text("business/control_plane.tru")
        retry = source.split(
            "function client_update_ack_should_retry(", 1
        )[1].split("function agent_client_update_payload(", 1)[0]
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        handler = agent.split(
            "Future<void> _handleRequestedClientUpdate(", 1
        )[1].split("Future<String> _buildDiagnosticsPayload()", 1)[0]

        self.assertIn("normalizedStatus == 'downloading'", retry)
        self.assertIn("normalizedStatus == 'installing'", retry)
        self.assertIn("status: reportedStatus", handler)
        self.assertIn("'installing' => 'installing'", handler)
        self.assertIn("_ => 'downloading'", handler)
        self.assertIn("'failed' => 'failed'", handler)
        self.assertIn("Verified files and partial downloads will be reused", handler)
        self.assertIn("continuing the durable update", handler)
        self.assertIn("final updateLogTail = _readUpdateLogTail()", agent)
        self.assertIn("'updateLogTail': updateLogTail", agent)
        ack = source.split("function agent_client_update_ack(", 1)[1].split(
            "function agent_window_action_request_all(", 1
        )[0]
        self.assertIn("normalizedNextStatus != 'downloading'", ack)
        self.assertIn("normalizedNextStatus != 'installing'", ack)

    def test_heartbeat_clears_stale_update_failure_after_manual_upgrade(self):
        source = read_text("business/control_plane.tru")
        heartbeat = source.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick", 1
        )[0]

        self.assertIn("nextClientVersion != previousClientVersion", heartbeat)
        self.assertIn("!client_update_request_pending(agent)", heartbeat)
        self.assertIn("previousClientUpdateStatus == 'failed'", heartbeat)
        self.assertIn("previousClientUpdateStatus == 'retrying'", heartbeat)
        self.assertIn("nextClientUpdateStatus = 'current'", heartbeat)
        self.assertIn(
            "nextClientUpdateMessage = 'Installed client version confirmed by heartbeat.'",
            heartbeat,
        )
        self.assertEqual(
            heartbeat.count("clientUpdateStatus: nextClientUpdateStatus"), 2
        )
        self.assertEqual(
            heartbeat.count("clientUpdateMessage: nextClientUpdateMessage"), 2
        )

    def test_heartbeat_retargets_outdated_clients_to_latest_confirmed_release(self):
        source = read_text("business/control_plane.tru")
        latest = source.split(
            "function latest_confirmed_client_release_for_owner(", 1
        )[1].split("function client_update_retarget_cooldown_elapsed", 1)[0]
        retarget = source.split(
            "function retarget_outdated_client_update_on_heartbeat(", 1
        )[1].split("function agent_client_update_payload", 1)[0]
        heartbeat = source.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick", 1
        )[0]

        self.assertIn("clientUpdateStatus: 'current'", latest)
        self.assertIn("orderBy: { field: 'clientUpdateLastAcknowledgedAt', dir: 'desc' }", latest)
        self.assertIn("limit: 1", latest)
        self.assertIn("client_update_request_pending(agent)", retarget)
        self.assertIn("ageMs >= 600000", source)
        self.assertIn("date.diff(latestAcknowledgedAt, agentAcknowledgedAt, 'ms') <= 0", retarget)
        self.assertIn("clientUpdateTargetVersion: null", retarget)
        self.assertIn("clientUpdateStatus: 'requested'", retarget)
        self.assertIn("clientUpdateRequestedByUserId: null", retarget)
        self.assertIn(
            "deliveryAgent = retarget_outdated_client_update_on_heartbeat(deliveryAgent, ownerUserId);",
            heartbeat,
        )

    def test_live_state_prioritizes_active_jobs_before_bounded_history(self):
        source = read_text("business/control_plane.tru")
        live_state = source.split("function live_state(token:", 1)[1].split(
            "function agents_heartbeat", 1
        )[0]
        active_query = source.split(
            "function live_state_active_job_rows_for", 1
        )[1].split("function list_scheduler_agent_owner_rows", 1)[0]

        self.assertIn("const recentJobRows = live_state_job_rows_for", live_state)
        self.assertIn("prioritized_live_state_job_rows(activeJobRows, recentJobRows)", live_state)
        self.assertIn("'direction'", active_query)
        self.assertIn("'createdAt'", active_query)
        self.assertIn("'completedAt'", active_query)

    def test_client_update_progress_is_persisted_and_exposed(self):
        source = read_text("business/control_plane.tru")
        payload = source.split("function agent_client_update_payload(", 1)[1].split(
            "function window_action_request_pending", 1
        )[0]
        acknowledgement = source.split("function agent_client_update_ack(", 1)[1].split(
            "function agent_window_action_request_all", 1
        )[0]

        self.assertIn("field clientUpdateDownloadedBytes: int? min=0", source)
        self.assertIn("downloadedBytes: agent.clientUpdateDownloadedBytes", payload)
        self.assertIn("totalBytes: agent.clientUpdateTotalBytes", payload)
        self.assertIn("progressPercent: agent.clientUpdateProgressPercent", payload)
        self.assertIn("downloadedBytes: int? = null", acknowledgement)
        self.assertIn("clientUpdateDownloadedBytes: nextDownloadedBytes", acknowledgement)
        self.assertIn("clientUpdateProgressPercent: nextProgressPercent", acknowledgement)

    def test_client_update_request_all_persists_requests_for_offline_agents(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function agent_client_update_request_all\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("const visibleAgents = visible_agent_rows_for(current);", body)
        self.assertNotIn("if (!effective_agent_online(agent)) {", body)
        self.assertIn("requestedClientNames = requestedClientNames.concat([clientName]);", body)
        self.assertIn("clientUpdateRequestId: requestId,", body)
        self.assertIn("clientUpdateTargetVersion: targetVersionOrNull,", body)
        self.assertIn("clientUpdateStatus: 'requested',", body)

    def test_diagnostics_request_all_and_batch_target_online_visible_agents(self):
        source = read_text("business/control_plane.tru")

        helper_match = re.search(
            r"function online_visible_agent_client_names\(.*?\): array<string> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(helper_match)
        helper_body = helper_match.group("body")
        self.assertIn("const visibleAgents = visible_agent_rows_for(current);", helper_body)
        self.assertIn("if (!effective_agent_online(agent)) {", helper_body)
        self.assertIn("if (clientName.length == 0 || string_array_contains(requestedClientNames, clientName)) {", helper_body)
        self.assertIn("if (limit > 0 && requestedClientNames.length >= limit) {", helper_body)

        batch_match = re.search(
            r"function agent_diagnostics_request_batch\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(batch_match)
        batch_body = batch_match.group("body")
        self.assertIn("const visibleClientNames = online_visible_agent_client_names(current);", batch_body)
        self.assertIn("if (!string_array_contains(visibleClientNames, clientName)) {", batch_body)
        self.assertIn("diagnosticRequestId: normalizedRequestId,", batch_body)
        self.assertIn("diagnosticStatus: 'requested',", batch_body)

        all_match = re.search(
            r"function agent_diagnostics_request_all\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(all_match)
        all_body = all_match.group("body")
        self.assertIn("let normalizedBatchSize = batchSize;", all_body)
        self.assertIn("if (normalizedBatchSize < 0) {", all_body)
        self.assertIn("if (normalizedBatchSize > 50) {", all_body)
        self.assertIn("const requestedClientNames = online_visible_agent_client_names(current, normalizedBatchSize);", all_body)
        self.assertIn("return agent_diagnostics_request_batch(requestedClientNames, null, token);", all_body)

    def test_auto_sync_tick_uses_lightweight_scheduler_agent_rows(self):
        source = read_text("business/control_plane.tru")
        scheduler_rows_match = re.search(
            r"function list_scheduler_agent_rows\(\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(scheduler_rows_match)
        scheduler_rows_body = scheduler_rows_match.group("body")
        self.assertIn("fields: ['clientName', 'machineName', 'server', 'database', 'replicationUseWindowsAuth', 'replicationUser', 'replicationPassword', 'syncEnabled', 'isOnline', 'autoSyncIntervalMinutes', 'serverConnected', 'sqlConnected', 'lastHeartbeat', 'tables', 'clientUserId', 'ownerUserId'],", scheduler_rows_body)
        self.assertNotIn("diagnosticRequestId", scheduler_rows_body)
        self.assertNotIn("clientUpdateRequestId", scheduler_rows_body)

        auto_tick_match = re.search(
            r"function auto_sync_tick\(token: string\? = null\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(auto_tick_match)
        auto_tick_body = auto_tick_match.group("body")
        self.assertIn("const allAgents = list_scheduler_agent_rows();", auto_tick_body)
        self.assertIn("const automaticSyncPaused = automatic_sync_is_paused();", auto_tick_body)
        self.assertIn("for (const agent of allAgents) {", auto_tick_body)
        self.assertIn(
            "const hasManualPendingTables = manual_sync_pending_tables_for_owner(ownerUserId).length > 0;",
            auto_tick_body,
        )
        self.assertIn(
            "claim_periodic_sync_scheduler_for_owner(ownerUserId, hasManualPendingTables)",
            auto_tick_body,
        )
        self.assertIn(
            "(automaticSyncPaused || automatic_sync_is_paused_for_owner(ownerUserId))",
            auto_tick_body,
        )
        self.assertIn("!hasManualPendingTables", auto_tick_body)
        self.assertIn("const ownerJobs = queue_due_periodic_sync_jobs_for_owner(ownerUserId, allAgents);", auto_tick_body)

        owner_match = re.search(
            r"function queue_due_periodic_sync_jobs_for_owner\(ownerUserId: string\? = null, allAgents: array<json>\? = null\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(owner_match)
        owner_body = owner_match.group("body")
        self.assertIn("const ownerPolicies = list_table_sync_policies_for_scope(ownerUserId);", owner_body)
        self.assertNotIn("list_completed_scheduler_job_rows(ownerUserId)", owner_body)
        self.assertIn("effective_agent_online(agent)", owner_body)
        self.assertIn("sync_table_baseline_plan(", owner_body)
        self.assertIn("!preserveChangeTrackingBaselines", owner_body)
        self.assertIn("create_multi_writer_batch(", owner_body)
        self.assertIn("preserveChangeTrackingBaselines", owner_body)
        self.assertIn("mark_offline_sync_debt(", owner_body)
        self.assertIn("create_authoritative_reconcile_batch(", owner_body)
        self.assertIn("const tableCaches = ownerAgents.map((agent) => scheduler_agent_table_state_cache(agent, ownerPolicies));", owner_body)
        self.assertIn("const sourceAgents = allAgents ?? list_scheduler_agent_rows();", owner_body)
        self.assertIn("for (const agent of ownerAgents) {", owner_body)
        self.assertIn("const activeTableCaches = ownerAgents.map", owner_body)
        self.assertIn("if (cache.tables.length > activeTableCapacityUsed)", owner_body)
        self.assertIn(
            "activeTableCapacityUsed >= periodic_sync_scheduler_table_limit()",
            owner_body,
        )
        self.assertIn("return [];", owner_body)
        self.assertIn("const agentTables = due_periodic_sync_tables_for_agent_with_policies(", owner_body)

        normalize_body = source.split(
            "function normalize_agent_table_payload_state(", 1
        )[1].split("function normalize_agent_tables_payload(", 1)[0]
        self.assertIn("status == 'snapshotting'", normalize_body)
        self.assertIn("status == 'applying'", normalize_body)

    def test_automatic_sync_pause_is_admin_controlled_and_persistent(self):
        source = read_text("business/control_plane.tru")
        self.assertIn("function automatic_sync_is_paused(): bool", source)
        self.assertIn("function automatic_sync_control_set(paused: bool", source)
        control_body = source.split("function automatic_sync_control_set(", 1)[1].split(
            "function ", 1
        )[0]
        self.assertIn("if (!is_admin_user(current) && !is_owner_user(current))", control_body)
        owner_body = control_body.split("if (is_owner_user(current))", 1)[1].split(
            "const controlOwnerUserId", 1
        )[0]
        self.assertIn("if (!paused && automatic_sync_is_paused())", owner_body)
        self.assertIn("Automatic sync remains paused globally by an administrator", owner_body)
        self.assertLess(
            owner_body.index("if (!paused && automatic_sync_is_paused())"),
            owner_body.index("set_owner_automatic_sync_paused(current.id, paused)"),
        )
        self.assertIn("set_owner_automatic_sync_paused(current.id, paused)", control_body)
        self.assertIn("controlOwnerUserId = '__automatic_sync_control__'", control_body)
        self.assertIn("automaticSyncPaused: paused", control_body)
        self.assertIn("if (!paused)", control_body)
        self.assertIn("list_scheduler_agent_owner_rows()", control_body)
        self.assertIn("set_owner_automatic_sync_paused(ownerUserId, false)", control_body)
        self.assertIn("resumedOwnerCount", control_body)
        self.assertIn("automatic_sync_admin_resume_owner_limit()", control_body)
        self.assertIn("function automatic_sync_admin_resume_owner_limit(): int", source)
        self.assertIn("return 100;", source)
        self.assertIn("function automatic_sync_is_paused_for_owner", source)
        self.assertIn(
            "automaticSyncPaused || automatic_sync_is_paused_for_owner(ownerUserId)",
            source,
        )

    def test_agent_heartbeat_preserves_explicit_sync_disabled_setting(self):
        source = read_text("business/control_plane.tru")
        heartbeat_body = source.split("function agents_heartbeat(", 1)[1].split(
            "\nfunction ", 1
        )[0]
        enabled_set_body = source.split(
            "function agent_sync_enabled_set(", 1
        )[1].split("\nfunction ", 1)[0]

        self.assertNotIn("syncEnabled: true", heartbeat_body)
        self.assertIn("syncEnabled: enabled", enabled_set_body)

    def test_paused_automatic_sync_does_not_stop_an_accepted_manual_queue(self):
        source = read_text("business/control_plane.tru")
        auto_tick_body = source.split("function auto_sync_tick(", 1)[1].split(
            "function agent_sync_settings_get(", 1
        )[0]
        set_pending_body = source.split(
            "function set_manual_sync_pending_tables_for_owner(", 1
        )[1].split("function periodic_sync_scheduled_table_attempts_for_owner(", 1)[0]

        self.assertNotIn(
            "if (automatic_sync_is_paused()) {\n    return",
            auto_tick_body,
        )
        self.assertIn(
            "const hasManualPendingTables = manual_sync_pending_tables_for_owner(ownerUserId).length > 0;",
            auto_tick_body,
        )
        self.assertIn(
            "if ((automaticSyncPaused || automatic_sync_is_paused_for_owner(ownerUserId)) &&",
            auto_tick_body,
        )
        self.assertIn("!hasManualPendingTables", auto_tick_body)
        self.assertIn(
            "string.from(marker).trim() == '__automatic_sync_paused__'",
            set_pending_body,
        )
        self.assertIn(
            "pendingTables = pendingTables.concat(['__automatic_sync_paused__']);",
            set_pending_body,
        )

    def test_unavailable_online_catchup_debt_is_released_without_sql_mutation(self):
        source = read_text("business/control_plane.tru")
        owner_scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]
        unavailable = owner_scheduler.split(
            "if (tableAgents.length == 0 || string.from(plan.mode) == 'unavailable')", 1
        )[1].split("continue;", 1)[0]

        self.assertIn("clear_offline_sync_debt_for_clients(", unavailable)
        self.assertIn("ownerAgents.map((agent) => string.from(agent.clientName))", unavailable)
        self.assertNotIn("db.delete", unavailable)
        self.assertNotIn("deleteMany", unavailable)

    def test_table_issues_stop_all_normal_sync_until_user_resolves_them(self):
        source = read_text("business/control_plane.tru")
        self.assertIn("field tableIssues: array<json>?", source)
        self.assertIn("function sync_owner_has_blocking_table_issues(", source)
        self.assertIn("function raise_sync_table_issue(", source)
        self.assertIn("function table_sync_issue_resolve(", source)
        self.assertIn("'retry_sync'", source)
        self.assertNotIn("normalizedAction != 'replace_client'", source)
        self.assertNotIn("normalizedAction != 'keep_client'", source)
        self.assertIn("'exclude_table'", source)
        self.assertIn("'accept_baseline'", source)

        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]
        self.assertIn("refresh_owner_baseline_table_issues(", scheduler)
        self.assertIn("sync_owner_has_blocking_table_issues(", scheduler)
        self.assertIn("return [];", scheduler)

        manual_all = source.split("function jobs_create_all_enabled_for_identity(", 1)[1].split(
            "function reset_all_agent_saved_state(", 1
        )[0]
        manual_prepare = source.split("function begin_manual_sync_all_for_owner(", 1)[1].split(
            "function jobs_create_all_enabled(", 1
        )[0]
        self.assertNotIn("refresh_owner_baseline_table_issues(ownerUserId, visibleAgents)", manual_all)
        self.assertIn("const plan = sync_table_baseline_plan(", scheduler)
        self.assertIn("sync_owner_has_blocking_table_issues(ownerUserId)", manual_prepare)
        self.assertIn(
            "sourceResolutionTableCount: sync_table_issues_for_owner(ownerUserId).length",
            manual_prepare,
        )

        manual_one = source.split("function jobs_create(", 1)[1].split(
            "function jobs_bootstrap(", 1
        )[0]
        self.assertIn("sync_owner_has_blocking_table_issues(ownerId)", manual_one)
        self.assertIn("raw_json_error(409", manual_one)

        complete = source.split("function jobs_complete(", 1)[1].split(
            "function jobs_fail(", 1
        )[0]
        fail = source.split("function jobs_fail(", 1)[1].split(
            "function jobs_cancel_active(", 1
        )[0]
        self.assertIn("raise_sync_table_issue(", complete)
        self.assertNotIn("raise_sync_table_issue(", fail)
        self.assertIn(
            "const failedBatchId = string.from(job.batchId ?? '').trim();",
            complete,
        )
        self.assertIn("Atomic batch failed:", complete)
        self.assertIn("cleanup_multi_writer_batch_storage(failedBatchId);", complete)
        self.assertIn(
            "advances its Change Tracking checkpoint after commit",
            fail,
        )
        self.assertIn("const failedBatchId = string.from(job.batchId ?? '').trim();", fail)
        self.assertIn("Atomic batch failed:", fail)
        self.assertIn("cleanup_multi_writer_batch_storage(failedBatchId);", fail)
        self.assertIn("function clear_retryable_sync_failure_issues(", source)
        self.assertIn("action: 'retry_sync'", source)
        self.assertIn(
            "clear_retryable_sync_failure_issues(ownerUserId);",
            source,
        )

        live_state = source.split("function live_state(", 1)[1].split(
            "function agents_heartbeat(", 1
        )[0]
        self.assertIn("syncGate,", live_state)

    def test_unique_key_conflicts_become_automatic_latest_change_retries(self):
        source = read_text("business/control_plane.tru")
        upload = source.split("function jobs_multi_writer_upload(", 1)[1].split(
            "function jobs_multi_writer_download(", 1
        )[0]
        complete = source.split("function jobs_complete(", 1)[1].split(
            "function jobs_fail(", 1
        )[0]
        clear_retryable = source.split(
            "function clear_retryable_sync_failure_issues(", 1
        )[1].split("function sync_owner_has_blocking_table_issues(", 1)[0]

        self.assertIn("field conflictPolicy: string? min=0 max=32", source)
        self.assertIn("latestModifiedAtUtc: latestModifiedAtUtc.trim()", upload)
        self.assertIn("latestOperationId: latestOperationId.trim()", upload)
        self.assertNotIn("function try_start_latest_change_resolution(", source)
        self.assertNotIn("function latest_change_candidate_for_batch(", source)
        self.assertIn("conflictKind.trim().toLowerCase() == 'unique_business_key'", complete)
        self.assertIn("? 'unique_business_key'", complete)
        self.assertIn("raise_sync_table_issue(", complete)
        self.assertIn("reason != 'unique_business_key'", clear_retryable)
        self.assertIn("latest-change policy", clear_retryable)
        self.assertIn("No user decision", clear_retryable)

    def test_conflict_source_selection_is_exclusive_and_primary_only_on_conflict(self):
        source = read_text("business/control_plane.tru")
        selector = source.split("function agent_conflict_source_set(", 1)[1].split(
            "function agent_sync_settings_post(", 1
        )[0]
        comparator = source.split("function sync_row_candidate_is_later(", 1)[1].split(
            "function sync_row_effective_modified_at(", 1
        )[0]
        upload = source.split("function jobs_multi_writer_upload(", 1)[1].split(
            "function jobs_multi_writer_download(", 1
        )[0]

        self.assertIn("visible_agent_rows_for(current)", selector)
        self.assertIn("db.atomicTransaction(() =>", selector)
        self.assertIn("conflictPolicy: 'latest_change_wins'", selector)
        self.assertIn("conflictPolicy: 'primary_source'", selector)
        self.assertLess(
            selector.index("conflictPolicy: 'latest_change_wins'"),
            selector.index("conflictPolicy: 'primary_source'"),
        )
        self.assertIn("candidateIsConflictSource != currentIsConflictSource", comparator)
        self.assertIn("return candidateIsConflictSource", comparator)
        self.assertLess(
            comparator.index("candidateIsConflictSource != currentIsConflictSource"),
            comparator.index("candidateModifiedAt"),
        )
        self.assertIn("conflict_source_client_for_owner(winnerOwnerUserId)", upload)
        self.assertIn("conflictSourceClient", upload)
        self.assertIn("field conflictSourceClient: string? min=0 max=128", source)
        create_batch = source.split("function create_multi_writer_batch(", 1)[1].split(
            "function table_comparison_job_rows(", 1
        )[0]
        self.assertIn(
            "conflictSourceClient: conflict_source_client_for_owner(ownerUserId)",
            create_batch,
        )

        settings = source.split("function agent_sync_settings_post(", 1)[1].split(
            "function agent_jobs(", 1
        )[0]
        self.assertNotIn("conflictPolicy:", settings)

    def test_automatic_repair_finishes_for_online_participants_without_user_input(self):
        source = read_text("business/control_plane.tru")
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]
        refresh = source.split(
            "function refresh_owner_baseline_table_issues(", 1
        )[1].split("function sync_gate_payload_for_owners(", 1)[0]
        gate = source.split("function sync_gate_payload_for_owners(", 1)[1].split(
            "function automatic_sync_control_set(", 1
        )[0]
        heartbeat = source.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick(", 1
        )[0]
        complete = source.split("function jobs_complete(", 1)[1].split(
            "function jobs_fail(", 1
        )[0]

        self.assertIn("sync_owner_has_needs_input_table_issues", scheduler)
        self.assertIn("refresh_owner_baseline_table_issues", scheduler)
        self.assertIn("resolutionClientNames", refresh)
        self.assertIn(
            "resolutionReportedClientCount == resolutionClientNames.length",
            refresh,
        )
        self.assertIn("Offline clients will catch up automatically", refresh)
        self.assertIn("decisionCount", gate)
        self.assertIn("resolvingCount", gate)
        self.assertIn("No user decision is required", gate)
        self.assertIn("tablesChanged", heartbeat)
        self.assertIn("sync_owner_has_resolving_table_issues(ownerUserId)", heartbeat)
        self.assertIn("refresh_owner_baseline_table_issues(ownerUserId)", heartbeat)
        self.assertIn("'server-authoritative-reconcile'", complete)
        self.assertIn("sync_batch_all_jobs_completed(completedBatchId)", complete)
        self.assertIn(
            "refresh_owner_baseline_table_issues(string.from(job.ownerUserId))",
            complete,
        )

    def test_manual_sync_all_defers_when_owner_has_active_batch_work(self):
        source = read_text("business/control_plane.tru")
        body = source.split("function queue_due_periodic_sync_jobs_for_owner(", 1)[1].split(
            "function periodic_sync_scheduler_agent_limit", 1
        )[0]

        self.assertIn("const activeTableCaches = ownerAgents.map", body)
        self.assertIn("if (activeTableCapacityUsed >= periodic_sync_scheduler_table_limit())", body)
        self.assertEqual(body.count("active_job_tables_for_client("), 1)
        self.assertIn("const manualPendingTables = manual_sync_pending_tables_for_owner(ownerUserId);", body)
        self.assertIn(
            "let remainingManualTables = manualPendingTables.filter", body
        )
        self.assertIn(
            "set_manual_sync_pending_tables_for_owner(ownerUserId, remainingManualTables);",
            body,
        )

    def test_periodic_scheduler_prioritizes_tables_with_detected_local_changes(self):
        source = read_text("business/control_plane.tru")
        helper = source.split(
            "function sync_table_state_has_pending_local_changes(", 1
        )[1].split("function due_periodic_sync_tables_for_agent(", 1)[0]
        selector = source.split(
            "function due_periodic_sync_tables_for_agent_with_policies(", 1
        )[1].split("function queue_due_periodic_sync_jobs_for_owner(", 1)[0]

        self.assertIn("tableState.localChangesPending == true", helper)
        self.assertIn(
            "A local SQL change was detected automatically.", helper
        )
        self.assertIn(
            "localChangesPending: sync_table_state_has_pending_local_changes(tableState)",
            selector,
        )
        self.assertIn(
            "candidateHasPendingLocalChanges && !selectedHasPendingLocalChanges",
            selector,
        )
        self.assertIn(
            "candidate.ageMinutes > selectedAgeMinutes", selector
        )
        normalizer = source.split(
            "function normalize_agent_table_payload_state(", 1
        )[1].split("function normalize_agent_tables_payload(", 1)[0]
        self.assertEqual(
            normalizer.count(
                "localChangesPending: tableState.localChangesPending == true"
            ),
            2,
        )

    def test_periodic_scheduler_skips_unchanged_maintenance_tables(self):
        source = read_text("business/control_plane.tru")
        requirement = source.split(
            "function sync_table_state_requires_automatic_sync(", 1
        )[1].split("function due_periodic_sync_tables_for_agent(", 1)[0]
        selector = source.split(
            "function due_periodic_sync_tables_for_agent_with_policies(", 1
        )[1].split("function order_owner_due_table_candidates(", 1)[0]

        self.assertIn(
            "sync_table_state_has_pending_local_changes(tableState)",
            requirement,
        )
        self.assertIn("'baseline_pending'", requirement)
        self.assertIn(
            "if (!sync_table_state_requires_automatic_sync(tableState))",
            selector,
        )
        self.assertLess(
            selector.index(
                "if (!sync_table_state_requires_automatic_sync(tableState))"
            ),
            selector.index("sync_table_state_due_age_minutes("),
        )

    def test_periodic_scheduler_repairs_complete_fingerprint_divergence(self):
        source = read_text("business/control_plane.tru")
        detector = source.split(
            "function divergent_fingerprint_tables_for_owner(", 1
        )[1].split("function due_periodic_sync_tables_for_agent_with_policies(", 1)[0]
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]
        planner = source.split("function sync_table_baseline_plan(", 1)[1].split(
            "function enabled_sync_policy_tables_for_agent(", 1
        )[0]

        self.assertIn("participantCount >= 2", detector)
        self.assertIn("reportedCount == participantCount", detector)
        self.assertIn("fingerprints.length > 1", detector)
        self.assertIn("sync_table_reported_fingerprint(state)", detector)
        self.assertIn("divergent_fingerprint_tables_for_owner(", scheduler)
        self.assertIn(
            "divergent_fingerprint_tables_for_owner(\n      ownerAgents,\n      tableCaches,\n      0\n    )",
            scheduler,
        )
        self.assertIn("periodic_sync_table_due_after_attempt(", scheduler)
        self.assertIn(
            "if (latest_completed_table_batch_was_union(table, recentUploadModes))",
            scheduler,
        )
        self.assertLess(
            scheduler.index(
                "if (latest_completed_table_batch_was_union(table, recentUploadModes))"
            ),
            scheduler.index("let retryDue = false;"),
        )
        self.assertIn("record_periodic_sync_table_attempt(ownerUserId, table)", scheduler)
        self.assertIn(
            "if (queuedTableCount >= periodic_sync_scheduler_table_limit())",
            scheduler,
        )
        self.assertIn("mode: 'union_bootstrap'", planner)
        self.assertIn(
            "Clients report different complete table fingerprints", planner
        )

    def test_completed_union_suppresses_unchanged_automatic_full_table_loop(self):
        source = read_text("business/control_plane.tru")
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]

        self.assertIn(
            "const recentUploadModes = latest_completed_upload_modes_for_owner(",
            scheduler,
        )
        self.assertIn(
            "if (latest_completed_table_batch_was_union(table, recentUploadModes))",
            scheduler,
        )
        self.assertIn(
            "due_periodic_sync_tables_for_agent_with_policies(", scheduler
        )
        self.assertLess(
            scheduler.index("due_periodic_sync_tables_for_agent_with_policies("),
            scheduler.index(
                "if (latest_completed_table_batch_was_union(table, recentUploadModes))"
            ),
        )

    def test_pending_change_with_valid_cursors_stays_on_delta_path(self):
        source = read_text("business/control_plane.tru")
        planner = source.split("function sync_table_baseline_plan(", 1)[1].split(
            "function enabled_sync_policy_tables_for_agent(", 1
        )[0]

        pending_branch = "readyAgents.length == participants.length && hasPendingLocalChanges"
        fingerprint_branch = "allFingerprints.length > 1"
        self.assertIn("sync_table_state_has_pending_local_changes(state)", planner)
        self.assertIn(pending_branch, planner)
        self.assertLess(planner.index(pending_branch), planner.index(fingerprint_branch))
        self.assertIn("pending local changes will use the delta path", planner)

    def test_client_status_prioritizes_sync_and_names_update_retries(self):
        control_plane = read_text("business/control_plane.tru")
        server_status = control_plane.split(
            "function client_runtime_status_payload(", 1
        )[1].split("function agent_diagnostics_payload(", 1)[0]
        clients_page = read_text("frontend/lib/clients_page.dart")
        web_status = clients_page.split(
            "String _clientActivityStatus(", 1
        )[1].split("Color _clientActivityColor(", 1)[0]

        self.assertIn("updateLabel = 'Update retrying'", server_status)
        self.assertIn("let updateLabel = 'Update pending'", server_status)
        self.assertLess(
            server_status.index("const priorities ="),
            server_status.index("agent_client_update_payload(agent).pending"),
        )
        self.assertIn("'Update retrying'", web_status)
        self.assertIn("'Update pending'", web_status)
        self.assertLess(
            web_status.index("agent.runtimeStatusLabel.trim().isNotEmpty"),
            web_status.index("agent.clientUpdate.pending"),
        )

    def test_periodic_scheduler_globally_orders_candidates_across_clients(self):
        source = read_text("business/control_plane.tru")
        ordering = source.split(
            "function order_owner_due_table_candidates(", 1
        )[1].split("function queue_due_periodic_sync_jobs_for_owner(", 1)[0]
        queue = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit", 1)[0]

        self.assertIn("for (const candidateTable of dueTables)", ordering)
        self.assertIn("for (const agent of ownerAgents)", ordering)
        self.assertIn("if (tableState == null)", ordering)
        self.assertIn(
            "sync_table_state_has_pending_local_changes(tableState)", ordering
        )
        self.assertIn(
            "candidateHasPendingLocalChanges && !selectedHasPendingLocalChanges",
            ordering,
        )
        self.assertIn("candidateAgeMinutes > selectedAgeMinutes", ordering)
        self.assertIn(
            "dueTables = order_owner_due_table_candidates(", queue
        )

    def test_cancel_active_sync_also_clears_durable_manual_queue(self):
        source = read_text("business/control_plane.tru")
        cancel = source.split("function jobs_cancel_active(", 1)[1].split(
            "function cleanup_multi_writer_batches_storage(", 1
        )[0]

        self.assertIn("visible_agent_rows_for(current)", cancel)
        self.assertIn("cancelledOwnerUserIds", cancel)
        self.assertIn(
            "set_manual_sync_pending_tables_for_owner(ownerUserId, []);",
            cancel,
        )
        self.assertIn("clearedManualQueueOwnerCount", cancel)
        claim_body = source.split(
            "function claim_periodic_sync_scheduler_for_owner(", 1
        )[1].split("function manual_sync_pending_tables_for_owner(", 1)[0]
        self.assertIn("bypassCooldown: bool? = false", claim_body)
        self.assertIn("if (bypassCooldown != true &&", claim_body)
        self.assertNotIn("bool.from(", claim_body)

        self.assertNotIn("preferred_source_client_name_for_agent_table(", source)
        self.assertNotIn("bulk_source_client_name_for_agent_table(", source)
        self.assertNotIn("latest_completed_source_for_target_table(", source)

        due_match = re.search(
            r"function due_periodic_sync_tables_for_agent_with_policies\(agent: map<json>, policies: array<json>\? = null, tableCache: map<json>\? = null, maxCount: int\? = null\): array<string> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(due_match)
        due_body = due_match.group("body")
        self.assertIn("let dueTableLimit = 0;", due_body)
        self.assertIn("if (maxCount != null && maxCount > 0) {", due_body)
        self.assertIn("sync_table_state_due_age_minutes(", due_body)
        self.assertIn("let dueCandidates = [];", due_body)
        self.assertIn("let selectedAgeMinutes = -1;", due_body)
        self.assertIn("candidate.ageMinutes > selectedAgeMinutes", due_body)
        self.assertIn("string_array_contains(dueTables, candidateTable)", due_body)
        self.assertIn("if (dueTableLimit > 0 && dueTables.length >= dueTableLimit) {", due_body)
        self.assertNotIn(
            "return dueTables;",
            due_body.split("for (const table of enabledTables)", 1)[1].split(
                "for (const ignored of dueCandidates)", 1
            )[0],
        )

        age_match = re.search(
            r"function sync_table_state_due_age_minutes\(tableState: map<json>\? = null, intervalMinutes: int\? = null\): int\? \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(age_match)
        age_body = age_match.group("body")
        self.assertIn("return 2147483647;", age_body)
        self.assertIn("if (elapsedMinutes < interval) {", age_body)
        self.assertIn("return elapsedMinutes;", age_body)

        owner_scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]
        self.assertIn(
            "const manualPendingTables = manual_sync_pending_tables_for_owner(ownerUserId);",
            owner_scheduler,
        )
        self.assertIn(
            "const scheduledTableAttempts = periodic_sync_scheduled_table_attempts_for_owner(ownerUserId);",
            owner_scheduler,
        )
        self.assertIn("due_offline_catchup_tables(", owner_scheduler)
        self.assertIn("if (manualPendingTables.length == 0) {", owner_scheduler)
        self.assertIn("periodic_sync_table_due_after_attempt(", owner_scheduler)
        self.assertIn(
            "record_periodic_sync_table_attempt(ownerUserId, table);",
            owner_scheduler,
        )
        self.assertIn("queuedTables = queuedTables.concat([table]);", owner_scheduler)
        self.assertIn(
            "set_manual_sync_pending_tables_for_owner(ownerUserId, remainingManualTables);",
            owner_scheduler,
        )

        self.assertIn("field scheduledTableAttempts: array<json>?", source)
        attempt_due_body = source.split(
            "function periodic_sync_table_due_after_attempt(", 1
        )[1].split("function record_periodic_sync_table_attempt(", 1)[0]
        self.assertIn(
            "return elapsedMinutes >= clamp_auto_sync_interval(intervalMinutes);",
            attempt_due_body,
        )
        complete_body = source.split("function jobs_complete(", 1)[1].split(
            "function jobs_fail(", 1
        )[0]
        fail_body = source.split("function jobs_fail(", 1)[1].split(
            "function jobs_cancel_active(", 1
        )[0]
        terminal_attempt = (
            "record_periodic_sync_table_attempt(job.ownerUserId, string.from(job.table));"
        )
        self.assertIn(terminal_attempt, complete_body)
        self.assertIn(terminal_attempt, fail_body)

        self.assertIn("field rejectedRowCount: int?", source)
        self.assertIn("field rejectionSummary: string?", source)
        self.assertIn("rejectedRowCount: job.rejectedRowCount", source)
        self.assertIn("rejectionSummary: job.rejectionSummary", source)
        self.assertIn("rejectedRowCount,", complete_body)
        self.assertIn("rejectionSummary,", complete_body)

        terminal_guard = (
            "if (sync_job_status_is_terminal(string.from(job.status))) {"
        )
        self.assertIn("function sync_job_status_is_terminal(", source)
        self.assertIn("normalizedStatus == 'completed'", source)
        self.assertIn("normalizedStatus == 'failed'", source)
        self.assertIn("normalizedStatus == 'cancelled'", source)
        start_body = source.split("function jobs_start(", 1)[1].split(
            "function jobs_progress(", 1
        )[0]
        progress_body = source.split("function jobs_progress(", 1)[1].split(
            "function jobs_complete(", 1
        )[0]
        self.assertIn(terminal_guard, start_body)
        self.assertIn(terminal_guard, progress_body)
        self.assertIn(terminal_guard, complete_body)
        self.assertIn(terminal_guard, fail_body)

    def test_window_action_request_all_only_targets_online_agents(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function agent_window_action_request_all\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("if (normalizedAction != 'minimize') {", body)
        self.assertIn("const visibleAgents = visible_agent_rows_for(current);", body)
        self.assertIn("if (!effective_agent_online(agent)) {", body)
        self.assertIn("windowActionRequestId: requestId,", body)
        self.assertIn("windowActionName: normalizedAction,", body)
        self.assertIn("windowActionStatus: 'requested',", body)

    def test_window_action_payload_and_ack_track_pending_and_last_ack_state(self):
        source = read_text("business/control_plane.tru")

        payload_match = re.search(
            r"function agent_window_action_payload\(agent: map<json>, authenticatedClientPoll: bool = false\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(payload_match)
        payload_body = payload_match.group("body")

        self.assertIn("const pending = window_action_request_pending(agent);", payload_body)
        self.assertIn("const waitingForClient = !authenticatedClientPoll && pending_request_awaits_online_client(agent, pending);", payload_body)
        self.assertIn("pending: pending && !waitingForClient,", payload_body)
        self.assertIn("const actionValue = agent.windowActionName == null ? '' : string.from(agent.windowActionName);", payload_body)
        self.assertIn("let statusValue = agent.windowActionStatus == null ? 'idle' : string.from(agent.windowActionStatus);", payload_body)
        self.assertIn("let messageValue = agent.windowActionMessage == null ? '' : string.from(agent.windowActionMessage);", payload_body)
        self.assertIn("Waiting for the client to heartbeat before the window action can be delivered.", payload_body)
        self.assertIn("requestId: agent.windowActionRequestId,", payload_body)
        self.assertIn("action: actionValue,", payload_body)
        self.assertIn("lastRequestId: agent.windowActionLastRequestId,", payload_body)
        self.assertIn("acknowledgedAt: agent.windowActionLastAcknowledgedAt,", payload_body)
        self.assertIn("status: statusValue,", payload_body)
        self.assertIn("message: messageValue", payload_body)

    def test_diagnostics_payload_marks_offline_pending_requests_as_client_offline(self):
        source = read_text("business/control_plane.tru")

        payload_match = re.search(
            r"function agent_diagnostics_payload\(agent: map<json>, includePayload: bool = false, authenticatedClientPoll: bool = false\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(payload_match)
        payload_body = payload_match.group("body")

        self.assertIn("const pending = diagnostic_request_pending(agent);", payload_body)
        self.assertIn("const waitingForClient = !authenticatedClientPoll && pending_request_awaits_online_client(agent, pending);", payload_body)
        self.assertIn("pending: pending && !waitingForClient,", payload_body)
        self.assertIn("statusValue = 'client_offline';", payload_body)
        self.assertIn("Waiting for the client to heartbeat before diagnostics can upload.", payload_body)
        self.assertIn("status: statusValue,", payload_body)
        self.assertIn("summary: summaryValue,", payload_body)

        ack_match = re.search(
            r"function agent_window_action_ack\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(ack_match)
        ack_body = ack_match.group("body")

        self.assertIn("if (agent.windowActionRequestId != null) {", ack_body)
        self.assertIn(
            "resolvedRequestId = string.from(agent.windowActionRequestId).trim();",
            ack_body,
        )
        self.assertNotIn("string.from(requestId)", ack_body)
        self.assertIn("windowActionLastRequestId: resolvedRequestIdOrNull,", ack_body)
        self.assertIn("windowActionLastAcknowledgedAt: now_iso(),", ack_body)
        self.assertIn("windowActionName: nextAction,", ack_body)
        self.assertIn("windowActionStatus: truncate_text(status.trim(), 32),", ack_body)
        self.assertIn("windowActionMessage: truncate_text(message, 4000),", ack_body)

        upload_match = re.search(
            r"function agent_diagnostics_upload\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(upload_match)
        upload_body = upload_match.group("body")
        self.assertIn("if (agent.diagnosticRequestId != null) {", upload_body)
        self.assertIn(
            "resolvedRequestId = string.from(agent.diagnosticRequestId).trim();",
            upload_body,
        )
        self.assertNotIn("string.from(requestId)", upload_body)

    def test_ensure_agent_repairs_stale_rows_before_recreating_them(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function ensure_agent\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("const repaired = db.update(Agent, { clientName }, {", body)
        self.assertIn("isOnline: false,", body)
        self.assertIn("serverConnected: false,", body)
        self.assertIn("sqlConnected: false,", body)
        self.assertIn("lastHeartbeat: '',", body)
        self.assertIn("selectedTable: null,", body)
        self.assertIn("tables: [],", body)
        self.assertIn("tableRelationships: [],", body)
        self.assertIn("diagnosticStatus: 'idle',", body)
        self.assertIn("clientUpdateRequestId: null,", body)
        self.assertIn("clientUpdateTargetVersion: null,", body)
        self.assertIn("clientUpdateLastRequestId: null,", body)
        self.assertIn("clientUpdateLastAcknowledgedAt: null,", body)
        self.assertIn("clientUpdateStatus: 'idle',", body)
        self.assertIn("clientUpdateMessage: '',", body)
        self.assertIn("windowActionRequestId: null,", body)
        self.assertIn("windowActionLastRequestId: null,", body)
        self.assertIn("windowActionLastAcknowledgedAt: null,", body)
        self.assertIn("windowActionStatus: 'idle',", body)
        self.assertNotIn("symmetricDsStatus", body)

    def test_table_policy_path_no_longer_keeps_legacy_key_normalizers(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertNotIn("function normalize_stored_table_sync_policy(", source)
        self.assertNotIn("const compatible = db.selectOne(TableSyncPolicy", source)
        self.assertNotIn("const keyed = db.selectOne(TableSyncPolicy", source)
        self.assertNotIn("compatibleKey =", agent_page)
        self.assertNotIn("dbo.$localTable", agent_page)

    def test_jobs_create_uses_shared_baseline_preflight_for_enabled_owner_clients(self):
        source = read_text("business/control_plane.tru")
        jobs_create = source.split("function jobs_create(", 1)[1].split(
            "function jobs_bootstrap(", 1
        )[0]

        self.assertIn(
            "const targetAgent = find_agent_row_by_name(ownerAgents, resolvedClientName);",
            jobs_create,
        )
        self.assertIn("agent_sync_enabled(targetAgent)", source)
        self.assertIn("const plan = sync_table_baseline_plan(", jobs_create)
        self.assertIn("!preserveChangeTrackingBaselines", jobs_create)
        self.assertIn("nextJobs = create_multi_writer_batch(", jobs_create)
        self.assertIn("nextJobs = create_authoritative_reconcile_batch(", jobs_create)
        self.assertIn(
            "function jobs_progress(jobId: string, status: string = 'running', progress: int, message: string, rowCount: int, token: string? = null): map<json> {",
            source,
        )
        self.assertIn("preserveChangeTrackingBaselines", jobs_create)
        self.assertIn("mark_offline_sync_debt(", jobs_create)
        self.assertIn("'the requested client is offline'", jobs_create)
        self.assertIn("field syncMode: string min=1 max=32", source)
        self.assertNotIn("mergeRole", source)
        self.assertNotIn("publicationName", source)
        self.assertNotIn("direction: 'sync'", source)
        self.assertNotIn("rowCount: int, direction: string, token: string? = null", source)
        self.assertNotIn("Queued SymmetricDS sync", source)

    def test_snapshot_transport_contract_remains_present(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        completion = source.split("function jobs_upload_chunk_complete(", 1)[1].split(
            "function jobs_download_snapshot_manifest(", 1
        )[0]

        self.assertIn("function jobs_upload_chunk_start(", source)
        self.assertIn("function jobs_upload_chunk_complete(", source)
        self.assertIn("storageId: ''", completion)
        self.assertIn("isDelta: false", completion)
        self.assertIn("function jobs_download_snapshot_manifest(", source)
        self.assertIn("function jobs_download_snapshot_chunk(", source)
        self.assertIn("Future<void> _processSnapshotJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayDownloadJob(", agent_page)
        self.assertNotIn("_runDirectQueuedTableSync(", agent_page)

    def test_change_tracking_transport_and_table_apply_are_atomic(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        output_codec = read_text("sync_windows_agent/lib/sql_cmd_output.dart")

        self.assertIn("sqlSyncHexRowTerminator", agent_page)
        self.assertIn("decodeSqlServerHexRows(", agent_page)
        self.assertNotIn("FOR JSON PATH", agent_page)
        self.assertNotIn("Change tracking delta returned", agent_page)
        self.assertIn("onChunk: null", agent_page)
        self.assertIn(
            "Buffer the complete table delta before SQL apply",
            agent_page,
        )
        self.assertNotIn("applySqlSyncRowsWithIsolation(", agent_page)
        self.assertIn("~SQLSYNC_ROW_END~", output_codec)
        self.assertIn("decodeSqlServerUtf16Hex(token.substring(1))", output_codec)

        stale_guard = source.split(
            "function multi_writer_batch_stale(", 1
        )[1].split("function auth_login(", 1)[0]
        self.assertIn("(batch.receivedChunks ?? []).length > 0", stale_guard)
        self.assertIn("(batch.uploadedClients ?? []).length > 0", stale_guard)
        self.assertIn("ageMinutes >= 1440", stale_guard)

    def test_v2_related_table_expansion_remains_active_without_source_selection(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertNotIn("create_sync_jobs_for_agent(", source)
        self.assertNotIn("queue_due_periodic_sync_jobs_for_agent(", source)
        self.assertIn("function expand_sync_job_tables_for_owner", source)
        self.assertNotIn("latest_completed_job_tables_for_client", source)
        self.assertNotIn("enabledTables = latest_completed_job_tables_for_client(agent.clientName);", source)
        self.assertIn("final tablesToQueue = <String>{", agent_page)
        self.assertIn("..._relatedSyncKeysFor(syncKey)", agent_page)

    def test_server_reset_clears_saved_agent_state_and_reports_counts(self):
        source = read_text("business/control_plane.tru")

        reset_match = re.search(
            r"function reset_all_agent_saved_state\(\): int \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(reset_match)
        reset_body = reset_match.group("body")

        self.assertIn("return db.updateMany(Agent, { clientName: { gte: '' } }, {", reset_body)
        self.assertNotIn("isOnline: false,", reset_body)
        self.assertNotIn("serverConnected: false,", reset_body)
        self.assertNotIn("sqlConnected: false,", reset_body)
        self.assertNotIn("clientVersion: '',", reset_body)
        self.assertNotIn("lastHeartbeat: '',", reset_body)
        self.assertIn("selectedTable: null,", reset_body)
        self.assertIn("tables: [],", reset_body)
        self.assertIn("tableRelationships: [],", reset_body)
        self.assertIn("diagnosticRequestId: null,", reset_body)
        self.assertIn("diagnosticLastRequestId: null,", reset_body)
        self.assertIn("diagnosticStatus: 'idle',", reset_body)
        self.assertIn("diagnosticSummary: '',", reset_body)
        self.assertIn("diagnosticPayload: '',", reset_body)
        self.assertIn("clientUpdateRequestId: null,", reset_body)
        self.assertIn("clientUpdateRequestedAt: null,", reset_body)
        self.assertIn("clientUpdateRequestedByUserId: null,", reset_body)
        self.assertIn("clientUpdateTargetVersion: null,", reset_body)
        self.assertIn("clientUpdateLastRequestId: null,", reset_body)
        self.assertIn("clientUpdateLastAcknowledgedAt: null,", reset_body)
        self.assertIn("clientUpdateStatus: 'idle',", reset_body)
        self.assertIn("clientUpdateMessage: '',", reset_body)
        self.assertIn("windowActionRequestId: null,", reset_body)
        self.assertIn("windowActionStatus: 'idle',", reset_body)

        server_reset_match = re.search(
            r"function server_saved_data_reset\(resetAgents: bool = true, continueReset: bool = false, token: string\? = null\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(server_reset_match)
        server_reset_body = server_reset_match.group("body")

        self.assertIn("const cancelledJobCount = db.updateMany(SyncJob", server_reset_body)
        self.assertIn("cancelledJobCount", server_reset_body)
        self.assertIn("delete_snapshot_storage_batch()", server_reset_body)
        self.assertIn("deletedStorageObjectCount", server_reset_body)
        self.assertIn("const hasMore = snapshotBatch.hasMore == true", server_reset_body)
        storage_cleanup = source.split("function delete_snapshot_storage_batch(", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("db.selectMany(SnapshotRecord", storage_cleanup)
        self.assertIn("limit: 25", storage_cleanup)
        self.assertIn("hasMore: storedSnapshots.length == 25", storage_cleanup)
        self.assertIn("storage.delete(storageId);", storage_cleanup)
        self.assertIn("snapshotIds = snapshotIds.concat([storedSnapshot.id])", storage_cleanup)
        self.assertIn("db.deleteMany(SnapshotRecord, { id: { in: snapshotIds } })", storage_cleanup)
        self.assertNotIn("delete_snapshot_storage_batch(", storage_cleanup)
        self.assertNotIn("db.page(SnapshotRecord", storage_cleanup)
        self.assertIn("delete_sync_job_batch()", server_reset_body)
        self.assertIn("delete_download_session_batch()", server_reset_body)
        self.assertIn("delete_upload_session_batch()", server_reset_body)
        self.assertNotIn("db.deleteMany(SnapshotRecord", server_reset_body)
        self.assertIn("delete_sync_batch_batch()", server_reset_body)
        self.assertIn("delete_periodic_sync_state_batch()", server_reset_body)
        self.assertIn("const automaticSyncControl = automatic_sync_control_set(true, token);", server_reset_body)
        self.assertIn("automaticSyncPaused: automaticSyncControl.automaticSyncPaused == true", server_reset_body)
        self.assertIn("cleanupStatus: hasMore ? 'cleaning' : 'cleaned'", server_reset_body)
        self.assertLess(
            server_reset_body.index("delete_periodic_sync_state_batch()"),
            server_reset_body.index("automatic_sync_control_set(true, token)"),
        )
        for helper_name in (
            "delete_download_session_batch",
            "delete_upload_session_batch",
            "delete_sync_batch_batch",
            "delete_sync_job_batch",
            "delete_periodic_sync_state_batch",
        ):
            helper_body = source.split(f"function {helper_name}(", 1)[1].split("\nfunction ", 1)[0]
            self.assertIn("limit: 50", helper_body)
            self.assertIn("hasMore: rows.length == 50", helper_body)
        self.assertIn("deletedRecordCount,", server_reset_body)
        self.assertIn("agentResetCount = reset_all_agent_saved_state();", server_reset_body)
        self.assertIn("jobDeletedCount,", server_reset_body)
        self.assertIn("agentResetCount", server_reset_body)
        self.assertIn("if (resetAgents && !continueReset)", server_reset_body)
        self.assertIn("if (!is_admin_user(current) && !is_owner_user(current))", server_reset_body)

    def test_active_job_statuses_include_snapshot_transfer_and_apply_states(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function is_active_job_status\(status: string\? = null\): bool \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("normalized == 'queued'", body)
        self.assertIn("normalized == 'running'", body)
        self.assertIn("normalized == 'snapshotting'", body)
        self.assertIn("normalized == 'uploading'", body)
        self.assertIn("normalized == 'downloading'", body)
        self.assertIn("normalized == 'applying'", body)

    def test_server_reset_cancellation_is_enforced_by_server_and_windows_client(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        agent_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        guarded_endpoints = (
            "jobs_upload_chunk_start",
            "jobs_multi_writer_upload",
            "jobs_multi_writer_download",
            "jobs_upload_chunk",
            "jobs_upload_chunk_complete",
            "jobs_download_snapshot_manifest",
            "jobs_download_snapshot_chunk",
        )
        for index, endpoint in enumerate(guarded_endpoints):
            start = source.index(f"function {endpoint}(")
            next_starts = [
                source.find("\nfunction ", start + 1),
                len(source),
            ]
            end = min(value for value in next_starts if value != -1)
            body = source[start:end]
            self.assertIn(
                "sync_job_status_is_terminal(string.from(job.status))",
                body,
                msg=f"{endpoint} must reject cancelled jobs ({index})",
            )
            self.assertIn("raw_json_error(410, 'sync job is no longer active')", body)

        self.assertIn("final Set<String> _cancelledProcessingJobIds", agent_page)
        self.assertIn("_checkSyncJobNotCancelled(job.id)", agent_page)
        self.assertIn("on _SyncJobCancelled catch", agent_page)
        self.assertIn("SyncCancellationCheck? checkCancelled", agent_api)
        self.assertIn("checkCancelled?.call();", agent_api)

    def test_control_plane_no_longer_advertises_old_sync_engine(self):
        source = read_text("business/control_plane.tru")

        self.assertNotIn("function sync_engine_metadata(): map<json>", source)
        self.assertNotIn("syncEngine: sync_engine_metadata()", source)
        self.assertNotIn("centralStore: 'symmetricds'", source)
        self.assertNotIn("mode: 'symmetricDs'", source)

    def test_multi_writer_batch_has_upload_barrier_and_merged_download(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("class SyncBatch {", source)
        self.assertIn("field expectedClients: array<json>", source)
        self.assertIn("field uploadedClients: array<json>", source)
        self.assertIn("field receivedChunks: array<json>", source)
        self.assertIn("field receivedBytes: int", source)
        self.assertIn("field revision: int min=0", source)
        self.assertIn("field clientChangeTrackingVersions: array<json>", source)
        self.assertIn("function jobs_multi_writer_upload(", source)
        self.assertIn("if (incomingRowCount > 100)", source)
        self.assertIn("let incomingBytes = json.stringify(incomingRows).length", source)
        self.assertIn("receivedBytes + incomingBytes > 128000000", source)
        self.assertIn("const ready = uploadedClients.length >= batch.expectedClients.length;", source)
        self.assertIn("function jobs_multi_writer_download(", source)
        self.assertIn("cursor: string? = null", source)
        self.assertIn("db.page(SnapshotRecord", source)
        self.assertIn("{ field: 'subscriberClientName', dir: 'asc' }", source)
        self.assertIn("nextCursor", source)
        download_body = source[source.index("function jobs_multi_writer_download("):source.index("function jobs_upload_chunk(")]
        self.assertNotIn("limit: 1000", download_body)
        self.assertIn("limit: 1", download_body)
        self.assertIn("done", source)
        self.assertIn("sync batch is still waiting for client uploads", source)
        self.assertIn("{ id: batch.id, revision: batch.revision }", source)
        self.assertIn("sync batch changed while uploading; retry this chunk", source)
        self.assertIn("clientChangeTrackingVersions", source)
        self.assertIn("multi-writer batch expired", source)
        self.assertIn("db.insert(SnapshotRecord", source)
        self.assertIn("storage.put({", source)
        self.assertIn("field storageId: string", source)
        self.assertIn("payloadBase64", source)
        self.assertIn("payloadRowCount", source)
        self.assertIn("let incomingRowCount = incomingRows.length", source)
        self.assertIn("where: { sourceJobId: batch.id }", source)
        self.assertIn("rows: []", source)
        self.assertIn("rows: [],", source)

    def test_sync_all_queues_one_batch_for_online_peers(self):
        source = read_text("business/control_plane.tru")
        sync_all = source.split("function jobs_create_all_enabled_for_identity(", 1)[1].split(
            "function reset_all_agent_saved_state", 1
        )[0]

        self.assertIn("mode: 'protocol-v4'", source)
        self.assertIn("if (effective_agent_online(agent))", source)
        self.assertIn("create_multi_writer_batch(", source)
        self.assertIn("const plan = sync_table_baseline_plan(", source)
        self.assertIn("!preserveChangeTrackingBaselines", source)
        self.assertNotIn("sync_gate_payload_for_owners(ownerUserIds)", sync_all)
        self.assertNotIn("refresh_owner_baseline_table_issues(ownerUserId, visibleAgents)", sync_all)
        self.assertIn("sync_owner_has_blocking_table_issues(ownerUserId)", source)
        self.assertIn("create_authoritative_reconcile_batch(", source)
        self.assertIn("function multi_writer_batch_stale(batch: map<json>): bool", source)
        self.assertIn("return raw_json_error(410, 'sync job is no longer active');", source)
        stale_guard = source.split(
            "function multi_writer_batch_stale(batch: map<json>): bool", 1
        )[1].split("function ", 1)[0]
        self.assertIn("batch.updatedAt", stale_guard)
        self.assertNotIn("batch.createdAt", stale_guard)
        self.assertIn("status: { in: ['running', 'snapshotting', 'uploading', 'downloading', 'applying'] }", stale_guard)
        self.assertIn("if (processingJobs.length > 0)", stale_guard)
        self.assertIn("let queuedTableCount = activeTableCapacityUsed;", source)
        self.assertIn(
            "remaining manual tables will drain automatically",
            source,
        )
        self.assertIn("Online peers continue syncing while another enabled client is offline", source)
        self.assertIn("'server-partial-delta-v3'", source)
        self.assertIn("'server-partial-merge'", source)
        self.assertIn("ownerAgents.length != allOwnerAgents.length", source)
        self.assertIn("onlineAgents.length != ownerAgents.length", source)
        self.assertIn("Change Tracking cursors are preserved until offline clients catch up", source)
        self.assertIn("skippedOfflineClientCount", source)

    def test_missing_or_expired_baseline_replans_as_safe_all_client_union(self):
        source = read_text("business/control_plane.tru")
        ready = source.split(
            "function scheduler_table_change_tracking_ready(", 1
        )[1].split("function sync_agents_enabled_for_table", 1)[0]
        planner = source.split("function sync_table_baseline_plan(", 1)[1].split(
            "function sync_owner_has_blocking_table_issues", 1
        )[0]
        failure = source.split("function jobs_fail(", 1)[1].split(
            "function jobs_cancel_active", 1
        )[0]

        self.assertIn("trackingStatus == 'enabled'", ready)
        self.assertIn("readyAgents.length != participants.length", planner)
        self.assertIn("reportedRowCountClientCount == participants.length", planner)
        self.assertIn("mode: 'union_bootstrap'", planner)
        self.assertIn("failureKind: string = ''", source)
        self.assertIn("failureKind.trim().toLowerCase() == 'baseline_required'", failure)
        self.assertIn("status: baselineReplan ? 'cancelled' : 'failed'", failure)
        self.assertIn("mark_agent_table_baseline_pending", failure)
        self.assertIn("pendingTables.concat([string.from(job.table)])", failure)

    def test_sync_all_tracks_whole_operation_and_refills_bounded_slots(self):
        source = read_text("business/control_plane.tru")
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit", 1)[0]
        complete = source.split("function jobs_complete(", 1)[1].split(
            "function jobs_fail(", 1
        )[0]
        live_state = source.split("function live_state(", 1)[1].split(
            "function agents_heartbeat(", 1
        )[0]

        self.assertIn("field manualSyncStartedAt: datetime?", source)
        self.assertIn("field manualSyncCompletedAt: datetime?", source)
        self.assertIn("const requestedAt = now_iso();", source)
        self.assertIn(
            "begin_manual_sync_operation(ownerUserId, enabledTables.length, requestedAt)",
            source,
        )
        self.assertIn("activeTableCapacityUsed", scheduler)
        self.assertIn(
            "queuedTableCount = activeTableCapacityUsed",
            scheduler,
        )
        self.assertIn(
            "activeTableCapacityUsed >= periodic_sync_scheduler_table_limit()",
            scheduler,
        )
        self.assertIn("queue_due_periodic_sync_jobs_for_owner", complete)
        self.assertIn("finish_manual_sync_operation", complete)
        self.assertIn("syncAllOperations", live_state)
        self.assertIn("manual_sync_operation_payload", live_state)

    def test_sync_all_finishes_when_a_table_has_no_current_peer_target(self):
        source = read_text("business/control_plane.tru")
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit", 1)[0]
        self.assertIn("let unavailableManualTables = [];", scheduler)
        self.assertIn(
            "string_array_contains(unavailableManualTables, table)", scheduler
        )
        self.assertIn(
            "reduce_manual_sync_table_count_for_owner(ownerUserId, unavailableManualTables.length)",
            scheduler,
        )
        self.assertIn(
            "remainingManualTables.length == 0", scheduler
        )
        self.assertIn("finish_manual_sync_operation", scheduler)

    def test_sync_scheduling_is_scoped_to_each_agents_selected_database(self):
        source = read_text("business/control_plane.tru")

        database_guard = source.split(
            "function sync_table_belongs_to_database(", 1
        )[1].split("\nfunction ", 1)[0]
        self.assertIn("database.trim().toLowerCase()", database_guard)
        self.assertIn("sync_table_reference(syncTable)", database_guard)
        self.assertIn("tableDatabase == selectedDatabase", database_guard)
        self.assertIn("return false;", database_guard)

        inventory_tables = source.split(
            "function enabled_sync_tables_for_agent_with_policies(", 1
        )[1].split("\nfunction scheduler_agent_table_states(", 1)[0]
        self.assertIn("sync_table_belongs_to_database(", inventory_tables)
        self.assertIn("string.from(agent.database)", inventory_tables)

        scheduler_states = source.split(
            "function scheduler_agent_table_states(", 1
        )[1].split("\nfunction scheduler_agent_table_state(", 1)[0]
        self.assertIn("sync_table_belongs_to_database(", scheduler_states)
        self.assertIn("selectedDatabaseTables", scheduler_states)

        policy_tables = source.split(
            "function enabled_sync_policy_tables_for_agent(", 1
        )[1].split("\nfunction sync_table_state_due_for_interval(", 1)[0]
        self.assertIn("sync_table_belongs_to_database(", policy_tables)
        self.assertIn("string.from(agent.database)", policy_tables)

        # Every scheduling entry point consumes one of the guarded shared
        # selectors, so stale mixed-database heartbeat inventory cannot leak
        # into Sync All, periodic waves, retries, or comparison jobs.
        self.assertGreaterEqual(
            source.count("enabled_sync_tables_for_agent_with_policies("), 8
        )
        self.assertGreaterEqual(
            source.count("enabled_sync_policy_tables_for_agent("), 8
        )

    def test_shared_baseline_preflight_keeps_delta_and_reconcile_modes_explicit(self):
        source = read_text("business/control_plane.tru")
        planner = source.split(
            "function sync_table_baseline_plan(", 1
        )[1].split("function enabled_sync_policy_tables_for_agent(", 1)[0]

        self.assertIn("readyAgents.length == participants.length", planner)
        self.assertLess(
            planner.index("allReportedRowCounts.length > 1"),
            planner.index("if (readyAgents.length == participants.length) {"),
        )
        self.assertIn("reportedRowCountClientCount == participants.length", planner)
        fingerprint_union = planner.split(
            "Clients report different complete table fingerprints", 1
        )[0].rsplit("if (participants.length >= 2", 1)[1]
        self.assertIn("allFingerprints.length > 1", fingerprint_union)
        self.assertNotIn(
            "reportedClientCount == participants.length", fingerprint_union
        )
        self.assertIn("missing fingerprint", planner)
        self.assertIn("establishedInventoryCanUnion", planner)
        self.assertIn(
            "const establishedInventoryCanUnion = allowInventoryUnion;", planner
        )
        self.assertNotIn("!latest_completed_table_batch_was_union", planner)
        self.assertNotIn("db.selectMany(", planner)
        self.assertIn("recentUploadModes", planner)
        self.assertIn("function latest_completed_upload_modes_for_owner(", source)
        self.assertIn("fields: ['table', 'sourceClientName']", source)
        self.assertIn("mode: 'delta'", planner)
        self.assertIn("mode: 'reconcile'", planner)
        self.assertIn("mode: 'needs_input'", planner)
        self.assertIn("mode: 'unavailable'", planner)
        self.assertIn("reportedClientCount != participants.length", planner)
        self.assertIn("readyFingerprints.length <= 1", planner)
        self.assertGreaterEqual(planner.count("allFingerprints.length == 1"), 2)
        self.assertIn("allFingerprints.length == 1", planner)

    def test_partial_batches_preserve_cursors_until_offline_clients_catch_up(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        cursor_policy = read_text(
            "sync_windows_agent/lib/change_tracking_cursor_policy.dart"
        )

        self.assertIn("class OfflineSyncDebt", source)
        self.assertIn("function mark_offline_sync_debt(", source)
        self.assertIn("function due_offline_catchup_tables(", source)
        self.assertIn("function clear_offline_sync_debt_for_clients(", source)
        self.assertIn("clientName: { in: normalizedClientNames }", source)
        self.assertIn("function sync_batch_client_names(", source)
        self.assertIn("sync_batch_all_jobs_completed(completedBatchId)", source)
        self.assertIn("string.from(job.sourceClientName).trim() == 'server-partial-merge'", source)
        self.assertIn("sync_batch_client_names(completedBatchId)", source)
        self.assertIn("sourceClientName: preserveChangeTrackingBaselines ? 'server-partial-merge'", source)
        self.assertIn(
            "authoritative baseline reconciliation waits until every enabled client is online",
            source,
        )
        self.assertIn("uploadPreservesChangeTrackingBaseline", agent_page)
        self.assertIn("downloadPreservesChangeTrackingBaseline", agent_page)
        self.assertIn("'server-partial-delta-v3'", cursor_policy)
        self.assertIn("'server-partial-merge'", cursor_policy)
        self.assertIn("final preserveChangeTrackingBaseline =", agent_page)
        self.assertIn("final appliedVersion =", agent_page)

    def test_orphan_client_registration_deletion_is_scoped_and_refuses_live_accounts(self):
        source = read_text("business/control_plane.tru")
        body = source.split("function agent_registration_delete(", 1)[1].split(
            "function agent_sync_settings_post(", 1
        )[0]

        self.assertIn("visible_agent_rows_for(current)", body)
        self.assertIn("if (clientUser != null)", body)
        self.assertIn("delete the client account instead", body)
        self.assertIn("if (agent_command_delivery_online(agent))", body)
        self.assertIn("cancel_active_sync_batches_for_client(", body)
        self.assertIn("db.delete(Agent, { clientName: normalizedClientName })", body)
        self.assertNotIn("db.deleteMany(SyncJob", body)

    def test_offline_debt_status_distinguishes_paused_from_active_catchup(self):
        source = read_text("business/control_plane.tru")
        status_body = source.split(
            "function client_runtime_status_payload(", 1
        )[1].split("function public_agent_payload(", 1)[0]

        self.assertIn("client_has_offline_sync_debt(agent)", status_body)
        self.assertIn("automatic_sync_is_paused()", status_body)
        self.assertIn("automatic_sync_is_paused_for_owner", status_body)
        self.assertIn("code: 'catchup_paused'", status_body)
        self.assertIn("label: 'Catch-up pending (sync paused)'", status_body)
        self.assertIn("code: 'catching_up'", status_body)

    def test_database_agnostic_policy_remains_a_safe_fallback(self):
        source = read_text("business/control_plane.tru")
        policy_lookup = source.split(
            "function table_sync_policy_for_table_with_policies(", 1
        )[1].split("function find_table_sync_policy(", 1)[0]

        self.assertIn("let databaseAgnosticMatch = null;", policy_lookup)
        self.assertIn("if (policyDatabase.length == 0 && databaseAgnosticMatch == null)", policy_lookup)
        self.assertIn("return databaseAgnosticMatch;", policy_lookup)
        self.assertIn("const fallbackPolicies = db.selectMany(TableSyncPolicy", policy_lookup)
        self.assertIn(
            "fields: ['ownerUserId', 'database', 'table', 'enabled', 'syncMode', 'updatedAt', 'updatedByClientName']",
            policy_lookup,
        )
        self.assertNotIn("database: null", policy_lookup)

    def test_protocol_v4_unions_full_snapshots_for_multi_client_anti_entropy(self):
        source = read_text("business/control_plane.tru")

        batch_body = source.split("function create_multi_writer_batch(", 1)[1].split(
            "function multi_writer_batch_stale(", 1
        )[0]
        self.assertNotIn("multi_writer_agents_have_fingerprint_mismatch", batch_body)
        self.assertNotIn("'server-anti-entropy'", source)
        self.assertIn("'server-delta-v3'", source)
        self.assertIn("'server-bootstrap-v3'", source)
        self.assertIn("'server-union-bootstrap-v3'", source)
        self.assertIn("const multiClientUnionBootstrap", source)
        self.assertIn("mode: 'union_bootstrap'", source)
        self.assertIn("every client will upload a complete snapshot", source)
        self.assertIn("explicitSingleClientBootstrap", source)
        self.assertIn("field protocolVersion: int? min=3 max=4", source)
        self.assertIn("field syncEpoch: string? min=0 max=64", source)
        self.assertIn("protocolVersion != sync_protocol_version()", source)
        self.assertIn("sync epoch changed; discard this job", source)
        self.assertIn("{ field: 'subscriberClientName', dir: 'asc' }", source)

    def test_disabled_clients_are_excluded_from_protocol_v2_barriers(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("field syncEnabled: bool?", source)
        live_rows = source.split("function live_state_agent_rows_for(", 1)[1].split(
            "function live_state_job_rows_for(", 1
        )[0]
        self.assertIn("'syncEnabled'", live_rows)
        self.assertIn("function agent_sync_enabled(agent: map<json>): bool", source)
        self.assertIn("syncEnabled: agent_sync_enabled(agent)", source)
        self.assertIn("function agent_sync_enabled_set(", source)
        self.assertIn(
            "agent.ownerUserId == ownerUserId && agent_sync_enabled(agent)",
            source,
        )
        sync_all = source.split("function jobs_create_all_enabled_for_identity(", 1)[1].split(
            "function reset_all_agent_saved_state", 1
        )[0]
        manual_prepare = source.split("function begin_manual_sync_all_for_owner(", 1)[1].split(
            "function jobs_create_all_enabled(", 1
        )[0]
        self.assertIn("list_scheduler_agent_rows_for_owner(ownerUserId)", sync_all)
        self.assertIn("agent_sync_enabled(agent)", manual_prepare)
        self.assertIn("preserveChangeTrackingBaselines", source)
        self.assertIn("function mark_offline_sync_debt(", source)
        self.assertIn("function due_offline_catchup_tables(", source)
        toggle_body = source.split(
            "function agent_sync_enabled_set(", 1
        )[1].split("function agent_registration_delete(", 1)[0]
        self.assertIn("cancel_active_sync_batches_for_client(", toggle_body)
        self.assertIn("if (!enabled)", toggle_body)
        cancellation_body = source.split(
            "function cancel_active_sync_batches_for_client(", 1
        )[1].split("function agent_sync_enabled_set(", 1)[0]
        self.assertIn("affectedBatchIds", cancellation_body)
        self.assertIn("status: 'cancelled'", cancellation_body)
        self.assertIn(
            "cleanup_multi_writer_batches_storage(affectedBatchIds)",
            cancellation_body,
        )

    def test_explicit_bootstrap_is_single_enabled_client_and_retry_safe(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("function jobs_bootstrap(", source)
        self.assertIn("explicit bootstrap requires exactly one enabled client", source)
        self.assertIn("'server-bootstrap-v3'", source)
        self.assertIn("explicitSingleClientBootstrap", source)
        self.assertIn("sync_batch_chunk_seen(", source)
        self.assertIn("duplicate: true", source)
        self.assertIn("job.sourceClientName == 'server-bootstrap-v3'", agent_page)
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        self.assertIn("matchClauseForColumns(primaryKeyColumns, columns)", merge)
        self.assertNotIn("matchClauseForColumnSets", merge)
        self.assertNotIn("create_sync_jobs_for_agent(", source)
        self.assertNotIn("jobs_create_all_enabled_legacy(", source)

    def test_authoritative_reconciliation_is_explicit_paused_and_one_way(self):
        source = read_text("business/control_plane.tru")
        reconcile_body = source.split(
            "function jobs_reconcile_authoritative(", 1
        )[1].split("function sync_job_status_is_terminal(", 1)[0]
        reconcile_rows = source.split(
            "function authoritative_reconcile_job_rows(", 1
        )[1].split("function create_authoritative_reconcile_batch(", 1)[0]
        reconcile_batch = source.split(
            "function create_authoritative_reconcile_batch(", 1
        )[1].split("function multi_writer_batch_stale(", 1)[0]

        self.assertIn("'server-authoritative-reconcile'", reconcile_rows)
        self.assertIn("expectedSourceRowCount", reconcile_rows)
        self.assertIn("sourceTableState.rowCount", reconcile_rows)
        self.assertEqual(reconcile_rows.count("direction: 'upload'"), 1)
        self.assertEqual(reconcile_rows.count("direction: 'download'"), 1)
        self.assertIn("expectedClients: [sourceClientName]", reconcile_batch)
        self.assertIn("automatic_sync_is_paused_for_user(current)", reconcile_body)
        self.assertIn("effective_agent_online(sourceAgent)", reconcile_body)
        self.assertIn("effective_agent_online(targetAgent)", reconcile_body)
        self.assertIn("active_job_tables_for_client", reconcile_body)
        self.assertIn("source client cannot also be a reconciliation target", reconcile_body)
        self.assertIn("reconciliation table is not enabled", reconcile_body)
        self.assertIn("status: 'resolving'", reconcile_body)
        self.assertIn("action: 'authoritative_reconcile'", reconcile_body)
        self.assertIn("sourceClientName: normalizedSourceClientName", reconcile_body)
        self.assertIn("targetClientNames: normalizedTargetClientNames", reconcile_body)
        self.assertIn("create_authoritative_reconcile_batch(", reconcile_body)

    def test_clients_list_does_not_offer_destructive_authoritative_source(self):
        source = read_text("frontend/lib/clients_page.dart")
        row_body = source.split("DataRow _buildClientDataRow(", 1)[1].split(
            "String _clientActivityStatus(", 1
        )[0]

        self.assertNotIn("Use as source", row_body)
        self.assertNotIn("initialSourceName: agent.clientName", row_body)
        self.assertIn("wins only when synchronized changes conflict", row_body)
        self.assertIn("Normal non-conflicting changes still upload from every active client", source)
        self.assertNotIn("Replace Target Data", row_body)

    def test_windows_agent_full_reconciliation_is_non_destructive_and_latest_conflicts_are_atomic(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")

        self.assertNotIn("authoritativeReplace", agent)
        self.assertNotIn("authoritativeReplace", merge)
        self.assertNotIn("DELETE FROM $targetTable", merge)
        self.assertIn("resolveUniqueConflictsLatestWins: true", agent)
        self.assertIn("_buildLatestUniqueConflictReplacementStatements", merge)
        self.assertIn("DELETE target", merge)
        self.assertIn("WHERE NOT ($samePrimaryKey)", merge)
        self.assertIn("post-upload user change", merge)

    def test_retained_full_union_recovery_is_explicit_scoped_and_download_only(self):
        source = read_text("business/control_plane.tru")
        recovery_body = source.split(
            "function jobs_replay_retained_union(", 1
        )[1].split("function table_comparison_request(", 1)[0]

        self.assertIn("automatic_sync_is_paused_for_user(current)", recovery_body)
        self.assertIn("sourceClientName: 'server-union-bootstrap-v3'", recovery_body)
        self.assertIn("sourceJobId: normalizedBatchId", recovery_body)
        self.assertIn("subscriberClientName: normalizedSourceClientName", recovery_body)
        self.assertIn("'server-retained-union-recovery'", recovery_body)
        self.assertIn("const recoveryBatchId = uuid.v4()", recovery_body)
        self.assertIn("previewRows: [{ winnerPolicyApplied: false", recovery_body)
        self.assertIn("db.insertMany(SnapshotRecord, recoverySnapshots)", recovery_body)
        self.assertIn("effective_agent_online(agent)", recovery_body)
        self.assertIn("active_job_tables_for_client", recovery_body)
        self.assertIn("retained table is not enabled", recovery_body)
        self.assertEqual(recovery_body.count("direction: 'upload'"), 2)
        self.assertEqual(recovery_body.count("direction: 'download'"), 1)


    def test_authoritative_full_snapshots_preserve_verification_checksum(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]
        download_body = source.split(
            "function jobs_multi_writer_download(", 1
        )[1].split("function jobs_upload_chunk(", 1)[0]

        self.assertIn("snapshotChecksum: string = ''", source)
        self.assertIn("snapshotChecksum.trim()", upload_body)
        self.assertIn("'server-authoritative-reconcile'", upload_body)
        self.assertIn("'checksum'", download_body)
        self.assertIn("string.from(storedChunks[0].checksum)", download_body)

    def test_multi_writer_transport_uses_bounded_compressed_resumable_packages(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]
        download_body = source.split(
            "function jobs_multi_writer_download(", 1
        )[1].split("function jobs_upload_chunk(", 1)[0]
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        packages = read_text("sync_windows_agent/lib/delta_package.dart")

        self.assertIn("payloadEncoding: string = 'json'", upload_body)
        self.assertIn("string.gzipBase64Utf8Decode(encodedPayload)", upload_body)
        self.assertIn(
            "compressed multi-writer payload byte manifests are required", upload_body
        )
        self.assertIn(
            "payload byte manifest is smaller than its decoded content", upload_body
        )
        self.assertIn("incomingRowCount > 100", upload_body)
        self.assertIn("incomingBytes > 2000000", upload_body)
        self.assertIn("incomingCompressedBytes > 750000", upload_body)
        self.assertIn(
            "incomingRowCount * (resolvedUniqueKeyColumnSets.length + 1) > 100",
            upload_body,
        )
        self.assertIn("content_type: normalizedPayloadEncoding == 'gzip-json'", upload_body)
        self.assertIn("encoding: normalizedPayloadEncoding", upload_body)
        self.assertIn("payloadEncoding: chunkPayloadEncoding", download_body)
        self.assertIn("'gzip-json' => gzip.decode(encodedBytes)", api)
        self.assertIn("encodedBytes.length > maxCompressedPackageBytes", api)
        self.assertIn("decodedBytes.length > maxDecompressedPackageBytes", api)
        self.assertIn("decodedBytes.length", api)
        self.assertIn("Iterable<CompressedDeltaPackage>", packages)
        self.assertIn(") sync* {", packages)

    def test_sync_all_reports_completed_with_errors_when_any_batch_failed(self):
        source = read_text("business/control_plane.tru")
        finish = source.split("function finish_manual_sync_operation(", 1)[1].split(
            "function reduce_manual_sync_table_count_for_owner(", 1
        )[0]

        self.assertIn("status: 'failed'", finish)
        self.assertIn("createdAt: { gte:", finish)
        self.assertIn("resolvedStatus = 'completed_errors'", finish)

    def test_server_reset_rotates_protocol_v2_epoch(self):
        source = read_text("business/control_plane.tru")
        reset_body = source.split("function server_saved_data_reset(", 1)[1].split(
            "function jobs_upload_chunk_start(", 1
        )[0]

        self.assertIn("class SyncProtocolState {", source)
        self.assertIn("function rotate_sync_epoch(): map<json>", source)
        self.assertIn("if (!continueReset)", reset_body)
        self.assertIn("protocol = rotate_sync_epoch();", reset_body)
        self.assertIn("protocolVersion: protocol.protocolVersion", reset_body)
        self.assertIn("syncEpoch: protocol.syncEpoch", reset_body)

    def test_multi_writer_heartbeat_exposes_upload_and_download_for_same_table(self):
        source = read_text("business/control_plane.tru")
        active_jobs = source.split("function active_jobs_for_client(", 1)[1].split(
            "function unique_string_values(", 1
        )[0]
        self.assertIn("const jobKey = batchId.length == 0", active_jobs)
        self.assertIn("batchId, '::', direction", active_jobs)
        self.assertIn("seenJobKeys", active_jobs)
        self.assertNotIn("seenTables", active_jobs)
        self.assertIn("multiWriterDownloadReady", active_jobs)
        self.assertIn("status: 'ready'", active_jobs)
        self.assertIn("id: { in: activeBatchIds }", active_jobs)
        self.assertIn("if (!multiWriterDownloadReady)", active_jobs)

    def test_sync_job_row_data_is_durable_authorized_and_paged(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]
        data_body = source.split("function sync_job_data_get(", 1)[1].split(
            "function sync_data_storage_status(", 1
        )[0]

        self.assertIn("class SyncJobDataChunk {", source)
        self.assertIn("db.insert(SyncJobDataChunk", upload_body)
        self.assertIn("jobId: job.id", upload_body)
        self.assertIn("batchId: batch.id", upload_body)
        self.assertIn("storageId", upload_body)
        archive_insert = upload_body.split(
            "db.insert(SyncJobDataChunk", 1
        )[1].split("if (archivedChunk == null)", 1)[0]
        self.assertIn("rows: []", archive_insert)
        self.assertIn("can_access_job(current, job)", data_body)
        self.assertIn("sync_job_data_chunk_page(job, cursor)", data_body)
        self.assertIn("payloadBase64", data_body)
        self.assertIn("nextCursor", data_body)

    def test_sync_job_data_retention_keeps_newest_whole_job(self):
        source = read_text("business/control_plane.tru")
        deletion = source.split(
            "function delete_sync_job_data(jobId: string)", 1
        )[1].split("function sync_job_data_owner_stats", 1)[0]
        retention = source.split(
            "function prune_sync_job_data_for_owner(", 1
        )[1].split("function sync_job_data_chunk_page(", 1)[0]
        relay_cleanup = source.split(
            "function cleanup_multi_writer_batches_storage(", 1
        )[1].split("function jobs_cleanup_multi_writer_batch(", 1)[0]

        self.assertIn("field syncDataLimitMb: int? min=1 max=1024", source)
        self.assertIn("storageId: { in: storageIds }", deletion)
        self.assertIn("fields: ['storageId']", deletion)
        self.assertNotIn(
            "sync_job_data_storage_referenced_by_relay(storageId)", deletion
        )
        self.assertIn("protectedJobId", retention)
        self.assertIn("jobId == protectedJobId", retention)
        self.assertIn("delete_sync_job_data(jobId)", retention)
        self.assertIn("totalBytes <= limitBytes", retention)
        self.assertIn("sync_job_data_owner_stats(ownerUserId)", retention)
        self.assertIn("const maxDeletedJobsPerRequest = 20", retention)
        self.assertIn("deletedJobCount >= maxDeletedJobsPerRequest", retention)
        self.assertIn("hasMore: totalBytes > limitBytes", retention)
        self.assertNotIn(
            "prune_sync_job_data_for_owner(ownerUserId, protectedJobId, limitMb)",
            retention,
        )
        self.assertIn("db.aggregate(SyncJobDataChunk", source)
        self.assertIn("where: { sourceJobId: { in: normalizedBatchIds } }", relay_cleanup)
        self.assertIn("where: { storageId: { in: storageIds } }", relay_cleanup)
        self.assertNotIn("sync_job_data_storage_referenced_by_archive(storageId)", relay_cleanup)
        self.assertIn("delete_sync_job_data_batch()", source)

    def test_latest_change_winner_is_durable_across_batches_and_resettable(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]
        download_body = source.split(
            "function jobs_multi_writer_download(", 1
        )[1].split("function jobs_upload_chunk(", 1)[0]
        reset_body = source.split("function server_saved_data_reset(", 1)[1].split(
            "function jobs_upload_chunk_start(", 1
        )[0]

        self.assertIn("class SyncRowWinner {", source)
        self.assertIn("function sync_row_winner_find_by_id(", source)
        self.assertIn("db.upsertMany(SyncRowWinner, pendingWinners, ['id'])", upload_body)
        self.assertIn("db.atomicTransaction(() => {", upload_body)
        self.assertIn("string.base64Utf8Decode(encodedPayload)", upload_body)
        self.assertIn("winnerPolicyApplied", upload_body)
        self.assertIn("acceptedOperationIds", upload_body)
        self.assertIn("serverReceivedAt", upload_body)
        self.assertIn("serverSequence", upload_body)
        self.assertIn("uniqueKeyColumnSets", upload_body)
        self.assertIn("sync_row_logical_winner_refs", upload_body)
        self.assertIn("displacedPrimaryWinnerIds", upload_body)
        self.assertIn("logicalWinnerIds", upload_body)
        self.assertIn("clients report different SQL unique-key definitions", upload_body)
        self.assertIn("acceptedOperationIds", download_body)
        self.assertIn("winnerPolicyApplied", download_body)
        self.assertIn("const durableWinners = db.selectMany(SyncRowWinner", download_body)
        self.assertIn("candidateDurableOperationIds", download_body)
        self.assertIn("operationId: { in: candidateDurableOperationIds }", download_body)
        self.assertIn(
            "string_array_contains(durableWinnerOperationIds, durableOperationId)",
            download_body,
        )
        self.assertIn(
            "durableWinner.operationId).trim() == durableOperationId",
            download_body,
        )
        self.assertIn("delete_sync_row_winner_batch()", reset_body)
        self.assertIn("syncRowWinnerDeletedCount", reset_body)

    def test_only_explicit_delta_tombstones_can_delete(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]
        identity_body = source.split(
            "function sync_row_identity_key(", 1
        )[1].split("function sync_timestamp_compare_ms(", 1)[0]

        self.assertIn("function sync_delete_policy(): string", source)
        self.assertIn("return 'explicit-tombstones-only'", source)
        self.assertIn("if (!payloadIsDelta)", upload_body)
        self.assertIn("delete tombstones are forbidden in full snapshots", upload_body)
        self.assertIn("snapshot absence never deletes data", upload_body)
        self.assertIn("delete tombstone requires every primary key value", upload_body)
        self.assertIn("__sync_change_version", upload_body)
        self.assertIn("__sync_origin_client", upload_body)
        self.assertIn("operation,", upload_body)
        self.assertIn("values: ['physical', physicalKey]", identity_body)
        self.assertNotIn("ParentGUID", identity_body)

    def test_full_union_zombie_row_reasserts_existing_durable_tombstone(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]
        download_body = source.split(
            "function jobs_multi_writer_download(", 1
        )[1].split("function jobs_upload_chunk(", 1)[0]

        self.assertIn("let reassertsDurableTombstone = false", upload_body)
        self.assertIn("multiClientUnionBootstrap &&", upload_body)
        self.assertIn("currentWinner.operation).trim().toUpperCase() == 'D'", upload_body)
        self.assertIn("authoritativeOperation = 'D'", upload_body)
        self.assertIn("durableOperationId = string.from(currentWinner.operationId)", upload_body)
        self.assertIn("durableTombstoneReassertion: reassertsDurableTombstone", upload_body)
        self.assertIn("authoritativeOperation", download_body)
        self.assertIn("candidateOperation.durableTombstoneReassertion == true", download_body)
        self.assertIn("authoritativeOperation == 'D'", download_body)
        self.assertIn("durableTombstoneReassertion", download_body)

    def test_table_row_comparison_is_scoped_read_only_and_multi_client(self):
        source = read_text("business/control_plane.tru")
        request_body = source.split(
            "function table_comparison_request(", 1
        )[1].split("function table_comparison_status(", 1)[0]
        comparison_rows = source.split(
            "function table_comparison_job_rows(", 1
        )[1].split("function create_table_comparison_batch(", 1)[0]
        comparison_batch = source.split(
            "function create_table_comparison_batch(", 1
        )[1].split("function authoritative_reconcile_job_rows(", 1)[0]

        self.assertIn("'server-diff-preview'", comparison_rows)
        self.assertEqual(comparison_rows.count("direction: 'upload'"), 1)
        self.assertNotIn("direction: 'download'", comparison_rows)
        self.assertIn("expectedClients: clientNames", comparison_batch)
        self.assertIn("is_admin_user(current)", request_body)
        self.assertIn("is_owner_user(current)", request_body)
        self.assertIn("sync_table_issue_for_owner", request_body)
        self.assertIn("'needs_input'", request_body)
        self.assertIn("participants.length < 2", request_body)
        self.assertIn("effective_agent_online(agent)", request_body)
        self.assertIn("active_job_tables_for_client", request_body)
        self.assertIn("create_table_comparison_batch", request_body)

    def test_table_row_comparison_upload_skips_winners_and_accepts_full_rows(self):
        source = read_text("business/control_plane.tru")
        upload_body = source.split(
            "function jobs_multi_writer_upload(", 1
        )[1].split("function jobs_multi_writer_download(", 1)[0]

        self.assertIn("const comparisonPreview", upload_body)
        self.assertIn("'server-diff-preview'", upload_body)
        self.assertIn(
            "!multiClientUnionBootstrap",
            upload_body,
        )
        self.assertIn(
            "const winnerPolicyApplied = payloadIsDelta || multiClientUnionBootstrap",
            upload_body,
        )
        self.assertIn("matchesDurableWinnerContent", upload_body)
        self.assertIn("let currentWinner = null", upload_body)
        self.assertIn("let matchesDurableWinnerContent = false", upload_body)
        self.assertNotIn("const matchesDurableWinnerContent =", upload_body)
        self.assertIn("incomingRowHash == string.from(currentWinner.rowHash).trim()", upload_body)
        self.assertIn("operation != 'D'", upload_body)
        self.assertIn(
            "string.from(currentWinner.operation).trim().toUpperCase() != 'D'",
            upload_body,
        )
        self.assertIn("!matchesDurableWinnerContent", upload_body)
        self.assertIn("const relayedWinner = {", upload_body)
        self.assertIn("serverSequence: currentWinner.serverSequence", upload_body)
        self.assertIn("modifiedAtUtc: currentWinner.modifiedAtUtc", upload_body)
        self.assertIn("pendingWinners, relayedWinner", upload_body)
        self.assertIn("durableOperationId,", upload_body)
        self.assertIn("db.insert(SyncJobDataChunk", upload_body)
        self.assertIn("row comparison requires permanent primary key columns", upload_body)
        self.assertIn("different primary key definitions", upload_body)
        self.assertIn("if (finalChunk && !comparisonPreview)", upload_body)

    def test_union_bootstrap_waits_for_all_clients_and_uses_full_client_snapshots(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("string.from(plan.mode) == 'union_bootstrap'", source)
        self.assertIn(
            "multi-client union bootstrap waits until every enabled client is online",
            source,
        )
        self.assertGreaterEqual(source.count("!preserveChangeTrackingBaselines"), 2)
        self.assertIn("unionBootstrap ? expectedRowCount : 0", source)
        self.assertIn("batch.expectedClients.length >= 2", source)
        self.assertIn("unionBootstrapSnapshot", agent_page)
        self.assertIn("job.sourceClientName == 'server-union-bootstrap-v3'", agent_page)
        self.assertIn("row['__sync_modified_at_utc'] = '1970-01-01T00:00:00.000Z'", agent_page)

    def test_read_only_data_export_credentials_are_heartbeat_only(self):
        source = read_text("business/control_plane.tru")
        public_payload = source.split("function public_agent_payload(", 1)[1].split(
            "function diagnostic_request_pending", 1
        )[0]
        heartbeat = source.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick", 1
        )[0]
        request = source.split("function agent_data_export_request(", 1)[1].split(
            "function agent_data_export_ack", 1
        )[0]

        self.assertIn("dataExport: agent_data_export_payload(agent)", public_payload)
        self.assertNotIn("includeUploadCredentials: true", public_payload)
        self.assertIn("agent_data_export_payload(deliveryAgent, true)", heartbeat)
        self.assertIn("agent_diagnostics_payload(deliveryAgent, false, true)", heartbeat)
        self.assertIn("export database must match the client selected database", request)
        self.assertIn("https://sync.velvet-leaf.com/private-export", request)
        self.assertIn("dataExportUploadToken", source)
        self.assertIn("terminalStatus", source)


if __name__ == "__main__":
    unittest.main()
