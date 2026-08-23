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
}
