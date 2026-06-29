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
    required this.agents,
    required this.jobs,
  });

  final String generatedAt;
  final List<AdminAgent> agents;
  final List<AdminJob> jobs;

  factory AdminLiveState.fromJson(Map<String, dynamic> json) {
    return AdminLiveState(
      generatedAt: json['generatedAt'] as String? ?? '',
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

class AdminAgent {
  const AdminAgent({
    required this.clientName,
    required this.clientUserId,
    required this.ownerUserId,
    required this.machineName,
    required this.server,
    required this.database,
    required this.isOnline,
    required this.historyLimit,
    required this.autoSyncIntervalMinutes,
    required this.serverConnected,
    required this.sqlConnected,
    required this.clientVersion,
    required this.lastHeartbeat,
    required this.selectedTable,
    required this.symmetricDs,
    required this.diagnostics,
    required this.tables,
  });

  final String clientName;
  final String? clientUserId;
  final String? ownerUserId;
  final String machineName;
  final String server;
  final String database;
  final bool isOnline;
  final int historyLimit;
  final int autoSyncIntervalMinutes;
  final bool serverConnected;
  final bool sqlConnected;
  final String clientVersion;
  final String lastHeartbeat;
  final String? selectedTable;
  final AdminAgentSymmetricDs symmetricDs;
  final AdminAgentDiagnostics diagnostics;
  final List<AdminTableState> tables;

  factory AdminAgent.fromJson(Map<String, dynamic> json) {
    return AdminAgent(
      clientName: json['clientName'] as String? ?? '',
      clientUserId: json['clientUserId'] as String?,
      ownerUserId: json['ownerUserId'] as String?,
      machineName: json['machineName'] as String? ?? '',
      server: json['server'] as String? ?? '',
      database: json['database'] as String? ?? '',
      isOnline: json['isOnline'] as bool? ?? false,
      historyLimit: (json['historyLimit'] as num? ?? 5).round(),
      autoSyncIntervalMinutes:
          (json['autoSyncIntervalMinutes'] as num? ?? 15).round(),
      serverConnected: json['serverConnected'] as bool? ?? false,
      sqlConnected: json['sqlConnected'] as bool? ?? false,
      clientVersion: json['clientVersion'] as String? ?? '',
      lastHeartbeat: json['lastHeartbeat'] as String? ?? '',
      selectedTable: json['selectedTable'] as String?,
      symmetricDs:
          json['symmetricDs'] is Map
              ? AdminAgentSymmetricDs.fromJson(
                Map<String, dynamic>.from(json['symmetricDs'] as Map),
              )
              : const AdminAgentSymmetricDs(),
      diagnostics:
          json['diagnostics'] is Map
              ? AdminAgentDiagnostics.fromJson(
                Map<String, dynamic>.from(json['diagnostics'] as Map),
              )
              : const AdminAgentDiagnostics(),
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

class AdminAgentSymmetricDs {
  const AdminAgentSymmetricDs({
    this.status = 'unknown',
    this.configPath = '',
    this.message = '',
    this.configuredAt,
  });

  final String status;
  final String configPath;
  final String message;
  final String? configuredAt;

  bool get configured => status == 'configured';

  factory AdminAgentSymmetricDs.fromJson(Map<String, dynamic> json) {
    return AdminAgentSymmetricDs(
      status: json['status'] as String? ?? 'unknown',
      configPath: json['configPath'] as String? ?? '',
      message: json['message'] as String? ?? '',
      configuredAt: json['configuredAt'] as String?,
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

class AdminServerResetResult {
  const AdminServerResetResult({
    required this.jobDeletedCount,
    required this.agentResetCount,
    required this.hasMore,
    required this.totalDeletedCount,
  });

  final int jobDeletedCount;
  final int agentResetCount;
  final bool hasMore;
  final int totalDeletedCount;

  factory AdminServerResetResult.fromJson(Map<String, dynamic> json) {
    return AdminServerResetResult(
      jobDeletedCount: (json['jobDeletedCount'] as num? ?? 0).round(),
      agentResetCount: (json['agentResetCount'] as num? ?? 0).round(),
      hasMore: json['hasMore'] as bool? ?? false,
      totalDeletedCount: (json['totalDeletedCount'] as num? ?? 0).round(),
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
    required this.direction,
    required this.syncMode,
    required this.rowCount,
    required this.message,
  });

  final String table;
  final bool enabled;
  final String status;
  final String lastSync;
  final int progress;
  final String direction;
  final String syncMode;
  final int rowCount;
  final String message;

  factory AdminTableState.fromJson(Map<String, dynamic> json) {
    return AdminTableState(
      table: json['table'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      status: json['status'] as String? ?? 'Paused',
      lastSync: json['lastSync'] as String? ?? '',
      progress: (json['progress'] as num? ?? 0).round(),
      direction: json['direction'] as String? ?? 'sync',
      syncMode: json['syncMode'] as String? ?? 'sync',
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
    required this.mergeRole,
    required this.publisherServer,
    required this.publisherDatabase,
    required this.publicationName,
    required this.publisherUseWindowsAuth,
    required this.status,
    required this.progress,
    required this.rowCount,
    required this.createdAt,
    required this.updatedAt,
    required this.startedAt,
    required this.completedAt,
    required this.message,
    required this.error,
  });

  final String id;
  final String clientName;
  final String sourceClientName;
  final String subscriberClientName;
  final String table;
  final String direction;
  final String mergeRole;
  final String publisherServer;
  final String publisherDatabase;
  final String publicationName;
  final bool publisherUseWindowsAuth;
  final String status;
  final int progress;
  final int rowCount;
  final String createdAt;
  final String updatedAt;
  final String? startedAt;
  final String? completedAt;
  final String message;
  final String? error;

  factory AdminJob.fromJson(Map<String, dynamic> json) {
    return AdminJob(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      sourceClientName: json['sourceClientName'] as String? ?? '',
      subscriberClientName: json['subscriberClientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      direction: json['direction'] as String? ?? 'sync',
      mergeRole: json['mergeRole'] as String? ?? '',
      publisherServer: json['publisherServer'] as String? ?? '',
      publisherDatabase: json['publisherDatabase'] as String? ?? '',
      publicationName: json['publicationName'] as String? ?? '',
      publisherUseWindowsAuth: json['publisherUseWindowsAuth'] as bool? ?? true,
      status: json['status'] as String? ?? 'queued',
      progress: (json['progress'] as num? ?? 0).round(),
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      startedAt: json['startedAt'] as String?,
      completedAt: json['completedAt'] as String?,
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
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
