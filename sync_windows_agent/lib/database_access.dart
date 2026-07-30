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
