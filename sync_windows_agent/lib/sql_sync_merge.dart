import 'dart:convert';

import 'sql_sync_schema.dart';

// "SQLSYNC" encoded as varbinary. Change Tracking preserves this origin on
// agent-applied writes so they can be excluded from the next outbound delta.
const sqlSyncChangeTrackingContextHex = '0x53514C53594E43';

/// Returns the stable business identity used when an application replaces a
/// row by deleting it and inserting the edited value under a new GUID.
///
/// Ameen invoice lines (`bi000`) keep their logical position under the invoice
/// in `ParentGUID + Number`. Treating the generated GUID as the only identity
/// would union concurrent replacements and duplicate the visible invoice.
List<String> sqlSyncLogicalIdentityColumns({
  required String table,
  required Iterable<String> availableColumns,
}) {
  final availableByLowerName = <String, String>{
    for (final column in availableColumns) column.toLowerCase(): column,
  };
  if (table.trim().toLowerCase() != 'bi000') {
    return const <String>[];
  }
  const required = <String>['parentguid', 'number'];
  if (required.any((column) => !availableByLowerName.containsKey(column))) {
    return const <String>[];
  }
  return required
      .map((column) => availableByLowerName[column]!)
      .toList(growable: false);
}

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
  List<List<String>> uniqueIndexColumnSets = const <List<String>>[],
  List<String> logicalIdentityColumns = const <String>[],
  List<Map<String, dynamic>> deltaDeleteRows = const <Map<String, dynamic>>[],
  int? protectLocalChangesAfterVersion,
  int? requireNoLocalChangesAfterVersion,
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
    ...uniqueIndexColumnSets,
    if (logicalIdentityColumns.isNotEmpty) logicalIdentityColumns,
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
  final uniqueConflictDeleteStatements = StringBuffer();
  if (deleteMissing && !insertOnly) {
    for (final uniqueColumns in uniqueIndexColumnSets) {
      if (uniqueColumns.isEmpty) {
        continue;
      }
      final uniqueJoinClause = nullableMatchClauseForColumns(
        uniqueColumns,
        columns,
      );
      uniqueConflictDeleteStatements.writeln('''
  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  DELETE target
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
  WHERE EXISTS (
    SELECT 1
    FROM $stageTarget AS source
    WHERE $uniqueJoinClause
      AND NOT ($joinClause)
  );''');
    }
  }
  final deltaDeleteStatements = _buildStagedDeltaDeleteStatements(
    database: database,
    schema: schema,
    table: table,
    columns: columns,
    primaryKeyColumns: primaryKeyColumns,
    rows: deltaDeleteRows,
    filterProtectedKeys: protectLocalChangesAfterVersion != null,
  );
  final postUploadProtectionStatements =
      protectLocalChangesAfterVersion == null
          ? ''
          : _buildPostUploadProtectionStatements(
            database: database,
            schema: schema,
            table: table,
            stageTarget: stageTarget,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            deltaDeleteRows: deltaDeleteRows,
            changeTrackingVersion: protectLocalChangesAfterVersion,
          );
  final transactionIsolation =
      protectLocalChangesAfterVersion == null &&
              requireNoLocalChangesAfterVersion == null
          ? ''
          : 'SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;';
  final fullReplacementRaceGuard =
      requireNoLocalChangesAfterVersion == null
          ? ''
          : '''
  -- A canonical replacement can delete rows absent from the upload-time
  -- view. Lock the table and abort if a user write occurred after upload;
  -- the next sync uploads that write instead of losing it.
  DECLARE @SqlSyncLockedTableRows BIGINT = 0;
  SELECT @SqlSyncLockedTableRows = COUNT_BIG(*)
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} WITH (TABLOCKX, HOLDLOCK);
  IF EXISTS (
    SELECT 1
    FROM CHANGETABLE(CHANGES ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)}, $requireNoLocalChangesAfterVersion) AS ct
    WHERE ct.SYS_CHANGE_CONTEXT IS NULL
       OR ct.SYS_CHANGE_CONTEXT <> $sqlSyncChangeTrackingContextHex
  )
  BEGIN
    RAISERROR('Local rows changed after this client uploaded; retry the canonical sync with a fresh snapshot.', 16, 1);
  END;''';
  final logicalIdentityStatements = _buildLogicalIdentityReconciliationSql(
    database: database,
    schema: schema,
    table: table,
    stageTarget: stageTarget,
    columns: columns,
    primaryKeyColumns: primaryKeyColumns,
    logicalIdentityColumns: logicalIdentityColumns,
  );
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
$transactionIsolation
BEGIN TRY
  $sourceIndexStatements
  BEGIN TRANSACTION;
  DECLARE @SqlSyncProtectedRows INT = 0;
  DECLARE @SqlSyncProtectedUpsertRows INT = 0;
  DECLARE @SqlSyncProtectedDeleteRows INT = 0;
  $fullReplacementRaceGuard
  $postUploadProtectionStatements
  $triggerDisableStatement
  $identityInsertOn
  DECLARE @SqlSyncInsertedRows INT = 0;
  $deltaDeleteStatements
  $logicalIdentityStatements
  ${uniqueConflictDeleteStatements.toString()}
  ${insertOnly ? '' : _buildBatchedUpdateStatement(database: database, schema: schema, table: table, sourceTableReference: stageTarget, sourceColumnList: sourceColumnList, joinClause: joinClause, updatableColumns: updatableColumns)}
  ${_buildBatchedInsertStatement(database: database, schema: schema, table: table, sourceTableReference: stageTarget, sourceColumnList: sourceColumnList, insertColumnList: insertColumnList, insertValueList: insertValueList, joinClause: joinClause)}
  SET @SqlSyncInsertedRows += @@ROWCOUNT;
  $deleteMissingBlock
  $identityInsertOff
  $triggerEnableStatement
  COMMIT TRANSACTION;
  SELECT N'__SQL_SYNC_INSERTED__=' + CONVERT(NVARCHAR(20), @SqlSyncInsertedRows);
  SELECT N'__SQL_SYNC_PROTECTED__=' + CONVERT(NVARCHAR(20), @SqlSyncProtectedRows);
  SELECT N'__SQL_SYNC_PROTECTED_UPSERTS__=' + CONVERT(NVARCHAR(20), @SqlSyncProtectedUpsertRows);
  SELECT N'__SQL_SYNC_PROTECTED_DELETES__=' + CONVERT(NVARCHAR(20), @SqlSyncProtectedDeleteRows);
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

String _buildStagedDeltaDeleteStatements({
  required String database,
  required String schema,
  required String table,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<Map<String, dynamic>> rows,
  bool filterProtectedKeys = false,
}) {
  if (rows.isEmpty) {
    return '';
  }
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  final keyColumns = primaryKeyColumns
      .map((name) => definitionsByName[name.toLowerCase()])
      .whereType<SqlSyncColumnDefinition>()
      .toList(growable: false);
  if (keyColumns.length != primaryKeyColumns.length) {
    throw ArgumentError(
      'Every delta delete key must have a column definition.',
    );
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
  final valueTuples = rows
      .map(
        (row) =>
            '(${keyColumns.map((column) => sourceBatchTargetLiteral(column, row[column.name])).join(', ')})',
      )
      .join(',\n      ');
  final joinClause = matchClauseForColumns(primaryKeyColumns, keyColumns);
  final protectedKeyFilter =
      filterProtectedKeys
          ? '''
  DELETE source
  FROM #delta_delete_rows AS source
  INNER JOIN #sqlsync_protected_keys AS target
    ON $joinClause;
  SET @SqlSyncProtectedDeleteRows += @@ROWCOUNT;'''
          : '';
  return '''
  CREATE TABLE #delta_delete_rows (
    $columnDefinitions
  );
  INSERT INTO #delta_delete_rows ($columnList)
  VALUES
      $valueTuples;
  $protectedKeyFilter
  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  DELETE target
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
  INNER JOIN #delta_delete_rows AS source
    ON $joinClause;
  DROP TABLE #delta_delete_rows;''';
}

String _buildPostUploadProtectionStatements({
  required String database,
  required String schema,
  required String table,
  required String stageTarget,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<Map<String, dynamic>> deltaDeleteRows,
  required int changeTrackingVersion,
}) {
  if (changeTrackingVersion < 0) {
    throw ArgumentError.value(
      changeTrackingVersion,
      'changeTrackingVersion',
      'Post-upload protection requires a non-negative Change Tracking version.',
    );
  }
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  final keyColumns = primaryKeyColumns
      .map((name) => definitionsByName[name.toLowerCase()])
      .whereType<SqlSyncColumnDefinition>()
      .toList(growable: false);
  if (keyColumns.length != primaryKeyColumns.length) {
    throw ArgumentError(
      'Every protected incoming row key must have a column definition.',
    );
  }
  final keyColumnList = keyColumns
      .map((column) => quoteIdentifier(column.name))
      .join(', ');
  final keyColumnDefinitions = keyColumns
      .map(
        (column) =>
            '${quoteIdentifier(column.name)} ${column.sqlCastType} NOT NULL',
      )
      .join(',\n    ');
  final stageKeyProjection = keyColumns
      .map((column) => 'source.${quoteIdentifier(column.name)}')
      .join(', ');
  final incomingToTargetJoin = _matchClauseForAliases(
    keyColumns,
    leftAlias: 'target',
    rightAlias: 'incoming',
  );
  final incomingToTrackingJoin = _matchClauseForAliases(
    keyColumns,
    leftAlias: 'ct',
    rightAlias: 'incoming',
  );
  final protectedToStageJoin = _matchClauseForAliases(
    keyColumns,
    leftAlias: 'protected',
    rightAlias: 'source',
  );
  final incomingKeyProjection = keyColumns
      .map((column) => 'incoming.${quoteIdentifier(column.name)}')
      .join(', ');
  final incomingKeyGroup = keyColumns
      .map((column) => 'incoming.${quoteIdentifier(column.name)}')
      .join(', ');
  final firstKey = quoteIdentifier(keyColumns.first.name);
  final target =
      '${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)}';
  final deleteKeyInsert =
      deltaDeleteRows.isEmpty
          ? ''
          : '''
  INSERT INTO #sqlsync_incoming_keys ($keyColumnList)
  VALUES
      ${deltaDeleteRows.map((row) => '(${keyColumns.map((column) => sourceBatchTargetLiteral(column, row[column.name])).join(', ')})').join(',\n      ')};''';
  return '''
  CREATE TABLE #sqlsync_incoming_keys (
    $keyColumnDefinitions
  );
  INSERT INTO #sqlsync_incoming_keys ($keyColumnList)
  SELECT DISTINCT $stageKeyProjection
  FROM $stageTarget AS source;
  $deleteKeyInsert

  -- Hold key/range locks until commit. A user write that starts after this
  -- point waits and is therefore a post-download change for the next cycle.
  DECLARE @SqlSyncLockedRows BIGINT = 0;
  SELECT @SqlSyncLockedRows = COUNT_BIG(target.$firstKey)
  FROM #sqlsync_incoming_keys AS incoming
  LEFT JOIN $target AS target WITH (UPDLOCK, HOLDLOCK)
    ON $incomingToTargetJoin;

  CREATE TABLE #sqlsync_protected_keys (
    $keyColumnDefinitions
  );
  INSERT INTO #sqlsync_protected_keys ($keyColumnList)
  SELECT $incomingKeyProjection
  FROM #sqlsync_incoming_keys AS incoming
  INNER JOIN CHANGETABLE(CHANGES $target, $changeTrackingVersion) AS ct
    ON $incomingToTrackingJoin
  WHERE ct.SYS_CHANGE_CONTEXT IS NULL
     OR ct.SYS_CHANGE_CONTEXT <> $sqlSyncChangeTrackingContextHex
  GROUP BY $incomingKeyGroup;
  SET @SqlSyncProtectedRows = @@ROWCOUNT;

  -- Remove only incoming rows whose permanent key was edited locally after
  -- this client uploaded. Unrelated local rows are never scanned or changed.
  DELETE source
  FROM $stageTarget AS source
  INNER JOIN #sqlsync_protected_keys AS protected
    ON $protectedToStageJoin;
  SET @SqlSyncProtectedUpsertRows = @@ROWCOUNT;
  DROP TABLE #sqlsync_incoming_keys;''';
}

String _buildLogicalIdentityReconciliationSql({
  required String database,
  required String schema,
  required String table,
  required String stageTarget,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<String> logicalIdentityColumns,
}) {
  if (logicalIdentityColumns.isEmpty) {
    return '';
  }
  if (primaryKeyColumns.length != 1) {
    throw ArgumentError(
      'Logical identity reconciliation currently requires one permanent primary key column.',
    );
  }
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  final primaryKey = definitionsByName[primaryKeyColumns.single.toLowerCase()];
  if (primaryKey == null || primaryKey.isIdentity) {
    throw ArgumentError(
      'Logical identity reconciliation requires a writable non-identity primary key.',
    );
  }
  for (final column in logicalIdentityColumns) {
    if (!definitionsByName.containsKey(column.toLowerCase())) {
      throw ArgumentError(
        'Every logical identity column must have a writable definition.',
      );
    }
  }
  final primaryKeyName = quoteIdentifier(primaryKey.name);
  final logicalJoinClause = nullableMatchClauseForColumns(
    logicalIdentityColumns,
    columns,
  );
  final primaryJoinClause = matchClauseForColumns(primaryKeyColumns, columns);
  final target =
      '${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)}';
  return '''
  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  UPDATE target
  SET target.$primaryKeyName = candidate.source_primary_key
  FROM $target AS target
  INNER JOIN (
    SELECT
      target.$primaryKeyName AS target_primary_key,
      source.$primaryKeyName AS source_primary_key,
      ROW_NUMBER() OVER (
        PARTITION BY source.$primaryKeyName
        ORDER BY target.$primaryKeyName
      ) AS logical_row_number
    FROM $target AS target
    INNER JOIN $stageTarget AS source
      ON $logicalJoinClause
    WHERE NOT ($primaryJoinClause)
      AND NOT EXISTS (
        SELECT 1
        FROM $target AS existing
        WHERE existing.$primaryKeyName = source.$primaryKeyName
      )
  ) AS candidate
    ON target.$primaryKeyName = candidate.target_primary_key
   AND candidate.logical_row_number = 1;

  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  DELETE target
  FROM $target AS target
  WHERE EXISTS (
    SELECT 1
    FROM $stageTarget AS source
    WHERE $logicalJoinClause
      AND NOT ($primaryJoinClause)
  );''';
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
/// Different GUIDs therefore remain independent. If the target constraint
/// detects that they represent the same business row, the client reports a
/// typed conflict so the control plane can choose a deterministic source and
/// run the generic authoritative reconciliation path.
List<Map<String, dynamic>> coalesceSqlSyncDeltaRows({
  required List<Map<String, dynamic>> rows,
  required List<String> primaryKeyColumns,
  List<String> logicalIdentityColumns = const <String>[],
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
  if (logicalIdentityColumns.isEmpty) {
    return winners;
  }

  final logicalWinnerByIdentity = <String, int>{};
  final logicalFirstIndex = <String, int>{};
  final logicalCandidates = <Map<String, dynamic>>[];
  for (final row in winners) {
    final operation = row['__sync_op']?.toString().toUpperCase() ?? '';
    final values = logicalIdentityColumns
        .map((column) => row[column])
        .toList(growable: false);
    final hasCompleteLogicalIdentity =
        operation != 'D' && values.every((value) => value != null);
    final identity =
        hasCompleteLogicalIdentity
            ? jsonEncode(values)
            : 'primary:${jsonEncode(primaryKeyColumns.map((column) => row[column]).toList())}';
    logicalFirstIndex[identity] ??= logicalCandidates.length;
    final currentIndex = logicalWinnerByIdentity[identity];
    logicalCandidates.add(row);
    final candidateIndex = logicalCandidates.length - 1;
    if (currentIndex == null ||
        _isLaterSyncRow(row, logicalCandidates[currentIndex])) {
      logicalWinnerByIdentity[identity] = candidateIndex;
    }
  }
  final orderedLogicalIdentities = logicalWinnerByIdentity.keys.toList(
    growable: false,
  )..sort(
    (left, right) =>
        logicalFirstIndex[left]!.compareTo(logicalFirstIndex[right]!),
  );
  return orderedLogicalIdentities
      .map((identity) => logicalCandidates[logicalWinnerByIdentity[identity]!])
      .toList(growable: false);
}

Map<String, dynamic>? latestSqlSyncDeltaRow(List<Map<String, dynamic>> rows) {
  Map<String, dynamic>? latest;
  for (final row in rows) {
    if (latest == null || _isLaterSyncRow(row, latest)) {
      latest = row;
    }
  }
  return latest;
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
  final candidateOrigin =
      candidate['__sync_origin_client']?.toString().toLowerCase() ?? '';
  final currentOrigin =
      current['__sync_origin_client']?.toString().toLowerCase() ?? '';
  final candidateVersion =
      int.tryParse(candidate['__sync_change_version']?.toString() ?? '') ?? -1;
  final currentVersion =
      int.tryParse(current['__sync_change_version']?.toString() ?? '') ?? -1;
  if (candidateOrigin == currentOrigin && candidateVersion != currentVersion) {
    return candidateVersion > currentVersion;
  }
  final candidateServerTime = _parseSyncUtcTimestamp(
    candidate['__sync_server_received_at_utc'],
  );
  final currentServerTime = _parseSyncUtcTimestamp(
    current['__sync_server_received_at_utc'],
  );
  if (candidateServerTime == null) {
    if (currentServerTime != null) return false;
  } else if (currentServerTime == null ||
      candidateServerTime.isAfter(currentServerTime)) {
    return true;
  } else if (candidateServerTime.isBefore(currentServerTime)) {
    return false;
  }
  final candidateServerSequence =
      candidate['__sync_server_sequence']?.toString() ?? '';
  final currentServerSequence =
      current['__sync_server_sequence']?.toString() ?? '';
  if (candidateServerSequence != currentServerSequence) {
    return candidateServerSequence.compareTo(currentServerSequence) > 0;
  }
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
        var sourceExpression = 'source.$quotedColumn';
        var targetExpression = 'target.$quotedColumn';
        final definition = definitionsByName[column.toLowerCase()];
        if (definition != null && definition.isTextLike) {
          sourceExpression = '$sourceExpression COLLATE DATABASE_DEFAULT';
          targetExpression = '$targetExpression COLLATE DATABASE_DEFAULT';
        }
        return '$sourceExpression IS NOT NULL AND $targetExpression = $sourceExpression';
      })
      .join(' AND ');
}

String nullableMatchClauseForColumns(
  List<String> matchColumns,
  List<SqlSyncColumnDefinition> columns,
) {
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  return matchColumns
      .map((column) {
        final quotedColumn = quoteIdentifier(column);
        var sourceExpression = 'source.$quotedColumn';
        var targetExpression = 'target.$quotedColumn';
        final definition = definitionsByName[column.toLowerCase()];
        if (definition != null && definition.isTextLike) {
          sourceExpression = '$sourceExpression COLLATE DATABASE_DEFAULT';
          targetExpression = '$targetExpression COLLATE DATABASE_DEFAULT';
        }
        return '(($sourceExpression IS NULL AND target.$quotedColumn IS NULL) OR $targetExpression = $sourceExpression)';
      })
      .join(' AND ');
}

String _matchClauseForAliases(
  List<SqlSyncColumnDefinition> columns, {
  required String leftAlias,
  required String rightAlias,
}) {
  return columns
      .map((column) {
        final quotedColumn = quoteIdentifier(column.name);
        var leftExpression = '$leftAlias.$quotedColumn';
        var rightExpression = '$rightAlias.$quotedColumn';
        if (column.isTextLike) {
          leftExpression = '$leftExpression COLLATE DATABASE_DEFAULT';
          rightExpression = '$rightExpression COLLATE DATABASE_DEFAULT';
        }
        return '$leftExpression = $rightExpression';
      })
      .join(' AND ');
}

String quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

String escapeSqlLiteral(String value) => value.replaceAll("'", "''");
