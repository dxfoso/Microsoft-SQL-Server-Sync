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
  THROW 51000, 'The restore target database already exists.', 1;
RESTORE DATABASE [$escapedDatabase]
FROM DISK = N'$backupLiteral'
WITH ${moves.join(',\n     ')}, CHECKSUM, RECOVERY, STATS = 5;
ALTER DATABASE [$escapedDatabase] SET MULTI_USER;
SELECT state_desc FROM sys.databases WHERE name = N'$databaseLiteral';
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
