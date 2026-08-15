import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/live_sync_api.dart';

void main() {
  test('server diagnostic command carries durable stage progress', () {
    final diagnostics = RemoteAgentDiagnostics.fromJson({
      'pending': true,
      'requestId': 'support-request-1',
      'status': 'running',
      'stage': 'running-self-tests',
      'progressPercent': 35,
      'startedAt': '2026-08-15T18:00:00Z',
    });

    expect(diagnostics.pending, isTrue);
    expect(diagnostics.requestId, 'support-request-1');
    expect(diagnostics.stage, 'running-self-tests');
    expect(diagnostics.progressPercent, 35);
  });
}
