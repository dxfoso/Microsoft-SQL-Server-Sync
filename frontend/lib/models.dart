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
    required this.snapshots,
  });

  final String generatedAt;
  final List<AdminAgent> agents;
  final List<AdminJob> jobs;
  final List<AdminSnapshot> snapshots;

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
      snapshots: (json['snapshots'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                AdminSnapshot.fromJson(Map<String, dynamic>.from(item as Map)),
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
    required this.isMaster,
    required this.historyLimit,
    required this.autoSyncIntervalMinutes,
    required this.serverConnected,
    required this.sqlConnected,
    required this.lastHeartbeat,
    required this.selectedTable,
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
  final bool isMaster;
  final int historyLimit;
  final int autoSyncIntervalMinutes;
  final bool serverConnected;
  final bool sqlConnected;
  final String lastHeartbeat;
  final String? selectedTable;
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
      isMaster: json['isMaster'] as bool? ?? true,
      historyLimit: (json['historyLimit'] as num? ?? 5).round(),
      autoSyncIntervalMinutes:
          (json['autoSyncIntervalMinutes'] as num? ?? 15).round(),
      serverConnected: json['serverConnected'] as bool? ?? false,
      sqlConnected: json['sqlConnected'] as bool? ?? false,
      lastHeartbeat: json['lastHeartbeat'] as String? ?? '',
      selectedTable: json['selectedTable'] as String?,
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
    required this.snapshotId,
    required this.snapshotCreatedAt,
    required this.snapshotBytes,
    required this.message,
    required this.mergedSnapshotSources,
  });

  final String table;
  final bool enabled;
  final String status;
  final String lastSync;
  final int progress;
  final String direction;
  final String syncMode;
  final int rowCount;
  final String? snapshotId;
  final String? snapshotCreatedAt;
  final int snapshotBytes;
  final String message;
  final Map<String, String> mergedSnapshotSources;

  factory AdminTableState.fromJson(Map<String, dynamic> json) {
    return AdminTableState(
      table: json['table'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      status: json['status'] as String? ?? 'Paused',
      lastSync: json['lastSync'] as String? ?? '',
      progress: (json['progress'] as num? ?? 0).round(),
      direction: json['direction'] as String? ?? 'upload',
      syncMode: json['syncMode'] as String? ?? 'master',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      snapshotId: json['snapshotId'] as String?,
      snapshotCreatedAt: json['snapshotCreatedAt'] as String?,
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      message: json['message'] as String? ?? '',
      mergedSnapshotSources: (json['mergedSnapshotSources']
                  as Map<dynamic, dynamic>? ??
              const {})
          .map(
            (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
          ),
    );
  }

  bool get inProgress =>
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
    required this.table,
    required this.direction,
    required this.status,
    required this.progress,
    required this.rowCount,
    required this.createdAt,
    required this.updatedAt,
    required this.startedAt,
    required this.completedAt,
    required this.snapshotId,
    required this.snapshotCreatedAt,
    required this.snapshotBytes,
    required this.message,
    required this.error,
  });

  final String id;
  final String clientName;
  final String sourceClientName;
  final String table;
  final String direction;
  final String status;
  final int progress;
  final int rowCount;
  final String createdAt;
  final String updatedAt;
  final String? startedAt;
  final String? completedAt;
  final String? snapshotId;
  final String? snapshotCreatedAt;
  final int snapshotBytes;
  final String message;
  final String? error;

  factory AdminJob.fromJson(Map<String, dynamic> json) {
    return AdminJob(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      sourceClientName: json['sourceClientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      direction: json['direction'] as String? ?? 'upload',
      status: json['status'] as String? ?? 'queued',
      progress: (json['progress'] as num? ?? 0).round(),
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      startedAt: json['startedAt'] as String?,
      completedAt: json['completedAt'] as String?,
      snapshotId: json['snapshotId'] as String?,
      snapshotCreatedAt: json['snapshotCreatedAt'] as String?,
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
    );
  }

  bool get isActive =>
      status == 'queued' ||
      status == 'snapshotting' ||
      status == 'uploading' ||
      status == 'downloading' ||
      status == 'applying';
}

class AdminSnapshot {
  const AdminSnapshot({
    required this.id,
    required this.clientName,
    required this.clientUserId,
    required this.ownerUserId,
    required this.table,
    required this.rowCount,
    required this.checksum,
    required this.createdAt,
    required this.snapshotBytes,
    required this.columns,
    required this.previewRows,
    required this.sourceJobId,
  });

  final String id;
  final String clientName;
  final String? clientUserId;
  final String? ownerUserId;
  final String table;
  final int rowCount;
  final String checksum;
  final String createdAt;
  final int snapshotBytes;
  final List<String> columns;
  final List<List<String>> previewRows;
  final String? sourceJobId;

  factory AdminSnapshot.fromJson(Map<String, dynamic> json) {
    final rawRows = json['previewRows'] as List<dynamic>? ?? const [];
    return AdminSnapshot(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      clientUserId: json['clientUserId'] as String?,
      ownerUserId: json['ownerUserId'] as String?,
      table: json['table'] as String? ?? '',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      checksum: json['checksum'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      columns: (json['columns'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      previewRows: rawRows
          .map(
            (row) => (row as List<dynamic>)
                .map((item) => item?.toString() ?? '')
                .toList(growable: false),
          )
          .toList(growable: false),
      sourceJobId: json['sourceJobId'] as String?,
    );
  }
}

class AdminSnapshotDetail {
  const AdminSnapshotDetail({
    required this.id,
    required this.clientName,
    required this.clientUserId,
    required this.ownerUserId,
    required this.table,
    required this.rowCount,
    required this.checksum,
    required this.createdAt,
    required this.snapshotBytes,
    required this.columns,
    required this.rows,
    required this.sourceJobId,
  });

  final String id;
  final String clientName;
  final String? clientUserId;
  final String? ownerUserId;
  final String table;
  final int rowCount;
  final String checksum;
  final String createdAt;
  final int snapshotBytes;
  final List<String> columns;
  final List<Map<String, String?>> rows;
  final String? sourceJobId;

  factory AdminSnapshotDetail.fromJson(Map<String, dynamic> json) {
    final columns = (json['columns'] as List<dynamic>? ?? const [])
        .map((item) => item.toString())
        .toList(growable: false);
    final rawRows = json['rows'] as List<dynamic>? ?? const [];

    return AdminSnapshotDetail(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      clientUserId: json['clientUserId'] as String?,
      ownerUserId: json['ownerUserId'] as String?,
      table: json['table'] as String? ?? '',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      checksum: json['checksum'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      columns: columns,
      rows: rawRows
          .map((row) => _decodeSnapshotRow(columns, row))
          .toList(growable: false),
      sourceJobId: json['sourceJobId'] as String?,
    );
  }

  static Map<String, String?> _decodeSnapshotRow(
    List<String> columns,
    dynamic row,
  ) {
    if (row is List) {
      return Map<String, String?>.fromEntries(
        columns.asMap().entries.map(
          (entry) => MapEntry(
            entry.value,
            entry.key < row.length ? row[entry.key]?.toString() : null,
          ),
        ),
      );
    }

    if (row is Map) {
      final rawMap = Map<String, dynamic>.fromEntries(
        row.entries.map((entry) => MapEntry(entry.key.toString(), entry.value)),
      );
      final lowerKeys = <String, dynamic>{
        for (final entry in rawMap.entries)
          entry.key.toLowerCase(): entry.value,
      };
      return Map<String, String?>.fromEntries(
        columns.map((column) {
          final direct = rawMap[column];
          final fallback = lowerKeys[column.toLowerCase()];
          final value = direct ?? fallback;
          return MapEntry(column, value?.toString());
        }),
      );
    }

    return Map<String, String?>.fromEntries(
      columns.map((column) => MapEntry(column, null)),
    );
  }
}
