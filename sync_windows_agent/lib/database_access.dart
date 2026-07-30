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
GRANT VIEW CHANGE TRACKING TO [$loginIdentifier];
GO
''';
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
