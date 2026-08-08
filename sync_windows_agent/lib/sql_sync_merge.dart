import 'dart:convert';

import 'sql_sync_schema.dart';

// "SQLSYNC" encoded as varbinary. Change Tracking preserves this origin on
// agent-applied writes so they can be excluded from the next outbound delta.
const sqlSyncChangeTrackingContextHex = '0x53514C53594E43';

/// Permanent safety rule: only an explicit Change Tracking delete tombstone
/// may remove the exact primary-key row it names. Snapshot absence is never a
/// delete instruction.
const sqlSyncDeletePolicy = 'explicit-tombstones-only';

// SQL Server accepts at most 1,000 rows in one INSERT ... VALUES statement.
// Keep that server-side bound and separate statements with sqlcmd's GO batch
// delimiter. This preserves one sqlcmd process/connection without asking SQL
// Server (especially memory-limited Express installations) to compile the
// complete snapshot as one enormous batch.
const targetSnapshotInsertRowsPerStatement = 1000;

int unexpectedCompleteSnapshotMismatchCount({
  required int unappliedRowCount,
  required int protectedUpsertRowCount,
}) {
  final safeUnappliedRows = unappliedRowCount < 0 ? 0 : unappliedRowCount;
  final safeProtectedRows =
      protectedUpsertRowCount < 0 ? 0 : protectedUpsertRowCount;
  final unexpected = safeUnappliedRows - safeProtectedRows;
  return unexpected < 0 ? 0 : unexpected;
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

String buildTargetSnapshotStageLoadSql({
  required String stageTableName,
  required List<SqlSyncColumnDefinition> columns,
  required List<Map<String, dynamic>> rows,
}) {
  final statements = <String>[
    buildTargetSnapshotStageSetupSql(
      stageTableName: stageTableName,
      columns: columns,
    ),
  ];
  for (
    var offset = 0;
    offset < rows.length;
    offset += targetSnapshotInsertRowsPerStatement
  ) {
    statements.add(
      buildTargetSnapshotStageInsertSql(
        stageTableName: stageTableName,
        columns: columns,
        rows: rows
            .skip(offset)
            .take(targetSnapshotInsertRowsPerStatement)
            .toList(growable: false),
      ),
    );
  }
  return statements.join('\nGO\n');
}

String buildTargetSnapshotStageApplySql({
  required String database,
  required String schema,
  required String table,
  required String stageTableName,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  List<List<String>> uniqueIndexColumnSets = const <List<String>>[],
  List<Map<String, dynamic>> deltaDeleteRows = const <Map<String, dynamic>>[],
  int? protectLocalChangesAfterVersion,
  bool manageTriggers = true,
  bool insertOnly = false,
  bool resolveUniqueConflictsLatestWins = false,
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
            uniqueIndexColumnSets: uniqueIndexColumnSets,
            deltaDeleteRows: deltaDeleteRows,
            changeTrackingVersion: protectLocalChangesAfterVersion,
          );
  final transactionIsolation =
      protectLocalChangesAfterVersion == null
          ? ''
          : 'SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;';
  final latestUniqueConflictStatements =
      resolveUniqueConflictsLatestWins
          ? _buildLatestUniqueConflictReplacementStatements(
            database: database,
            schema: schema,
            table: table,
            stageTarget: stageTarget,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            uniqueIndexColumnSets: uniqueIndexColumnSets,
          )
          : '';
  final mergeStatements = '''
  $deltaDeleteStatements
  $latestUniqueConflictStatements
  ${insertOnly ? '' : _buildBatchedUpdateStatement(database: database, schema: schema, table: table, sourceTableReference: stageTarget, sourceColumnList: sourceColumnList, joinClause: joinClause, updatableColumns: updatableColumns)}
  ${_buildBatchedInsertStatement(database: database, schema: schema, table: table, sourceTableReference: stageTarget, sourceColumnList: sourceColumnList, insertColumnList: insertColumnList, insertValueList: insertValueList, joinClause: joinClause)}
  SET @SqlSyncInsertedRows += @@ROWCOUNT;''';

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
  $postUploadProtectionStatements
  $triggerDisableStatement
  $identityInsertOn
  DECLARE @SqlSyncInsertedRows INT = 0;
  $mergeStatements
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

String _buildLatestUniqueConflictReplacementStatements({
  required String database,
  required String schema,
  required String table,
  required String stageTarget,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<List<String>> uniqueIndexColumnSets,
}) {
  final usableSets = uniqueIndexColumnSets
      .where((columnSet) => columnSet.isNotEmpty)
      .toList(growable: false);
  if (usableSets.isEmpty) {
    return '';
  }
  final businessKeyMatch = usableSets
      .map(
        (columnSet) =>
            '(${_nullableMatchClauseForAliases(columnSet, columns, leftAlias: 'target', rightAlias: 'source')})',
      )
      .join(' OR ');
  final samePrimaryKey = _nullableMatchClauseForAliases(
    primaryKeyColumns,
    columns,
    leftAlias: 'target',
    rightAlias: 'source',
  );
  return '''
  -- A server-approved latest winner may use a different permanent primary key
  -- while colliding with an older SQL unique/business key. Replace only that
  -- conflicting identity, inside the same transaction and tracking context.
  WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)
  DELETE target
  FROM ${quoteIdentifier(database)}.${quoteIdentifier(schema)}.${quoteIdentifier(table)} AS target
  INNER JOIN $stageTarget AS source
    ON $businessKeyMatch
  WHERE NOT ($samePrimaryKey);''';
}

String _buildPostUploadProtectionStatements({
  required String database,
  required String schema,
  required String table,
  required String stageTarget,
  required List<SqlSyncColumnDefinition> columns,
  required List<String> primaryKeyColumns,
  required List<List<String>> uniqueIndexColumnSets,
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
  final usableUniqueSets = uniqueIndexColumnSets
      .where((columnSet) => columnSet.isNotEmpty)
      .toList(growable: false);
  final uniqueConflictProtection =
      usableUniqueSets.isEmpty
          ? ''
          : '''
  -- A local edit to an older business-key identity after this client uploaded
  -- outranks the incoming replacement for this pass. Leave it for the next
  -- upload instead of silently deleting the post-upload user change.
  DELETE source
  FROM $stageTarget AS source
  WHERE EXISTS (
    SELECT 1
    FROM $target AS conflict
    INNER JOIN CHANGETABLE(CHANGES $target, $changeTrackingVersion) AS ct
      ON ${_matchClauseForAliases(keyColumns, leftAlias: 'conflict', rightAlias: 'ct')}
    WHERE (${usableUniqueSets.map((columnSet) => '(${_nullableMatchClauseForAliases(columnSet, columns, leftAlias: 'conflict', rightAlias: 'source')})').join(' OR ')})
      AND NOT (${_nullableMatchClauseForAliases(primaryKeyColumns, columns, leftAlias: 'conflict', rightAlias: 'source')})
      AND (ct.SYS_CHANGE_CONTEXT IS NULL
        OR ct.SYS_CHANGE_CONTEXT <> $sqlSyncChangeTrackingContextHex)
  );
  DECLARE @SqlSyncProtectedBusinessRows INT = @@ROWCOUNT;
  SET @SqlSyncProtectedRows += @SqlSyncProtectedBusinessRows;
  SET @SqlSyncProtectedUpsertRows += @SqlSyncProtectedBusinessRows;''';
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
  $uniqueConflictProtection
  DROP TABLE #sqlsync_incoming_keys;''';
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

String stageTableReference(String stageTableName) =>
    'tempdb.dbo.${quoteIdentifier(stageTableName)}';

/// Keeps one deterministic latest version for each permanent primary identity
/// and, when supplied, each SQL unique/business identity.
List<Map<String, dynamic>> coalesceSqlSyncDeltaRows({
  required List<Map<String, dynamic>> rows,
  required List<String> primaryKeyColumns,
  List<List<String>> uniqueKeyColumnSets = const <List<String>>[],
  Map<String, Map<String, dynamic>>? latestRowByKey,
}) {
  if (rows.isEmpty || primaryKeyColumns.isEmpty) {
    return rows;
  }
  if (uniqueKeyColumnSets.any((columnSet) => columnSet.isNotEmpty)) {
    final orderedIndexes = List<int>.generate(rows.length, (index) => index)
      ..sort((left, right) {
        if (_isLaterSyncRow(rows[left], rows[right])) return -1;
        if (_isLaterSyncRow(rows[right], rows[left])) return 1;
        return left.compareTo(right);
      });
    final claimedIdentities = <String>{};
    final acceptedIndexes = <int>[];
    for (final index in orderedIndexes) {
      final row = rows[index];
      final primaryValues = primaryKeyColumns
          .map((column) => row[column])
          .toList(growable: false);
      if (primaryValues.any((value) => value == null)) {
        continue;
      }
      final identities = <String>['primary:${jsonEncode(primaryValues)}'];
      if ((row['__sync_op']?.toString().trim().toUpperCase() ?? 'S') != 'D') {
        for (final columnSet in uniqueKeyColumnSets) {
          if (columnSet.isEmpty) continue;
          identities.add(
            'unique:${columnSet.map((column) => column.toLowerCase()).join('|')}:${jsonEncode(columnSet.map((column) => row[column]).toList(growable: false))}',
          );
        }
      }
      if (identities.any(claimedIdentities.contains)) {
        continue;
      }
      claimedIdentities.addAll(identities);
      acceptedIndexes.add(index);
      latestRowByKey?[jsonEncode(primaryValues)] = Map<String, dynamic>.from(
        row,
      );
    }
    acceptedIndexes.sort();
    return acceptedIndexes.map((index) => rows[index]).toList(growable: false);
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

String _nullableMatchClauseForAliases(
  List<String> matchColumns,
  List<SqlSyncColumnDefinition> columns, {
  required String leftAlias,
  required String rightAlias,
}) {
  final definitionsByName = {
    for (final column in columns) column.name.toLowerCase(): column,
  };
  return matchColumns
      .map((columnName) {
        final quotedColumn = quoteIdentifier(columnName);
        var leftExpression = '$leftAlias.$quotedColumn';
        var rightExpression = '$rightAlias.$quotedColumn';
        final column = definitionsByName[columnName.toLowerCase()];
        if (column != null && column.isTextLike) {
          leftExpression = '$leftExpression COLLATE DATABASE_DEFAULT';
          rightExpression = '$rightExpression COLLATE DATABASE_DEFAULT';
        }
        return '(($leftAlias.$quotedColumn IS NULL AND $rightAlias.$quotedColumn IS NULL) OR $leftExpression = $rightExpression)';
      })
      .join(' AND ');
}

String quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

String escapeSqlLiteral(String value) => value.replaceAll("'", "''");
