import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sync_windows_agent/live_sync_api.dart';

class _DelayedClient extends http.BaseClient {
  _DelayedClient({required this.delay, required this.responseForName});

  final Duration delay;
  final Map<String, Object?> Function(String name) responseForName;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final payload = jsonDecode(await request.finalize().bytesToString()) as Map;
    final name = payload['name'] as String? ?? '';
    await Future<void>.delayed(delay);
    final body = jsonEncode({
      'status': 'success',
      'value': responseForName(name),
    });
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

void main() {
  test(
    'uploadDiagnostics uses its longer timeout than regular control plane calls',
    () async {
      final client = AgentControlPlaneClient(
        client: _DelayedClient(
          delay: const Duration(milliseconds: 100),
          responseForName: (name) {
            switch (name) {
              case 'agent_diagnostics_upload':
                return {
                  'diagnostics': {
                    'requestId': 'req-1',
                    'status': 'uploaded',
                    'summary': 'ok',
                  },
                };
              case 'agent_client_update_ack':
                return {
                  'clientUpdate': {'requestId': 'req-1', 'status': 'current'},
                };
              default:
                return <String, Object?>{};
            }
          },
        ),
        baseUrl: 'https://example.com/call',
        controlPlaneRequestTimeout: const Duration(milliseconds: 50),
        diagnosticsUploadRequestTimeout: const Duration(milliseconds: 200),
      );

      final diagnostics = await client.uploadDiagnostics(
        clientName: 'c1',
        requestId: 'req-1',
        summary: 'summary',
        payload: '{"ok":true}',
      );

      expect(diagnostics.requestId, 'req-1');
      expect(diagnostics.status, 'uploaded');

      await expectLater(
        client.acknowledgeClientUpdate(
          clientName: 'c1',
          requestId: 'req-1',
          status: 'current',
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('timed out during acknowledging client update request'),
          ),
        ),
      );
    },
  );

  test(
    'heartbeat parses pending window actions and acknowledges them through the dedicated call',
    () async {
      final client = AgentControlPlaneClient(
        client: _DelayedClient(
          delay: Duration.zero,
          responseForName: (name) {
            switch (name) {
              case 'agents_heartbeat':
                return {
                  'windowAction': {
                    'pending': true,
                    'requestId': 'win-1',
                    'action': 'minimize',
                    'status': 'requested',
                  },
                };
              case 'agent_window_action_ack':
                return {
                  'windowAction': {
                    'requestId': 'win-1',
                    'action': 'minimize',
                    'status': 'completed',
                  },
                };
              default:
                return <String, Object?>{};
            }
          },
        ),
        baseUrl: 'https://example.com/call',
      );

      final heartbeat = await client.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      );

      expect(heartbeat.windowAction.pending, isTrue);
      expect(heartbeat.windowAction.action, 'minimize');

      final ack = await client.acknowledgeWindowAction(
        clientName: 'c1',
        requestId: 'win-1',
        action: 'minimize',
        status: 'completed',
      );

      expect(ack.requestId, 'win-1');
      expect(ack.status, 'completed');
    },
  );
}
