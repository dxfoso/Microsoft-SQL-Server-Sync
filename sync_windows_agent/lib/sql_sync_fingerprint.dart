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

  void addRow(
    List<SqlSyncColumnDefinition> columns,
    Map<String, dynamic> row,
  ) {
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
