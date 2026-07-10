import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ControlPlaneContractsTests(unittest.TestCase):
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
            r"function public_agent_payload\(agent: map<json>\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertNotIn("db.selectOne(Agent", body)
        self.assertIn("agent_client_update_payload(agent)", body)
        self.assertIn("agent_window_action_payload(agent)", body)

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

        self.assertIn("replicationUseWindowsAuth: bool = true", source)
        self.assertIn("replicationUser: string = ''", source)
        self.assertIn("replicationPassword: string = ''", source)
        self.assertIn("clientUpdate: agent_client_update_payload(nextAgent)", source)
        self.assertNotIn("symmetricDsStatus", source)
        self.assertNotIn("agent_symmetricds_status_post", source)

    def test_control_plane_exposes_server_requested_client_updates(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("field clientUpdateRequestId: string? min=0 max=64", source)
        self.assertIn("field clientUpdateStatus: string min=0 max=32", source)
        self.assertIn("function agent_client_update_payload(agent: map<json>): map<json> {", source)
        self.assertIn("function agent_client_update_request(clientName: string, targetVersion: string? = null, token: string? = null): map<json> {", source)
        self.assertIn("function agent_client_update_request_all(targetVersion: string? = null, token: string? = null): map<json> {", source)
        self.assertIn("function agent_client_update_ack(clientName: string? = null, requestId: string? = null, status: string = 'current', installedVersion: string = '', message: string = '', token: string? = null): map<json> {", source)

    def test_control_plane_exposes_server_requested_window_actions(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("field windowActionRequestId: string? min=0 max=64", source)
        self.assertIn("field windowActionName: string? min=0 max=32", source)
        self.assertIn("function agent_window_action_payload(agent: map<json>): map<json> {", source)
        self.assertIn("function agent_window_action_request_all(action: string = 'minimize', token: string? = null): map<json> {", source)
        self.assertIn("function agent_window_action_ack(clientName: string? = null, requestId: string? = null, action: string = '', status: string = 'completed', message: string = '', token: string? = null): map<json> {", source)

    def test_client_update_payload_and_ack_track_pending_and_last_ack_state(self):
        source = read_text("business/control_plane.tru")

        payload_match = re.search(
            r"function agent_client_update_payload\(agent: map<json>\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(payload_match)
        payload_body = payload_match.group("body")

        self.assertIn("const pending = client_update_request_pending(agent);", payload_body)
        self.assertIn("const waitingForClient = pending_request_awaits_online_client(agent, pending);", payload_body)
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

        self.assertIn("clientUpdateLastRequestId: resolvedRequestIdOrNull,", ack_body)
        self.assertIn("clientUpdateLastAcknowledgedAt: now_iso(),", ack_body)
        self.assertIn("clientUpdateStatus: truncate_text(status.trim(), 32),", ack_body)
        self.assertIn("clientUpdateMessage: truncate_text(message, 4000),", ack_body)
        self.assertIn("clientVersion: nextClientVersion,", ack_body)

    def test_client_update_request_all_only_targets_online_agents(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function agent_client_update_request_all\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("const visibleAgents = visible_agent_rows_for(current);", body)
        self.assertIn("if (!effective_agent_online(agent)) {", body)
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
        self.assertIn("fields: ['clientName', 'machineName', 'server', 'database', 'replicationUseWindowsAuth', 'replicationUser', 'replicationPassword', 'isOnline', 'autoSyncIntervalMinutes', 'serverConnected', 'sqlConnected', 'lastHeartbeat', 'tables', 'clientUserId', 'ownerUserId'],", scheduler_rows_body)
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
        self.assertIn("for (const agent of allAgents) {", auto_tick_body)
        self.assertIn("const ownerJobs = queue_due_periodic_sync_jobs_for_owner(ownerUserId, allAgents);", auto_tick_body)

        owner_match = re.search(
            r"function queue_due_periodic_sync_jobs_for_owner\(ownerUserId: string\? = null, allAgents: array<json>\? = null\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(owner_match)
        owner_body = owner_match.group("body")
        self.assertIn("const sourceAgents = allAgents ?? list_scheduler_agent_rows();", owner_body)
        self.assertIn("for (const agent of sourceAgents) {", owner_body)
        self.assertIn("const agentJobs = queue_due_periodic_sync_jobs_for_agent(agent, sourceAgents);", owner_body)

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
            r"function agent_window_action_payload\(agent: map<json>\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(payload_match)
        payload_body = payload_match.group("body")

        self.assertIn("const pending = window_action_request_pending(agent);", payload_body)
        self.assertIn("const waitingForClient = pending_request_awaits_online_client(agent, pending);", payload_body)
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
            r"function agent_diagnostics_payload\(agent: map<json>, includePayload: bool = false\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(payload_match)
        payload_body = payload_match.group("body")

        self.assertIn("const pending = diagnostic_request_pending(agent);", payload_body)
        self.assertIn("const waitingForClient = pending_request_awaits_online_client(agent, pending);", payload_body)
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

        self.assertIn("windowActionLastRequestId: resolvedRequestIdOrNull,", ack_body)
        self.assertIn("windowActionLastAcknowledgedAt: now_iso(),", ack_body)
        self.assertIn("windowActionName: nextAction,", ack_body)
        self.assertIn("windowActionStatus: truncate_text(status.trim(), 32),", ack_body)
        self.assertIn("windowActionMessage: truncate_text(message, 4000),", ack_body)

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
        self.assertIn("tableRelationships: [],", body)
        self.assertIn("diagnosticStatus: 'idle',", body)
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

    def test_jobs_create_queues_snapshot_sync_for_remote_source(self):
        source = read_text("business/control_plane.tru")

        self.assertIn(
            "const targetAgent = db.selectOne(Agent, { clientName: resolvedClientName });",
            source,
        )
        self.assertIn(
            "nextSourceClientName = preferred_source_client_name_for_agent_table(targetAgent, table, visibleAgents);",
            source,
        )
        self.assertIn(
            "const nextJobs = create_sync_jobs_for_agent(targetAgent, [table], nextSourceClientName);",
            source,
        )
        self.assertIn(
            "function jobs_progress(jobId: string, status: string = 'running', progress: int, message: string, rowCount: int, token: string? = null): map<json> {",
            source,
        )
        self.assertIn("return raw_json_error(404, 'source client not found');", source)
        self.assertIn(
            "message: string.concat('Waiting for source snapshot upload for ', table, '.')",
            source,
        )
        self.assertIn("field syncMode: string min=1 max=32", source)
        self.assertNotIn("mergeRole", source)
        self.assertNotIn("publicationName", source)
        self.assertNotIn("direction: 'sync'", source)
        self.assertNotIn("rowCount: int, direction: string, token: string? = null", source)
        self.assertNotIn("Queued SymmetricDS sync", source)

    def test_snapshot_transport_contract_remains_present(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("function jobs_upload_chunk_start(", source)
        self.assertIn("function jobs_upload_chunk_complete(", source)
        self.assertIn("function jobs_download_snapshot_manifest(", source)
        self.assertIn("function jobs_download_snapshot_chunk(", source)
        self.assertIn("Future<void> _processSnapshotJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayDownloadJob(", agent_page)
        self.assertNotIn("_runDirectQueuedTableSync(", agent_page)

    def test_source_selection_and_related_tables_remain_active(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn(
            "function preferred_source_client_name_for_agent_table(targetAgent: map<json>, table: string, visibleAgents: array<json>): string {",
            source,
        )
        self.assertIn("const sourceClientName = preferred_source_client_name_for_agent_table(agent, table, visibleAgents);", source)
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
        self.assertIn("selectedTable: null,", reset_body)
        self.assertIn("tables: [],", reset_body)
        self.assertIn("diagnosticRequestId: null,", reset_body)
        self.assertIn("diagnosticLastRequestId: null,", reset_body)
        self.assertIn("diagnosticStatus: 'idle',", reset_body)
        self.assertIn("diagnosticSummary: '',", reset_body)
        self.assertIn("diagnosticPayload: '',", reset_body)
        self.assertIn("windowActionRequestId: null,", reset_body)
        self.assertIn("windowActionStatus: 'idle',", reset_body)

        server_reset_match = re.search(
            r"function server_saved_data_reset\(resetAgents: bool = true, token: string\? = null\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(server_reset_match)
        server_reset_body = server_reset_match.group("body")

        self.assertIn("const jobDeletedCount = db.deleteMany(SyncJob, { id: { gte: '' } });", server_reset_body)
        self.assertIn("agentResetCount = reset_all_agent_saved_state();", server_reset_body)
        self.assertIn("jobDeletedCount,", server_reset_body)
        self.assertIn("agentResetCount", server_reset_body)

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

    def test_control_plane_no_longer_advertises_old_sync_engine(self):
        source = read_text("business/control_plane.tru")

        self.assertNotIn("function sync_engine_metadata(): map<json>", source)
        self.assertNotIn("syncEngine: sync_engine_metadata()", source)
        self.assertNotIn("centralStore: 'symmetricds'", source)
        self.assertNotIn("mode: 'symmetricDs'", source)


if __name__ == "__main__":
    unittest.main()
