import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sql_sync_schema.dart';

const int _sqlSyncFingerprintFieldSeparator = 31;
const int _sqlSyncFingerprintRowSeparator = 29;
const int _sqlSyncFingerprintEscapeSeparator = 30;
const int _fnv64OffsetBasis = 0xcbf29ce484222325;
const int _fnv64Prime = 0x100000001b3;
const int _fnv64Mask = 0xffffffffffffffff;
const int kSqlSyncRangeBucketCount = 16;
const String kSqlSyncRangeFingerprintVersion = 'v1';
const String kSqlSyncRangeUnionSourcePrefix = 'server-range-union-v1:';

class SqlSyncFingerprintAccumulator {
  int _rowCount = 0;
  int _hash = _fnv64OffsetBasis;

  int get rowCount => _rowCount;

  void addRow(List<SqlSyncColumnDefinition> columns, Map<String, dynamic> row) {
    for (final column in columns) {
      _addEncodedString(encodeSqlSyncFingerprintField(row[column.name]));
      _addByte(_sqlSyncFingerprintFieldSeparator);
    }
    _addByte(_sqlSyncFingerprintRowSeparator);
    _rowCount += 1;
  }

  String build() {
    final hex = _hash.toRadixString(16).padLeft(16, '0');
    return '$_rowCount:$hex';
  }

  void _addEncodedString(String value) {
    for (final codeUnit in value.codeUnits) {
      _addByte(codeUnit);
    }
  }

  void _addByte(int byte) {
    _hash ^= byte;
    _hash = (_hash * _fnv64Prime) & _fnv64Mask;
  }
}

class SqlSyncRangeFingerprintManifest {
  const SqlSyncRangeFingerprintManifest({
    required this.rowCount,
    required this.tableChecksum,
    required this.bucketFingerprints,
  });

  final int rowCount;
  final String tableChecksum;
  final List<String> bucketFingerprints;

  String encode() => <String>[
    kSqlSyncRangeFingerprintVersion,
    bucketFingerprints.length.toString(),
    rowCount.toString(),
    tableChecksum,
    ...bucketFingerprints,
  ].join('|');

  static SqlSyncRangeFingerprintManifest? tryParse(String encoded) {
    final parts = encoded.trim().split('|');
    if (parts.length < 5 || parts[0] != kSqlSyncRangeFingerprintVersion) {
      return null;
    }
    final bucketCount = int.tryParse(parts[1]);
    final rowCount = int.tryParse(parts[2]);
    if (bucketCount == null ||
        bucketCount <= 0 ||
        rowCount == null ||
        rowCount < 0 ||
        parts.length != bucketCount + 4 ||
        parts[3].trim().isEmpty) {
      return null;
    }
    final buckets = parts.sublist(4);
    if (buckets.any((value) => value.trim().isEmpty)) {
      return null;
    }
    return SqlSyncRangeFingerprintManifest(
      rowCount: rowCount,
      tableChecksum: parts[3],
      bucketFingerprints: List<String>.unmodifiable(buckets),
    );
  }
}

int sqlSyncRangeBucketForRow({
  required List<String> keyColumns,
  required Map<String, dynamic> row,
  int bucketCount = kSqlSyncRangeBucketCount,
}) {
  if (keyColumns.isEmpty || bucketCount <= 0) {
    throw ArgumentError('Range reconciliation requires primary-key columns.');
  }
  final framedKey = jsonEncode([
    for (final column in keyColumns)
      [column.toLowerCase(), encodeSqlSyncFingerprintField(row[column])],
  ]);
  final digest = sha256.convert(utf8.encode(framedKey)).bytes;
  final prefix =
      (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
  return prefix % bucketCount;
}

SqlSyncRangeFingerprintManifest buildSqlSyncRangeFingerprintManifest({
  required List<SqlSyncColumnDefinition> columns,
  required List<String> keyColumns,
  required Iterable<Map<String, dynamic>> rows,
  int bucketCount = kSqlSyncRangeBucketCount,
}) {
  final accumulator = SqlSyncRangeFingerprintAccumulator(
    columns: columns,
    keyColumns: keyColumns,
    bucketCount: bucketCount,
  );
  for (final row in rows) {
    accumulator.addRow(row);
  }
  return accumulator.build();
}

class SqlSyncRangeFingerprintAccumulator {
  SqlSyncRangeFingerprintAccumulator({
    required this.columns,
    required this.keyColumns,
    this.bucketCount = kSqlSyncRangeBucketCount,
  }) : _table = SqlSyncFingerprintAccumulator(),
       _buckets = List<SqlSyncFingerprintAccumulator>.generate(
         bucketCount,
         (_) => SqlSyncFingerprintAccumulator(),
         growable: false,
       ) {
    if (keyColumns.isEmpty || bucketCount <= 0) {
      throw ArgumentError('Range reconciliation requires primary-key columns.');
    }
  }

  final List<SqlSyncColumnDefinition> columns;
  final List<String> keyColumns;
  final int bucketCount;
  final SqlSyncFingerprintAccumulator _table;
  final List<SqlSyncFingerprintAccumulator> _buckets;

  void addRow(Map<String, dynamic> row) {
    _table.addRow(columns, row);
    _buckets[sqlSyncRangeBucketForRow(
          keyColumns: keyColumns,
          row: row,
          bucketCount: bucketCount,
        )]
        .addRow(columns, row);
  }

  SqlSyncRangeFingerprintManifest build() => SqlSyncRangeFingerprintManifest(
    rowCount: _table.rowCount,
    tableChecksum: _table.build(),
    bucketFingerprints: List<String>.unmodifiable(
      _buckets.map((bucket) => bucket.build()),
    ),
  );
}

Set<int> parseSqlSyncRangeUnionBuckets(
  String sourceClientName, {
  int bucketCount = kSqlSyncRangeBucketCount,
}) {
  final normalized = sourceClientName.trim();
  if (!normalized.startsWith(kSqlSyncRangeUnionSourcePrefix)) {
    return const <int>{};
  }
  final encoded = normalized.substring(kSqlSyncRangeUnionSourcePrefix.length);
  final buckets = <int>{};
  for (final value in encoded.split(',')) {
    final bucket = int.tryParse(value.trim());
    if (bucket == null || bucket < 0 || bucket >= bucketCount) {
      throw FormatException('Invalid selective reconciliation bucket: $value');
    }
    buckets.add(bucket);
  }
  if (buckets.isEmpty) {
    throw const FormatException(
      'Selective reconciliation requires at least one bucket.',
    );
  }
  return Set<int>.unmodifiable(buckets);
}

bool isSqlSyncRangeUnionSource(String sourceClientName) =>
    sourceClientName.trim().startsWith(kSqlSyncRangeUnionSourcePrefix);

String encodeSqlSyncFingerprintField(Object? value) {
  if (value == null) {
    return r'\N';
  }
  final text = value is String ? value : value.toString();
  return text
      .replaceAll(r'\', r'\\')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n')
      .replaceAll(
        String.fromCharCode(_sqlSyncFingerprintFieldSeparator),
        r'\u001f',
      )
      .replaceAll(
        String.fromCharCode(_sqlSyncFingerprintEscapeSeparator),
        r'\u001e',
      )
      .replaceAll(
        String.fromCharCode(_sqlSyncFingerprintRowSeparator),
        r'\u001d',
      );
}

/// Returns a stable SHA-256 for one complete synchronized business row.
///
/// Column names, SQL types, null markers, and UTF-8 byte lengths are framed
/// explicitly so distinct typed rows cannot become ambiguous when concatenated.
/// Sync transport metadata is excluded because only [columns] are encoded.
String canonicalSqlSyncRowSha256(
  List<SqlSyncColumnDefinition> columns,
  Map<String, dynamic> row,
) {
  final bytes = <int>[];
  void addFrame(String value) {
    final encoded = utf8.encode(value);
    bytes
      ..addAll(utf8.encode(encoded.length.toString()))
      ..add(58)
      ..addAll(encoded)
      ..add(30);
  }

  addFrame('sql-sync-row-v1');
  for (final column in columns) {
    addFrame(column.name.toLowerCase());
    addFrame(column.sqlType.trim().toLowerCase());
    final value = row[column.name];
    if (value == null) {
      addFrame('null');
    } else {
      addFrame('value');
      addFrame(encodeSqlSyncFingerprintField(value));
    }
  }
  return sha256.convert(bytes).toString();
}

String canonicalSqlSyncOperationId({
  required String table,
  required String originClient,
  required Object? changeVersion,
  required String operation,
  required List<String> keyColumns,
  required Map<String, dynamic> row,
  required String rowHash,
}) {
  final identity = jsonEncode([
    for (final column in keyColumns) [column, row[column]?.toString()],
  ]);
  return sha256
      .convert(
        utf8.encode(
          [
            'sql-sync-operation-v1',
            table.trim().toLowerCase(),
            originClient.trim().toLowerCase(),
            changeVersion?.toString() ?? '',
            operation.trim().toUpperCase(),
            identity,
            rowHash.toLowerCase(),
          ].join('\u001e'),
        ),
      )
      .toString();
}

bool hasValidCanonicalSqlSyncRowHash(
  List<SqlSyncColumnDefinition> columns,
  Map<String, dynamic> row,
) {
  final supplied = row['__sync_row_hash']?.toString().trim().toLowerCase();
  return supplied != null &&
      supplied.length == 64 &&
      supplied == canonicalSqlSyncRowSha256(columns, row);
}
