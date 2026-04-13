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
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Uri _uriWithQuery(String path, Map<String, String> queryParameters) =>
      _uri(path).replace(queryParameters: queryParameters);

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
        if (sourceClientName != null && sourceClientName.trim().isNotEmpty)
          'sourceClientName': sourceClientName,
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

  Future<AdminSnapshotDetail?> fetchLatestSnapshot({
    required String clientName,
    required String table,
  }) async {
    final response = await _client.get(
      _uriWithQuery('/snapshots/latest', {
        'clientName': clientName,
        'table': table,
      }),
    );

    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw LiveSyncApiException(
        'Latest snapshot request failed with ${response.statusCode}.',
      );
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

    final response = await _client.get(_uri('/snapshots/$trimmedId'));
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw LiveSyncApiException(
        'Snapshot request failed with ${response.statusCode}.',
      );
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
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'clientName': clientName,
        'table': table,
        'snapshot': snapshot,
      }),
    );

    if (response.statusCode != 200) {
      throw LiveSyncApiException(
        'Snapshot import failed with ${response.statusCode}.',
      );
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
}

class LiveSyncApiException implements Exception {
  const LiveSyncApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
