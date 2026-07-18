import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_admin_web/live_sync_api.dart';

void main() {
  test('automatic sync control posts requested pause state', () async {
    late Map<String, dynamic> requestPayload;
    final api = LiveSyncApiClient(
      baseUrl: 'https://sync.example/call',
      client: MockClient((request) async {
        requestPayload = Map<String, dynamic>.from(
          jsonDecode(request.body) as Map,
        );
        return http.Response(
          jsonEncode({
            'status': 'success',
            'value': {'ok': true, 'automaticSyncPaused': true},
          }),
          200,
        );
      }),
    );
    api.setAuthToken('test-token');

    final paused = await api.setAutomaticSyncPaused(paused: true);

    expect(paused, isTrue);
    expect(requestPayload['name'], 'automatic_sync_control_set');
    expect(requestPayload['args'], {'paused': true, 'token': 'test-token'});
    api.dispose();
  });

  test(
    'all-client sync settings returns server-confirmed update count',
    () async {
      late Map<String, dynamic> requestPayload;
      final api = LiveSyncApiClient(
        baseUrl: 'https://sync.example/call',
        client: MockClient((request) async {
          requestPayload = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          return http.Response(
            jsonEncode({
              'status': 'success',
              'value': {'ok': true, 'updatedCount': 2},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      api.setAuthToken('test-token');

      final updatedCount = await api.updateAllAgentSyncSettings(
        historyLimit: 10,
        autoSyncIntervalMinutes: 30,
      );

      expect(updatedCount, 2);
      expect(requestPayload['name'], 'agent_sync_settings_post_all');
      expect(requestPayload['args'], {
        'historyLimit': 10,
        'autoSyncIntervalMinutes': 30,
        'token': 'test-token',
      });
      api.dispose();
    },
  );
}
