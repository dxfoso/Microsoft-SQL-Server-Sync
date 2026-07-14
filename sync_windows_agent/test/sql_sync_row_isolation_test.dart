import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_sync_row_isolation.dart';

void main() {
  test(
    'isolates rejected rows and applies valid transactional groups',
    () async {
      final appliedIds = <int>[];
      final rejected = await applySqlSyncRowsWithIsolation(
        rows: List.generate(8, (index) => <String, dynamic>{'Id': index + 1}),
        applyBatch: (rows) async {
          if (rows.any((row) => row['Id'] == 5)) {
            throw Exception('AmnW0062: الرصيد أقل من صفر');
          }
          appliedIds.addAll(rows.map((row) => row['Id'] as int));
        },
      );

      expect(appliedIds, containsAll(<int>[1, 2, 3, 4, 6, 7, 8]));
      expect(appliedIds, isNot(contains(5)));
      expect(rejected, hasLength(1));
      expect(rejected.single.row['Id'], 5);
      expect(rejected.single.error, contains('الرصيد أقل من صفر'));
    },
  );

  test('formats bounded key and Unicode error details', () {
    final message = formatSqlSyncRejectedRows(
      rejected: const <SqlSyncRejectedRow>[
        SqlSyncRejectedRow(
          row: <String, dynamic>{'Id': 5},
          error: 'AmnW0062: الرصيد أقل من صفر',
        ),
      ],
      keyColumns: const <String>['Id'],
    );

    expect(message, contains('Id=5'));
    expect(message, contains('الرصيد أقل من صفر'));
  });

  test('does not isolate transport failures', () async {
    var attempts = 0;

    await expectLater(
      applySqlSyncRowsWithIsolation(
        rows: const <Map<String, dynamic>>[
          <String, dynamic>{'Id': 1},
          <String, dynamic>{'Id': 2},
        ],
        applyBatch: (rows) async {
          attempts += 1;
          throw Exception('sqlcmd timed out');
        },
        shouldIsolateError: (error) => !error.toString().contains('timed out'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(attempts, 1);
  });
}
