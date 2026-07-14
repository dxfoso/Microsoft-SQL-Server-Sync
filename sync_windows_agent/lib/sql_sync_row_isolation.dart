typedef SqlSyncRowBatchApply =
    Future<void> Function(List<Map<String, dynamic>> rows);
typedef SqlSyncShouldIsolateError = bool Function(Object error);

class SqlSyncRejectedRow {
  const SqlSyncRejectedRow({required this.row, required this.error});

  final Map<String, dynamic> row;
  final String error;
}

/// Applies the largest possible transactional groups while isolating rows
/// rejected by target constraints or business triggers.
Future<List<SqlSyncRejectedRow>> applySqlSyncRowsWithIsolation({
  required List<Map<String, dynamic>> rows,
  required SqlSyncRowBatchApply applyBatch,
  SqlSyncShouldIsolateError? shouldIsolateError,
}) async {
  if (rows.isEmpty) {
    return const <SqlSyncRejectedRow>[];
  }

  try {
    await applyBatch(rows);
    return const <SqlSyncRejectedRow>[];
  } catch (error) {
    if (shouldIsolateError != null && !shouldIsolateError(error)) {
      rethrow;
    }
    if (rows.length == 1) {
      return <SqlSyncRejectedRow>[
        SqlSyncRejectedRow(
          row: Map<String, dynamic>.from(rows.single),
          error: error.toString(),
        ),
      ];
    }
  }

  final midpoint = rows.length ~/ 2;
  final rejected = <SqlSyncRejectedRow>[];
  rejected.addAll(
    await applySqlSyncRowsWithIsolation(
      rows: rows.sublist(0, midpoint),
      applyBatch: applyBatch,
      shouldIsolateError: shouldIsolateError,
    ),
  );
  rejected.addAll(
    await applySqlSyncRowsWithIsolation(
      rows: rows.sublist(midpoint),
      applyBatch: applyBatch,
      shouldIsolateError: shouldIsolateError,
    ),
  );
  return rejected;
}

String formatSqlSyncRejectedRows({
  required List<SqlSyncRejectedRow> rejected,
  required List<String> keyColumns,
  int maxDetails = 5,
  int maxErrorLength = 1200,
}) {
  if (rejected.isEmpty) {
    return '';
  }
  final details = rejected
      .take(maxDetails)
      .map((item) {
        final key = keyColumns
            .map((column) => '$column=${item.row[column] ?? '<null>'}')
            .join(', ');
        final error =
            item.error.length <= maxErrorLength
                ? item.error
                : '${item.error.substring(0, maxErrorLength)}...';
        return '[$key] $error';
      })
      .join(' | ');
  final omitted = rejected.length - maxDetails;
  final suffix = omitted > 0 ? ' | $omitted additional rejected row(s)' : '';
  return '${rejected.length} row(s) rejected by target SQL: $details$suffix';
}
