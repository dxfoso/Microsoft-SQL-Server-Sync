import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_state.dart';

const String _defaultControlPlaneUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'https://sync.velvet-leaf.com/api',
);

class AgentControlPlaneClient {
  AgentControlPlaneClient({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultControlPlaneUrl);

  final http.Client _client;
  final String _baseUrl;

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return 'https://sync.velvet-leaf.com/api';
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Future<bool> checkHealth() async {
    try {
      final response = await _client.get(_uri('/health'));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<RemoteSyncJob>> heartbeat({
    required String clientName,
    required String machineName,
    required bool isMaster,
    required String server,
    required String database,
    required bool serverConnected,
    required bool sqlConnected,
    required String? selectedTable,
    required Map<String, SyncTableState> tables,
  }) async {
    final response = await _client.post(
      _uri('/agents/heartbeat'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'clientName': clientName,
        'machineName': machineName,
        'isMaster': isMaster,
        'server': server,
        'database': database,
        'serverConnected': serverConnected,
        'sqlConnected': sqlConnected,
        'selectedTable': selectedTable,
        'tables': tables.entries
            .map((entry) => {'table': entry.key, ...entry.value.toJson()})
            .toList(growable: false),
      }),
    );

    if (response.statusCode != 200) {
      throw AgentControlPlaneException(
        'Heartbeat failed with ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AgentControlPlaneException('Unexpected heartbeat payload.');
    }

    final jobs = decoded['jobs'] as List<dynamic>? ?? const [];
    return jobs
        .map(
          (item) =>
              RemoteSyncJob.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<List<RemoteSyncJob>> createJobs({
    required String clientName,
    required List<String> tables,
    required String direction,
    String? sourceClientName,
  }) async {
    final response = await _client.post(
      _uri('/jobs'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'clientName': clientName,
        if (sourceClientName != null && sourceClientName.trim().isNotEmpty)
          'sourceClientName': sourceClientName,
        'direction': direction,
        'tables': tables,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AgentControlPlaneException(
        'Queueing jobs failed with ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AgentControlPlaneException('Unexpected job queue payload.');
    }
    final jobs = decoded['jobs'] as List<dynamic>? ?? const [];
    return jobs
        .map(
          (item) =>
              RemoteSyncJob.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
  }

  Future<RemoteSyncJob> startJob(
    String jobId, {
    required String status,
    required int progress,
    required String message,
  }) async {
    final response = await _client.post(
      _uri('/jobs/$jobId/start'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'status': status,
        'progress': progress,
        'message': message,
      }),
    );
    return _parseJobResponse(response, 'job start');
  }

  Future<RemoteSyncJob> updateJobProgress(
    String jobId, {
    required String status,
    required int progress,
    required String message,
    required int rowCount,
    required String direction,
  }) async {
    final response = await _client.post(
      _uri('/jobs/$jobId/progress'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'status': status,
        'progress': progress,
        'message': message,
        'rowCount': rowCount,
        'direction': direction,
      }),
    );
    return _parseJobResponse(response, 'job progress');
  }

  Future<UploadSnapshotResult> uploadSnapshot(
    String jobId, {
    required String clientName,
    required String table,
    required List<String> columns,
    required List<Map<String, String?>> rows,
    required int rowCount,
    required String snapshotCreatedAt,
    required int snapshotBytes,
  }) async {
    final response = await _client.post(
      _uri('/jobs/$jobId/upload'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'clientName': clientName,
        'table': table,
        'columns': columns,
        'rows': rows,
        'rowCount': rowCount,
        'snapshotCreatedAt': snapshotCreatedAt,
        'snapshotBytes': snapshotBytes,
      }),
    );

    if (response.statusCode != 200) {
      throw AgentControlPlaneException(
        'Snapshot upload failed with ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AgentControlPlaneException('Unexpected upload payload.');
    }

    return UploadSnapshotResult(
      job: RemoteSyncJob.fromJson(
        Map<String, dynamic>.from(decoded['job'] as Map),
      ),
      snapshot: RemoteSnapshot.fromJson(
        Map<String, dynamic>.from(decoded['snapshot'] as Map),
      ),
    );
  }

  Future<RemoteSnapshot> downloadSnapshot(String jobId) async {
    final response = await _client.get(_uri('/jobs/$jobId/download-snapshot'));
    if (response.statusCode != 200) {
      throw AgentControlPlaneException(
        'Snapshot download failed with ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AgentControlPlaneException('Unexpected download payload.');
    }

    return RemoteSnapshot.fromJson(
      Map<String, dynamic>.from(decoded['snapshot'] as Map),
    );
  }

  Future<RemoteSyncJob> completeJob(
    String jobId, {
    required String status,
    required int progress,
    required String message,
    required int rowCount,
    String? snapshotId,
    String? snapshotCreatedAt,
    int? snapshotBytes,
  }) async {
    final response = await _client.post(
      _uri('/jobs/$jobId/complete'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'status': status,
        'progress': progress,
        'message': message,
        'rowCount': rowCount,
        'snapshotId': snapshotId,
        'snapshotCreatedAt': snapshotCreatedAt,
        'snapshotBytes': snapshotBytes,
      }),
    );
    return _parseJobResponse(response, 'job completion');
  }

  Future<void> failJob(String jobId, String message, {int? progress}) async {
    final response = await _client.post(
      _uri('/jobs/$jobId/fail'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        if (progress != null) 'progress': progress,
      }),
    );

    if (response.statusCode != 200) {
      throw AgentControlPlaneException(
        'Job failure callback failed with ${response.statusCode}.',
      );
    }
  }

  RemoteSyncJob _parseJobResponse(http.Response response, String phase) {
    if (response.statusCode != 200) {
      throw AgentControlPlaneException(
        '$phase failed with ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw AgentControlPlaneException(
        'Unexpected payload returned from $phase.',
      );
    }

    return RemoteSyncJob.fromJson(
      Map<String, dynamic>.from(decoded['job'] as Map),
    );
  }

  void dispose() {
    _client.close();
  }
}

class RemoteSyncJob {
  const RemoteSyncJob({
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

  factory RemoteSyncJob.fromJson(Map<String, dynamic> json) {
    return RemoteSyncJob(
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

class RemoteSnapshot {
  const RemoteSnapshot({
    required this.id,
    required this.clientName,
    required this.table,
    required this.createdAt,
    required this.rowCount,
    required this.checksum,
    required this.snapshotBytes,
    required this.columns,
    required this.rows,
    required this.sourceJobId,
  });

  final String id;
  final String clientName;
  final String table;
  final String createdAt;
  final int rowCount;
  final String checksum;
  final int snapshotBytes;
  final List<String> columns;
  final List<Map<String, String?>> rows;
  final String? sourceJobId;

  factory RemoteSnapshot.fromJson(Map<String, dynamic> json) {
    final rawRows = json['rows'] as List<dynamic>? ?? const [];
    return RemoteSnapshot(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      checksum: json['checksum'] as String? ?? '',
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      columns: (json['columns'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      rows: rawRows
          .map(
            (row) => Map<String, String?>.fromEntries(
              Map<String, dynamic>.from(row as Map).entries.map(
                (entry) => MapEntry(entry.key, entry.value?.toString()),
              ),
            ),
          )
          .toList(growable: false),
      sourceJobId: json['sourceJobId'] as String?,
    );
  }
}

class UploadSnapshotResult {
  const UploadSnapshotResult({required this.job, required this.snapshot});

  final RemoteSyncJob job;
  final RemoteSnapshot snapshot;
}

class AgentControlPlaneException implements Exception {
  const AgentControlPlaneException(this.message);

  final String message;

  @override
  String toString() => message;
}
