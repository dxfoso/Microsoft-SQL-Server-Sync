String windowsDatabaseLogin({
  required String domainOrMachine,
  required String username,
}) {
  final normalizedDomain = domainOrMachine.trim();
  final normalizedUsername = username.trim();
  if (normalizedDomain.isEmpty) {
    return normalizedUsername;
  }
  if (normalizedUsername.isEmpty) {
    return normalizedDomain;
  }
  return '$normalizedDomain\\$normalizedUsername';
}

String buildWindowsDatabaseAccessGrantSql({
  required String database,
  required String login,
}) {
  final databaseIdentifier = database.replaceAll(']', ']]');
  final loginIdentifier = login.replaceAll(']', ']]');
  final dynamicLoginIdentifier = loginIdentifier.replaceAll("'", "''");
  final loginLiteral = login.replaceAll("'", "''");
  return '''USE [master];

IF SUSER_ID(N'$loginLiteral') IS NULL
    CREATE LOGIN [$loginIdentifier] FROM WINDOWS;
GO

USE [$databaseIdentifier];

IF USER_ID(N'$loginLiteral') IS NULL
    CREATE USER [$loginIdentifier] FOR LOGIN [$loginIdentifier];
GO

IF ISNULL(IS_ROLEMEMBER(N'db_datareader', N'$loginLiteral'), 0) <> 1
    EXEC sp_addrolemember N'db_datareader', N'$loginLiteral';

IF ISNULL(IS_ROLEMEMBER(N'db_datawriter', N'$loginLiteral'), 0) <> 1
    EXEC sp_addrolemember N'db_datawriter', N'$loginLiteral';

GRANT CONNECT TO [$loginIdentifier];
GRANT ALTER TO [$loginIdentifier];

DECLARE @viewChangeTrackingSql nvarchar(max);
SET @viewChangeTrackingSql = N'';
SELECT @viewChangeTrackingSql = @viewChangeTrackingSql
    + N'GRANT VIEW CHANGE TRACKING ON SCHEMA::'
    + QUOTENAME(user_schemas.name)
    + N' TO [$dynamicLoginIdentifier];'
    + CHAR(13) + CHAR(10)
FROM (
    SELECT DISTINCT schemas.name
    FROM sys.schemas AS schemas
    INNER JOIN sys.tables AS tables
        ON tables.schema_id = schemas.schema_id
    WHERE tables.is_ms_shipped = 0
) AS user_schemas;
IF LEN(@viewChangeTrackingSql) > 0
    EXEC sp_executesql @viewChangeTrackingSql;
GO
''';
}

String buildDatabaseAccessDiscoverySql() {
  return r'''
SET NOCOUNT ON;
SELECT
  name,
  state_desc
FROM sys.databases
WHERE database_id > 4
ORDER BY name;
''';
}

List<DatabaseAccessStatus> parseDatabaseAccessDiscoveryRows(
  Iterable<List<String>> rows,
) {
  final statuses = <DatabaseAccessStatus>[];
  final seen = <String>{};
  for (final row in rows) {
    if (row.length < 2) {
      continue;
    }
    final database = row[0].trim();
    if (database.isEmpty || !seen.add(database.toLowerCase())) {
      continue;
    }
    statuses.add(
      DatabaseAccessStatus(
        database: database,
        hasAccess: false,
        state: row[1].trim(),
        accessProblem: 'not_checked',
      ),
    );
  }
  return statuses;
}

List<DatabaseAccessStatus> mergeDatabaseAccessDiscovery({
  required Iterable<DatabaseAccessStatus> catalog,
  required Iterable<String> referencedDatabases,
}) {
  final statusesByName = <String, DatabaseAccessStatus>{};
  for (final status in catalog) {
    final database = status.database.trim();
    if (database.isEmpty) {
      continue;
    }
    statusesByName.putIfAbsent(database.toLowerCase(), () => status);
  }
  for (final value in referencedDatabases) {
    final database = value.trim();
    if (database.isEmpty) {
      continue;
    }
    statusesByName.putIfAbsent(
      database.toLowerCase(),
      () => DatabaseAccessStatus(
        database: database,
        hasAccess: false,
        state: 'UNKNOWN',
        accessProblem: 'not_checked',
      ),
    );
  }
  final statuses = statusesByName.values.toList(growable: false);
  statuses.sort(
    (left, right) =>
        left.database.toLowerCase().compareTo(right.database.toLowerCase()),
  );
  return statuses;
}

String classifyDatabaseAccessProblem(String errorText) {
  final normalized = errorText.toLowerCase();
  final databaseUnavailable =
      normalized.contains('msg 5120') ||
      normalized.contains('msg 5173') ||
      normalized.contains('msg 945') ||
      normalized.contains('msg 926') ||
      normalized.contains('operating system error') ||
      normalized.contains('file activation failure');
  if (databaseUnavailable) {
    return 'database_unavailable';
  }
  final permissionDenied =
      normalized.contains('msg 4060') ||
      normalized.contains('msg 18456') ||
      normalized.contains('cannot open database');
  return permissionDenied ? 'access_required' : 'database_unavailable';
}

String powerShellSingleQuotedLiteral(String value) {
  return "'${value.replaceAll("'", "''")}'";
}

String buildElevatedDatabaseAccessHelperPowerShell({
  required String sqlCmdExecutable,
  required String server,
  required String sqlScriptPath,
  required String outputPath,
}) {
  final executableLiteral = powerShellSingleQuotedLiteral(sqlCmdExecutable);
  final serverLiteral = powerShellSingleQuotedLiteral(server);
  final scriptLiteral = powerShellSingleQuotedLiteral(sqlScriptPath);
  final outputLiteral = powerShellSingleQuotedLiteral(outputPath);
  return '''\$ErrorActionPreference = 'Stop'
try {
    \$sqlOutput = & $executableLiteral -S $serverLiteral -E -C -b -u -f 65001 -i $scriptLiteral 2>&1
    \$sqlExitCode = \$LASTEXITCODE
    \$sqlOutput | Out-File -LiteralPath $outputLiteral -Encoding Unicode
    if (\$sqlExitCode -ne 0) {
        exit \$sqlExitCode
    }
    exit 0
} catch {
    \$_ | Out-String | Out-File -LiteralPath $outputLiteral -Encoding Unicode
    exit 1
}
''';
}

String buildElevatedDatabaseAccessBatchHelperPowerShell({
  required String sqlCmdExecutable,
  required String server,
  required List<DatabaseAccessGrantScript> scripts,
  required String outputPath,
}) {
  final executableLiteral = powerShellSingleQuotedLiteral(sqlCmdExecutable);
  final serverLiteral = powerShellSingleQuotedLiteral(server);
  final outputLiteral = powerShellSingleQuotedLiteral(outputPath);
  final commands = scripts
      .map(
        (script) =>
            "    [PSCustomObject]@{ Database = "
            "${powerShellSingleQuotedLiteral(script.database)}; "
            "DatabaseSqlLiteral = "
            "${powerShellSingleQuotedLiteral(script.database.replaceAll("'", "''"))}; "
            "ScriptPath = "
            "${powerShellSingleQuotedLiteral(script.sqlScriptPath)} }",
      )
      .join(",\n");
  return '''\$ErrorActionPreference = 'Stop'
try {
  \$commands = @(
$commands
  )
  \$allSucceeded = \$true
  Remove-Item -LiteralPath $outputLiteral -Force -ErrorAction SilentlyContinue
  \$candidates = @($serverLiteral)
  \$requestedServer = $serverLiteral
  if (\$requestedServer -match '^(?i)(\\.|localhost|127\\.0\\.0\\.1|\\(local\\))(\\\\.*)?\$') {
    \$registryPaths = @(
      'HKLM:\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\SQL',
      'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Microsoft SQL Server\\Instance Names\\SQL'
    )
    foreach (\$registryPath in \$registryPaths) {
      if (-not (Test-Path -LiteralPath \$registryPath)) {
        continue
      }
      \$properties = (Get-ItemProperty -LiteralPath \$registryPath).PSObject.Properties |
        Where-Object { -not \$_.Name.StartsWith('PS') }
      foreach (\$property in \$properties) {
        if (\$property.Name -eq 'MSSQLSERVER') {
          \$candidates += '.'
          \$candidates += \$env:COMPUTERNAME
        } else {
          \$candidates += ('.\\' + \$property.Name)
          \$candidates += (\$env:COMPUTERNAME + '\\' + \$property.Name)
        }
      }
    }
  }
  \$candidates = @(\$candidates | Select-Object -Unique)
  foreach (\$command in \$commands) {
    \$selectedServer = \$null
    \$selectedResolvedServer = ''
    foreach (\$candidate in \$candidates) {
      ('--- Probe ' + \$command.Database + ' on ' + \$candidate + ' ---') | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
      \$probeQuery = "SET NOCOUNT ON; SELECT N'SYNC_GRANT_PROBE|' + REPLACE(COALESCE(CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), N''), N'|', N'/') + N'|' + REPLACE(COALESCE(SUSER_SNAME(), N''), N'|', N'/') + N'|' + CONVERT(nvarchar(1), COALESCE(IS_SRVROLEMEMBER(N'sysadmin'), 0)) + N'|' + CASE WHEN DB_ID(N'" + \$command.DatabaseSqlLiteral + "') IS NULL THEN N'0' ELSE N'1' END;"
      \$savedErrorActionPreference = \$ErrorActionPreference
      \$ErrorActionPreference = 'Continue'
      \$probeOutput = & $executableLiteral -S \$candidate -d master -E -C -b -u -h -1 -W -Q \$probeQuery 2>&1
      \$probeExitCode = \$LASTEXITCODE
      \$ErrorActionPreference = \$savedErrorActionPreference
      \$probeOutput | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
      if (\$probeExitCode -ne 0) {
        continue
      }
      \$probeLine = \$probeOutput |
        ForEach-Object { \$_.ToString().Trim() } |
        Where-Object { \$_.StartsWith('SYNC_GRANT_PROBE|') } |
        Select-Object -First 1
      if ([string]::IsNullOrWhiteSpace(\$probeLine)) {
        continue
      }
      \$probeFields = \$probeLine.Split('|')
      if (\$probeFields.Count -ge 5 -and \$probeFields[3].Trim() -eq '1' -and \$probeFields[4].Trim() -eq '1') {
        \$selectedServer = \$candidate
        \$selectedResolvedServer = \$probeFields[1].Trim()
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace(\$selectedServer)) {
      ('SYNC_GRANT_NOT_FOUND|' + \$command.Database) | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
      \$allSucceeded = \$false
      continue
    }
    ('=== ' + \$command.Database + ' ===') | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
    \$savedErrorActionPreference = \$ErrorActionPreference
    \$ErrorActionPreference = 'Continue'
    \$sqlOutput = & $executableLiteral -S \$selectedServer -E -C -b -u -f 65001 -i \$command.ScriptPath 2>&1
    \$sqlExitCode = \$LASTEXITCODE
    \$ErrorActionPreference = \$savedErrorActionPreference
    \$sqlOutput | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
    ('Result: exit ' + \$sqlExitCode) | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
    ('SYNC_GRANT_RESULT|' + \$command.Database + '|' + \$selectedResolvedServer + '|' + \$sqlExitCode) | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
    if (\$sqlExitCode -ne 0) {
      \$allSucceeded = \$false
    }
  }
  if (-not \$allSucceeded) {
    exit 1
  }
  exit 0
} catch {
  \$_ | Out-String | Out-File -LiteralPath $outputLiteral -Encoding Unicode -Append
  exit 1
}
''';
}

ElevatedDatabaseAccessContext? parseElevatedDatabaseAccessContext(
  String output,
) {
  for (final rawLine in output.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (!line.startsWith('SYNC_GRANT_CONTEXT|') &&
        !line.startsWith('SYNC_GRANT_PROBE|')) {
      continue;
    }
    final fields = line.split('|');
    if (fields.length < 4) {
      continue;
    }
    return ElevatedDatabaseAccessContext(
      server: fields[1].trim(),
      identity: fields[2].trim(),
      isSysadmin: fields[3].trim() == '1',
    );
  }
  return null;
}

List<DatabaseAccessGrantResult> parseDatabaseAccessGrantResults(String output) {
  final results = <DatabaseAccessGrantResult>[];
  for (final rawLine in output.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (!line.startsWith('SYNC_GRANT_RESULT|')) {
      continue;
    }
    final fields = line.split('|');
    if (fields.length < 4) {
      continue;
    }
    results.add(
      DatabaseAccessGrantResult(
        database: fields[1].trim(),
        server: fields[2].trim(),
        exitCode: int.tryParse(fields[3].trim()) ?? -1,
      ),
    );
  }
  return results;
}

String databaseAccessGrantFailureMessage({
  required String requestedServer,
  required Iterable<String> databases,
  required String sqlOutput,
}) {
  final names = databases.where((value) => value.trim().isNotEmpty).join(', ');
  final context = parseElevatedDatabaseAccessContext(sqlOutput);
  if (context != null && !context.isSysadmin) {
    return 'Windows approved the request as ${context.identity}, but that '
        'account is not a SQL Server administrator on ${context.server}. '
        'Windows administrator permission does not automatically grant SQL '
        'Server permission.\n\n'
        'Use an account that is already a SQL Server sysadmin, or ask the SQL '
        'Server administrator to run Copy grant scripts for $names.';
  }
  final normalized = sqlOutput.toLowerCase();
  if (context?.isSysadmin == true &&
      (normalized.contains('msg 911') ||
          normalized.contains('does not exist'))) {
    return 'The approved SQL Server administrator connected to '
        '${context!.server}, but $names does not exist on that SQL Server '
        'instance. In SQL Server Management Studio, verify that the Server '
        'name containing the database matches $requestedServer.';
  }
  if (normalized.contains('sync_grant_not_found|')) {
    return 'The approved SQL Server administrator searched the installed '
        'local SQL Server instances, but $names was not found. In SQL Server '
        'Management Studio, use the exact Server name shown in Object '
        'Explorer and verify that the database is attached and online.';
  }
  return 'Access was not granted to $names on $requestedServer.'
      '${sqlOutput.trim().isEmpty ? '' : '\n\n$sqlOutput'}';
}

String buildWindowsUacLauncherPowerShell({required String helperScriptPath}) {
  final helperLiteral = powerShellSingleQuotedLiteral(helperScriptPath);
  return '''\$ErrorActionPreference = 'Stop'
try {
    \$helperPath = $helperLiteral
    \$escapedHelperPath = \$helperPath.Replace('"', '`"')
    \$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + \$escapedHelperPath + '"'
    \$elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList \$arguments -Wait -PassThru
    exit \$elevated.ExitCode
} catch {
    [Console]::Error.WriteLine(\$_.Exception.Message)
    exit 1223
}
''';
}

class DatabaseAccessIssue {
  const DatabaseAccessIssue({
    required this.server,
    required this.database,
    required this.login,
    required this.details,
  });

  final String server;
  final String database;
  final String login;
  final String details;
}

class DatabaseAccessGrantScript {
  const DatabaseAccessGrantScript({
    required this.database,
    required this.sqlScriptPath,
  });

  final String database;
  final String sqlScriptPath;
}

class DatabaseAccessStatus {
  const DatabaseAccessStatus({
    required this.database,
    required this.hasAccess,
    required this.state,
    required this.accessProblem,
    this.accessError = '',
  });

  final String database;
  final bool hasAccess;
  final String state;
  final String accessProblem;
  final String accessError;
}

class ElevatedDatabaseAccessContext {
  const ElevatedDatabaseAccessContext({
    required this.server,
    required this.identity,
    required this.isSysadmin,
  });

  final String server;
  final String identity;
  final bool isSysadmin;
}

class DatabaseAccessGrantResult {
  const DatabaseAccessGrantResult({
    required this.database,
    required this.server,
    required this.exitCode,
  });

  final String database;
  final String server;
  final int exitCode;
}
