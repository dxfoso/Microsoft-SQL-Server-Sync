import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/models.dart';

void main() {
  test('client parses durable integrity progress and table batch history', () {
    final agent = AdminAgent.fromJson(<String, dynamic>{
      'clientName': 'client-a',
      'fingerprintAudit': <dynamic>[
        <String, dynamic>{
          'status': 'checking',
          'progressPercent': 40,
          'checkedTables': 4,
          'totalTables': 10,
          'lastBatchTables': <String>['db::a', 'db::b'],
          'history': <dynamic>[
            <String, dynamic>{
              'checkedCount': 2,
              'failedCount': 0,
              'unsupportedCount': 0,
              'tables': <dynamic>[
                <String, dynamic>{
                  'table': 'db::a',
                  'status': 'checked',
                  'rowCount': 12,
                },
              ],
            },
          ],
        },
      ],
    });

    expect(agent.fingerprintAudit.status, 'checking');
    expect(agent.fingerprintAudit.progressPercent, 40);
    expect(agent.fingerprintAudit.lastBatchTables, <String>['db::a', 'db::b']);
    expect(agent.fingerprintAudit.history.single.checkedCount, 2);
    expect(agent.fingerprintAudit.history.single.tables.single.table, 'db::a');
    expect(agent.fingerprintAudit.history.single.tables.single.rowCount, 12);
  });

  test('integrity duration covers the whole cycle and live elapsed time', () {
    final completed = AdminFingerprintAudit.fromJson(<String, dynamic>{
      'status': 'complete',
      'cycleStartedAt': '2026-08-24T08:00:00Z',
      'lastCompletedAt': '2026-08-24T08:07:30Z',
    });
    final checking = AdminFingerprintAudit.fromJson(<String, dynamic>{
      'status': 'checking',
      'cycleStartedAt': '2026-08-24T08:00:00Z',
    });

    expect(completed.duration(), const Duration(minutes: 7, seconds: 30));
    expect(completed.isActive, isFalse);
    expect(
      checking.duration(now: DateTime.parse('2026-08-24T08:02:15Z')),
      const Duration(minutes: 2, seconds: 15),
    );
    expect(checking.isActive, isTrue);
  });
}
