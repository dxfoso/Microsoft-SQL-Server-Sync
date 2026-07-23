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

  test('canonical row SHA-256 is stable for Arabic and detects any change', () {
    final columns = [
      const SqlSyncColumnDefinition(
        name: 'GUID',
        sqlType: 'uniqueidentifier',
        maxLength: 16,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
      const SqlSyncColumnDefinition(
        name: 'ArabicText',
        sqlType: 'nvarchar',
        maxLength: 400,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
      const SqlSyncColumnDefinition(
        name: 'Amount',
        sqlType: 'decimal',
        maxLength: 9,
        precision: 18,
        scale: 2,
        isIdentity: false,
        isComputed: false,
      ),
    ];
    final row = {
      'GUID': '3c97891e-93f6-4fe8-b1d5-c9803fe6822d',
      'ArabicText': 'البيانات العربية الصحيحة',
      'Amount': '123.45',
    };
    final hash = canonicalSqlSyncRowSha256(columns, row);
    final transported = {...row, '__sync_row_hash': hash};

    expect(hash, hasLength(64));
    expect(canonicalSqlSyncRowSha256(columns, Map.of(row)), hash);
    expect(hasValidCanonicalSqlSyncRowHash(columns, transported), isTrue);
    expect(
      canonicalSqlSyncRowSha256(columns, {...row, 'Amount': '123.46'}),
      isNot(hash),
    );
    expect(
      hasValidCanonicalSqlSyncRowHash(columns, {
        ...transported,
        'ArabicText': 'بيانات مختلفة',
      }),
      isFalse,
    );
  });

  test('operation identity is deterministic and origin-specific', () {
    final row = {'GUID': 'a-guid', 'Value': 'same'};
    final first = canonicalSqlSyncOperationId(
      table: 'db.dbo.pt000',
      originClient: 'c1',
      changeVersion: 42,
      operation: 'I',
      keyColumns: const ['GUID'],
      row: row,
      rowHash: 'abc',
    );
    final retry = canonicalSqlSyncOperationId(
      table: 'db.dbo.pt000',
      originClient: 'c1',
      changeVersion: 42,
      operation: 'I',
      keyColumns: const ['GUID'],
      row: Map.of(row),
      rowHash: 'abc',
    );
    final otherOrigin = canonicalSqlSyncOperationId(
      table: 'db.dbo.pt000',
      originClient: 'c2',
      changeVersion: 42,
      operation: 'I',
      keyColumns: const ['GUID'],
      row: row,
      rowHash: 'abc',
    );

    expect(first, hasLength(64));
    expect(retry, first);
    expect(otherOrigin, isNot(first));
  });
}
