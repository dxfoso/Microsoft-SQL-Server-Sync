import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const String _defaultBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'http://localhost:9001/api',
);

class LiveSyncApiClient {
  LiveSyncApiClient({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultBackendBaseUrl);

  final http.Client _client;
  final String _baseUrl;

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return 'http://localhost:9001/api';
    }
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Future<AdminLiveState> fetchLiveState() async {
    final response = await _client.get(_uri('/live-state'));
    if (response.statusCode != 200) {
      throw LiveSyncApiException(
        'Live state request failed with ${response.statusCode}.',
      );
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
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'clientName': clientName,
        'sourceClientName': sourceClientName ?? clientName,
        'direction': direction,
        'tables': [table],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveSyncApiException(
        'Sync request failed with ${response.statusCode}.',
      );
    }
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
}

class LiveSyncApiException implements Exception {
  const LiveSyncApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
