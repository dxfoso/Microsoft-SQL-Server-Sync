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
      database: 'AmnDb048',
      login: r'DESKTOP-6MQFNA3\MY-PC',
    );

    expect(sql, contains('USE [AmnDb048];'));
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
}
