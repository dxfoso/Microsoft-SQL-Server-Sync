import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sql_sync_schema.dart';

const int _sqlSyncFingerprintFieldSeparator = 31;
const int _sqlSyncFingerprintRowSeparator = 29;
const int _sqlSyncFingerprintEscapeSeparator = 30;
const int kSqlSyncRangeBucketCount = 16;
const String kSqlSyncTableFingerprintVersion = 'v3';
const String kSqlSyncRangeFingerprintVersion = 'v3';
const String kSqlSyncRangeUnionSourcePrefix = 'server-range-union-v1:';

class SqlSyncUploadInventoryMetadata {
  const SqlSyncUploadInventoryMetadata({
    required this.rowCount,
    required this.tableChecksum,
    required this.rangeFingerprint,
  });

  final int rowCount;
  final String tableChecksum;
  final String rangeFingerprint;
}

/// Keeps changed-row transport counts separate from the complete physical
/// inventory used by anti-entropy. A delta may contain zero rows while its
/// freshly scanned complete checksum still proves that clients diverge.
SqlSyncUploadInventoryMetadata resolveSqlSyncUploadInventoryMetadata({
  required int payloadRowCount,
  int? completeRowCount,
  String completeTableChecksum = '',
  String completeRangeFingerprint = '',
}) {
  final hasCompleteInventory = completeTableChecksum.trim().isNotEmpty;
  if (hasCompleteInventory &&
      (completeRowCount == null || completeRowCount < 0)) {
    throw ArgumentError(
      'A complete table checksum requires its complete physical row count.',
    );
  }
  return SqlSyncUploadInventoryMetadata(
    rowCount: hasCompleteInventory ? completeRowCount! : payloadRowCount,
    tableChecksum: hasCompleteInventory ? completeTableChecksum : '',
    rangeFingerprint: hasCompleteInventory ? completeRangeFingerprint : '',
  );
}

class SqlSyncFingerprintAccumulator {
  SqlSyncFingerprintAccumulator({this.table = ''});

  final String table;
  int _rowCount = 0;
  final _digestSink = _SingleDigestSink();
  late final ByteConversionSink _hashSink = sha256.startChunkedConversion(
    _digestSink,
  );
  bool _closed = false;

  int get rowCount => _rowCount;

  void addRow(List<SqlSyncColumnDefinition> columns, Map<String, dynamic> row) {
    if (_closed) {
      throw StateError('A completed SQL sync fingerprint cannot accept rows.');
    }
    for (final column in columns) {
      _addEncodedString(
        encodeSqlSyncFingerprintField(
          canonicalSqlSyncInventoryValue(
            table: table,
            column: column,
            value: row[column.name],
          ),
        ),
      );
      _addByte(_sqlSyncFingerprintFieldSeparator);
    }
    _addByte(_sqlSyncFingerprintRowSeparator);
    _rowCount += 1;
  }

  String build() {
    if (!_closed) {
      _hashSink.close();
      _closed = true;
    }
    final digest = _digestSink.value;
    if (digest == null) {
      throw StateError('SQL sync fingerprint digest was not finalized.');
    }
    return '$kSqlSyncTableFingerprintVersion:$_rowCount:$digest';
  }

  void _addEncodedString(String value) {
    _hashSink.add(utf8.encode(value));
  }

  void _addByte(int byte) {
    _hashSink.add([byte]);
  }
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    if (value != null) {
      throw StateError('SQL sync fingerprint produced more than one digest.');
    }
    value = data;
  }

  @override
  void close() {}
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
  String table = '',
  required List<SqlSyncColumnDefinition> columns,
  required List<String> keyColumns,
  required Iterable<Map<String, dynamic>> rows,
  int bucketCount = kSqlSyncRangeBucketCount,
}) {
  final accumulator = SqlSyncRangeFingerprintAccumulator(
    table: table,
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
    this.table = '',
    required this.columns,
    required this.keyColumns,
    this.bucketCount = kSqlSyncRangeBucketCount,
  }) : _table = SqlSyncFingerprintAccumulator(table: table),
       _buckets = List<SqlSyncFingerprintAccumulator>.generate(
         bucketCount,
         (_) => SqlSyncFingerprintAccumulator(table: table),
         growable: false,
       ) {
    if (keyColumns.isEmpty || bucketCount <= 0) {
      throw ArgumentError('Range reconciliation requires primary-key columns.');
    }
  }

  final String table;
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

/// Returns a comparison-only representation for explicitly proven SQL float
/// artifacts. Transport and canonical row hashes intentionally remain exact.
///
/// Historical production copies contain two POS totals that differ from their
/// integer value by exactly one IEEE-754 ULP. SQL Server and the application
/// treat those values as the same amount. This narrow table/column allowlist
/// prevents that representation noise from blocking anti-entropy without
/// hiding any other fractional value or any accounting-voucher difference.
Object? canonicalSqlSyncInventoryValue({
  required String table,
  required SqlSyncColumnDefinition column,
  required Object? value,
}) {
  if (value == null || !_isPosOrderInventoryAmount(table, column)) {
    return value;
  }
  final number = double.tryParse(value.toString());
  if (number == null || !number.isFinite || number.abs() > 9007199254740992) {
    return value;
  }
  final integer = number.roundToDouble();
  if ((number - integer).abs() > _sqlSyncDoubleUlp(number)) {
    return value;
  }
  return integer == 0 ? '0' : integer.toStringAsFixed(0);
}

bool _isPosOrderInventoryAmount(String table, SqlSyncColumnDefinition column) {
  final normalizedTable =
      table
          .trim()
          .toLowerCase()
          .replaceAll('[', '')
          .replaceAll(']', '')
          .split('::')
          .last
          .split('.')
          .last;
  final normalizedColumn = column.name.trim().toLowerCase();
  final normalizedType = column.sqlType.trim().toLowerCase();
  return normalizedTable == 'posorder000' &&
      (normalizedColumn == 'cashed' || normalizedColumn == 'subtotal') &&
      (normalizedType == 'float' || normalizedType == 'real');
}

double _sqlSyncDoubleUlp(double value) {
  final absolute = value.abs();
  if (absolute == 0) {
    return double.minPositive;
  }
  final bits = ByteData(8)..setFloat64(0, absolute, Endian.big);
  final exponentBits = (bits.getUint64(0, Endian.big) >> 52) & 0x7ff;
  if (exponentBits == 0) {
    return double.minPositive;
  }
  final exponent = exponentBits - 1023;
  return math.pow(2, exponent - 52).toDouble();
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
  if (supplied == null || supplied.length != 64) return false;
  if (supplied == canonicalSqlSyncRowSha256(columns, row)) return true;

  // The trusted control plane may reserve a replacement business number after
  // validating an uploaded row. Verify the immutable source hash against the
  // exact before-value, while the returned row keeps the server-reserved
  // after-value for comparison and atomic apply.
  final directiveColumn =
      row['__sync_auto_number_column']?.toString().trim() ?? '';
  final before = row['__sync_auto_number_before']?.toString() ?? '';
  final after = row['__sync_auto_number_after']?.toString() ?? '';
  final incidentId =
      row['__sync_auto_number_incident_id']?.toString().trim() ?? '';
  final knownColumn = columns.any(
    (column) => column.name.toLowerCase() == directiveColumn.toLowerCase(),
  );
  if (!knownColumn ||
      before.isEmpty ||
      after.isEmpty ||
      incidentId.length != 64 ||
      row[directiveColumn]?.toString() != after) {
    return false;
  }
  final sourceRow = Map<String, dynamic>.from(row);
  sourceRow[directiveColumn] = before;
  return supplied == canonicalSqlSyncRowSha256(columns, sourceRow);
}

String canonicalSqlSyncTargetComparisonSha256(
  List<SqlSyncColumnDefinition> columns,
  Map<String, dynamic> row,
) {
  final supplied =
      row['__sync_row_hash']?.toString().trim().toLowerCase() ?? '';
  if (!hasValidCanonicalSqlSyncRowHash(columns, row)) {
    return supplied;
  }
  // A validated automatic-number directive intentionally keeps the signed
  // hash of the source/before row while transporting the server-reserved
  // after value. Target comparison must hash that after row; otherwise the
  // originating client sees its unchanged before row and skips the correction.
  return canonicalSqlSyncRowSha256(columns, row);
}
