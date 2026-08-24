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
    expect(single.build(), startsWith('v2:3:'));
    expect(single.build().split(':').last, hasLength(64));
  });

  test('fingerprint distinguishes close lossless SQL float values', () {
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
        name: 'Debit',
        sqlType: 'float',
        maxLength: 8,
        precision: 53,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ];
    const floatColumn = SqlSyncColumnDefinition(
      name: 'Debit',
      sqlType: 'float',
      maxLength: 8,
      precision: 53,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    );
    const guid = 'BFE518EB-0FC5-46AC-AEA5-793CBC26384F';
    // This is the exact legacy production collapse: SQL8 formatted both
    // physical values as the same six-significant-digit text.
    const oldVelvetTransport = '1.83275e+007';
    const oldAlTransport = '1.83275e+007';
    expect(oldVelvetTransport, oldAlTransport);

    final velvetValue = decodeSqlSyncFloatingPointTransport(
      column: floatColumn,
      value: r'\F41717A79A0000000',
    );
    final alValue = decodeSqlSyncFloatingPointTransport(
      column: floatColumn,
      value: r'\F41717A7CC0000000',
    );
    final rounded =
        SqlSyncFingerprintAccumulator()
          ..addRow(columns, {'GUID': guid, 'Debit': alValue});
    final lossless =
        SqlSyncFingerprintAccumulator()
          ..addRow(columns, {'GUID': guid, 'Debit': velvetValue});

    expect(rounded.build(), startsWith('v2:1:'));
    expect(lossless.build(), startsWith('v2:1:'));
    expect(rounded.build(), isNot(lossless.build()));
    expect(
      canonicalSqlSyncRowSha256(columns, {'GUID': guid, 'Debit': alValue}),
      isNot(
        canonicalSqlSyncRowSha256(columns, {
          'GUID': guid,
          'Debit': velvetValue,
        }),
      ),
    );
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

  test('server-reserved automatic number verifies exact before row only', () {
    const columns = [
      SqlSyncColumnDefinition(
        name: 'GUID',
        sqlType: 'uniqueidentifier',
        maxLength: 16,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
      SqlSyncColumnDefinition(
        name: 'Number',
        sqlType: 'int',
        maxLength: 4,
        precision: 10,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ];
    const before = {'GUID': 'purchase-guid', 'Number': '2307'};
    final sourceHash = canonicalSqlSyncRowSha256(columns, before);
    final reserved = <String, dynamic>{
      'GUID': 'purchase-guid',
      'Number': '2308',
      '__sync_row_hash': sourceHash,
      '__sync_auto_number_column': 'Number',
      '__sync_auto_number_before': '2307',
      '__sync_auto_number_after': '2308',
      '__sync_auto_number_incident_id': List.filled(64, 'a').join(),
    };

    expect(hasValidCanonicalSqlSyncRowHash(columns, reserved), isTrue);
    expect(
      hasValidCanonicalSqlSyncRowHash(columns, {...reserved, 'Number': '2309'}),
      isFalse,
    );
    expect(
      hasValidCanonicalSqlSyncRowHash(columns, {
        ...reserved,
        '__sync_auto_number_before': '2306',
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

  test(
    'range manifest localizes one changed row to one primary-key bucket',
    () {
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
          name: 'Value',
          sqlType: 'nvarchar',
          maxLength: 80,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ];
      final beforeRows = [
        for (var id = 1; id <= 64; id++) {'Id': '$id', 'Value': 'value-$id'},
      ];
      final afterRows = [
        for (final row in beforeRows)
          row['Id'] == '37' ? {...row, 'Value': 'changed'} : Map.of(row),
      ];

      final before = buildSqlSyncRangeFingerprintManifest(
        columns: columns,
        keyColumns: const ['Id'],
        rows: beforeRows,
      );
      final after = buildSqlSyncRangeFingerprintManifest(
        columns: columns,
        keyColumns: const ['Id'],
        rows: afterRows,
      );
      final differingBuckets = [
        for (var bucket = 0; bucket < kSqlSyncRangeBucketCount; bucket++)
          if (before.bucketFingerprints[bucket] !=
              after.bucketFingerprints[bucket])
            bucket,
      ];

      expect(before.rowCount, 64);
      expect(after.rowCount, 64);
      expect(before.tableChecksum, isNot(after.tableChecksum));
      expect(differingBuckets, hasLength(1));
      expect(
        differingBuckets.single,
        sqlSyncRangeBucketForRow(
          keyColumns: const ['Id'],
          row: const {'Id': '37', 'Value': 'changed'},
        ),
      );
      expect(
        SqlSyncRangeFingerprintManifest.tryParse(before.encode())?.encode(),
        before.encode(),
      );
    },
  );

  test(
    'selective range source is parsed strictly and filters deterministically',
    () {
      final selected = parseSqlSyncRangeUnionBuckets(
        'server-range-union-v1:2,7,12',
      );
      expect(selected, {2, 7, 12});
      expect(isSqlSyncRangeUnionSource('server-range-union-v1:2'), isTrue);
      expect(isSqlSyncRangeUnionSource('server-union-bootstrap-v3'), isFalse);
      expect(
        () => parseSqlSyncRangeUnionBuckets('server-range-union-v1:16'),
        throwsFormatException,
      );
      expect(
        SqlSyncRangeFingerprintManifest.tryParse('v2|16|1|checksum|too-short'),
        isNull,
      );
    },
  );

  test(
    'empty delta publishes its fresh complete inventory for anti-entropy',
    () {
      final metadata = resolveSqlSyncUploadInventoryMetadata(
        payloadRowCount: 0,
        completeRowCount: 731,
        completeTableChecksum: '731:fresh-lossless-float-checksum',
        completeRangeFingerprint: 'v2|16|731|fresh|buckets',
      );

      expect(metadata.rowCount, 731);
      expect(metadata.tableChecksum, '731:fresh-lossless-float-checksum');
      expect(metadata.rangeFingerprint, 'v2|16|731|fresh|buckets');
    },
  );

  test('delta without a completed audit does not fabricate inventory', () {
    final metadata = resolveSqlSyncUploadInventoryMetadata(payloadRowCount: 6);

    expect(metadata.rowCount, 6);
    expect(metadata.tableChecksum, isEmpty);
    expect(metadata.rangeFingerprint, isEmpty);
    expect(
      () => resolveSqlSyncUploadInventoryMetadata(
        payloadRowCount: 0,
        completeTableChecksum: 'checksum-without-count',
      ),
      throwsArgumentError,
    );
  });
}
