import 'dart:convert';
import 'package:http/http.dart' as http;

import 'models.dart';

const String _defaultBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: '/call',
);

class LiveSyncApiClient {
  LiveSyncApiClient({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultBackendBaseUrl);

  final http.Client _client;
  final String _baseUrl;
  String? _authToken;

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return '/call';
    }
    final normalized =
        trimmed.endsWith('/')
            ? trimmed.substring(0, trimmed.length - 1)
            : trimmed;
    if (normalized == '/call') {
      return normalized;
    }
    final parsed = Uri.tryParse(normalized);
    if (parsed != null &&
        parsed.hasScheme &&
        parsed.host.isNotEmpty &&
        (parsed.path.isEmpty || parsed.path == '/')) {
      return '$normalized/call';
    }
    return normalized;
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');
  Uri _uriCall() => Uri.parse(_baseUrl);

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

  dynamic _unwrapApiResponse(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) {
      return decoded;
    }

    final status = decoded['status'];
    if (status == 'failed') {
      throw LiveSyncApiException(_errorMessageFromMap(decoded));
    }

    if (status == 'success' && decoded.containsKey('value')) {
      return decoded['value'];
    }

    return decoded;
  }

  Future<dynamic> _invokeFunction(
    String name,
    Map<String, dynamic> args,
  ) async {
    final payloadArgs = <String, dynamic>{...args};
    if (_authToken != null && _authToken!.isNotEmpty && name != 'auth_login') {
      payloadArgs['token'] = _authToken;
    }
    final response = await _client.post(
      _uriCall(),
      headers: _headers(json: true),
      body: jsonEncode({'name': name, 'args': payloadArgs}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    return _unwrapApiResponse(decoded);
  }

  Future<AuthLoginResult> loginWeb({
    required String name,
    required String password,
  }) async {
    final decoded = await _invokeFunction('auth_login', {
      'name': name.trim(),
      'email': name.trim(),
      'password': password,
      'app': 'web',
    });
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const LiveSyncApiException('Unexpected login payload.');
    }

    final result = AuthLoginResult(
      token: decoded['token'] as String? ?? '',
      user: AuthenticatedUser.fromJson(
        Map<String, dynamic>.from(decoded['user'] as Map),
      ),
    );
    setAuthToken(result.token);
    return result;
  }

  Future<AuthenticatedUser> fetchCurrentUser() async {
    final decoded = await _invokeFunction('auth_me', {});
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const LiveSyncApiException('Unexpected current-user payload.');
    }
    return AuthenticatedUser.fromJson(
      Map<String, dynamic>.from(decoded['user'] as Map),
    );
  }

  Future<void> logout() async {
    await _invokeFunction('auth_logout', {});
    setAuthToken(null);
  }

  Future<List<AuthenticatedUser>> listUsers() async {
    final decoded = await _invokeFunction('users_list', {});
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected users payload.');
    }

    final users = decoded['users'] as List<dynamic>? ?? const [];
    return users
        .map(
          (item) => AuthenticatedUser.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<AuthenticatedUser> createUser({
    required String name,
    String? email,
    required String password,
    required String role,
    String? ownerUserId,
  }) async {
    final decoded = await _invokeFunction('users_create', {
      'name': name.trim(),
      'email': email?.trim() ?? '',
      'password': password,
      'role': role,
      if (ownerUserId != null && ownerUserId.trim().isNotEmpty)
        'ownerUserId': ownerUserId.trim(),
    });
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const LiveSyncApiException('Unexpected create-user payload.');
    }
    return AuthenticatedUser.fromJson(
      Map<String, dynamic>.from(decoded['user'] as Map),
    );
  }

  Future<void> resetUserPassword({
    required String userId,
    required String newPassword,
  }) async {
    final trimmedUserId = userId.trim();
    await _invokeFunction('user_reset_password', {
      'userId': trimmedUserId,
      'password': newPassword,
    });
  }

  Future<void> deleteUser({required String userId}) async {
    final trimmedUserId = userId.trim();
    await _invokeFunction('user_delete', {'userId': trimmedUserId});
  }

  Future<AdminLiveState> fetchLiveState() async {
    final decoded = await _invokeFunction('live_state', {});
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected live state payload.');
    }

    return AdminLiveState.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<void> triggerJob({
    required String clientName,
    required String table,
  }) async {
    final decoded = await _invokeFunction('jobs_create', {
      'clientName': clientName,
      'tables': [table],
    });
    if (decoded is! Map || decoded['jobs'] is! List) {
      throw const LiveSyncApiException('Unexpected job queue payload.');
    }
  }

  Future<bool> setAgentSyncEnabled({
    required String clientName,
    required bool enabled,
  }) async {
    final decoded = await _invokeFunction('agent_sync_enabled_set', {
      'clientName': clientName,
      'enabled': enabled,
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected client synchronization state payload.',
      );
    }
    return decoded['syncEnabled'] as bool? ?? enabled;
  }

  Future<AdminBulkSyncResult> triggerSyncAllEnabledNow() async {
    final decoded = await _invokeFunction('jobs_create_all_enabled', {});
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected bulk sync payload.');
    }
    return AdminBulkSyncResult.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<bool> setAutomaticSyncPaused({required bool paused}) async {
    final decoded = await _invokeFunction('automatic_sync_control_set', {
      'paused': paused,
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected automatic sync control payload.',
      );
    }
    return decoded['automaticSyncPaused'] as bool? ?? paused;
  }

  Future<int> reconcileAuthoritative({
    required String sourceClientName,
    required List<String> targetClientNames,
    required List<String> tables,
  }) async {
    final decoded = await _invokeFunction('jobs_reconcile_authoritative', {
      'sourceClientName': sourceClientName.trim(),
      'targetClientNames': targetClientNames
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toList(growable: false),
      'tables': tables
          .map((table) => table.trim())
          .where((table) => table.isNotEmpty)
          .toList(growable: false),
    });
    if (decoded is! Map || decoded['jobs'] is! List) {
      throw const LiveSyncApiException(
        'Unexpected authoritative reconciliation payload.',
      );
    }
    return (decoded['jobs'] as List).length;
  }

  Future<int> resolveTableSyncIssue({
    required String clientName,
    required String table,
    required String action,
    String sourceClientName = '',
  }) async {
    final decoded = await _invokeFunction('table_sync_issue_resolve', {
      'clientName': clientName.trim(),
      'table': table.trim(),
      'action': action.trim(),
      if (sourceClientName.trim().isNotEmpty)
        'sourceClientName': sourceClientName.trim(),
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected table resolution payload.');
    }
    return (decoded['jobs'] as List<dynamic>? ?? const []).length;
  }

  Future<AdminBulkDiagnosticsRequestResult> requestAllAgentDiagnostics() async {
    final decoded = await _invokeFunction('agent_diagnostics_request_all', {});
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected bulk diagnostics request payload.',
      );
    }
    return AdminBulkDiagnosticsRequestResult.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<AdminBulkDiagnosticsRequestResult> requestAgentDiagnosticsBatch({
    required List<String> clientNames,
    String requestId = '',
  }) async {
    final normalizedClientNames = clientNames
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final decoded = await _invokeFunction('agent_diagnostics_request_batch', {
      'clientNames': normalizedClientNames,
      if (requestId.trim().isNotEmpty) 'requestId': requestId.trim(),
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected diagnostics batch request payload.',
      );
    }
    return AdminBulkDiagnosticsRequestResult.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<AdminBulkClientUpdateRequestResult>
  requestAllAgentClientUpdates() async {
    final decoded = await _invokeFunction(
      'agent_client_update_request_all',
      {},
    );
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected bulk client update request payload.',
      );
    }
    return AdminBulkClientUpdateRequestResult.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<AdminBulkWindowActionRequestResult> requestAllAgentWindowActions({
    String action = 'minimize',
  }) async {
    final decoded = await _invokeFunction('agent_window_action_request_all', {
      'action': action.trim(),
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected bulk window action request payload.',
      );
    }
    return AdminBulkWindowActionRequestResult.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<AdminServerResetResult> resetServerSavedData() async {
    var continueReset = false;
    var transientRetryCount = 0;
    var cancelledJobCount = 0;
    var deletedRecordCount = 0;
    var jobDeletedCount = 0;
    var agentResetCount = 0;
    var automaticSyncPaused = false;

    // Drain bounded, durable server batches instead of holding one recursive
    // request open until every storage object has been removed.
    for (var batch = 0; batch < 10000;) {
      dynamic decoded;
      try {
        decoded = await _invokeFunction('server_saved_data_reset', {
          'resetAgents': true,
          'continueReset': continueReset,
        });
        transientRetryCount = 0;
      } catch (error) {
        if (!_isTransientServerResetError(error) || transientRetryCount >= 4) {
          rethrow;
        }
        transientRetryCount += 1;
        continue;
      }
      if (decoded is! Map) {
        throw const LiveSyncApiException('Unexpected server reset payload.');
      }
      final result = Map<String, dynamic>.from(decoded);
      cancelledJobCount += (result['cancelledJobCount'] as num? ?? 0).round();
      deletedRecordCount += (result['deletedRecordCount'] as num? ?? 0).round();
      jobDeletedCount += (result['jobDeletedCount'] as num? ?? 0).round();
      agentResetCount += (result['agentResetCount'] as num? ?? 0).round();
      automaticSyncPaused = result['automaticSyncPaused'] == true;
      if (result['hasMore'] != true) {
        return AdminServerResetResult(
          cancelledJobCount: cancelledJobCount,
          deletedRecordCount: deletedRecordCount,
          jobDeletedCount: jobDeletedCount,
          agentResetCount: agentResetCount,
          cleanupStatus: result['cleanupStatus'] as String? ?? 'cleaned',
          automaticSyncPaused: automaticSyncPaused,
        );
      }
      continueReset = true;
      batch += 1;
    }
    throw const LiveSyncApiException(
      'Server reset did not finish within the safety batch limit.',
    );
  }

  bool _isTransientServerResetError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('request timeout') ||
        message.contains('timed out') ||
        message.contains('connection reset') ||
        message.contains('request failed with 502') ||
        message.contains('request failed with 503') ||
        message.contains('request failed with 504');
  }

  Future<AdminAgentDiagnostics> requestAgentDiagnostics({
    required String clientName,
  }) async {
    final decoded = await _invokeFunction('agent_diagnostics_request', {
      'clientName': clientName.trim(),
    });
    if (decoded is! Map || decoded['diagnostics'] is! Map) {
      throw const LiveSyncApiException(
        'Unexpected diagnostics request payload.',
      );
    }
    return AdminAgentDiagnostics.fromJson(
      Map<String, dynamic>.from(decoded['diagnostics'] as Map),
    );
  }

  Future<AdminAgentClientUpdate> requestAgentClientUpdate({
    required String clientName,
  }) async {
    final decoded = await _invokeFunction('agent_client_update_request', {
      'clientName': clientName.trim(),
    });
    if (decoded is! Map || decoded['clientUpdate'] is! Map) {
      throw const LiveSyncApiException(
        'Unexpected client update request payload.',
      );
    }
    return AdminAgentClientUpdate.fromJson(
      Map<String, dynamic>.from(decoded['clientUpdate'] as Map),
    );
  }

  Future<AdminAgentDiagnostics> fetchAgentDiagnostics({
    required String clientName,
  }) async {
    final decoded = await _invokeFunction('agent_diagnostics_get', {
      'clientName': clientName.trim(),
    });
    if (decoded is! Map || decoded['diagnostics'] is! Map) {
      throw const LiveSyncApiException('Unexpected diagnostics payload.');
    }
    return AdminAgentDiagnostics.fromJson(
      Map<String, dynamic>.from(decoded['diagnostics'] as Map),
    );
  }

  Future<void> updateAgentSyncSettings({
    required String clientName,
    required int historyLimit,
    required int autoSyncIntervalMinutes,
    int? syncDataLimitMb,
  }) async {
    await _invokeFunction('agent_sync_settings_post', {
      'clientName': clientName,
      'historyLimit': historyLimit,
      'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
      if (syncDataLimitMb != null) 'syncDataLimitMb': syncDataLimitMb,
    });
  }

  Future<int> updateAllAgentSyncSettings({
    required int historyLimit,
    required int autoSyncIntervalMinutes,
    int? syncDataLimitMb,
  }) async {
    final decoded = await _invokeFunction('agent_sync_settings_post_all', {
      'historyLimit': historyLimit,
      'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
      if (syncDataLimitMb != null) 'syncDataLimitMb': syncDataLimitMb,
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected sync settings update payload.',
      );
    }
    return (decoded['updatedCount'] as num? ?? 0).round();
  }

  Future<AdminSyncJobDataPage> fetchSyncJobData({
    required String jobId,
    String? cursor,
  }) async {
    final decoded = await _invokeFunction('sync_job_data_get', {
      'jobId': jobId,
      if (cursor?.trim().isNotEmpty == true) 'cursor': cursor!.trim(),
    });
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected sync job data payload.');
    }
    final payload = Map<String, dynamic>.from(decoded);
    var rows = _jobDataRows(payload['rows']);
    final encodedPayload = payload['payloadBase64']?.toString().trim() ?? '';
    if (encodedPayload.isNotEmpty) {
      try {
        rows = _jobDataRows(
          jsonDecode(utf8.decode(base64Decode(encodedPayload))),
        );
      } catch (_) {
        throw const LiveSyncApiException('Stored sync job data is unreadable.');
      }
    }
    var columns = (payload['columns'] as List<dynamic>? ?? const [])
        .map((item) => item.toString())
        .where((item) => item.trim().isNotEmpty)
        .toList(growable: false);
    if (columns.isEmpty && rows.isNotEmpty) {
      columns = rows.first.keys.toList(growable: false);
    }
    return AdminSyncJobDataPage(
      available: payload['available'] == true,
      pruned: payload['pruned'] == true,
      sourceJobId: payload['sourceJobId']?.toString() ?? '',
      sourceClientName: payload['sourceClientName']?.toString() ?? '',
      columns: columns,
      rows: rows,
      rowCount: (payload['rowCount'] as num? ?? rows.length).round(),
      retainedRowCount:
          (payload['retainedRowCount'] as num? ?? rows.length).round(),
      retainedBytes: (payload['retainedBytes'] as num? ?? 0).round(),
      chunkCount: (payload['chunkCount'] as num? ?? 0).round(),
      nextCursor: payload['nextCursor']?.toString(),
      done: payload['done'] != false,
    );
  }

  Future<AdminSyncDataStorageStatus> fetchSyncDataStorageStatus() async {
    final decoded = await _invokeFunction('sync_data_storage_status', {});
    if (decoded is! Map) {
      throw const LiveSyncApiException(
        'Unexpected sync data storage status payload.',
      );
    }
    return AdminSyncDataStorageStatus.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  List<Map<String, dynamic>> _jobDataRows(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Future<void> updateTableSyncPolicy({
    required String clientName,
    required String table,
    required bool enabled,
  }) async {
    final trimmedTable = table.trim();
    final trimmedClientName = clientName.trim();
    if (trimmedTable.isEmpty) {
      throw const LiveSyncApiException('Table is required.');
    }
    await _invokeFunction('table_sync_policy_set', {
      if (trimmedClientName.isNotEmpty) 'clientName': trimmedClientName,
      'table': trimmedTable,
      'enabled': enabled,
    });
  }

  Future<bool> checkHealth() async {
    try {
      final response = await _client.get(_uri('/health'));
      if (response.statusCode != 200) {
        return false;
      }
      final decoded = _unwrapApiResponse(jsonDecode(response.body));
      return decoded is Map && decoded['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _client.close();
  }

  String _errorMessageFromMap(Map<String, dynamic> payload) {
    final messages = payload['messages'];
    if (messages is List && messages.isNotEmpty) {
      final first = messages.first;
      if (first is Map && first['text'] is String) {
        return first['text'] as String;
      }
    }
    if (payload['error'] is String) {
      return payload['error'] as String;
    }
    return 'Request failed.';
  }

  String _errorMessageFromResponse(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return _errorMessageFromMap(decoded);
      }
    } catch (_) {}
    return 'Request failed with ${response.statusCode}.';
  }
}

class LiveSyncApiException implements Exception {
  const LiveSyncApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
