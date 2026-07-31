import 'dart:convert';

const _missingComparisonValue = '<missing row>';

class TableComparisonClientRows {
  const TableComparisonClientRows({
    required this.clientName,
    required this.columns,
    required this.rows,
    required this.reportedRowCount,
    required this.truncated,
  });

  final String clientName;
  final List<String> columns;
  final List<Map<String, dynamic>> rows;
  final int reportedRowCount;
  final bool truncated;
}

class TableComparisonDifference {
  const TableComparisonDifference({
    required this.key,
    required this.rowsByClient,
    required this.changedColumns,
  });

  final String key;
  final Map<String, Map<String, dynamic>?> rowsByClient;
  final List<String> changedColumns;
}

String tableComparisonValue(dynamic value) {
  if (value == null) return '<NULL>';
  if (value is Map || value is List) return jsonEncode(value);
  return value.toString();
}

String _rowKey(Map<String, dynamic> row, List<String> keyColumns) {
  return jsonEncode([
    for (final column in keyColumns) tableComparisonValue(row[column]),
  ]);
}

List<TableComparisonDifference> buildTableComparisonDifferences({
  required List<String> keyColumns,
  required List<TableComparisonClientRows> clients,
}) {
  if (keyColumns.isEmpty || clients.length < 2) return const [];
  final rowsByClient = <String, Map<String, Map<String, dynamic>>>{};
  final keys = <String>{};
  final columns = <String>{};
  for (final client in clients) {
    final keyed = <String, Map<String, dynamic>>{};
    for (final row in client.rows) {
      final key = _rowKey(row, keyColumns);
      keyed[key] = row;
      keys.add(key);
      columns.addAll(row.keys.where((column) => !column.startsWith('__sync_')));
    }
    rowsByClient[client.clientName] = keyed;
  }
  final orderedColumns = columns.toList(growable: false)..sort();
  final orderedKeys = keys.toList(growable: false)..sort();
  final differences = <TableComparisonDifference>[];
  for (final key in orderedKeys) {
    final clientRows = <String, Map<String, dynamic>?>{
      for (final client in clients)
        client.clientName: rowsByClient[client.clientName]?[key],
    };
    final changedColumns = <String>[];
    for (final column in orderedColumns) {
      final values = <String>{};
      for (final client in clients) {
        final row = clientRows[client.clientName];
        values.add(
          row == null
              ? _missingComparisonValue
              : tableComparisonValue(row[column]),
        );
      }
      if (values.length > 1) changedColumns.add(column);
    }
    if (changedColumns.isNotEmpty) {
      differences.add(
        TableComparisonDifference(
          key: key,
          rowsByClient: clientRows,
          changedColumns: changedColumns,
        ),
      );
    }
  }
  return differences;
}
