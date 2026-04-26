import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_state.dart';

const String _defaultControlPlaneUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'https://sync.velvet-leaf.com/api',
);
const int _snapshotTransferChunkSizeBytes = 100 * 1024;
const int _snapshotTransferMaxAttempts = 10;
const Duration _snapshotTransferRequestTimeout = Duration(minutes: 10);
const List<Duration> _snapshotTransferRetryDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 60),
  Duration(seconds: 60),
];

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
    required String name,
    required String password,
  }) async {
    final response = await _client.post(
      _uri('/auth/login'),
      headers: _headers(json: true),
      body: jsonEncode({
        'name': name.trim(),
        'password': password,
        'app': 'windows',
      }),
    );

    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const AgentControlPlaneException('Unexpected login payload.');
    }

    final user = AgentAuthenticatedUser(
      token: decoded['token'] as String? ?? '',
      id: (decoded['user'] as Map)['id'] as String? ?? '',
      username: (decoded['user'] as Map)['username'] as String? ?? '',
      email: (decoded['user'] as Map)['email'] as String? ?? '',
      name: (decoded['user'] as Map)['name'] as String? ?? '',
      role: (decoded['user'] as Map)['role'] as String? ?? '',
      ownerUserId: (decoded['user'] as Map)['ownerUserId'] as String?,
      ownerUsername: (decoded['user'] as Map)['ownerUsername'] as String?,
      ownerEmail: (decoded['user'] as Map)['ownerEmail'] as String?,
      ownerName: (decoded['user'] as Map)['ownerName'] as String?,
    );
    setAuthToken(user.token);
    return user;
  }

  Future<AgentAuthenticatedUser> fetchCurrentUser() async {
    final response = await _client.get(_uri('/auth/me'), headers: _headers());
    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
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
      username: user['username'] as String? ?? '',
      email: user['email'] as String? ?? '',
      name: user['name'] as String? ?? '',
      role: user['role'] as String? ?? '',
      ownerUserId: user['ownerUserId'] as String?,
      ownerUsername: user['ownerUsername'] as String?,
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
      throw _exceptionFromResponse(response);
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

  bool _isRetryableTransferStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  Duration _transferRetryDelay(int attempt) {
    final index =
        attempt.clamp(0, _snapshotTransferRetryDelays.length - 1).toInt();
    return _snapshotTransferRetryDelays[index];
  }

  Future<http.Response> _transferRequestWithRetry(
    Future<http.Response> Function() request,
    String phase,
  ) async {
    Object? lastError;
    for (
      var attempt = 0;
      attempt < _snapshotTransferMaxAttempts;
      attempt += 1
    ) {
      try {
        final response = await request().timeout(
          _snapshotTransferRequestTimeout,
        );
        if (!_isRetryableTransferStatus(response.statusCode) ||
            attempt == _snapshotTransferMaxAttempts - 1) {
          return response;
        }
        lastError = AgentControlPlaneException(
          _errorMessageFromResponse(response),
          statusCode: response.statusCode,
        );
      } catch (error) {
        lastError = error;
        if (attempt == _snapshotTransferMaxAttempts - 1) {
          throw AgentControlPlaneException(
            'Control plane connection dropped during $phase. Retrying automatically.',
            statusCode: 503,
          );
        }
      }
      await Future<void>.delayed(_transferRetryDelay(attempt));
    }

    throw AgentControlPlaneException(
      'Control plane connection dropped during $phase. Retrying automatically. $lastError',
      statusCode: 503,
    );
  }

  Future<HeartbeatResult> heartbeat({
    required String clientName,
    required String machineName,
    required bool isMaster,
    required int historyLimit,
    required int autoSyncIntervalMinutes,
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
        'historyLimit': historyLimit,
        'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
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
      throw _exceptionFromResponse(response);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AgentControlPlaneException('Unexpected heartbeat payload.');
    }

    final jobs = decoded['jobs'] as List<dynamic>? ?? const [];
    final syncSettings =
        decoded['syncSettings'] is Map
            ? RemoteAgentSyncSettings.fromJson(
              Map<String, dynamic>.from(decoded['syncSettings'] as Map),
            )
            : RemoteAgentSyncSettings(
              isMaster: isMaster,
              historyLimit: historyLimit,
              autoSyncIntervalMinutes: autoSyncIntervalMinutes,
            );
    return HeartbeatResult(
      syncSettings: syncSettings,
      jobs: jobs
          .map(
            (item) =>
                RemoteSyncJob.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false),
    );
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
      throw _exceptionFromResponse(response);
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
    required int rowCount,
    required String snapshotCreatedAt,
    required int snapshotBytes,
    required String snapshotJson,
  }) async {
    final payloadBytes = Uint8List.fromList(utf8.encode(snapshotJson));
    final compressedBytes = Uint8List.fromList(gzip.encode(payloadBytes));
    final chunkCount =
        (compressedBytes.length / _snapshotTransferChunkSizeBytes).ceil();
    final uploadId =
        '$jobId-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

    final startResponse = await _transferRequestWithRetry(
      () => _client.post(
        _uri('/jobs/$jobId/upload-chunk-start'),
        headers: _headers(json: true),
        body: jsonEncode({
          'uploadId': uploadId,
          'clientName': clientName,
          'table': table,
          'rowCount': rowCount,
          'snapshotCreatedAt': snapshotCreatedAt,
          'snapshotBytes': snapshotBytes,
          'compressedBytes': compressedBytes.length,
          'chunkSizeBytes': _snapshotTransferChunkSizeBytes,
          'chunkCount': chunkCount,
          'encoding': 'gzip',
        }),
      ),
      'starting snapshot upload',
    );

    if (startResponse.statusCode != 200) {
      throw _exceptionFromResponse(startResponse);
    }

    final startDecoded = jsonDecode(startResponse.body);
    if (startDecoded is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected chunked upload start payload.',
      );
    }
    final receivedIndexes =
        (startDecoded['receivedIndexes'] as List<dynamic>?)
            ?.map((item) => (item as num).round())
            .toSet() ??
        <int>{};

    for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      if (receivedIndexes.contains(chunkIndex)) {
        continue;
      }

      final start = chunkIndex * _snapshotTransferChunkSizeBytes;
      final end = start + _snapshotTransferChunkSizeBytes;
      final chunkBytes = compressedBytes.sublist(
        start,
        end > compressedBytes.length ? compressedBytes.length : end,
      );
      final chunkResponse = await _transferRequestWithRetry(
        () => _client.post(
          _uri('/jobs/$jobId/upload-chunk'),
          headers: _headers(json: true),
          body: jsonEncode({
            'uploadId': uploadId,
            'chunkIndex': chunkIndex,
            'chunkData': base64Encode(chunkBytes),
          }),
        ),
        'uploading snapshot chunk ${chunkIndex + 1} of $chunkCount',
      );

      if (chunkResponse.statusCode != 200) {
        throw _exceptionFromResponse(chunkResponse);
      }
    }

    final response = await _transferRequestWithRetry(
      () => _client.post(
        _uri('/jobs/$jobId/upload-chunk-complete'),
        headers: _headers(json: true),
        body: jsonEncode({'uploadId': uploadId}),
      ),
      'completing snapshot upload',
    );

    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
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
    final manifestResponse = await _transferRequestWithRetry(
      () => _client.get(
        _uri('/jobs/$jobId/download-snapshot-manifest'),
        headers: _headers(),
      ),
      'starting snapshot download',
    );

    if (manifestResponse.statusCode == 404) {
      return _downloadSnapshotLegacy(jobId);
    }
    if (manifestResponse.statusCode != 200) {
      throw _exceptionFromResponse(manifestResponse);
    }

    final manifestDecoded = jsonDecode(manifestResponse.body);
    if (manifestDecoded is! Map || manifestDecoded['manifest'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected chunked download manifest payload.',
      );
    }
    final manifest = Map<String, dynamic>.from(
      manifestDecoded['manifest'] as Map,
    );
    final transferId = manifest['id'] as String? ?? '';
    final chunkCount = (manifest['chunkCount'] as num? ?? 0).round();
    final compressedBytes = (manifest['compressedBytes'] as num? ?? 0).round();

    if (transferId.isEmpty || chunkCount < 1 || compressedBytes < 1) {
      throw const AgentControlPlaneException(
        'Chunked download manifest is incomplete.',
      );
    }

    final buffer = BytesBuilder(copy: false);
    for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      final chunkResponse = await _transferRequestWithRetry(
        () => _client.get(
          _uri('/jobs/$jobId/download-snapshot-chunk?index=$chunkIndex'),
          headers: _headers(),
        ),
        'downloading snapshot chunk ${chunkIndex + 1} of $chunkCount',
      );

      if (chunkResponse.statusCode != 200) {
        throw _exceptionFromResponse(chunkResponse);
      }

      final chunkDecoded = jsonDecode(chunkResponse.body);
      if (chunkDecoded is! Map || chunkDecoded['chunkData'] is! String) {
        throw const AgentControlPlaneException(
          'Unexpected snapshot chunk payload.',
        );
      }
      buffer.add(base64Decode(chunkDecoded['chunkData'] as String));
    }

    final compressedPayload = buffer.takeBytes();
    if (compressedPayload.length != compressedBytes) {
      throw const AgentControlPlaneException(
        'Downloaded snapshot byte count does not match the manifest.',
      );
    }

    final snapshotJson = utf8.decode(gzip.decode(compressedPayload));
    final decoded = jsonDecode(snapshotJson);
    if (decoded is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected decompressed snapshot payload.',
      );
    }

    return RemoteSnapshot.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<RemoteSnapshot> _downloadSnapshotLegacy(String jobId) async {
    final response = await _client.get(
      _uri('/jobs/$jobId/download-snapshot'),
      headers: _headers(),
    );
    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
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
      throw _exceptionFromResponse(response);
    }
  }

  RemoteSyncJob _parseJobResponse(http.Response response, String phase) {
    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
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
    if (response.statusCode == 503) {
      return 'Control plane is temporarily unavailable. Retrying automatically.';
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return 'Request failed with ${response.statusCode}.';
  }

  AgentControlPlaneException _exceptionFromResponse(http.Response response) {
    return AgentControlPlaneException(
      _errorMessageFromResponse(response),
      statusCode: response.statusCode,
    );
  }
}

class HeartbeatResult {
  const HeartbeatResult({required this.syncSettings, required this.jobs});

  final RemoteAgentSyncSettings syncSettings;
  final List<RemoteSyncJob> jobs;
}

class RemoteAgentSyncSettings {
  const RemoteAgentSyncSettings({
    required this.isMaster,
    required this.historyLimit,
    required this.autoSyncIntervalMinutes,
  });

  final bool isMaster;
  final int historyLimit;
  final int autoSyncIntervalMinutes;

  factory RemoteAgentSyncSettings.fromJson(Map<String, dynamic> json) {
    return RemoteAgentSyncSettings(
      isMaster: json['isMaster'] as bool? ?? true,
      historyLimit:
          (json['historyLimit'] as num? ?? kDefaultHistoryLimit)
              .round()
              .clamp(1, kMaxHistoryLimit)
              .toInt(),
      autoSyncIntervalMinutes:
          (json['autoSyncIntervalMinutes'] as num? ??
                  kDefaultAutoSyncIntervalMinutes)
              .round()
              .clamp(kMinAutoSyncIntervalMinutes, kMaxAutoSyncIntervalMinutes)
              .toInt(),
    );
  }
}

class AgentAuthenticatedUser {
  const AgentAuthenticatedUser({
    required this.token,
    required this.id,
    required this.username,
    required this.email,
    required this.name,
    required this.role,
    required this.ownerUserId,
    required this.ownerUsername,
    required this.ownerEmail,
    required this.ownerName,
  });

  final String token;
  final String id;
  final String username;
  final String email;
  final String name;
  final String role;
  final String? ownerUserId;
  final String? ownerUsername;
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
  const AgentControlPlaneException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
