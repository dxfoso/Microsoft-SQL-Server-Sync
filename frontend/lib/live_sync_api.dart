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
    final normalized = trimmed.endsWith('/')
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
      return '${normalized}/call';
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

    if (response.statusCode != 200) {
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
    required String direction,
    String? sourceClientName,
  }) async {
    final decoded = await _invokeFunction('jobs_create', {
      'clientName': clientName,
      if (sourceClientName != null && sourceClientName.trim().isNotEmpty)
        'sourceClientName': sourceClientName,
      'direction': direction,
      'tables': [table],
    });
    if (decoded is! Map || decoded['jobs'] is! List) {
      throw const LiveSyncApiException('Unexpected job queue payload.');
    }
  }

  Future<void> updateAgentSyncSettings({
    required String clientName,
    required bool isMaster,
    required int historyLimit,
    required int autoSyncIntervalMinutes,
  }) async {
    await _invokeFunction('agent_sync_settings_post', {
      'clientName': clientName,
      'isMaster': isMaster,
      'historyLimit': historyLimit,
      'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
    });
  }

  Future<AdminSnapshotDetail?> fetchLatestSnapshot({
    required String clientName,
    required String table,
  }) async {
    try {
      final decoded = await _invokeFunction(
        'snapshots_latest',
        {'clientName': clientName, 'table': table},
      );
      if (decoded is! Map) {
        throw const LiveSyncApiException('Unexpected latest snapshot payload.');
      }
      return AdminSnapshotDetail.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error) {
      if (error is LiveSyncApiException &&
          error.message.toLowerCase().contains('not found')) {
        return null;
      }
      rethrow;
    }
  }

  Future<AdminSnapshotDetail?> fetchSnapshotById(String snapshotId) async {
    final trimmedId = snapshotId.trim();
    if (trimmedId.isEmpty) {
      return null;
    }

    try {
      final decoded = await _invokeFunction('snapshots_by_id', {
        'snapshotId': trimmedId,
      });
      if (decoded is! Map) {
        throw const LiveSyncApiException('Unexpected snapshot payload.');
      }

      return AdminSnapshotDetail.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error) {
      if (error is LiveSyncApiException &&
          error.message.toLowerCase().contains('not found')) {
        return null;
      }
      rethrow;
    }
  }

  Future<AdminSnapshotDetail> importSnapshot({
    required String clientName,
    required String table,
    required Map<String, dynamic> snapshot,
  }) async {
    final decoded = await _invokeFunction('snapshots_import', {
      'clientName': clientName,
      'table': table,
      'snapshot': snapshot,
    });
    if (decoded is! Map || decoded['snapshot'] is! Map) {
      throw const LiveSyncApiException('Unexpected snapshot import payload.');
    }
    return AdminSnapshotDetail.fromJson(
      Map<String, dynamic>.from(decoded['snapshot'] as Map),
    );
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
