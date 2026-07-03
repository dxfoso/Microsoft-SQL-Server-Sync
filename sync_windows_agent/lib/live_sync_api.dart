import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_state.dart';

const String _defaultControlPlaneUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'https://sync.velvet-leaf.com/call',
);
const String _liveControlPlaneUrl = 'https://sync.velvet-leaf.com/call';
const int _snapshotTransferChunkSizeBytes = 100 * 1024;
const int _snapshotTransferMaxAttempts = 10;
const Duration _snapshotTransferRequestTimeout = Duration(minutes: 10);
const Duration _controlPlaneRequestTimeout = Duration(seconds: 10);
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

typedef TransferProgressCallback =
    void Function(TransferProgressSnapshot progress);

class TransferProgressSnapshot {
  const TransferProgressSnapshot({
    required this.bytesTransferred,
    required this.totalBytes,
  });

  final int bytesTransferred;
  final int totalBytes;
}

class ClientUpdateInfo {
  const ClientUpdateInfo({
    required this.version,
    required this.commit,
    required this.releaseDate,
    required this.zipUrl,
    required this.updateScriptUrl,
    required this.sha256,
    required this.sizeBytes,
  });

  final String version;
  final String commit;
  final String releaseDate;
  final String zipUrl;
  final String updateScriptUrl;
  final String sha256;
  final int sizeBytes;

  factory ClientUpdateInfo.fromJson(Map<String, dynamic> json) {
    return ClientUpdateInfo(
      version: json['version'] as String? ?? '',
      commit: json['commit'] as String? ?? '',
      releaseDate: json['releaseDate'] as String? ?? '',
      zipUrl: json['zipUrl'] as String? ?? '',
      updateScriptUrl: json['updateScriptUrl'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
    );
  }
}

class AgentControlPlaneClient {
  AgentControlPlaneClient({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultControlPlaneUrl);

  final http.Client _client;
  final String _baseUrl;
  String? _authToken;

  String get baseUrl => _baseUrl;

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return _liveControlPlaneUrl;
    }
    final parsed = Uri.tryParse(trimmed);
    final host = parsed?.host.toLowerCase() ?? '';
    final port = parsed?.port;
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '0.0.0.0' ||
        port == 6006) {
      return _liveControlPlaneUrl;
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');
  Uri _uriCall() => Uri.parse(_baseUrl);

  Uri _originUri(String path) {
    final base = Uri.parse(_baseUrl);
    return base.replace(path: path, query: null, fragment: null);
  }

  dynamic _unwrapApiResponse(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) {
      return decoded;
    }
    final status = decoded['status'];
    if (status == 'failed') {
      throw AgentControlPlaneException(_errorMessageFromMap(decoded));
    }
    if (status == 'success' && decoded.containsKey('value')) {
      return decoded['value'];
    }
    return decoded;
  }

  Future<dynamic> _invokeFunction(
    String functionName,
    Map<String, dynamic> args,
    String phase,
  ) async {
    final payloadArgs = <String, dynamic>{...args};
    if (_authToken != null &&
        _authToken!.isNotEmpty &&
        functionName != 'auth_login') {
      payloadArgs['token'] = _authToken;
    }
    final response = await _sendRequest(
      _client.post(
        _uriCall(),
        headers: _headers(json: true),
        body: jsonEncode({'name': functionName, 'args': payloadArgs}),
      ),
      phase,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFromResponse(response);
    }
    return _unwrapApiResponse(jsonDecode(response.body));
  }

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

  Future<http.Response> _sendRequest(
    Future<http.Response> request,
    String phase,
  ) async {
    try {
      return await request.timeout(_controlPlaneRequestTimeout);
    } on TimeoutException {
      throw AgentControlPlaneException(
        'Control plane request timed out during $phase. Check network connectivity.',
        statusCode: 503,
      );
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

  Future<dynamic> _invokeFunctionWithRetry(
    String functionName,
    Map<String, dynamic> args,
    String phase,
  ) async {
    Object? lastError;
    for (
      var attempt = 0;
      attempt < _snapshotTransferMaxAttempts;
      attempt += 1
    ) {
      try {
        return await _invokeFunction(functionName, args, phase);
      } catch (error) {
        lastError = error;
        final statusCode =
            error is AgentControlPlaneException ? error.statusCode : null;
        final canRetry =
            statusCode != null && _isRetryableTransferStatus(statusCode);
        if (!canRetry || attempt == _snapshotTransferMaxAttempts - 1) {
          throw error is AgentControlPlaneException
              ? error
              : AgentControlPlaneException(
                'Control plane connection dropped during $phase. Retrying automatically.',
                statusCode: 503,
              );
        }
        await Future<void>.delayed(_transferRetryDelay(attempt));
      }
    }

    throw AgentControlPlaneException(
      'Control plane connection dropped during $phase. Retrying automatically. $lastError',
      statusCode: 503,
    );
  }

  Future<AgentAuthenticatedUser> loginClient({
    required String name,
    required String password,
  }) async {
    final decoded = await _invokeFunction('auth_login', {
      'name': name.trim(),
      'email': name.trim(),
      'password': password,
      'app': 'windows',
    }, 'signing in');
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
    final decoded = await _invokeFunction('auth_me', {}, 'restoring session');
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
    await _invokeFunction('auth_logout', {}, 'logging out');
    setAuthToken(null);
  }

  Future<bool> checkHealth() async {
    try {
      final response = await _sendRequest(
        _client.get(_uri('/health')),
        'checking backend health',
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<ClientUpdateInfo?> fetchClientUpdateInfo({String? manifestUrl}) async {
    final overrideUrl = manifestUrl?.trim() ?? '';
    final targetUri =
        overrideUrl.isEmpty
            ? _originUri('/client/latest.json')
            : Uri.parse(overrideUrl);
    final response = await _sendRequest(
      _client.get(targetUri),
      'checking client update manifest',
    );
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFromResponse(response);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const AgentControlPlaneException(
        'Unexpected client update manifest payload.',
      );
    }
    return ClientUpdateInfo.fromJson(decoded);
  }

  Future<HeartbeatResult> heartbeat({
    required String clientName,
    required String machineName,
    required int historyLimit,
    required int autoSyncIntervalMinutes,
    required String server,
    required String database,
    required bool replicationUseWindowsAuth,
    required String replicationUser,
    required String replicationPassword,
    required bool serverConnected,
    required bool sqlConnected,
    required String? selectedTable,
    required Map<String, SyncTableState> tables,
    required List<Map<String, String>> tableRelationships,
    required String clientVersion,
  }) async {
    final response = await _invokeFunction('agents_heartbeat', {
      'clientName': clientName,
      'machineName': machineName,
      'historyLimit': historyLimit,
      'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
      'server': server,
      'database': database,
      'replicationUseWindowsAuth': replicationUseWindowsAuth,
      'replicationUser': replicationUser,
      'replicationPassword': replicationPassword,
      'serverConnected': serverConnected,
      'sqlConnected': sqlConnected,
      'selectedTable': selectedTable,
      'clientVersion': clientVersion,
      'tables': tables.entries
          .map((entry) => {'table': entry.key, ...entry.value.toJson()})
          .toList(growable: false),
      'tableRelationships': tableRelationships,
    }, 'sending heartbeat');

    if (response is! Map) {
      throw const AgentControlPlaneException('Unexpected heartbeat payload.');
    }
    final decoded = response;

    final jobs = decoded['jobs'] as List<dynamic>? ?? const [];
    final syncSettings =
        decoded['syncSettings'] is Map
            ? RemoteAgentSyncSettings.fromJson(
              Map<String, dynamic>.from(decoded['syncSettings'] as Map),
            )
            : RemoteAgentSyncSettings(
              historyLimit: historyLimit,
              autoSyncIntervalMinutes: autoSyncIntervalMinutes,
            );
    final tablePolicies = (decoded['tablePolicies'] as List<dynamic>? ??
            const [])
        .map(
          (item) => RemoteTableSyncPolicy.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    final tableDependencies = (decoded['tableDependencies'] as List<dynamic>? ??
            const [])
        .map(
          (item) => RemoteTableDependency.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    return HeartbeatResult(
      syncSettings: syncSettings,
      tablePolicies: tablePolicies,
      tableDependencies: tableDependencies,
      jobs: jobs
          .map(
            (item) =>
                RemoteSyncJob.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false),
      diagnostics:
          decoded['diagnostics'] is Map
              ? RemoteAgentDiagnostics.fromJson(
                Map<String, dynamic>.from(decoded['diagnostics'] as Map),
              )
              : const RemoteAgentDiagnostics(),
      clientUpdate:
          decoded['clientUpdate'] is Map
              ? RemoteAgentClientUpdate.fromJson(
                Map<String, dynamic>.from(decoded['clientUpdate'] as Map),
              )
              : const RemoteAgentClientUpdate(),
    );
  }

  Future<RemoteAgentClientUpdate> acknowledgeClientUpdate({
    required String clientName,
    String? requestId,
    required String status,
    String installedVersion = '',
    String message = '',
  }) async {
    final response = await _invokeFunction('agent_client_update_ack', {
      'clientName': clientName,
      'requestId': requestId,
      'status': status,
      'installedVersion': installedVersion,
      'message': message,
    }, 'acknowledging client update request');
    if (response is! Map || response['clientUpdate'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected client update acknowledgement payload.',
      );
    }
    return RemoteAgentClientUpdate.fromJson(
      Map<String, dynamic>.from(response['clientUpdate'] as Map),
    );
  }

  Future<RemoteAgentDiagnostics> uploadDiagnostics({
    required String clientName,
    String? requestId,
    required String summary,
    required String payload,
  }) async {
    final response = await _invokeFunction('agent_diagnostics_upload', {
      'clientName': clientName,
      if (requestId != null && requestId.trim().isNotEmpty)
        'requestId': requestId.trim(),
      'summary': summary,
      'payload': payload,
    }, 'uploading diagnostics');
    if (response is! Map || response['diagnostics'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected diagnostics upload payload.',
      );
    }
    return RemoteAgentDiagnostics.fromJson(
      Map<String, dynamic>.from(response['diagnostics'] as Map),
    );
  }

  Future<RemoteTableSyncPolicy> updateTableSyncPolicy({
    required String table,
    required bool enabled,
    bool cascadeRelated = true,
  }) async {
    final response = await _invokeFunction('table_sync_policy_set', {
      'table': table,
      'enabled': enabled,
      'cascadeRelated': cascadeRelated,
    }, 'updating table sync policy');
    if (response is! Map || response['policy'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected table sync policy payload.',
      );
    }
    return RemoteTableSyncPolicy.fromJson(
      Map<String, dynamic>.from(response['policy'] as Map),
    );
  }

  Future<List<RemoteSyncJob>> createJobs({
    required String clientName,
    required List<String> tables,
    String? sourceClientName,
  }) async {
    final response = await _invokeFunction('jobs_create', {
      'clientName': clientName,
      if (sourceClientName != null && sourceClientName.trim().isNotEmpty)
        'sourceClientName': sourceClientName,
      'tables': tables,
    }, 'creating jobs');

    if (response is! Map) {
      throw const AgentControlPlaneException('Unexpected job queue payload.');
    }
    final decoded = response;
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
    final response = await _invokeFunction('jobs_start', {
      'jobId': jobId,
      'status': status,
      'progress': progress,
      'message': message,
    }, 'starting job');
    return _parseJobPayload(response, 'job start');
  }

  Future<RemoteSyncJob> updateJobProgress(
    String jobId, {
    required String status,
    required int progress,
    required String message,
    required int rowCount,
  }) async {
    final response = await _invokeFunction('jobs_progress', {
      'jobId': jobId,
      'status': status,
      'progress': progress,
      'message': message,
      'rowCount': rowCount,
    }, 'updating job progress');
    return _parseJobPayload(response, 'job progress');
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
    final response = await _invokeFunction('jobs_complete', {
      'jobId': jobId,
      'status': status,
      'progress': progress,
      'message': message,
      'rowCount': rowCount,
      if (snapshotId != null && snapshotId.trim().isNotEmpty)
        'snapshotId': snapshotId.trim(),
      if (snapshotCreatedAt != null && snapshotCreatedAt.trim().isNotEmpty)
        'snapshotCreatedAt': snapshotCreatedAt.trim(),
      if (snapshotBytes != null) 'snapshotBytes': snapshotBytes,
    }, 'completing job');
    return _parseJobPayload(response, 'job completion');
  }

  Future<void> failJob(String jobId, String message, {int? progress}) async {
    await _invokeFunction('jobs_fail', {
      'jobId': jobId,
      'message': message,
      if (progress != null) 'progress': progress,
    }, 'failing job');
  }

  Future<UploadSnapshotResult> uploadSnapshot(
    String jobId, {
    required String clientName,
    required String table,
    required int rowCount,
    required String snapshotCreatedAt,
    required int snapshotBytes,
    required String snapshotJson,
    TransferProgressCallback? onProgress,
  }) async {
    final payloadBytes = Uint8List.fromList(utf8.encode(snapshotJson));
    final compressedBytes = Uint8List.fromList(gzip.encode(payloadBytes));
    final chunkCount =
        (compressedBytes.length / _snapshotTransferChunkSizeBytes).ceil();
    final uploadId =
        '$jobId-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

    final startResponse = await _transferRequestWithRetry(
      () => _sendRequest(
        _client.post(
          _uriCall(),
          headers: _headers(json: true),
          body: jsonEncode({
            'name': 'jobs_upload_chunk_start',
            'args': {
              'jobId': jobId,
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
              'token': _authToken,
            },
          }),
        ),
        'starting snapshot upload',
      ),
      'starting snapshot upload',
    );

    if (startResponse.statusCode != 200) {
      throw _exceptionFromResponse(startResponse);
    }

    final startDecoded = _unwrapApiResponse(jsonDecode(startResponse.body));
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
    var bytesTransferred = 0;

    for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      if (receivedIndexes.contains(chunkIndex)) {
        final skippedStart = chunkIndex * _snapshotTransferChunkSizeBytes;
        final skippedEnd = skippedStart + _snapshotTransferChunkSizeBytes;
        bytesTransferred +=
            (skippedEnd > compressedBytes.length
                ? compressedBytes.length
                : skippedEnd) -
            skippedStart;
        continue;
      }

      final start = chunkIndex * _snapshotTransferChunkSizeBytes;
      final end = start + _snapshotTransferChunkSizeBytes;
      final chunkBytes = compressedBytes.sublist(
        start,
        end > compressedBytes.length ? compressedBytes.length : end,
      );
      final chunkResponse = await _transferRequestWithRetry(
        () => _sendRequest(
          _client.post(
            _uriCall(),
            headers: _headers(json: true),
            body: jsonEncode({
              'name': 'jobs_upload_chunk',
              'args': {
                'jobId': jobId,
                'uploadId': uploadId,
                'chunkIndex': chunkIndex,
                'chunkData': base64Encode(chunkBytes),
                'token': _authToken,
              },
            }),
          ),
          'uploading snapshot chunk ${chunkIndex + 1} of $chunkCount',
        ),
        'uploading snapshot chunk ${chunkIndex + 1} of $chunkCount',
      );

      if (chunkResponse.statusCode != 200) {
        throw _exceptionFromResponse(chunkResponse);
      }
      _unwrapApiResponse(jsonDecode(chunkResponse.body));
      bytesTransferred += chunkBytes.length;
      onProgress?.call(
        TransferProgressSnapshot(
          bytesTransferred: bytesTransferred,
          totalBytes: compressedBytes.length,
        ),
      );
    }

    final response = await _transferRequestWithRetry(
      () => _sendRequest(
        _client.post(
          _uriCall(),
          headers: _headers(json: true),
          body: jsonEncode({
            'name': 'jobs_upload_chunk_complete',
            'args': {'jobId': jobId, 'uploadId': uploadId, 'token': _authToken},
          }),
        ),
        'finalizing snapshot upload',
      ),
      'finalizing snapshot upload',
    );
    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
    }
    final decoded = _unwrapApiResponse(jsonDecode(response.body));
    if (decoded is! Map ||
        decoded['job'] is! Map ||
        decoded['snapshot'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected snapshot upload completion payload.',
      );
    }
    onProgress?.call(
      TransferProgressSnapshot(
        bytesTransferred: compressedBytes.length,
        totalBytes: compressedBytes.length,
      ),
    );
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
    final manifest = await _invokeFunctionWithRetry(
      'jobs_download_snapshot_manifest',
      {'jobId': jobId},
      'starting snapshot download',
    );
    if (manifest is! Map || manifest['manifest'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected chunked download manifest payload.',
      );
    }
    final manifestResponse = Map<String, dynamic>.from(manifest);
    final manifestDecoded = Map<String, dynamic>.from(
      manifest['manifest'] as Map,
    );
    final transferId = manifestDecoded['id'] as String? ?? '';
    final chunkCount = (manifestDecoded['chunkCount'] as num? ?? 0).round();
    final encoding = manifestDecoded['encoding'] as String? ?? 'gzip';
    final compressedBytes =
        (manifestDecoded['compressedBytes'] as num? ?? 0).round();

    if (encoding != 'gzip') {
      throw AgentControlPlaneException(
        'Unsupported snapshot encoding $encoding.',
      );
    }
    if (transferId.isEmpty || chunkCount < 1 || compressedBytes < 1) {
      throw const AgentControlPlaneException(
        'Chunked download manifest is incomplete.',
      );
    }

    final buffer = BytesBuilder(copy: false);
    for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      final chunkDecoded = await _invokeFunctionWithRetry(
        'jobs_download_snapshot_chunk',
        {'jobId': jobId, 'chunkIndex': chunkIndex},
        'downloading snapshot chunk ${chunkIndex + 1} of $chunkCount',
      );
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
    final snapshot = RemoteSnapshot.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    if (snapshot.id.isEmpty && manifestResponse['snapshot'] is Map) {
      final metadata = Map<String, dynamic>.from(
        manifestResponse['snapshot'] as Map,
      );
      return snapshot.copyWith(
        id: metadata['id'] as String? ?? '',
        clientName: metadata['clientName'] as String? ?? '',
        createdAt: metadata['createdAt'] as String? ?? '',
        rowCount: (metadata['rowCount'] as num? ?? snapshot.rowCount).round(),
        checksum: metadata['checksum'] as String? ?? '',
        snapshotBytes:
            (metadata['snapshotBytes'] as num? ?? snapshot.snapshotBytes)
                .round(),
        sourceJobId: metadata['sourceJobId'] as String?,
      );
    }
    return snapshot;
  }

  RemoteSyncJob _parseJobPayload(dynamic response, String phase) {
    if (response is! Map) {
      throw AgentControlPlaneException(
        'Unexpected payload returned from $phase.',
      );
    }
    final decoded = Map<String, dynamic>.from(response);

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
      if (decoded is Map<String, dynamic>) {
        return _errorMessageFromMap(decoded);
      }
    } catch (_) {}
    return 'Request failed with ${response.statusCode}.';
  }

  String _errorMessageFromMap(Map<String, dynamic> payload) {
    final messages = payload['messages'];
    if (messages is List && messages.isNotEmpty) {
      final first = messages[0];
      if (first is Map && first['text'] is String) {
        return first['text'] as String;
      }
    }
    if (payload['error'] is String) {
      return payload['error'] as String;
    }
    return 'Request failed.';
  }

  AgentControlPlaneException _exceptionFromResponse(http.Response response) {
    return AgentControlPlaneException(
      _errorMessageFromResponse(response),
      statusCode: response.statusCode,
    );
  }
}

class HeartbeatResult {
  const HeartbeatResult({
    required this.syncSettings,
    required this.tablePolicies,
    required this.tableDependencies,
    required this.jobs,
    required this.diagnostics,
    required this.clientUpdate,
  });

  final RemoteAgentSyncSettings syncSettings;
  final List<RemoteTableSyncPolicy> tablePolicies;
  final List<RemoteTableDependency> tableDependencies;
  final List<RemoteSyncJob> jobs;
  final RemoteAgentDiagnostics diagnostics;
  final RemoteAgentClientUpdate clientUpdate;
}

class RemoteTableDependency {
  const RemoteTableDependency({
    required this.table,
    required this.relatedTable,
    required this.relationshipType,
    required this.updatedAt,
    required this.updatedByClientName,
  });

  final String table;
  final String relatedTable;
  final String relationshipType;
  final String updatedAt;
  final String updatedByClientName;

  factory RemoteTableDependency.fromJson(Map<String, dynamic> json) {
    return RemoteTableDependency(
      table: json['table'] as String? ?? '',
      relatedTable: json['relatedTable'] as String? ?? '',
      relationshipType: json['relationshipType'] as String? ?? 'business',
      updatedAt: json['updatedAt'] as String? ?? '',
      updatedByClientName: json['updatedByClientName'] as String? ?? '',
    );
  }
}

class RemoteTableSyncPolicy {
  const RemoteTableSyncPolicy({
    required this.table,
    required this.enabled,
    required this.updatedAt,
    required this.updatedByClientName,
  });

  final String table;
  final bool enabled;
  final String updatedAt;
  final String updatedByClientName;

  factory RemoteTableSyncPolicy.fromJson(Map<String, dynamic> json) {
    return RemoteTableSyncPolicy(
      table: json['table'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      updatedAt: json['updatedAt'] as String? ?? '',
      updatedByClientName: json['updatedByClientName'] as String? ?? '',
    );
  }
}

class RemoteAgentSyncSettings {
  const RemoteAgentSyncSettings({
    required this.historyLimit,
    required this.autoSyncIntervalMinutes,
  });

  final int historyLimit;
  final int autoSyncIntervalMinutes;

  factory RemoteAgentSyncSettings.fromJson(Map<String, dynamic> json) {
    return RemoteAgentSyncSettings(
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

class RemoteAgentDiagnostics {
  const RemoteAgentDiagnostics({
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

  factory RemoteAgentDiagnostics.fromJson(Map<String, dynamic> json) {
    return RemoteAgentDiagnostics(
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
}

class RemoteAgentClientUpdate {
  const RemoteAgentClientUpdate({
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

  factory RemoteAgentClientUpdate.fromJson(Map<String, dynamic> json) {
    return RemoteAgentClientUpdate(
      pending: json['pending'] as bool? ?? false,
      requestId: json['requestId'] as String?,
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
    required this.subscriberClientName,
    required this.table,
    required this.direction,
    required this.publisherServer,
    required this.publisherDatabase,
    required this.publisherUseWindowsAuth,
    required this.publisherUser,
    required this.publisherPassword,
    required this.status,
    required this.progress,
    required this.rowCount,
    required this.snapshotBytes,
    required this.snapshotCreatedAt,
    required this.snapshotId,
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
  final String publisherServer;
  final String publisherDatabase;
  final bool publisherUseWindowsAuth;
  final String publisherUser;
  final String publisherPassword;
  final String status;
  final int progress;
  final int rowCount;
  final int snapshotBytes;
  final String? snapshotCreatedAt;
  final String? snapshotId;
  final String createdAt;
  final String updatedAt;
  final String? startedAt;
  final String? completedAt;
  final String message;
  final String? error;

  factory RemoteSyncJob.fromJson(Map<String, dynamic> json) {
    return RemoteSyncJob(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      sourceClientName: json['sourceClientName'] as String? ?? '',
      subscriberClientName: json['subscriberClientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      direction: json['direction'] as String? ?? '',
      publisherServer: json['publisherServer'] as String? ?? '',
      publisherDatabase: json['publisherDatabase'] as String? ?? '',
      publisherUseWindowsAuth: json['publisherUseWindowsAuth'] as bool? ?? true,
      publisherUser: json['publisherUser'] as String? ?? '',
      publisherPassword: json['publisherPassword'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      progress: (json['progress'] as num? ?? 0).round(),
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      snapshotCreatedAt: json['snapshotCreatedAt'] as String?,
      snapshotId: json['snapshotId'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      startedAt: json['startedAt'] as String?,
      completedAt: json['completedAt'] as String?,
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
    );
  }

  bool get isActive =>
      status == 'queued' ||
      status == 'running' ||
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

  RemoteSnapshot copyWith({
    String? id,
    String? clientName,
    String? table,
    String? createdAt,
    int? rowCount,
    String? checksum,
    int? snapshotBytes,
    List<String>? columns,
    List<Map<String, String?>>? rows,
    String? sourceJobId,
  }) {
    return RemoteSnapshot(
      id: id ?? this.id,
      clientName: clientName ?? this.clientName,
      table: table ?? this.table,
      createdAt: createdAt ?? this.createdAt,
      rowCount: rowCount ?? this.rowCount,
      checksum: checksum ?? this.checksum,
      snapshotBytes: snapshotBytes ?? this.snapshotBytes,
      columns: columns ?? this.columns,
      rows: rows ?? this.rows,
      sourceJobId: sourceJobId ?? this.sourceJobId,
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
