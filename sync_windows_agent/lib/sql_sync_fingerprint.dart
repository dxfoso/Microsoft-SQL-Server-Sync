import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sql_sync_schema.dart';

const int _sqlSyncFingerprintFieldSeparator = 31;
const int _sqlSyncFingerprintRowSeparator = 29;
const int _sqlSyncFingerprintEscapeSeparator = 30;
const int _fnv64OffsetBasis = 0xcbf29ce484222325;
const int _fnv64Prime = 0x100000001b3;
const int _fnv64Mask = 0xffffffffffffffff;

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
