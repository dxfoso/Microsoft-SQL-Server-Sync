import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const String _defaultBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: '/api',
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
      return '/api';
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Uri _uriWithQuery(String path, Map<String, String> queryParameters) =>
      _uri(path).replace(queryParameters: queryParameters);

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

  Future<AuthLoginResult> loginWeb({
    required String name,
    required String password,
  }) async {
    final response = await _client.post(
      _uri('/auth/login'),
      headers: _headers(json: true),
      body: jsonEncode({
        'name': name.trim(),
        'password': password,
        'app': 'web',
      }),
    );

    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
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
    final response = await _client.get(_uri('/auth/me'), headers: _headers());
    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const LiveSyncApiException('Unexpected current-user payload.');
    }
    return AuthenticatedUser.fromJson(
      Map<String, dynamic>.from(decoded['user'] as Map),
    );
  }

  Future<void> logout() async {
    final response = await _client.post(
      _uri('/auth/logout'),
      headers: _headers(json: true),
    );
    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }
    setAuthToken(null);
  }

  Future<List<AuthenticatedUser>> listUsers() async {
    final response = await _client.get(_uri('/users'), headers: _headers());
    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
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
    final response = await _client.post(
      _uri('/users'),
      headers: _headers(json: true),
      body: jsonEncode({
        'name': name.trim(),
        'email': email?.trim() ?? '',
        'password': password,
        'role': role,
        if (ownerUserId != null && ownerUserId.trim().isNotEmpty)
          'ownerUserId': ownerUserId.trim(),
      }),
    );

    if (response.statusCode != 201) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['user'] is! Map) {
      throw const LiveSyncApiException('Unexpected create-user payload.');
    }

    return AuthenticatedUser.fromJson(
      Map<String, dynamic>.from(decoded['user'] as Map),
    );
  }

  Future<AdminLiveState> fetchLiveState() async {
    final response = await _client.get(
      _uri('/live-state'),
      headers: _headers(),
    );
    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
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
    final response = await _client.post(
      _uri('/jobs'),
      headers: _headers(json: true),
      body: jsonEncode({
        'clientName': clientName,
        if (sourceClientName != null && sourceClientName.trim().isNotEmpty)
          'sourceClientName': sourceClientName,
        'direction': direction,
        'tables': [table],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }
  }

  Future<AdminSnapshotDetail?> fetchLatestSnapshot({
    required String clientName,
    required String table,
  }) async {
    final response = await _client.get(
      _uriWithQuery('/snapshots/latest', {
        'clientName': clientName,
        'table': table,
      }),
      headers: _headers(),
    );

    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected latest snapshot payload.');
    }

    return AdminSnapshotDetail.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<AdminSnapshotDetail?> fetchSnapshotById(String snapshotId) async {
    final trimmedId = snapshotId.trim();
    if (trimmedId.isEmpty) {
      return null;
    }

    final response = await _client.get(
      _uri('/snapshots/$trimmedId'),
      headers: _headers(),
    );
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const LiveSyncApiException('Unexpected snapshot payload.');
    }

    return AdminSnapshotDetail.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<AdminSnapshotDetail> importSnapshot({
    required String clientName,
    required String table,
    required Map<String, dynamic> snapshot,
  }) async {
    final response = await _client.post(
      _uri('/snapshots/import'),
      headers: _headers(json: true),
      body: jsonEncode({
        'clientName': clientName,
        'table': table,
        'snapshot': snapshot,
      }),
    );

    if (response.statusCode != 200) {
      throw LiveSyncApiException(_errorMessageFromResponse(response));
    }

    final decoded = jsonDecode(response.body);
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
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
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

class LiveSyncApiException implements Exception {
  const LiveSyncApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
