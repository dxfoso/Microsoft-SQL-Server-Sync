import 'dart:convert';

class RestoreFileEntry {
  const RestoreFileEntry({required this.logicalName, required this.type});

  final String logicalName;
  final String type;
}

String safeDatabaseFileStem(String database) {
  final normalized = database.trim().replaceAll(
    RegExp(r'[^A-Za-z0-9._-]'),
    '_',
  );
  if (normalized.isEmpty) {
    throw const FormatException('Database name has no usable file characters.');
  }
  return normalized;
}

String normalizeBackupDestination(String destination) {
  final trimmed = destination.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Backup destination is empty.');
  }
  return trimmed.toLowerCase().endsWith('.bak') ? trimmed : '$trimmed.bak';
}

List<RestoreFileEntry> parseRestoreFileList(String output) {
  final entries = <RestoreFileEntry>[];
  final logicalNames = <String>{};
  for (final line in const LineSplitter().convert(output)) {
    final trimmed = line.trim().replaceFirst('\u{feff}', '');
    if (trimmed.isEmpty ||
        trimmed.startsWith('---') ||
        trimmed.startsWith('(') ||
        trimmed.toLowerCase().contains('changed database context')) {
      continue;
    }
    final values = trimmed.split('|').map((value) => value.trim()).toList();
    if (values.length < 3 || values.first.toLowerCase() == 'logicalname') {
      continue;
    }
    final logicalName = values[0];
    final type = values[2].toUpperCase();
    if (logicalName.isEmpty || !const {'D', 'L', 'F', 'S'}.contains(type)) {
      continue;
    }
    if (!logicalNames.add(logicalName)) {
      throw FormatException('Duplicate logical backup file: $logicalName');
    }
    entries.add(RestoreFileEntry(logicalName: logicalName, type: type));
  }
  if (entries.isEmpty || !entries.any((entry) => entry.type == 'D')) {
    throw const FormatException(
      'The backup does not contain a primary SQL Server data file.',
    );
  }
  return entries;
}

String buildRestoreAsNewDatabaseSql({
  required String database,
  required String backupPath,
  required String dataDirectory,
  required String logDirectory,
  required List<RestoreFileEntry> files,
}) {
  if (files.isEmpty) {
    throw ArgumentError.value(files, 'files', 'must not be empty');
  }
  final escapedDatabase = database.replaceAll(']', ']]');
  final databaseLiteral = database.replaceAll("'", "''");
  final backupLiteral = backupPath.replaceAll("'", "''");
  final stem = safeDatabaseFileStem(database);
  var dataIndex = 0;
  var logIndex = 0;
  final moves = <String>[];
  for (final file in files) {
    final isLog = file.type == 'L';
    final directory = isLog ? logDirectory : dataDirectory;
    final separator =
        directory.endsWith('\\') || directory.endsWith('/') ? '' : '\\';
    final fileName =
        isLog
            ? '${stem}_log${++logIndex}.ldf'
            : dataIndex++ == 0
            ? '$stem.mdf'
            : '${stem}_data$dataIndex.ndf';
    final targetPath = '$directory$separator$fileName'.replaceAll("'", "''");
    final logicalName = file.logicalName.replaceAll("'", "''");
    moves.add("MOVE N'$logicalName' TO N'$targetPath'");
  }
  return '''
SET NOCOUNT ON;
IF DB_ID(N'$databaseLiteral') IS NOT NULL
BEGIN
  RAISERROR('The restore target database already exists.', 16, 1);
  RETURN;
END;
RESTORE DATABASE [$escapedDatabase]
FROM DISK = N'$backupLiteral'
WITH ${moves.join(',\n     ')}, CHECKSUM, RECOVERY, STATS = 5;
ALTER DATABASE [$escapedDatabase] SET MULTI_USER;
SELECT state_desc FROM sys.databases WHERE name = N'$databaseLiteral';
''';
}

String buildReplaceDatabaseFromBackupSql({
  required String database,
  required String backupPath,
  required String dataDirectory,
  required String logDirectory,
  required List<RestoreFileEntry> files,
}) {
  if (files.isEmpty) {
    throw ArgumentError.value(files, 'files', 'must not be empty');
  }
  final escapedDatabase = database.replaceAll(']', ']]');
  final databaseLiteral = database.replaceAll("'", "''");
  final backupLiteral = backupPath.replaceAll("'", "''");
  final stem = safeDatabaseFileStem(database);
  var dataIndex = 0;
  var logIndex = 0;
  final moves = <String>[];
  for (final file in files) {
    final isLog = file.type == 'L';
    final directory = isLog ? logDirectory : dataDirectory;
    final separator =
        directory.endsWith('\\') || directory.endsWith('/') ? '' : '\\';
    final fileName =
        isLog
            ? '${stem}_recovery_log${++logIndex}.ldf'
            : dataIndex++ == 0
            ? '${stem}_recovery.mdf'
            : '${stem}_recovery_data$dataIndex.ndf';
    final targetPath = '$directory$separator$fileName'.replaceAll("'", "''");
    final logicalName = file.logicalName.replaceAll("'", "''");
    moves.add("MOVE N'$logicalName' TO N'$targetPath'");
  }
  return '''
SET NOCOUNT ON;
IF DB_ID(N'$databaseLiteral') IS NULL
BEGIN
  RAISERROR('The replacement target database does not exist.', 16, 1);
  RETURN;
END;
ALTER DATABASE [$escapedDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$escapedDatabase]
FROM DISK = N'$backupLiteral'
WITH REPLACE, ${moves.join(',\n     ')}, CHECKSUM, RECOVERY, STATS = 5;
ALTER DATABASE [$escapedDatabase] SET MULTI_USER;
SELECT state_desc FROM sys.databases WHERE name = N'$databaseLiteral';
''';
}

String buildReturnDatabaseToMultiUserSql(String database) {
  final escapedDatabase = database.replaceAll(']', ']]');
  final databaseLiteral = database.replaceAll("'", "''");
  return '''
SET NOCOUNT ON;
IF DB_ID(N'$databaseLiteral') IS NOT NULL
  ALTER DATABASE [$escapedDatabase] SET MULTI_USER WITH ROLLBACK IMMEDIATE;
''';
}

String buildInstallAlameenLabAuditSql() => r"""
SET NOCOUNT ON;
IF OBJECT_ID(N'dbo.SqlSyncLabAudit', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.SqlSyncLabAudit (
    AuditId uniqueidentifier NOT NULL CONSTRAINT DF_SqlSyncLabAudit_AuditId DEFAULT NEWID(),
    TableName sysname NOT NULL,
    Operation nvarchar(16) NOT NULL,
    CapturedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_SqlSyncLabAudit_CapturedAtUtc DEFAULT SYSUTCDATETIME(),
    InsertedRows xml NULL,
    DeletedRows xml NULL,
    CONSTRAINT PK_SqlSyncLabAudit PRIMARY KEY (AuditId)
  );
END;
IF NOT EXISTS (
  SELECT 1 FROM sys.change_tracking_tables
  WHERE object_id = OBJECT_ID(N'dbo.SqlSyncLabAudit')
)
  ALTER TABLE dbo.SqlSyncLabAudit ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = OFF);

DECLARE @tables TABLE (TableName sysname NOT NULL PRIMARY KEY);
INSERT INTO @tables (TableName) VALUES
  (N'ac000'), (N'bi000'), (N'bu000'), (N'ce000'), (N'cp000'),
  (N'en000'), (N'er000'), (N'MatExBarcode000'), (N'mc000'),
  (N'ms000'), (N'mt000'), (N'pt000');

DECLARE @table sysname;
DECLARE @trigger sysname;
DECLARE @columns nvarchar(max);
DECLARE @sql nvarchar(max);
DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT TableName FROM @tables ORDER BY TableName;
OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table;
WHILE @@FETCH_STATUS = 0
BEGIN
  IF OBJECT_ID(N'dbo.' + QUOTENAME(@table), N'U') IS NOT NULL
  BEGIN
    SET @trigger = N'TR_SqlSyncLabAudit_' + @table;
    SET @columns = N'';
    SELECT @columns = @columns +
      CASE WHEN LEN(@columns) = 0 THEN N'' ELSE N',' END +
      N'r.' + QUOTENAME(c.name)
    FROM sys.columns AS c
    WHERE c.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@table))
      AND c.system_type_id NOT IN (34, 35, 99)
    ORDER BY c.column_id;
    IF LEN(@columns) = 0
    BEGIN
      RAISERROR('A lab-audit table has no serializable columns.', 16, 1);
      CLOSE table_cursor;
      DEALLOCATE table_cursor;
      RETURN;
    END;
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@trigger), N'TR') IS NOT NULL
    BEGIN
      SET @sql = N'DROP TRIGGER dbo.' + QUOTENAME(@trigger);
      EXEC sp_executesql @sql;
    END;
    SET @sql = N'CREATE TRIGGER dbo.' + QUOTENAME(@trigger) +
      N' ON dbo.' + QUOTENAME(@table) + N' AFTER INSERT, UPDATE, DELETE AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @inserted xml;
  DECLARE @deleted xml;
  SELECT @inserted = (SELECT ' + @columns + N' FROM inserted AS r FOR XML RAW(''row''), ROOT(''rows''), BINARY BASE64, TYPE);
  SELECT @deleted = (SELECT ' + @columns + N' FROM deleted AS r FOR XML RAW(''row''), ROOT(''rows''), BINARY BASE64, TYPE);
  INSERT dbo.SqlSyncLabAudit (TableName, Operation, InsertedRows, DeletedRows)
  VALUES (N''' + REPLACE(@table, N'''', N'''''') + N''',
    CASE WHEN EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted) THEN N''U''
         WHEN EXISTS (SELECT 1 FROM inserted) THEN N''I'' ELSE N''D'' END,
    @inserted, @deleted);
END;';
    EXEC sp_executesql @sql;
  END;
  FETCH NEXT FROM table_cursor INTO @table;
END;
CLOSE table_cursor;
DEALLOCATE table_cursor;
SELECT COUNT(*) AS InstalledTriggerCount
FROM sys.triggers
WHERE name LIKE N'TR[_]SqlSyncLabAudit[_]%';
""";

String buildDatabaseStorageDirectoriesSql(String database) {
  final databaseLiteral = database.replaceAll("'", "''");
  return '''
SET NOCOUNT ON;
DECLARE @data nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath'));
DECLARE @logs nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultLogPath'));
IF NULLIF(@data, N'') IS NULL
  SELECT TOP (1) @data =
    CASE
      WHEN CHARINDEX(N'\\', REVERSE(physical_name)) > 0 THEN
        LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'\\', REVERSE(physical_name)) + 1)
      WHEN CHARINDEX(N'/', REVERSE(physical_name)) > 0 THEN
        LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'/', REVERSE(physical_name)) + 1)
      ELSE NULL
    END
  FROM master.sys.master_files
  WHERE database_id = DB_ID(N'$databaseLiteral') AND type = 0
  ORDER BY file_id;
IF NULLIF(@logs, N'') IS NULL
  SELECT TOP (1) @logs =
    CASE
      WHEN CHARINDEX(N'\\', REVERSE(physical_name)) > 0 THEN
        LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'\\', REVERSE(physical_name)) + 1)
      WHEN CHARINDEX(N'/', REVERSE(physical_name)) > 0 THEN
        LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'/', REVERSE(physical_name)) + 1)
      ELSE NULL
    END
  FROM master.sys.master_files
  WHERE database_id = DB_ID(N'$databaseLiteral') AND type = 1
  ORDER BY file_id;
SELECT @data, COALESCE(NULLIF(@logs, N''), @data);
''';
}

int? parseSqlServerPercentComplete(String output) {
  for (final line in const LineSplitter().convert(output)) {
    final value = double.tryParse(line.trim().replaceFirst('\u{feff}', ''));
    if (value != null && value >= 0 && value <= 100) {
      return value.round().clamp(0, 100);
    }
  }
  return null;
}
