import 'dart:convert';

import 'sql_sync_schema.dart';

// "SQLSYNC" encoded as varbinary. Change Tracking preserves this origin on
// agent-applied writes so they can be excluded from the next outbound delta.
const sqlSyncChangeTrackingContextHex = '0x53514C53594E43';

String buildTargetSnapshotMergeSql({
  required String database,
  required String schema,
  required String table,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<Map<String, dynamic>> rows,
  int targetMergeInsertBatchSize = 100,
  int targetMergeApplyBatchSize = 500,
  bool deleteMissing = true,
}) {
  final insertColumns = columns
      .where((column) => column.isWritable)
      .toList(growable: false);
  final primaryKeyColumnNames =
      primaryKeyColumns.map((column) => column.toLowerCase()).toSet();
  final updatableColumns = insertColumns
      .where((column) {
        if (column.isIdentity) {
          return false;
        }
        if (primaryKeyColumnNames.contains(column.name.toLowerCase())) {
          return false;
        }
        return true;
      })
      .toList(growable: false);
  final joinClause = matchClauseForColumns(primaryKeyColumns, columns);
  final insertColumnList = insertColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final insertValueList = insertColumns
      .map((column) => 'source.${quoteIdentifier(column.name)}')
      .join(', ');
  final sourceColumnList = insertColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final sourceTempColumnDefinitions = insertColumns
      .map(
        (column) =>
            '${quoteIdentifier(column.name)} ${column.sqlCastType} NULL',
      )
      .join(',\n    ');
  final sourceIndexStatements = _buildSourceTempIndexStatements(<List<String>>[
    primaryKeyColumns,
  ]);
  final identityColumns = insertColumns
      .where((column) => column.isIdentity)
      .toList(growable: false);
  final identityInsertOn =
      identityColumns.isEmpty
          ? ''
          : 'SET IDENTITY_INSERT ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} ON;';
  final identityInsertOff =
      identityColumns.isEmpty
          ? ''
          : 'SET IDENTITY_INSERT ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} OFF;';
  final triggerTarget =
      '${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)}';
  final insertStatements = StringBuffer();
  for (
    var offset = 0;
    offset < rows.length;
    offset += targetMergeInsertBatchSize
  ) {
    final sourceValueTuples = rows
        .skip(offset)
        .take(targetMergeInsertBatchSize)
        .map(
          (row) =>
              '(${insertColumns.map((column) => sourceBatchTargetLiteral(column, row[column.name])).join(', ')})',
        )
        .join(',\n      ');
    insertStatements.writeln('''
INSERT INTO #source_rows ($sourceColumnList)
VALUES
    $sourceValueTuples;
''');
  }

  final applyStatements = StringBuffer();
  for (
    var offset = 0;
    offset < rows.length;
    offset += targetMergeApplyBatchSize
  ) {
    final startRow = offset + 1;
    final endRow =
        (offset + targetMergeApplyBatchSize).clamp(0, rows.length).toInt();
    applyStatements.writeln('''
${_buildBatchedUpdateStatement(database: database, schema: schema, table: table, sourceColumnList: sourceColumnList, joinClause: joinClause, updatableColumns: updatableColumns, startRow: startRow, endRow: endRow)}
${_buildBatchedInsertStatement(database: database, schema: schema, table: table, sourceColumnList: sourceColumnList, insertColumnList: insertColumnList, insertValueList: insertValueList, joinClause: joinClause, startRow: startRow, endRow: endRow)}
''');
  }

  final deleteMissingStatements =
      deleteMissing
          ? '''
WHILE 1 = 1
BEGIN
  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  DELETE TOP ($targetMergeApplyBatchSize) target
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
  WHERE NOT EXISTS (
    SELECT 1
    FROM #source_rows AS source
    WHERE $joinClause
  );
  IF @@ROWCOUNT = 0 BREAK;
END;
'''
          : '';

  return '''
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
CREATE TABLE #source_rows (
  __row_num INT IDENTITY(1,1) NOT NULL,
  $sourceTempColumnDefinitions
);
$sourceIndexStatements
ALTER TABLE $triggerTarget DISABLE TRIGGER ALL;
$identityInsertOn
${insertStatements.toString()}
${applyStatements.toString()}
$deleteMissingStatements
$identityInsertOff
ALTER TABLE $triggerTarget ENABLE TRIGGER ALL;
DROP TABLE #source_rows;
COMMIT TRANSACTION;
''';
}

String buildTargetSnapshotStageSetupSql({
  required String stageTableName,
  required List<SqlSyncColumnDefinition> columns,
}) {
  final insertColumns = columns
      .where((column) => column.isWritable)
      .toList(growable: false);
  final sourceTempColumnDefinitions = insertColumns
      .map(
        (column) =>
            '${quoteIdentifier(column.name)} ${column.sqlCastType} NULL',
      )
      .join(',\n    ');
  final stageTarget = stageTableReference(stageTableName);
  return '''
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF OBJECT_ID(N'$stageTarget', N'U') IS NOT NULL
BEGIN
  DROP TABLE $stageTarget;
END;
CREATE TABLE $stageTarget (
  __row_num INT IDENTITY(1,1) NOT NULL,
  $sourceTempColumnDefinitions
);
''';
}

String buildTargetSnapshotStageInsertSql({
  required String stageTableName,
  required List<SqlSyncColumnDefinition> columns,
  required List<Map<String, dynamic>> rows,
}) {
  final insertColumns = columns
      .where((column) => column.isWritable)
      .toList(growable: false);
  final sourceColumnList = insertColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final sourceValueTuples = rows
      .map(
        (row) =>
            '(${insertColumns.map((column) => sourceBatchTargetLiteral(column, row[column.name])).join(', ')})',
      )
      .join(',\n    ');
  return '''
SET NOCOUNT ON;
SET XACT_ABORT ON;
INSERT INTO ${stageTableReference(stageTableName)} ($sourceColumnList)
VALUES
    $sourceValueTuples;
''';
}

String buildTargetSnapshotStageApplySql({
  required String database,
  required String schema,
  required String table,
  required String stageTableName,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  int targetMergeApplyBatchSize = 500,
  bool deleteMissing = true,
  bool manageTriggers = true,
  bool insertOnly = false,
}) {
  final insertColumns = columns
      .where((column) => column.isWritable)
      .toList(growable: false);
  final primaryKeyColumnNames =
      primaryKeyColumns.map((column) => column.toLowerCase()).toSet();
  final updatableColumns = insertColumns
      .where((column) {
        if (column.isIdentity) {
          return false;
        }
        if (primaryKeyColumnNames.contains(column.name.toLowerCase())) {
          return false;
        }
        return true;
      })
      .toList(growable: false);
  final joinClause = matchClauseForColumns(primaryKeyColumns, columns);
  final insertColumnList = insertColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final insertValueList = insertColumns
      .map((column) => 'source.${quoteIdentifier(column.name)}')
      .join(', ');
  final sourceColumnList = insertColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final stageTarget = stageTableReference(stageTableName);
  final sourceIndexStatements = _buildSourceTempIndexStatements(<List<String>>[
    primaryKeyColumns,
  ]).replaceAll('#source_rows', stageTarget);
  final identityColumns = insertColumns
      .where((column) => column.isIdentity)
      .toList(growable: false);
  final identityInsertOn =
      identityColumns.isEmpty
          ? ''
          : 'SET IDENTITY_INSERT ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} ON;';
  final identityInsertOff =
      identityColumns.isEmpty
          ? ''
          : 'SET IDENTITY_INSERT ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} OFF;';
  final triggerTarget =
      '${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)}';
  final triggerDisableStatement =
      manageTriggers ? 'ALTER TABLE $triggerTarget DISABLE TRIGGER ALL;' : '';
  final triggerEnableStatement =
      manageTriggers ? 'ALTER TABLE $triggerTarget ENABLE TRIGGER ALL;' : '';
  final triggerRestoreBlock =
      manageTriggers
          ? '''
  BEGIN TRY
    $triggerEnableStatement
  END TRY
  BEGIN CATCH
  END CATCH;'''
          : '';
  final deleteMissingBlock =
      deleteMissing && !insertOnly
          ? '''
  WHILE 1 = 1
  BEGIN
    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
    DELETE TOP ($targetMergeApplyBatchSize) target
    FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
    WHERE NOT EXISTS (
      SELECT 1
      FROM $stageTarget AS source
      WHERE $joinClause
    );
    IF @@ROWCOUNT = 0 BREAK;
  END;'''
          : '';

  return '''
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
  $sourceIndexStatements
  BEGIN TRANSACTION;
  $triggerDisableStatement
  $identityInsertOn
  DECLARE @SqlSyncInsertedRows INT = 0;
  ${insertOnly ? '' : _buildBatchedUpdateStatement(database: database, schema: schema, table: table, sourceTableReference: stageTarget, sourceColumnList: sourceColumnList, joinClause: joinClause, updatableColumns: updatableColumns)}
  ${_buildBatchedInsertStatement(database: database, schema: schema, table: table, sourceTableReference: stageTarget, sourceColumnList: sourceColumnList, insertColumnList: insertColumnList, insertValueList: insertValueList, joinClause: joinClause)}
  SET @SqlSyncInsertedRows += @@ROWCOUNT;
  $deleteMissingBlock
  $identityInsertOff
  $triggerEnableStatement
  COMMIT TRANSACTION;
  SELECT N'__SQL_SYNC_INSERTED__=' + CONVERT(NVARCHAR(20), @SqlSyncInsertedRows);
END TRY
BEGIN CATCH
  DECLARE @SqlSyncStageErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
  IF @@TRANCOUNT > 0
  BEGIN
    ROLLBACK TRANSACTION;
  END;
  $triggerRestoreBlock
  IF OBJECT_ID(N'$stageTarget', N'U') IS NOT NULL
  BEGIN
    DROP TABLE $stageTarget;
  END;
  RAISERROR(@SqlSyncStageErrorMessage, 16, 1);
END CATCH;
IF OBJECT_ID(N'$stageTarget', N'U') IS NOT NULL
BEGIN
  DROP TABLE $stageTarget;
END;
''';
}

String buildTargetSnapshotStageDropSql({required String stageTableName}) {
  final stageTarget = stageTableReference(stageTableName);
  return '''
SET NOCOUNT ON;
IF OBJECT_ID(N'$stageTarget', N'U') IS NOT NULL
BEGIN
  DROP TABLE $stageTarget;
END;
''';
}

String buildTargetDeltaDeleteSql({
  required String database,
  required String schema,
  required String table,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<Map<String, dynamic>> rows,
  int insertBatchSize = 100,
  bool manageTriggers = true,
}) {
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  final keyColumns = primaryKeyColumns
      .map((name) => definitionsByName[name.toLowerCase()])
      .whereType<SqlSyncColumnDefinition>()
      .toList(growable: false);
  if (keyColumns.length != primaryKeyColumns.length) {
    throw ArgumentError('Every delete key must have a column definition.');
  }
  final columnList = keyColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final columnDefinitions = keyColumns
      .map(
        (column) =>
            '${quoteIdentifier(column.name)} ${column.sqlCastType} NULL',
      )
      .join(',\n    ');
  final inserts = StringBuffer();
  for (var offset = 0; offset < rows.length; offset += insertBatchSize) {
    final tuples = rows
        .skip(offset)
        .take(insertBatchSize)
        .map(
          (row) =>
              '(${keyColumns.map((column) => sourceBatchTargetLiteral(column, row[column.name])).join(', ')})',
        )
        .join(',\n    ');
    inserts.writeln('''
INSERT INTO #delete_rows ($columnList)
VALUES
    $tuples;
''');
  }
  final joinClause = matchClauseForColumns(primaryKeyColumns, keyColumns);
  final triggerTarget =
      '${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)}';
  final triggerDisableStatement =
      manageTriggers ? 'ALTER TABLE $triggerTarget DISABLE TRIGGER ALL;' : '';
  final triggerEnableStatement =
      manageTriggers ? 'ALTER TABLE $triggerTarget ENABLE TRIGGER ALL;' : '';
  final triggerRestoreBlock =
      manageTriggers
          ? '''
  BEGIN TRY
    $triggerEnableStatement
  END TRY
  BEGIN CATCH
  END CATCH;'''
          : '';
  return '''
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
  BEGIN TRANSACTION;
  $triggerDisableStatement
  CREATE TABLE #delete_rows (
    $columnDefinitions
  );
  ${inserts.toString()}
  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  DELETE target
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
  INNER JOIN #delete_rows AS source
    ON $joinClause;
  DECLARE @SqlSyncDeletedRows INT = @@ROWCOUNT;
  DROP TABLE #delete_rows;
  $triggerEnableStatement
  COMMIT TRANSACTION;
  SELECT N'__SQL_SYNC_DELETED__=' + CONVERT(NVARCHAR(20), @SqlSyncDeletedRows);
END TRY
BEGIN CATCH
  DECLARE @SqlSyncDeleteErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
  IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
  $triggerRestoreBlock
  IF OBJECT_ID(N'tempdb..#delete_rows', N'U') IS NOT NULL
    DROP TABLE #delete_rows;
  RAISERROR(@SqlSyncDeleteErrorMessage, 16, 1);
END CATCH;
''';
}

String stageTableReference(String stageTableName) =>
    'tempdb.dbo.${quoteIdentifier(stageTableName)}';

/// Keeps one deterministic version for each permanent primary identity.
///
/// Alternate unique/business keys never participate in identity matching.
/// Different GUIDs therefore remain independent and any business-key collision
/// is rejected by the target constraint and retained in the conflict outbox.
List<Map<String, dynamic>> coalesceSqlSyncDeltaRows({
  required List<Map<String, dynamic>> rows,
  required List<String> primaryKeyColumns,
  Map<String, Map<String, dynamic>>? latestRowByKey,
}) {
  if (rows.isEmpty || primaryKeyColumns.isEmpty) {
    return rows;
  }
  final candidates = <Map<String, dynamic>>[];
  final candidateIdentities = <String>[];

  for (final row in rows) {
    final values = primaryKeyColumns.map((column) => row[column]).toList();
    if (values.any((value) => value == null)) {
      candidates.add(row);
      candidateIdentities.add('missing:${candidates.length - 1}');
      continue;
    }
    final identity = jsonEncode(values);
    final previousRow = latestRowByKey?[identity];
    if (previousRow != null && !_isLaterSyncRow(row, previousRow)) {
      continue;
    }
    candidates.add(row);
    candidateIdentities.add(identity);
  }

  final winnerByIdentity = <String, int>{};
  final firstIndexByIdentity = <String, int>{};
  for (var index = 0; index < candidates.length; index++) {
    final identity = candidateIdentities[index];
    firstIndexByIdentity[identity] ??= index;
    final currentIndex = winnerByIdentity[identity];
    if (currentIndex == null ||
        _isLaterSyncRow(candidates[index], candidates[currentIndex])) {
      winnerByIdentity[identity] = index;
    }
  }

  final identities = winnerByIdentity.keys.toList(growable: false)..sort(
    (left, right) =>
        firstIndexByIdentity[left]!.compareTo(firstIndexByIdentity[right]!),
  );
  final winners = identities
      .map((identity) => candidates[winnerByIdentity[identity]!])
      .toList(growable: false);
  if (latestRowByKey != null) {
    for (final identity in identities) {
      final winnerIndex = winnerByIdentity[identity]!;
      latestRowByKey[identity] = Map<String, dynamic>.from(
        candidates[winnerIndex],
      );
    }
  }
  return winners;
}

bool _isLaterSyncRow(
  Map<String, dynamic> candidate,
  Map<String, dynamic> current,
) {
  final candidateTime = _parseSyncUtcTimestamp(
    candidate['__sync_modified_at_utc'],
  );
  final currentTime = _parseSyncUtcTimestamp(current['__sync_modified_at_utc']);
  if (candidateTime == null) {
    if (currentTime != null) return false;
  } else if (currentTime == null || candidateTime.isAfter(currentTime)) {
    return true;
  } else if (candidateTime.isBefore(currentTime)) {
    return false;
  }
  final candidateVersion =
      int.tryParse(candidate['__sync_change_version']?.toString() ?? '') ?? -1;
  final currentVersion =
      int.tryParse(current['__sync_change_version']?.toString() ?? '') ?? -1;
  if (candidateVersion != currentVersion) {
    return candidateVersion > currentVersion;
  }
  final candidateOrigin =
      candidate['__sync_origin_client']?.toString().toLowerCase() ?? '';
  final currentOrigin =
      current['__sync_origin_client']?.toString().toLowerCase() ?? '';
  if (candidateOrigin != currentOrigin) {
    return candidateOrigin.compareTo(currentOrigin) > 0;
  }
  return (candidate['__sync_operation_id']?.toString() ?? '').compareTo(
        current['__sync_operation_id']?.toString() ?? '',
      ) >=
      0;
}

DateTime? _parseSyncUtcTimestamp(dynamic value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text)?.toUtc();
}

String _buildSourceTempIndexStatements(List<List<String>> matchColumnSets) {
  final buffer = StringBuffer();
  buffer.writeln(
    'CREATE UNIQUE CLUSTERED INDEX IX_source_rows_row_num ON #source_rows (__row_num);',
  );
  final seen = <String>{};
  var indexNumber = 0;
  for (final columnSet in matchColumnSets) {
    if (columnSet.isEmpty) {
      continue;
    }
    final key = columnSet.map((column) => column.toLowerCase()).join('|');
    if (!seen.add(key)) {
      continue;
    }
    indexNumber += 1;
    final columnList = columnSet
        .map((column) => quoteIdentifier(column))
        .join(', ');
    buffer.writeln(
      'CREATE INDEX IX_source_rows_match_$indexNumber ON #source_rows ($columnList);',
    );
  }
  return buffer.toString();
}

String _buildBatchedUpdateStatement({
  required String database,
  required String schema,
  required String table,
  String sourceTableReference = '#source_rows',
  required String sourceColumnList,
  required String joinClause,
  required List<SqlSyncColumnDefinition> updatableColumns,
  int? startRow,
  int? endRow,
}) {
  if (updatableColumns.isEmpty) {
    return '';
  }
  final updateAssignments = updatableColumns
      .map(
        (column) =>
            'target.${quoteIdentifier(column.name)} = source.${quoteIdentifier(column.name)}',
      )
      .join(',\n    ');
  final sourceSelection = _sourceSelectionSql(
    sourceTableReference: sourceTableReference,
    sourceColumnList: sourceColumnList,
    startRow: startRow,
    endRow: endRow,
  );
  return '''
WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
UPDATE target
SET
    $updateAssignments
FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
INNER JOIN (
  $sourceSelection
) AS source
ON $joinClause;
''';
}

String _buildBatchedInsertStatement({
  required String database,
  required String schema,
  required String table,
  String sourceTableReference = '#source_rows',
  required String sourceColumnList,
  required String insertColumnList,
  required String insertValueList,
  required String joinClause,
  int? startRow,
  int? endRow,
}) {
  final sourceSelection = _sourceSelectionSql(
    sourceTableReference: sourceTableReference,
    sourceColumnList: sourceColumnList,
    startRow: startRow,
    endRow: endRow,
  );
  return '''
WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
INSERT INTO ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} ($insertColumnList)
SELECT $insertValueList
FROM (
  $sourceSelection
) AS source
WHERE NOT EXISTS (
  SELECT 1
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
  WHERE $joinClause
);
''';
}

String _sourceSelectionSql({
  required String sourceTableReference,
  required String sourceColumnList,
  int? startRow,
  int? endRow,
}) {
  if (startRow != null && endRow != null) {
    return '''
SELECT $sourceColumnList
FROM $sourceTableReference
WHERE __row_num BETWEEN $startRow AND $endRow''';
  }
  return '''
SELECT $sourceColumnList
FROM $sourceTableReference''';
}

String sourceBatchTargetLiteral(SqlSyncColumnDefinition column, Object? value) {
  if (value == null) {
    return 'NULL';
  }

  final stringValue = value.toString();
  final normalized = column.sqlType.trim().toLowerCase();
  if (normalized == 'binary' || normalized == 'varbinary') {
    return "CONVERT(${column.sqlCastType}, '${escapeSqlLiteral(stringValue)}', 1)";
  }
  if (column.isTextLike) {
    return "N'${escapeSqlLiteral(stringValue)}'";
  }
  if (column.isDateOrTimeType) {
    return dateTimeTargetLiteral(column, stringValue);
  }
  return "CAST(N'${escapeSqlLiteral(stringValue)}' AS ${column.sqlCastType})";
}

String dateTimeTargetLiteral(SqlSyncColumnDefinition column, String value) {
  final escapedValue = escapeSqlLiteral(value);
  final literal = "N'$escapedValue'";
  final trimmedLiteral = "NULLIF(LTRIM(RTRIM($literal)), N'')";
  final targetType = column.sqlCastType;
  final normalized = column.sqlType.trim().toLowerCase();

  final expression = switch (normalized) {
    'date' => 'CONVERT($targetType, $literal, 23)',
    'datetimeoffset' => 'CONVERT($targetType, $literal, 127)',
    'datetime' ||
    'smalldatetime' ||
    'datetime2' => 'CONVERT($targetType, $literal, 126)',
    'time' => 'CAST($literal AS $targetType)',
    _ => 'CAST($literal AS $targetType)',
  };

  return '''
CASE
  WHEN $trimmedLiteral IS NULL THEN NULL
  ELSE $expression
END
''';
}

String matchClauseForColumns(
  List<String> matchColumns,
  List<SqlSyncColumnDefinition> columns,
) {
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  return matchColumns
      .map((column) {
        final quotedColumn = quoteIdentifier(column);
        final sourceExpression = 'source.$quotedColumn';
        var targetExpression = 'target.$quotedColumn';
        final definition = definitionsByName[column.toLowerCase()];
        if (definition != null && definition.isTextLike) {
          targetExpression = '$targetExpression COLLATE DATABASE_DEFAULT';
        }
        return '$sourceExpression IS NOT NULL AND $targetExpression = $sourceExpression';
      })
      .join(' AND ');
}

String quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

String escapeSqlLiteral(String value) => value.replaceAll("'", "''");
