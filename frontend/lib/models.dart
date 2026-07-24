class AuthenticatedUser {
  const AuthenticatedUser({
    required this.id,
    required this.username,
    required this.email,
    required this.name,
    required this.role,
    required this.ownerUserId,
    required this.ownerUsername,
    required this.ownerEmail,
    required this.ownerName,
    required this.createdByUserId,
    required this.createdAt,
  });

  final String id;
  final String username;
  final String email;
  final String name;
  final String role;
  final String? ownerUserId;
  final String? ownerUsername;
  final String? ownerEmail;
  final String? ownerName;
  final String? createdByUserId;
  final String createdAt;

  factory AuthenticatedUser.fromJson(Map<String, dynamic> json) {
    return AuthenticatedUser(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      email: json['email'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      ownerUserId: json['ownerUserId'] as String?,
      ownerUsername: json['ownerUsername'] as String?,
      ownerEmail: json['ownerEmail'] as String?,
      ownerName: json['ownerName'] as String?,
      createdByUserId: json['createdByUserId'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'email': email,
    'name': name,
    'role': role,
    'ownerUserId': ownerUserId,
    'ownerUsername': ownerUsername,
    'ownerEmail': ownerEmail,
    'ownerName': ownerName,
    'createdByUserId': createdByUserId,
    'createdAt': createdAt,
  };

  bool get isAdmin => role == 'admin';
  bool get isOwner => role == 'owner';
  bool get isClient => role == 'client';
  bool get canManageUsers => isAdmin || isOwner;
}

class AuthLoginResult {
  const AuthLoginResult({required this.token, required this.user});

  final String token;
  final AuthenticatedUser user;
}

class AdminLiveState {
  const AdminLiveState({
    required this.generatedAt,
    required this.automaticSyncPaused,
    required this.syncGate,
    required this.agents,
    required this.jobs,
  });

  final String generatedAt;
  final bool automaticSyncPaused;
  final AdminSyncGate syncGate;
  final List<AdminAgent> agents;
  final List<AdminJob> jobs;

  factory AdminLiveState.fromJson(Map<String, dynamic> json) {
    return AdminLiveState(
      generatedAt: json['generatedAt'] as String? ?? '',
      automaticSyncPaused: json['automaticSyncPaused'] as bool? ?? false,
      syncGate: AdminSyncGate.fromJson(
        Map<String, dynamic>.from(json['syncGate'] as Map? ?? const {}),
      ),
      agents: (json['agents'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                AdminAgent.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false),
      jobs: (json['jobs'] as List<dynamic>? ?? const [])
          .map(
            (item) => AdminJob.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false),
    );
  }
}

class AdminSyncGate {
  const AdminSyncGate({
    required this.blocked,
    required this.status,
    required this.issueCount,
    required this.message,
    required this.issues,
  });

  final bool blocked;
  final String status;
  final int issueCount;
  final String message;
  final List<AdminTableSyncIssue> issues;

  factory AdminSyncGate.fromJson(Map<String, dynamic> json) {
    return AdminSyncGate(
      blocked: json['blocked'] as bool? ?? false,
      status: json['status'] as String? ?? 'ready',
      issueCount: (json['issueCount'] as num? ?? 0).round(),
      message:
          json['message'] as String? ??
          'Every table is ready for synchronization.',
      issues: (json['issues'] as List<dynamic>? ?? const [])
          .map(
            (item) => AdminTableSyncIssue.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
    );
  }
}

class AdminTableSyncIssue {
  const AdminTableSyncIssue({
    required this.ownerUserId,
    required this.table,
    required this.status,
    required this.reason,
    required this.message,
    required this.clientName,
    required this.action,
    required this.sourceClientName,
    required this.targetClientNames,
    required this.detectedAt,
    required this.updatedAt,
    required this.resolvedAt,
  });

  final String ownerUserId;
  final String table;
  final String status;
  final String reason;
  final String message;
  final String clientName;
  final String action;
  final String sourceClientName;
  final List<String> targetClientNames;
  final String detectedAt;
  final String updatedAt;
  final String resolvedAt;

  bool get needsInput => status.toLowerCase() == 'needs_input';
  bool get resolving => status.toLowerCase() == 'resolving';
  bool get blocksSync => needsInput || resolving;

  factory AdminTableSyncIssue.fromJson(Map<String, dynamic> json) {
    return AdminTableSyncIssue(
      ownerUserId: json['ownerUserId'] as String? ?? '',
      table: json['table'] as String? ?? '',
      status: json['status'] as String? ?? 'ready',
      reason: json['reason'] as String? ?? '',
      message: json['message'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      action: json['action'] as String? ?? '',
      sourceClientName: json['sourceClientName'] as String? ?? '',
      targetClientNames: (json['targetClientNames'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
      detectedAt: json['detectedAt']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
      resolvedAt: json['resolvedAt']?.toString() ?? '',
    );
  }
}

class AdminAgent {
  const AdminAgent({
    required this.clientName,
    required this.clientUserId,
    required this.ownerUserId,
    required this.machineName,
    required this.server,
    required this.database,
    required this.syncEnabled,
    required this.isOnline,
    required this.historyLimit,
    required this.autoSyncIntervalMinutes,
    required this.serverConnected,
    required this.sqlConnected,
    required this.clientVersion,
    required this.lastHeartbeat,
    required this.selectedTable,
    required this.diagnostics,
    required this.clientUpdate,
    required this.tables,
  });

  final String clientName;
  final String? clientUserId;
  final String? ownerUserId;
  final String machineName;
  final String server;
  final String database;
  final bool syncEnabled;
  final bool isOnline;
  final int historyLimit;
  final int autoSyncIntervalMinutes;
  final bool serverConnected;
  final bool sqlConnected;
  final String clientVersion;
  final String lastHeartbeat;
  final String? selectedTable;
  final AdminAgentDiagnostics diagnostics;
  final AdminAgentClientUpdate clientUpdate;
  final List<AdminTableState> tables;

  factory AdminAgent.fromJson(Map<String, dynamic> json) {
    return AdminAgent(
      clientName: json['clientName'] as String? ?? '',
      clientUserId: json['clientUserId'] as String?,
      ownerUserId: json['ownerUserId'] as String?,
      machineName: json['machineName'] as String? ?? '',
      server: json['server'] as String? ?? '',
      database: json['database'] as String? ?? '',
      syncEnabled: json['syncEnabled'] as bool? ?? true,
      isOnline: json['isOnline'] as bool? ?? false,
      historyLimit: (json['historyLimit'] as num? ?? 5).round(),
      autoSyncIntervalMinutes:
          (json['autoSyncIntervalMinutes'] as num? ?? 15).round(),
      serverConnected: json['serverConnected'] as bool? ?? false,
      sqlConnected: json['sqlConnected'] as bool? ?? false,
      clientVersion: json['clientVersion'] as String? ?? '',
      lastHeartbeat: json['lastHeartbeat'] as String? ?? '',
      selectedTable: json['selectedTable'] as String?,
      diagnostics:
          json['diagnostics'] is Map
              ? AdminAgentDiagnostics.fromJson(
                Map<String, dynamic>.from(json['diagnostics'] as Map),
              )
              : const AdminAgentDiagnostics(),
      clientUpdate:
          json['clientUpdate'] is Map
              ? AdminAgentClientUpdate.fromJson(
                Map<String, dynamic>.from(json['clientUpdate'] as Map),
              )
              : const AdminAgentClientUpdate(),
      tables: (json['tables'] as List<dynamic>? ?? const [])
          .map(
            (item) => AdminTableState.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
    );
  }
}

class AdminAgentClientUpdate {
  const AdminAgentClientUpdate({
    this.pending = false,
    this.requestId,
    this.requestedAt,
    this.requestedByUserId,
    this.targetVersion,
    this.lastRequestId,
    this.acknowledgedAt,
    this.status = 'idle',
    this.message = '',
  });

  final bool pending;
  final String? requestId;
  final String? requestedAt;
  final String? requestedByUserId;
  final String? targetVersion;
  final String? lastRequestId;
  final String? acknowledgedAt;
  final String status;
  final String message;

  factory AdminAgentClientUpdate.fromJson(Map<String, dynamic> json) {
    return AdminAgentClientUpdate(
      pending: json['pending'] as bool? ?? false,
      requestId: json['requestId'] as String? ?? '',
      requestedAt: json['requestedAt'] as String?,
      requestedByUserId: json['requestedByUserId'] as String?,
      targetVersion: json['targetVersion'] as String?,
      lastRequestId: json['lastRequestId'] as String?,
      acknowledgedAt: json['acknowledgedAt'] as String?,
      status: json['status'] as String? ?? 'idle',
      message: json['message'] as String? ?? '',
    );
  }
}

class AdminAgentDiagnostics {
  const AdminAgentDiagnostics({
    this.pending = false,
    this.requestId,
    this.requestedAt,
    this.requestedByUserId,
    this.uploadedAt,
    this.lastRequestId,
    this.status = 'idle',
    this.summary = '',
    this.payload,
  });

  final bool pending;
  final String? requestId;
  final String? requestedAt;
  final String? requestedByUserId;
  final String? uploadedAt;
  final String? lastRequestId;
  final String status;
  final String summary;
  final String? payload;

  factory AdminAgentDiagnostics.fromJson(Map<String, dynamic> json) {
    return AdminAgentDiagnostics(
      pending: json['pending'] as bool? ?? false,
      requestId: json['requestId'] as String?,
      requestedAt: json['requestedAt'] as String?,
      requestedByUserId: json['requestedByUserId'] as String?,
      uploadedAt: json['uploadedAt'] as String?,
      lastRequestId: json['lastRequestId'] as String?,
      status: json['status'] as String? ?? 'idle',
      summary: json['summary'] as String? ?? '',
      payload: json['payload'] as String?,
    );
  }

  bool get hasReport =>
      (uploadedAt?.trim().isNotEmpty ?? false) ||
      summary.trim().isNotEmpty ||
      (payload?.trim().isNotEmpty ?? false);
}

class AdminBulkSyncResult {
  const AdminBulkSyncResult({
    required this.queuedJobCount,
    required this.queuedClientCount,
    required this.skippedOfflineClients,
    required this.skippedBusyTables,
  });

  final int queuedJobCount;
  final int queuedClientCount;
  final List<String> skippedOfflineClients;
  final List<String> skippedBusyTables;

  factory AdminBulkSyncResult.fromJson(Map<String, dynamic> json) {
    return AdminBulkSyncResult(
      queuedJobCount: (json['queuedJobCount'] as num? ?? 0).round(),
      queuedClientCount: (json['queuedClientCount'] as num? ?? 0).round(),
      skippedOfflineClients: (json['skippedOfflineClients'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
      skippedBusyTables: (json['skippedBusyTables'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}

class AdminBulkDiagnosticsRequestResult {
  const AdminBulkDiagnosticsRequestResult({
    required this.requestId,
    required this.requestedAt,
    required this.requestedByUserId,
    required this.requestedClientCount,
    required this.requestedClientNames,
  });

  final String requestId;
  final String requestedAt;
  final String? requestedByUserId;
  final int requestedClientCount;
  final List<String> requestedClientNames;

  factory AdminBulkDiagnosticsRequestResult.fromJson(
    Map<String, dynamic> json,
  ) {
    return AdminBulkDiagnosticsRequestResult(
      requestId: json['requestId'] as String? ?? '',
      requestedAt: json['requestedAt'] as String? ?? '',
      requestedByUserId: json['requestedByUserId'] as String?,
      requestedClientCount: (json['requestedClientCount'] as num? ?? 0).round(),
      requestedClientNames: (json['requestedClientNames'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}

class AdminBulkClientUpdateRequestResult {
  const AdminBulkClientUpdateRequestResult({
    required this.requestId,
    required this.requestedAt,
    required this.requestedByUserId,
    required this.requestedClientCount,
    required this.requestedClientNames,
  });

  final String requestId;
  final String requestedAt;
  final String? requestedByUserId;
  final int requestedClientCount;
  final List<String> requestedClientNames;

  factory AdminBulkClientUpdateRequestResult.fromJson(
    Map<String, dynamic> json,
  ) {
    return AdminBulkClientUpdateRequestResult(
      requestId: json['requestId'] as String? ?? '',
      requestedAt: json['requestedAt'] as String? ?? '',
      requestedByUserId: json['requestedByUserId'] as String?,
      requestedClientCount: (json['requestedClientCount'] as num? ?? 0).round(),
      requestedClientNames: (json['requestedClientNames'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}

class AdminBulkWindowActionRequestResult {
  const AdminBulkWindowActionRequestResult({
    required this.action,
    required this.requestId,
    required this.requestedAt,
    required this.requestedByUserId,
    required this.requestedClientCount,
    required this.requestedClientNames,
  });

  final String action;
  final String requestId;
  final String requestedAt;
  final String? requestedByUserId;
  final int requestedClientCount;
  final List<String> requestedClientNames;

  factory AdminBulkWindowActionRequestResult.fromJson(
    Map<String, dynamic> json,
  ) {
    return AdminBulkWindowActionRequestResult(
      action: json['action'] as String? ?? '',
      requestId: json['requestId'] as String? ?? '',
      requestedAt: json['requestedAt'] as String? ?? '',
      requestedByUserId: json['requestedByUserId'] as String?,
      requestedClientCount: (json['requestedClientCount'] as num? ?? 0).round(),
      requestedClientNames: (json['requestedClientNames'] as List<dynamic>? ??
              const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}

class AdminServerResetResult {
  const AdminServerResetResult({
    required this.cancelledJobCount,
    required this.deletedRecordCount,
    required this.jobDeletedCount,
    required this.agentResetCount,
    required this.cleanupStatus,
    required this.automaticSyncPaused,
  });

  final int cancelledJobCount;
  final int deletedRecordCount;
  final int jobDeletedCount;
  final int agentResetCount;
  final String cleanupStatus;
  final bool automaticSyncPaused;

  bool get cleaned => cleanupStatus == 'cleaned';

  factory AdminServerResetResult.fromJson(Map<String, dynamic> json) {
    return AdminServerResetResult(
      cancelledJobCount: (json['cancelledJobCount'] as num? ?? 0).round(),
      deletedRecordCount: (json['deletedRecordCount'] as num? ?? 0).round(),
      jobDeletedCount: (json['jobDeletedCount'] as num? ?? 0).round(),
      agentResetCount: (json['agentResetCount'] as num? ?? 0).round(),
      cleanupStatus: json['cleanupStatus'] as String? ?? 'cleaned',
      automaticSyncPaused: json['automaticSyncPaused'] as bool? ?? true,
    );
  }
}

class AdminTableState {
  const AdminTableState({
    required this.table,
    required this.enabled,
    required this.status,
    required this.lastSync,
    required this.progress,
    required this.rowCount,
    required this.message,
  });

  final String table;
  final bool enabled;
  final String status;
  final String lastSync;
  final int progress;
  final int rowCount;
  final String message;

  factory AdminTableState.fromJson(Map<String, dynamic> json) {
    return AdminTableState(
      table: json['table'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      status: json['status'] as String? ?? 'Paused',
      lastSync: json['lastSync'] as String? ?? '',
      progress: (json['progress'] as num? ?? 0).round(),
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      message: json['message'] as String? ?? '',
    );
  }

  bool get inProgress =>
      status.toLowerCase() == 'running' ||
      status.toLowerCase() == 'snapshotting' ||
      status.toLowerCase() == 'uploading' ||
      status.toLowerCase() == 'downloading' ||
      status.toLowerCase() == 'applying';
}

class AdminJob {
  const AdminJob({
    required this.id,
    required this.clientName,
    required this.sourceClientName,
    required this.subscriberClientName,
    required this.table,
    required this.direction,
    required this.publisherServer,
    required this.publisherDatabase,
    required this.publisherUseWindowsAuth,
    required this.status,
    required this.progress,
    required this.rowCount,
    required this.changedRowCount,
    this.rejectedRowCount = 0,
    this.rejectionSummary,
    required this.createdAt,
    required this.updatedAt,
    required this.startedAt,
    required this.completedAt,
    required this.message,
    required this.error,
    required this.snapshotId,
    required this.batchId,
  });

  final String id;
  final String clientName;
  final String sourceClientName;
  final String subscriberClientName;
  final String table;
  final String direction;
  final String publisherServer;
  final String publisherDatabase;
  final bool publisherUseWindowsAuth;
  final String status;
  final int progress;
  final int rowCount;
  final int? changedRowCount;
  final int rejectedRowCount;
  final String? rejectionSummary;
  final String createdAt;
  final String updatedAt;
  final String? startedAt;
  final String? completedAt;
  final String message;
  final String? error;
  final String? snapshotId;
  final String batchId;

  factory AdminJob.fromJson(Map<String, dynamic> json) {
    return AdminJob(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      sourceClientName: json['sourceClientName'] as String? ?? '',
      subscriberClientName: json['subscriberClientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      direction: json['direction'] as String? ?? '',
      publisherServer: json['publisherServer'] as String? ?? '',
      publisherDatabase: json['publisherDatabase'] as String? ?? '',
      publisherUseWindowsAuth: json['publisherUseWindowsAuth'] as bool? ?? true,
      status: json['status'] as String? ?? 'queued',
      progress: (json['progress'] as num? ?? 0).round(),
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      changedRowCount: (json['changedRowCount'] as num?)?.round(),
      rejectedRowCount: (json['rejectedRowCount'] as num? ?? 0).round(),
      rejectionSummary: json['rejectionSummary'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      startedAt: json['startedAt'] as String?,
      completedAt: json['completedAt'] as String?,
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
      snapshotId: json['snapshotId'] as String?,
      batchId: json['batchId'] as String? ?? '',
    );
  }

  bool get isActive =>
      status.toLowerCase() == 'queued' ||
      status.toLowerCase() == 'running' ||
      status.toLowerCase() == 'snapshotting' ||
      status.toLowerCase() == 'uploading' ||
      status.toLowerCase() == 'downloading' ||
      status.toLowerCase() == 'applying';
}
