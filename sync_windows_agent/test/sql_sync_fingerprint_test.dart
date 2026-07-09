import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_sync_fingerprint.dart';
import 'package:sync_windows_agent/sql_sync_schema.dart';

void main() {
  test('fingerprint accumulator is stable across chunk boundaries', () {
    final columns = [
      const SqlSyncColumnDefinition(
        name: 'Id',
        sqlType: 'int',
        maxLength: 4,
        precision: 10,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
      const SqlSyncColumnDefinition(
        name: 'Name',
        sqlType: 'nvarchar',
        maxLength: 40,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ];
    final rows = [
      {'Id': '1', 'Name': 'alpha'},
      {'Id': '2', 'Name': 'beta'},
      {'Id': '3', 'Name': 'gamma'},
    ];

    final single = SqlSyncFingerprintAccumulator();
    for (final row in rows) {
      single.addRow(columns, row);
    }

    final split = SqlSyncFingerprintAccumulator();
    for (final row in rows.take(2)) {
      split.addRow(columns, row);
    }
    for (final row in rows.skip(2)) {
      split.addRow(columns, row);
    }

    expect(single.build(), split.build());
    expect(single.build(), '3:32a21c9a0122811d');
  });

  test('fingerprint encoding escapes separators and nulls', () {
    expect(encodeSqlSyncFingerprintField(null), r'\N');
    expect(encodeSqlSyncFingerprintField(r'a\b'), r'a\\b');
    expect(encodeSqlSyncFingerprintField('a\r\nb'), r'a\r\nb');
    expect(
      encodeSqlSyncFingerprintField(
        'a${String.fromCharCode(31)}b${String.fromCharCode(30)}c${String.fromCharCode(29)}d',
      ),
      r'a\u001fb\u001ec\u001dd',
    );
  });
}
