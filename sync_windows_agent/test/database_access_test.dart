import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/database_access.dart';

void main() {
  test('builds the Windows login from the machine and user names', () {
    expect(
      windowsDatabaseLogin(
        domainOrMachine: 'DESKTOP-6MQFNA3',
        username: 'MY-PC',
      ),
      r'DESKTOP-6MQFNA3\MY-PC',
    );
  });

  test('builds a SQL Server 2008 compatible access grant script', () {
    final sql = buildWindowsDatabaseAccessGrantSql(
      database: 'CustomerLedger',
      login: r'DESKTOP-6MQFNA3\MY-PC',
    );

    expect(sql, contains('USE [CustomerLedger];'));
    expect(
      sql,
      contains(r'CREATE LOGIN [DESKTOP-6MQFNA3\MY-PC] FROM WINDOWS;'),
    );
    expect(sql, contains("ISNULL(IS_ROLEMEMBER(N'db_datareader'"));
    expect(sql, contains("EXEC sp_addrolemember N'db_datareader'"));
    expect(sql, contains("EXEC sp_addrolemember N'db_datawriter'"));
    expect(sql, contains(r'GRANT CONNECT TO [DESKTOP-6MQFNA3\MY-PC]'));
    expect(sql, contains(r'GRANT ALTER TO [DESKTOP-6MQFNA3\MY-PC]'));
    expect(
      sql,
      contains(r'GRANT VIEW CHANGE TRACKING TO [DESKTOP-6MQFNA3\MY-PC]'),
    );
    expect(sql, isNot(contains('ALTER ROLE')));
  });

  test('escapes database and login identifiers and literals', () {
    final sql = buildWindowsDatabaseAccessGrantSql(
      database: "db]'one",
      login: "PC\\user]'one",
    );

    expect(sql, contains("USE [db]]'one];"));
    expect(sql, contains("SUSER_ID(N'PC\\user]''one')"));
    expect(sql, contains("CREATE LOGIN [PC\\user]]'one]"));
  });

  test('discovers every non-system database and its access state', () {
    final sql = buildDatabaseAccessDiscoverySql();
    final statuses = parseDatabaseAccessDiscoveryRows([
      ['ConfigStore', 'ONLINE'],
      ['CustomerLedger', 'ONLINE'],
      ['ArchiveStore', 'OFFLINE'],
    ]);

    expect(sql, isNot(contains('HAS_DBACCESS')));
    expect(sql, contains('database_id > 4'));
    expect(statuses.map((status) => status.database), [
      'ConfigStore',
      'CustomerLedger',
      'ArchiveStore',
    ]);
    expect(statuses.first.hasAccess, isFalse);
    expect(statuses[1].hasAccess, isFalse);
    expect(statuses.last.state, 'OFFLINE');
    expect(statuses.first.accessProblem, 'not_checked');
  });

  test('merges configured database references hidden from sys.databases', () {
    final statuses = mergeDatabaseAccessDiscovery(
      catalog: parseDatabaseAccessDiscoveryRows([
        ['AmnConfig', 'ONLINE'],
        ['AmnDb015', 'RECOVERY_PENDING'],
      ]),
      referencedDatabases: ['AmnConfig', 'AmnDb028', 'AmnDb048', 'amndb048'],
    );

    expect(statuses.map((status) => status.database), [
      'AmnConfig',
      'AmnDb015',
      'AmnDb028',
      'AmnDb048',
    ]);
    expect(
      statuses.firstWhere((status) => status.database == 'AmnDb048').state,
      'UNKNOWN',
    );
  });

  test('distinguishes access grants from broken database attachments', () {
    expect(
      classifyDatabaseAccessProblem(
        "Msg 4060 Cannot open database requested by the login. Msg 18456 Login failed.",
      ),
      'access_required',
    );
    expect(
      classifyDatabaseAccessProblem(
        'Msg 5120 Unable to open the physical file. Operating system error 2.',
      ),
      'database_unavailable',
    );
    expect(
      classifyDatabaseAccessProblem(
        'File activation failure. Cannot open database requested by the login.',
      ),
      'database_unavailable',
    );
  });

  test('builds an elevated helper without exposing credentials', () {
    final script = buildElevatedDatabaseAccessHelperPowerShell(
      sqlCmdExecutable: r'C:\Program Files\SQL Tools\SQLCMD.EXE',
      server: r'.\SQLEXPRESS',
      sqlScriptPath: r'C:\Temp Folder\grant-access.sql',
      outputPath: r'C:\Temp Folder\grant-output.txt',
    );

    expect(script, contains(r"& 'C:\Program Files\SQL Tools\SQLCMD.EXE'"));
    expect(script, contains(r"-S '.\SQLEXPRESS' -E -C -b"));
    expect(script, contains(r"-i 'C:\Temp Folder\grant-access.sql'"));
    expect(
      script,
      contains(r"Out-File -LiteralPath 'C:\Temp Folder\grant-output.txt'"),
    );
    expect(script, isNot(contains('-U')));
    expect(script, isNot(contains('-P')));
  });

  test('builds a standard Windows UAC launcher and escapes paths', () {
    final script = buildWindowsUacLauncherPowerShell(
      helperScriptPath: r"C:\Users\O'Brien\App Data\grant.ps1",
    );

    expect(script, contains('-Verb RunAs'));
    expect(script, contains('-Wait -PassThru'));
    expect(script, contains(r"'C:\Users\O''Brien\App Data\grant.ps1'"));
    expect(script, contains('exit 1223'));
  });

  test('generated PowerShell scripts pass the Windows parser', () async {
    if (!Platform.isWindows) {
      return;
    }
    final scripts = [
      buildElevatedDatabaseAccessHelperPowerShell(
        sqlCmdExecutable: r"C:\Program Files\O'Brien Tools\SQLCMD.EXE",
        server: r'.\SQLEXPRESS',
        sqlScriptPath: r"C:\Users\O'Brien\App Data\grant-access.sql",
        outputPath: r"C:\Users\O'Brien\App Data\grant-output.txt",
      ),
      buildWindowsUacLauncherPowerShell(
        helperScriptPath: r"C:\Users\O'Brien\App Data\grant.ps1",
      ),
    ];

    for (final script in scripts) {
      final result = await Process.run(
        'powershell.exe',
        const [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r"$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseInput($env:SYNC_AGENT_TEST_SCRIPT, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 }",
        ],
        environment: {
          ...Platform.environment,
          'SYNC_AGENT_TEST_SCRIPT': script,
        },
        runInShell: false,
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
    }
  });
}
