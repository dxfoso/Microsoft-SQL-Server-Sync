import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_state.dart';

const int kSyncProtocolVersion = 3;
const String _defaultControlPlaneUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'https://sync.velvet-leaf.com/call',
);
const String _liveControlPlaneUrl = 'https://sync.velvet-leaf.com/call';
const int _snapshotTransferChunkSizeBytes = 100 * 1024;
const int _defaultSnapshotTransferMaxAttempts = 10;
const Duration _defaultSnapshotTransferRequestTimeout = Duration(minutes: 10);
const Duration _defaultControlPlaneRequestTimeout = Duration(seconds: 10);
const Duration _defaultDiagnosticsUploadRequestTimeout = Duration(minutes: 2);
const List<Duration> _defaultSnapshotTransferRetryDelays = <Duration>[
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
typedef SyncCancellationCheck = void Function();

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
  AgentControlPlaneClient({
    http.Client? client,
    String? baseUrl,
    Duration controlPlaneRequestTimeout = _defaultControlPlaneRequestTimeout,
    Duration diagnosticsUploadRequestTimeout =
        _defaultDiagnosticsUploadRequestTimeout,
    int? snapshotTransferMaxAttempts,
    Duration? snapshotTransferRequestTimeout,
    List<Duration>? snapshotTransferRetryDelays,
  }) : _client = client ?? http.Client(),
       _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultControlPlaneUrl),
       _controlPlaneRequestTimeout = controlPlaneRequestTimeout,
       _diagnosticsUploadRequestTimeout = diagnosticsUploadRequestTimeout,
       _snapshotTransferMaxAttempts =
           (snapshotTransferMaxAttempts ??
                       _defaultSnapshotTransferMaxAttempts) <
                   1
               ? 1
               : (snapshotTransferMaxAttempts ??
                   _defaultSnapshotTransferMaxAttempts),
       _snapshotTransferRequestTimeout =
           snapshotTransferRequestTimeout ??
           _defaultSnapshotTransferRequestTimeout,
       _snapshotTransferRetryDelays =
           (snapshotTransferRetryDelays ?? _defaultSnapshotTransferRetryDelays)
                   .isEmpty
               ? const <Duration>[Duration.zero]
               : List<Duration>.unmodifiable(
                 snapshotTransferRetryDelays ??
                     _defaultSnapshotTransferRetryDelays,
               );

  final http.Client _client;
  final String _baseUrl;
  final Duration _controlPlaneRequestTimeout;
  final Duration _diagnosticsUploadRequestTimeout;
  final int _snapshotTransferMaxAttempts;
  final Duration _snapshotTransferRequestTimeout;
  final List<Duration> _snapshotTransferRetryDelays;
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

  List<T> _mapListOrThrow<T>(
    dynamic value,
    T Function(Map<String, dynamic> item) mapper,
    String message,
  ) {
    final raw = value as List<dynamic>? ?? const [];
    final items = <T>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw AgentControlPlaneException(message);
      }
      items.add(mapper(Map<String, dynamic>.from(entry)));
    }
    return items;
  }

  dynamic _decodeJsonOrThrow(String body, String message) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw AgentControlPlaneException(message);
    }
  }

  Uint8List _decodeBase64OrThrow(String encoded, String message) {
    try {
      return Uint8List.fromList(base64Decode(encoded));
    } on FormatException {
      throw AgentControlPlaneException(message);
    }
  }

  String _decodeGzipUtf8OrThrow(Uint8List bytes, String message) {
    try {
      return utf8.decode(gzip.decode(bytes));
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  Set<int> _intSetOrThrow(dynamic value, String message) {
    final raw = value as List<dynamic>? ?? const [];
    final values = <int>{};
    for (final entry in raw) {
      if (entry is! num) {
        throw AgentControlPlaneException(message);
      }
      values.add(entry.round());
    }
    return values;
  }

  Future<dynamic> _invokeFunction(
    String functionName,
    Map<String, dynamic> args,
    String phase, {
    Duration? timeout,
  }) async {
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
      timeout: timeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFromResponse(response);
    }
    return _unwrapApiResponse(
      _decodeJsonOrThrow(
        response.body,
        'Unexpected payload returned from $phase.',
      ),
    );
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
    String phase, {
    Duration? timeout,
  }) async {
    try {
      return await request.timeout(timeout ?? _controlPlaneRequestTimeout);
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
        // Final multi-writer chunks use an optimistic batch revision. A
        // concurrent writer can legitimately return 409; retrying the same
        // chunk is safe because chunkId makes the upload idempotent.
        statusCode == 409 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  bool _isRetryableTransferResponse(http.Response response) {
    if (_isRetryableTransferStatus(response.statusCode)) {
      return true;
    }
    if (response.statusCode != 200) {
      return false;
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['status'] != 'failed') {
        return false;
      }
      final message = _errorMessageFromMap(decoded).toLowerCase();
      return message.contains('db error') ||
          message.contains('database error') ||
          message.contains('temporarily unavailable') ||
          message.contains('timeout');
    } catch (_) {
      return false;
    }
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
        if (!_isRetryableTransferResponse(response) ||
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
        return await _invokeFunction(
          functionName,
          args,
          phase,
          timeout: _snapshotTransferRequestTimeout,
        );
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

    final user = _parseAuthenticatedUserPayload(
      token: decoded['token'],
      user: decoded['user'],
      message: 'Unexpected login payload.',
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
    return _parseAuthenticatedUserPayload(
      token: _authToken,
      user: decoded['user'],
      message: 'Unexpected current-user payload.',
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
        _client.get(_originUri('/health')),
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
    final decoded = _decodeJsonOrThrow(
      response.body,
      'Unexpected client update manifest payload.',
    );
    if (decoded is! Map<String, dynamic>) {
      throw const AgentControlPlaneException(
        'Unexpected client update manifest payload.',
      );
    }
    return _parseClientUpdateInfoPayload(
      decoded,
      'Unexpected client update manifest payload.',
    );
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

    final syncSettings =
        decoded['syncSettings'] is Map
            ? _parseRemoteAgentSyncSettingsPayload(
              decoded['syncSettings'],
              'Unexpected heartbeat payload.',
            )
            : RemoteAgentSyncSettings(
              historyLimit: historyLimit,
              autoSyncIntervalMinutes: autoSyncIntervalMinutes,
            );
    final tablePolicies = _mapListOrThrow(
      decoded['tablePolicies'],
      (item) => _parseRemoteTableSyncPolicyPayload(
        item,
        'Unexpected heartbeat payload.',
      ),
      'Unexpected heartbeat payload.',
    );
    final tableDependencies = _mapListOrThrow(
      decoded['tableDependencies'],
      (item) => _parseRemoteTableDependencyPayload(
        item,
        'Unexpected heartbeat payload.',
      ),
      'Unexpected heartbeat payload.',
    );
    final jobs = _mapListOrThrow(
      decoded['jobs'],
      (item) =>
          _parseRemoteSyncJobPayload(item, 'Unexpected heartbeat payload.'),
      'Unexpected heartbeat payload.',
    );
    return HeartbeatResult(
      syncSettings: syncSettings,
      tablePolicies: tablePolicies,
      tableDependencies: tableDependencies,
      jobs: jobs,
      diagnostics:
          decoded['diagnostics'] is Map
              ? _parseRemoteAgentDiagnosticsPayload(
                decoded['diagnostics'],
                'Unexpected heartbeat payload.',
              )
              : const RemoteAgentDiagnostics(),
      clientUpdate:
          decoded['clientUpdate'] is Map
              ? _parseRemoteAgentClientUpdatePayload(
                decoded['clientUpdate'],
                'Unexpected heartbeat payload.',
              )
              : const RemoteAgentClientUpdate(),
      windowAction:
          decoded['windowAction'] is Map
              ? _parseRemoteAgentWindowActionPayload(
                decoded['windowAction'],
                'Unexpected heartbeat payload.',
              )
              : const RemoteAgentWindowAction(),
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
    return _parseRemoteAgentClientUpdatePayload(
      response['clientUpdate'],
      'Unexpected client update acknowledgement payload.',
    );
  }

  Future<RemoteAgentDiagnostics> uploadDiagnostics({
    required String clientName,
    String? requestId,
    required String summary,
    required String payload,
  }) async {
    final response = await _invokeFunction(
      'agent_diagnostics_upload',
      {
        'clientName': clientName,
        if (requestId != null && requestId.trim().isNotEmpty)
          'requestId': requestId.trim(),
        'summary': summary,
        'payload': payload,
      },
      'uploading diagnostics',
      timeout: _diagnosticsUploadRequestTimeout,
    );
    if (response is! Map || response['diagnostics'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected diagnostics upload payload.',
      );
    }
    return _parseRemoteAgentDiagnosticsPayload(
      response['diagnostics'],
      'Unexpected diagnostics upload payload.',
    );
  }

  Future<RemoteAgentWindowAction> acknowledgeWindowAction({
    required String clientName,
    String? requestId,
    String action = '',
    required String status,
    String message = '',
  }) async {
    final response = await _invokeFunction('agent_window_action_ack', {
      'clientName': clientName,
      'requestId': requestId,
      'action': action,
      'status': status,
      'message': message,
    }, 'acknowledging window action request');
    if (response is! Map || response['windowAction'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected window action acknowledgement payload.',
      );
    }
    return _parseRemoteAgentWindowActionPayload(
      response['windowAction'],
      'Unexpected window action acknowledgement payload.',
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
    return _parseRemoteTableSyncPolicyPayload(
      response['policy'],
      'Unexpected table sync policy payload.',
    );
  }

  Future<List<RemoteSyncJob>> createJobs({
    required String clientName,
    required List<String> tables,
  }) async {
    final response = await _invokeFunction('jobs_create', {
      'clientName': clientName,
      'tables': tables,
    }, 'creating jobs');

    if (response is! Map) {
      throw const AgentControlPlaneException('Unexpected job queue payload.');
    }
    final decoded = response;
    return _mapListOrThrow(
      decoded['jobs'],
      (item) =>
          _parseRemoteSyncJobPayload(item, 'Unexpected job queue payload.'),
      'Unexpected job queue payload.',
    );
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
    int? rejectedRowCount,
    String? rejectionSummary,
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
      if (rejectedRowCount != null) 'rejectedRowCount': rejectedRowCount,
      if (rejectionSummary != null && rejectionSummary.trim().isNotEmpty)
        'rejectionSummary': rejectionSummary.trim(),
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
    SyncCancellationCheck? checkCancelled,
  }) async {
    checkCancelled?.call();
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
    checkCancelled?.call();

    if (startResponse.statusCode != 200) {
      throw _exceptionFromResponse(startResponse);
    }

    final startDecoded = _unwrapApiResponse(
      _decodeJsonOrThrow(
        startResponse.body,
        'Unexpected chunked upload start payload.',
      ),
    );
    if (startDecoded is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected chunked upload start payload.',
      );
    }
    final receivedIndexes = _intSetOrThrow(
      startDecoded['receivedIndexes'],
      'Unexpected chunked upload start payload.',
    );
    var bytesTransferred = 0;

    for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      checkCancelled?.call();
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
      checkCancelled?.call();

      if (chunkResponse.statusCode != 200) {
        throw _exceptionFromResponse(chunkResponse);
      }
      _unwrapApiResponse(
        _decodeJsonOrThrow(
          chunkResponse.body,
          'Unexpected snapshot chunk payload.',
        ),
      );
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
    checkCancelled?.call();
    if (response.statusCode != 200) {
      throw _exceptionFromResponse(response);
    }
    final decoded = _unwrapApiResponse(
      _decodeJsonOrThrow(
        response.body,
        'Unexpected snapshot upload completion payload.',
      ),
    );
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
      job: _parseRemoteSyncJobPayload(
        decoded['job'],
        'Unexpected snapshot upload completion payload.',
      ),
      targetJob:
          decoded['targetJob'] is Map
              ? _parseRemoteSyncJobPayload(
                decoded['targetJob'],
                'Unexpected target job in snapshot upload completion payload.',
              )
              : null,
      snapshot: _parseSnapshotPayload(
        decoded['snapshot'],
        'Unexpected snapshot upload completion payload.',
      ),
    );
  }

  Future<RemoteSnapshot> downloadSnapshot(
    String jobId, {
    SyncCancellationCheck? checkCancelled,
  }) async {
    checkCancelled?.call();
    final manifest = await _invokeFunctionWithRetry(
      'jobs_download_snapshot_manifest',
      {'jobId': jobId},
      'starting snapshot download',
    );
    checkCancelled?.call();
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
      checkCancelled?.call();
      final chunkDecoded = await _invokeFunctionWithRetry(
        'jobs_download_snapshot_chunk',
        {'jobId': jobId, 'chunkIndex': chunkIndex},
        'downloading snapshot chunk ${chunkIndex + 1} of $chunkCount',
      );
      checkCancelled?.call();
      if (chunkDecoded is! Map || chunkDecoded['chunkData'] is! String) {
        throw const AgentControlPlaneException(
          'Unexpected snapshot chunk payload.',
        );
      }
      buffer.add(
        _decodeBase64OrThrow(
          chunkDecoded['chunkData'] as String,
          'Unexpected snapshot chunk payload.',
        ),
      );
    }

    final compressedPayload = buffer.takeBytes();
    if (compressedPayload.length != compressedBytes) {
      throw const AgentControlPlaneException(
        'Downloaded snapshot byte count does not match the manifest.',
      );
    }

    final snapshotJson = _decodeGzipUtf8OrThrow(
      compressedPayload,
      'Unexpected decompressed snapshot payload.',
    );
    final decoded = _decodeJsonOrThrow(
      snapshotJson,
      'Unexpected decompressed snapshot payload.',
    );
    if (decoded is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected decompressed snapshot payload.',
      );
    }
    final snapshot = _parseSnapshotPayload(
      decoded,
      'Unexpected decompressed snapshot payload.',
    );
    if (snapshot.id.isEmpty && manifestResponse['snapshot'] is Map) {
      return _mergeSnapshotMetadataOrThrow(
        snapshot,
        manifestResponse['snapshot'],
        'Unexpected chunked download manifest payload.',
      );
    }
    return snapshot;
  }

  Future<RemoteSyncJob> uploadMultiWriterDelta(
    String jobId, {
    required String batchId,
    required String clientName,
    required String table,
    required List<String> columns,
    required List<String> keyColumns,
    required List<Map<String, String?>> rows,
    required String chunkId,
    required bool finalChunk,
    int? changeTrackingVersion,
    String? payloadBase64,
    bool payloadIsDelta = true,
    String snapshotChecksum = '',
    required int protocolVersion,
    required String syncEpoch,
  }) async {
    final encodedPayload =
        payloadBase64 ?? base64Encode(utf8.encode(jsonEncode(rows)));
    final decoded = await _invokeFunctionWithRetry('jobs_multi_writer_upload', {
      'jobId': jobId,
      'batchId': batchId,
      'clientName': clientName,
      'table': table,
      'columns': columns,
      'keyColumns': keyColumns,
      // The relay stores the encoded payload as a blob. Do not send the same
      // rows again in the request or retain them in the control-plane record.
      'rows': const <Map<String, String?>>[],
      'chunkId': chunkId,
      'finalChunk': finalChunk,
      if (changeTrackingVersion != null)
        'changeTrackingVersion': changeTrackingVersion,
      'payloadBase64': encodedPayload,
      'payloadRowCount': rows.length,
      'payloadIsDelta': payloadIsDelta,
      if (snapshotChecksum.trim().isNotEmpty)
        'snapshotChecksum': snapshotChecksum.trim(),
      'protocolVersion': protocolVersion,
      'syncEpoch': syncEpoch,
    }, 'uploading multi-writer delta');
    if (decoded is! Map || decoded['job'] is! Map) {
      throw const AgentControlPlaneException(
        'Unexpected multi-writer upload payload.',
      );
    }
    return _parseRemoteSyncJobPayload(
      decoded['job'],
      'Unexpected multi-writer upload payload.',
    );
  }

  Future<RemoteSnapshot> downloadMultiWriterDelta(
    String jobId, {
    required String batchId,
    required int protocolVersion,
    required String syncEpoch,
    Future<void> Function(RemoteSnapshot snapshot)? onChunk,
    SyncCancellationCheck? checkCancelled,
  }) async {
    String? cursor;
    RemoteSnapshot? firstSnapshot;
    final mergedRows = <Map<String, String?>>[];
    var mergedRowCount = 0;
    var totalSnapshotBytes = 0;
    while (true) {
      checkCancelled?.call();
      final decoded =
          await _invokeFunctionWithRetry('jobs_multi_writer_download', {
            'jobId': jobId,
            'batchId': batchId,
            'protocolVersion': protocolVersion,
            'syncEpoch': syncEpoch,
            if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          }, 'downloading merged multi-writer delta');
      checkCancelled?.call();
      if (decoded is! Map || decoded['snapshot'] is! Map) {
        throw const AgentControlPlaneException(
          'Unexpected merged multi-writer download payload.',
        );
      }
      final snapshotPayload = Map<String, dynamic>.from(
        decoded['snapshot'] as Map,
      );
      final encodedChunk = decoded['payloadBase64']?.toString() ?? '';
      if (encodedChunk.isNotEmpty) {
        final chunkJson = utf8.decode(base64Decode(encodedChunk));
        final chunkRows = jsonDecode(chunkJson);
        if (chunkRows is! List) {
          throw const AgentControlPlaneException(
            'Unexpected stored multi-writer payload.',
          );
        }
        snapshotPayload['rows'] = chunkRows;
      }
      final snapshot = _parseSnapshotPayload(
        snapshotPayload,
        'Unexpected merged multi-writer download payload.',
      );
      firstSnapshot ??= snapshot;
      mergedRowCount += snapshot.rows.length;
      if (onChunk != null) {
        await onChunk(snapshot);
      } else {
        mergedRows.addAll(snapshot.rows);
      }
      totalSnapshotBytes += snapshot.snapshotBytes;
      final done = decoded['done'] == true;
      if (done) {
        return firstSnapshot.copyWith(
          rowCount: mergedRowCount,
          rows: onChunk == null ? mergedRows : const [],
          snapshotBytes: totalSnapshotBytes,
          isDelta: firstSnapshot.isDelta && snapshot.isDelta,
        );
      }
      final nextCursor = decoded['nextCursor']?.toString();
      if (nextCursor == null || nextCursor.isEmpty || nextCursor == cursor) {
        throw const AgentControlPlaneException(
          'Merged multi-writer download did not advance its cursor.',
        );
      }
      cursor = nextCursor;
    }
  }

  ClientUpdateInfo _parseClientUpdateInfoPayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }

    try {
      return ClientUpdateInfo.fromJson(Map<String, dynamic>.from(response));
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteSyncJob _parseJobPayload(dynamic response, String phase) {
    if (response is! Map) {
      throw AgentControlPlaneException(
        'Unexpected payload returned from $phase.',
      );
    }
    final decoded = Map<String, dynamic>.from(response);
    if (decoded['job'] is! Map) {
      throw AgentControlPlaneException(
        'Unexpected payload returned from $phase.',
      );
    }

    return _parseRemoteSyncJobPayload(
      decoded['job'],
      'Unexpected payload returned from $phase.',
    );
  }

  RemoteSyncJob _parseRemoteSyncJobPayload(dynamic response, String message) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }

    try {
      return RemoteSyncJob.fromJson(Map<String, dynamic>.from(response));
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  AgentAuthenticatedUser _parseAuthenticatedUserPayload({
    required dynamic token,
    required dynamic user,
    required String message,
  }) {
    if (user is! Map) {
      throw AgentControlPlaneException(message);
    }

    try {
      final decoded = Map<String, dynamic>.from(user);
      return AgentAuthenticatedUser(
        token: token as String? ?? '',
        id: decoded['id'] as String? ?? '',
        username: decoded['username'] as String? ?? '',
        email: decoded['email'] as String? ?? '',
        name: decoded['name'] as String? ?? '',
        role: decoded['role'] as String? ?? '',
        ownerUserId: decoded['ownerUserId'] as String?,
        ownerUsername: decoded['ownerUsername'] as String?,
        ownerEmail: decoded['ownerEmail'] as String?,
        ownerName: decoded['ownerName'] as String?,
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteTableSyncPolicy _parseRemoteTableSyncPolicyPayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }
    try {
      return RemoteTableSyncPolicy.fromJson(
        Map<String, dynamic>.from(response),
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteAgentSyncSettings _parseRemoteAgentSyncSettingsPayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }
    try {
      return RemoteAgentSyncSettings.fromJson(
        Map<String, dynamic>.from(response),
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteTableDependency _parseRemoteTableDependencyPayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }
    try {
      return RemoteTableDependency.fromJson(
        Map<String, dynamic>.from(response),
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteAgentDiagnostics _parseRemoteAgentDiagnosticsPayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }
    try {
      return RemoteAgentDiagnostics.fromJson(
        Map<String, dynamic>.from(response),
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteAgentClientUpdate _parseRemoteAgentClientUpdatePayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }
    try {
      return RemoteAgentClientUpdate.fromJson(
        Map<String, dynamic>.from(response),
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteAgentWindowAction _parseRemoteAgentWindowActionPayload(
    dynamic response,
    String message,
  ) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }
    try {
      return RemoteAgentWindowAction.fromJson(
        Map<String, dynamic>.from(response),
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteSnapshot _parseSnapshotPayload(dynamic response, String message) {
    if (response is! Map) {
      throw AgentControlPlaneException(message);
    }

    final decoded = Map<String, dynamic>.from(response);
    final columns = decoded['columns'];
    if (columns != null && columns is! List) {
      throw AgentControlPlaneException(message);
    }

    final rows = decoded['rows'];
    if (rows != null && rows is! List) {
      throw AgentControlPlaneException(message);
    }
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) {
          throw AgentControlPlaneException(message);
        }
      }
    }

    try {
      return RemoteSnapshot.fromJson(decoded);
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  RemoteSnapshot _mergeSnapshotMetadataOrThrow(
    RemoteSnapshot snapshot,
    dynamic metadata,
    String message,
  ) {
    if (metadata is! Map) {
      throw AgentControlPlaneException(message);
    }

    try {
      final decoded = Map<String, dynamic>.from(metadata);
      return snapshot.copyWith(
        id: decoded['id'] as String? ?? '',
        clientName: decoded['clientName'] as String? ?? '',
        createdAt: decoded['createdAt'] as String? ?? '',
        rowCount: (decoded['rowCount'] as num? ?? snapshot.rowCount).round(),
        checksum: decoded['checksum'] as String? ?? '',
        snapshotBytes:
            (decoded['snapshotBytes'] as num? ?? snapshot.snapshotBytes)
                .round(),
        sourceJobId: decoded['sourceJobId'] as String?,
      );
    } catch (_) {
      throw AgentControlPlaneException(message);
    }
  }

  void dispose() {
    _client.close();
  }

  String _errorMessageFromResponse(http.Response response) {
    if (response.statusCode == 503) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final detailed = _errorMessageFromMap(decoded).trim();
          if (detailed.isNotEmpty && detailed != 'Request failed.') {
            return detailed;
          }
        }
      } catch (_) {}
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
    required this.windowAction,
  });

  final RemoteAgentSyncSettings syncSettings;
  final List<RemoteTableSyncPolicy> tablePolicies;
  final List<RemoteTableDependency> tableDependencies;
  final List<RemoteSyncJob> jobs;
  final RemoteAgentDiagnostics diagnostics;
  final RemoteAgentClientUpdate clientUpdate;
  final RemoteAgentWindowAction windowAction;
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

class RemoteAgentWindowAction {
  const RemoteAgentWindowAction({
    this.pending = false,
    this.requestId,
    this.requestedAt,
    this.requestedByUserId,
    this.action,
    this.lastRequestId,
    this.acknowledgedAt,
    this.status = 'idle',
    this.message = '',
  });

  final bool pending;
  final String? requestId;
  final String? requestedAt;
  final String? requestedByUserId;
  final String? action;
  final String? lastRequestId;
  final String? acknowledgedAt;
  final String status;
  final String message;

  factory RemoteAgentWindowAction.fromJson(Map<String, dynamic> json) {
    return RemoteAgentWindowAction(
      pending: json['pending'] as bool? ?? false,
      requestId: json['requestId'] as String?,
      requestedAt: json['requestedAt'] as String?,
      requestedByUserId: json['requestedByUserId'] as String?,
      action: json['action'] as String? ?? '',
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
    this.batchId,
    this.protocolVersion = 0,
    this.syncEpoch = '',
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
  final String? batchId;
  final int protocolVersion;
  final String syncEpoch;

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
      batchId: json['batchId'] as String?,
      protocolVersion: (json['protocolVersion'] as num? ?? 0).round(),
      syncEpoch: json['syncEpoch'] as String? ?? '',
    );
  }

  bool get isActive =>
      status == 'queued' ||
      status == 'running' ||
      status == 'snapshotting' ||
      status == 'uploading' ||
      status == 'downloading' ||
      status == 'applying' ||
      (status == 'waiting' && batchId?.trim().isNotEmpty == true);
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
    this.changeTrackingVersion,
    this.changeTrackingVersions = const <String, int>{},
    this.isDelta = false,
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
  final int? changeTrackingVersion;
  final Map<String, int> changeTrackingVersions;
  final bool isDelta;

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
      changeTrackingVersion: (json['changeTrackingVersion'] as num?)?.round(),
      changeTrackingVersions: _parseChangeTrackingVersions(
        json['clientChangeTrackingVersions'],
      ),
      isDelta: json['isDelta'] == true,
    );
  }

  static Map<String, int> _parseChangeTrackingVersions(dynamic raw) {
    if (raw is! List) {
      return const <String, int>{};
    }
    final result = <String, int>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final clientName = item['clientName']?.toString().trim() ?? '';
      final version = (item['changeTrackingVersion'] as num?)?.round();
      if (clientName.isNotEmpty && version != null && version >= 0) {
        result[clientName] = version;
      }
    }
    return result;
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
    int? changeTrackingVersion,
    Map<String, int>? changeTrackingVersions,
    bool? isDelta,
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
      changeTrackingVersion:
          changeTrackingVersion ?? this.changeTrackingVersion,
      changeTrackingVersions:
          changeTrackingVersions ?? this.changeTrackingVersions,
      isDelta: isDelta ?? this.isDelta,
    );
  }
}

class UploadSnapshotResult {
  const UploadSnapshotResult({
    required this.job,
    required this.snapshot,
    this.targetJob,
  });

  final RemoteSyncJob job;
  final RemoteSyncJob? targetJob;
  final RemoteSnapshot snapshot;
}

class AgentControlPlaneException implements Exception {
  const AgentControlPlaneException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
