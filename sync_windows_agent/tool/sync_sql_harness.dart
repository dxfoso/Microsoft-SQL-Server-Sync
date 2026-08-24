import 'dart:convert';
import 'dart:io';

import 'package:sync_windows_agent/sql_sync_merge.dart';
import 'package:sync_windows_agent/sql_sync_fingerprint.dart';
import 'package:sync_windows_agent/sql_sync_schema.dart';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/sync_sql_harness.dart <request.json>');
    exitCode = 64;
    return;
  }

  final request =
      jsonDecode(File(arguments.single).readAsStringSync())
          as Map<String, dynamic>;
  final operation = request['operation']?.toString() ?? '';
  if (operation == 'transport-expression') {
    stdout.write(
      buildSqlSyncTransportValueExpression(
        column: _column(Map<String, dynamic>.from(request['column'] as Map)),
        columnReference: request['columnReference'].toString(),
      ),
    );
    return;
  }
  if (operation == 'decode-floating-transport') {
    final columns = (request['columns'] as List)
        .map((column) => _column(Map<String, dynamic>.from(column as Map)))
        .toList(growable: false);
    final values = (request['values'] as List)
        .map((value) => value.toString())
        .toList(growable: false);
    if (columns.length != values.length) {
      throw const FormatException(
        'Floating transport columns and values must have equal lengths.',
      );
    }
    stdout.write(
      jsonEncode([
        for (var index = 0; index < columns.length; index += 1)
          decodeSqlSyncFloatingPointTransport(
            column: columns[index],
            value: values[index],
          ),
      ]),
    );
    return;
  }
  if (operation == 'fingerprint-row') {
    final columns = (request['columns'] as List)
        .map((column) => _column(Map<String, dynamic>.from(column as Map)))
        .toList(growable: false);
    final row = Map<String, dynamic>.from(request['row'] as Map);
    final accumulator = SqlSyncFingerprintAccumulator()..addRow(columns, row);
    stdout.write(
      jsonEncode({
        'tableChecksum': accumulator.build(),
        'rowHash': canonicalSqlSyncRowSha256(columns, row),
      }),
    );
    return;
  }
  if (operation == 'coalesce') {
    final rows = (request['rows'] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
    final winners = coalesceSqlSyncDeltaRows(
      rows: rows,
      primaryKeyColumns: _strings(request['primaryKeyColumns']),
      uniqueKeyColumnSets:
          (request['uniqueKeyColumnSets'] as List? ?? const [])
              .map((columns) => _strings(columns))
              .toList(growable: false),
    );
    stdout.write(jsonEncode(winners));
    return;
  }
  if (operation != 'apply') {
    throw ArgumentError.value(operation, 'operation', 'Unsupported operation');
  }

  final columns = (request['columns'] as List)
      .map((column) => _column(Map<String, dynamic>.from(column as Map)))
      .toList(growable: false);
  final primaryKeyColumns = _strings(request['primaryKeyColumns']);
  final uniqueIndexColumnSets = (request['uniqueIndexColumnSets'] as List? ??
          const [])
      .map((columns) => _strings(columns))
      .toList(growable: false);
  final deletes = (request['deletes'] as List? ?? const [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList(growable: false);
  final rows = (request['rows'] as List? ?? const [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList(growable: false);
  final protectLocalChangesAfterVersion =
      (request['protectLocalChangesAfterVersion'] as num?)?.toInt();
  final database = request['database'].toString();
  final schema = request['schema']?.toString() ?? 'dbo';
  final table = request['table'].toString();
  final stageTableName =
      request['stageTableName']?.toString() ??
      'sql_sync_harness_${DateTime.now().microsecondsSinceEpoch}';
  final sql = StringBuffer();

  if (rows.isNotEmpty || deletes.isNotEmpty) {
    sql.writeln(
      buildTargetSnapshotStageSetupSql(
        stageTableName: stageTableName,
        columns: columns,
      ),
    );
    for (var offset = 0; offset < rows.length; offset += 100) {
      sql.writeln(
        buildTargetSnapshotStageInsertSql(
          stageTableName: stageTableName,
          columns: columns,
          rows: rows.skip(offset).take(100).toList(growable: false),
        ),
      );
    }
    sql.writeln(
      buildTargetSnapshotStageApplySql(
        database: database,
        schema: schema,
        table: table,
        stageTableName: stageTableName,
        columns: columns,
        primaryKeyColumns: primaryKeyColumns,
        uniqueIndexColumnSets: uniqueIndexColumnSets,
        deltaDeleteRows: deletes,
        protectLocalChangesAfterVersion: protectLocalChangesAfterVersion,
        manageTriggers: true,
        insertOnly: false,
        resolveUniqueConflictsLatestWins:
            request['resolveUniqueConflictsLatestWins'] == true,
      ),
    );
  }
  stdout.write(sql.toString());
}

List<String> _strings(Object? value) =>
    (value as List).map((item) => item.toString()).toList(growable: false);

SqlSyncColumnDefinition _column(Map<String, dynamic> value) =>
    SqlSyncColumnDefinition(
      name: value['name'].toString(),
      sqlType: value['sqlType'].toString(),
      maxLength: (value['maxLength'] as num).toInt(),
      precision: (value['precision'] as num).toInt(),
      scale: (value['scale'] as num).toInt(),
      isIdentity: value['isIdentity'] == true,
      isComputed: value['isComputed'] == true,
    );
