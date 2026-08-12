import 'dart:convert';

import 'sql_sync_schema.dart';

const int targetSnapshotBulkCommitRows = 1000;
// Each internal 1,000-row transaction is a durable resume checkpoint. Keeping
// one helper invocation bounded at 10,000 rows avoids an unbounded duplicate
// in-memory DataTable while amortizing PowerShell/.NET startup and compilation.
const int targetSnapshotBulkRowsPerInvocation = 10000;
const String sqlBulkStageAssetPath = 'assets/sql_bulk_stage.ps1';
const String sqlBulkStageSourceAssetPath = 'assets/SqlBulkStage.cs';

Map<String, dynamic> buildSqlBulkStageRequest({
  required String server,
  required String database,
  required bool useWindowsAuth,
  required String user,
  required String password,
  required String destinationTable,
  required List<SqlSyncColumnDefinition> columns,
  required List<Map<String, dynamic>> rows,
}) {
  final writableColumns = columns
      .where((column) => column.isWritable)
      .toList(growable: false);
  return <String, dynamic>{
    'server': server,
    'database': database,
    'useWindowsAuth': useWindowsAuth,
    'user': useWindowsAuth ? '' : user,
    'password': useWindowsAuth ? '' : password,
    'destinationTable': destinationTable,
    'connectTimeoutSeconds': 30,
    'commandTimeoutSeconds': 600,
    'commitBatchRows': targetSnapshotBulkCommitRows,
    'columns': [
      for (final column in writableColumns)
        <String, dynamic>{'name': column.name, 'sqlType': column.sqlType},
    ],
    'rows': [
      for (final row in rows)
        [for (final column in writableColumns) row[column.name]],
    ],
  };
}

int? parseSqlBulkCopiedRowCount(String output) {
  final match = RegExp(r'__SQL_SYNC_BULK_ROWS__=(\d+)').firstMatch(output);
  return match == null ? null : int.tryParse(match.group(1)!);
}

int sqlBulkStageRequestUtf8Bytes(Map<String, dynamic> request) =>
    utf8.encode(jsonEncode(request)).length;
