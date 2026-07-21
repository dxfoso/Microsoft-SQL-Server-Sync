import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ControlPlaneContractsTests(unittest.TestCase):
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

    def test_cancel_active_jobs_includes_waiting_relay_jobs(self):
        source = read_text("business/control_plane.tru")

        self.assertIn(
            "normalized == 'queued' || normalized == 'waiting' || normalized == 'running'",
            source,
        )
        self.assertIn("cleanup_multi_writer_batch_storage(batchId)", source)
        self.assertIn("function jobs_cleanup_multi_writer_batch(", source)

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
        self.assertIn("if (automatic_sync_is_paused()) {", auto_tick_body)
        self.assertIn("for (const agent of allAgents) {", auto_tick_body)
        self.assertIn(
            "const hasManualPendingTables = manual_sync_pending_tables_for_owner(ownerUserId).length > 0;",
            auto_tick_body,
        )
        self.assertIn(
            "claim_periodic_sync_scheduler_for_owner(ownerUserId, hasManualPendingTables)",
            auto_tick_body,
        )
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
        self.assertIn("create_multi_writer_batch(ownerUserId, table, tableAgents)", owner_body)
        self.assertIn("const tableCaches = ownerAgents.map((agent) => scheduler_agent_table_state_cache(agent, ownerPolicies));", owner_body)
        self.assertIn("const sourceAgents = allAgents ?? list_scheduler_agent_rows();", owner_body)
        self.assertIn("for (const agent of ownerAgents) {", owner_body)
        self.assertIn("const activeTableCaches = ownerAgents.map", owner_body)
        self.assertIn("if (cache.tables.length > 0)", owner_body)
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
        self.assertIn("set_owner_automatic_sync_paused(current.id, paused)", control_body)
        self.assertIn("controlOwnerUserId = '__automatic_sync_control__'", control_body)
        self.assertIn("automaticSyncPaused: paused", control_body)
        self.assertIn("function automatic_sync_is_paused_for_owner", source)
        self.assertIn("if (automatic_sync_is_paused_for_owner(ownerUserId))", source)

    def test_manual_sync_all_defers_when_owner_has_active_batch_work(self):
        source = read_text("business/control_plane.tru")
        body = source.split("function jobs_create_all_enabled(", 1)[1].split(
            "function reset_all_agent_saved_state(", 1
        )[0]

        self.assertIn("let ownerHasActiveJobs = false;", body)
        self.assertIn(
            "const activeTableCaches = onlineAgents.map",
            body,
        )
        self.assertIn("if (cache.tables.length > 0)", body)
        self.assertIn("if (ownerHasActiveJobs) {", body)
        self.assertIn("deferredTables = deferredTables.concat(", body)
        self.assertIn("let ownerDeferredTables = [];", body)
        self.assertIn(
            "set_manual_sync_pending_tables_for_owner(ownerUserId, ownerDeferredTables);",
            body,
        )
        claim_body = source.split(
            "function claim_periodic_sync_scheduler_for_owner(", 1
        )[1].split("function manual_sync_pending_tables_for_owner(", 1)[0]
        self.assertIn("bypassCooldown: bool? = false", claim_body)
        self.assertIn("if (bypassCooldown != true &&", claim_body)
        self.assertNotIn("bool.from(", claim_body)

        preferred_source_match = re.search(
            r"function preferred_source_client_name_for_agent_table\(targetAgent: map<json>, table: string, visibleAgents: array<json>, ownerPolicies: array<json>\? = null, allTableCaches: array<json>\? = null, completedJobRows: array<json>\? = null\): string \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(preferred_source_match)
        preferred_source_body = preferred_source_match.group("body")
        self.assertIn("const targetTableCache = scheduler_agent_table_state_cache_for_agent(targetClientName, allTableCaches ?? []);", preferred_source_body)
        self.assertIn("const targetRowCount = live_row_count_for_agent_table(targetAgent, table, ownerPolicies, targetTableCache, completedJobRows);", preferred_source_body)
        self.assertIn("const targetChecksum = live_checksum_for_agent_table(targetAgent, table, ownerPolicies, targetTableCache);", preferred_source_body)
        self.assertIn("const candidateTableCache = scheduler_agent_table_state_cache_for_agent(string.from(candidate.clientName), allTableCaches ?? []);", preferred_source_body)
        self.assertIn("if (!agent_table_sync_enabled(candidate, table, ownerPolicies, candidateTableCache)) {", preferred_source_body)
        self.assertIn("const rememberedSource = latest_completed_source_for_target_table(string.from(targetAgent.clientName), table, completedJobRows);", preferred_source_body)

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
        self.assertIn("if (candidate.ageMinutes > selectedAgeMinutes) {", due_body)
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
        self.assertIn("let dueTables = manualPendingTables;", owner_scheduler)
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

    def test_source_selection_and_related_tables_remain_active(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn(
            "function preferred_source_client_name_for_agent_table(targetAgent: map<json>, table: string, visibleAgents: array<json>, ownerPolicies: array<json>? = null, allTableCaches: array<json>? = null, completedJobRows: array<json>? = null): string {",
            source,
        )
        self.assertIn("const sourceClientName = preferred_source_client_name_for_agent_table(agent, table, peerAgents, ownerPolicies, allTableCaches, completedJobRows);", source)
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
        self.assertIn("isOnline: false,", reset_body)
        self.assertIn("serverConnected: false,", reset_body)
        self.assertIn("sqlConnected: false,", reset_body)
        self.assertIn("clientVersion: '',", reset_body)
        self.assertIn("lastHeartbeat: '',", reset_body)
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
        self.assertIn("hasMore: snapshotBatch.hasMore == true", server_reset_body)
        storage_cleanup = source.split("function delete_snapshot_storage_batch(", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("db.selectMany(SnapshotRecord", storage_cleanup)
        self.assertIn("limit: 50", storage_cleanup)
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
        self.assertIn("if (incomingRowCount > 500)", source)
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

        self.assertIn("mode: 'multi-writer'", source)
        self.assertIn("if (effective_agent_online(agent))", source)
        self.assertIn("create_multi_writer_batch(ownerUserId, table, tableAgents)", source)
        self.assertIn("if (string_array_contains(agentTables, table))", source)
        self.assertIn("function multi_writer_batch_stale(batch: map<json>): bool", source)
        self.assertIn("return raw_json_error(410, 'sync job is no longer active');", source)
        stale_guard = source.split(
            "function multi_writer_batch_stale(batch: map<json>): bool", 1
        )[1].split("function ", 1)[0]
        self.assertIn("batch.updatedAt", stale_guard)
        self.assertNotIn("batch.createdAt", stale_guard)
        self.assertIn("let queuedTablesForOwner = 0;", source)
        self.assertIn(
            "remaining manual tables will drain in bounded scheduler waves",
            source,
        )
        self.assertIn("Periodic sync uses the same multi-writer barrier as manual Sync All", source)
        self.assertIn("every online client uploads first, then every client downloads the merge", source)
        self.assertIn("skippedOfflineClients", source)

    def test_multi_writer_repairs_fingerprint_divergence_with_full_snapshots(self):
        source = read_text("business/control_plane.tru")

        self.assertIn(
            "function multi_writer_agents_have_fingerprint_mismatch(",
            source,
        )
        self.assertIn("return fingerprints.length > 1;", source)
        self.assertIn("'server-anti-entropy'", source)
        self.assertIn(
            "const forceFullSnapshot = multi_writer_agents_have_fingerprint_mismatch(table, agents);",
            source,
        )
        self.assertIn("{ field: 'subscriberClientName', dir: 'asc' }", source)

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
        self.assertIn("where: { status: 'ready' }", active_jobs)
        self.assertIn("if (!multiWriterDownloadReady)", active_jobs)


if __name__ == "__main__":
    unittest.main()
