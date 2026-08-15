import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/models.dart';

void main() {
  test('remote support progress is parsed for web monitoring', () {
    final diagnostics = AdminAgentDiagnostics.fromJson({
      'pending': false,
      'status': 'running',
      'stage': 'refreshing-table-fingerprints',
      'progressPercent': 80,
      'startedAt': '2026-08-15T18:00:00Z',
      'completedAt': null,
      'summary': 'Support report is available.',
    });

    expect(diagnostics.status, 'running');
    expect(diagnostics.stage, 'refreshing-table-fingerprints');
    expect(diagnostics.progressPercent, 80);
    expect(diagnostics.startedAt, '2026-08-15T18:00:00Z');
    expect(diagnostics.completedAt, isNull);
  });
}
