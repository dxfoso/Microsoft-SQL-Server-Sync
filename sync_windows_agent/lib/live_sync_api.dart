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
  String? _authToken;

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

  void setAuthToken(String? token) {
    final trimmed = token?.trim();
    _authToken = trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Map<String, String> _headers({bool json = false}) {
    final headers = <String, String>{};
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    if (_authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }
    return headers;
  }

  Future<AgentAuthenticatedUser> loginClient({
    required String email,
    required String password,
  }) async {
    final response = await _client.post(
      _uri('/auth/login'),
      headers: _headers(json: true),
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'app': 'windows',
      }),
    );

    if (response.statusCode != 200) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const AgentControlPlaneException('Unexpected login payload.');
    }

    final user = AgentAuthenticatedUser(
      token: decoded['token'] as String? ?? '',
      id: (decoded['user'] as Map)['id'] as String? ?? '',
      email: (decoded['user'] as Map)['email'] as String? ?? '',
      name: (decoded['user'] as Map)['name'] as String? ?? '',
      role: (decoded['user'] as Map)['role'] as String? ?? '',
      ownerUserId: (decoded['user'] as Map)['ownerUserId'] as String?,
      ownerEmail: (decoded['user'] as Map)['ownerEmail'] as String?,
      ownerName: (decoded['user'] as Map)['ownerName'] as String?,
    );
    setAuthToken(user.token);
    return user;
  }

  Future<AgentAuthenticatedUser> fetchCurrentUser() async {
    final response = await _client.get(_uri('/auth/me'), headers: _headers());
    if (response.statusCode != 200) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected current-user payload.',
      );
    }
    final user = Map<String, dynamic>.from(decoded['user'] as Map);
    return AgentAuthenticatedUser(
      token: _authToken ?? '',
      id: user['id'] as String? ?? '',
      email: user['email'] as String? ?? '',
      name: user['name'] as String? ?? '',
      role: user['role'] as String? ?? '',
      ownerUserId: user['ownerUserId'] as String?,
      ownerEmail: user['ownerEmail'] as String?,
      ownerName: user['ownerName'] as String?,
    );
  }

  Future<void> logout() async {
    if (_authToken == null) {
      return;
    }
    final response = await _client.post(
      _uri('/auth/logout'),
      headers: _headers(json: true),
    );
    if (response.statusCode != 200) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
    }
    setAuthToken(null);
  }

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
      headers: _headers(json: true),
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
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
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
      headers: _headers(json: true),
      body: jsonEncode({
        'clientName': clientName,
        if (sourceClientName != null && sourceClientName.trim().isNotEmpty)
          'sourceClientName': sourceClientName,
        'direction': direction,
        'tables': tables,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
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
      headers: _headers(json: true),
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
      headers: _headers(json: true),
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
      headers: _headers(json: true),
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
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
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
    final response = await _client.get(
      _uri('/jobs/$jobId/download-snapshot'),
      headers: _headers(),
    );
    if (response.statusCode != 200) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
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
      headers: _headers(json: true),
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
      headers: _headers(json: true),
      body: jsonEncode({
        'message': message,
        if (progress != null) 'progress': progress,
      }),
    );

    if (response.statusCode != 200) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
    }
  }

  RemoteSyncJob _parseJobResponse(http.Response response, String phase) {
    if (response.statusCode != 200) {
      throw AgentControlPlaneException(_errorMessageFromResponse(response));
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

  String _errorMessageFromResponse(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return 'Request failed with ${response.statusCode}.';
  }
}

class AgentAuthenticatedUser {
  const AgentAuthenticatedUser({
    required this.token,
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.ownerUserId,
    required this.ownerEmail,
    required this.ownerName,
  });

  final String token;
  final String id;
  final String email;
  final String name;
  final String role;
  final String? ownerUserId;
  final String? ownerEmail;
  final String? ownerName;
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
