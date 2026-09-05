import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/database_backup_restore.dart';

void main() {
  test(
    'normalizes backup destinations without replacing existing suffixes',
    () {
      expect(
        normalizeBackupDestination(r'C:\Backups\AmnDb048'),
        r'C:\Backups\AmnDb048.bak',
      );
      expect(
        normalizeBackupDestination(r'C:\Backups\AmnDb048.BAK'),
        r'C:\Backups\AmnDb048.BAK',
      );
      expect(() => normalizeBackupDestination('  '), throwsFormatException);
    },
  );

  test('parses SQL Server restore file inventory', () {
    final files = parseRestoreFileList('''
LogicalName|PhysicalName|Type|FileGroupName
-----------|------------|----|-------------
AmnDb048|D:\\Data\\AmnDb048.mdf|D|PRIMARY
AmnDb048_log|D:\\Data\\AmnDb048_log.ldf|L|NULL
''');
    expect(files.map((file) => file.logicalName), <String>[
      'AmnDb048',
      'AmnDb048_log',
    ]);
    expect(files.map((file) => file.type), <String>['D', 'L']);
  });

  test('restore SQL creates a new database and never replaces one', () {
    final sql = buildRestoreAsNewDatabaseSql(
      database: 'AmnDb048_Restored',
      backupPath: r'C:\Shared\backup.bak',
      dataDirectory: r'D:\SQLData',
      logDirectory: r'E:\SQLLogs',
      files: const <RestoreFileEntry>[
        RestoreFileEntry(logicalName: 'AmnDb048', type: 'D'),
        RestoreFileEntry(logicalName: 'AmnDb048_2', type: 'D'),
        RestoreFileEntry(logicalName: 'AmnDb048_log', type: 'L'),
      ],
    );
    expect(sql, contains("IF DB_ID(N'AmnDb048_Restored') IS NOT NULL"));
    expect(
      sql,
      contains(
        "RAISERROR('The restore target database already exists.', 16, 1)",
      ),
    );
    expect(sql, isNot(contains('THROW')));
    expect(sql, contains('RESTORE DATABASE [AmnDb048_Restored]'));
    expect(
      sql,
      contains(r"MOVE N'AmnDb048' TO N'D:\SQLData\AmnDb048_Restored.mdf'"),
    );
    expect(
      sql,
      contains(
        r"MOVE N'AmnDb048_2' TO N'D:\SQLData\AmnDb048_Restored_data2.ndf'",
      ),
    );
    expect(
      sql,
      contains(
        r"MOVE N'AmnDb048_log' TO N'E:\SQLLogs\AmnDb048_Restored_log1.ldf'",
      ),
    );
    expect(sql, isNot(contains('WITH REPLACE')));
    expect(sql, contains('CHECKSUM, RECOVERY, STATS = 5'));
  });

  test(
    'remote replacement SQL is explicit, checksum verified, and recoverable',
    () {
      final sql = buildReplaceDatabaseFromBackupSql(
        database: 'AmnDb048',
        backupPath: r'C:\Shared\source.bak',
        dataDirectory: r'D:\SQLData',
        logDirectory: r'E:\SQLLogs',
        files: const <RestoreFileEntry>[
          RestoreFileEntry(logicalName: 'AmnDb048', type: 'D'),
          RestoreFileEntry(logicalName: 'AmnDb048_log', type: 'L'),
        ],
      );
      expect(sql, contains("IF DB_ID(N'AmnDb048') IS NULL"));
      expect(
        sql,
        contains(
          "RAISERROR('The replacement target database does not exist.', 16, 1)",
        ),
      );
      expect(sql, contains('RETURN;'));
      expect(sql, isNot(contains('THROW')));
      expect(sql, contains('SET SINGLE_USER WITH ROLLBACK IMMEDIATE'));
      expect(sql, contains('RESTORE DATABASE [AmnDb048]'));
      expect(sql, contains('WITH REPLACE'));
      expect(sql, contains('CHECKSUM, RECOVERY, STATS = 5'));
      expect(sql, contains('SET MULTI_USER'));

      final recovery = buildReturnDatabaseToMultiUserSql('AmnDb048');
      expect(recovery, contains("IF DB_ID(N'AmnDb048') IS NOT NULL"));
      expect(recovery, contains('SET MULTI_USER WITH ROLLBACK IMMEDIATE'));
    },
  );

  test('parses bounded SQL Server operation progress', () {
    expect(parseSqlServerPercentComplete('\u{feff} 42.75\r\n'), 43);
    expect(parseSqlServerPercentComplete('101'), isNull);
    expect(parseSqlServerPercentComplete(''), isNull);
  });

  test('legacy SQL Server storage lookup falls back to target physical files', () {
    final sql = buildDatabaseStorageDirectoriesSql("AmnDb'048");
    expect(sql, contains("SERVERPROPERTY('InstanceDefaultDataPath')"));
    expect(sql, contains("SERVERPROPERTY('InstanceDefaultLogPath')"));
    expect(sql, contains("database_id = DB_ID(N'AmnDb''048') AND type = 0"));
    expect(sql, contains("database_id = DB_ID(N'AmnDb''048') AND type = 1"));
    expect(sql, contains('master.sys.master_files'));
    expect(sql, contains("CHARINDEX(N'\\', REVERSE(physical_name))"));
    expect(sql, contains("CHARINDEX(N'/', REVERSE(physical_name))"));
    expect(sql, isNot(contains('THROW')));
  });
}
