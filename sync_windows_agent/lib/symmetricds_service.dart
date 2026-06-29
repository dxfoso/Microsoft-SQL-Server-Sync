import 'dart:io';

import 'package:path/path.dart' as path;

class SymmetricDsTableConfig {
  const SymmetricDsTableConfig({
    required this.syncKey,
    required this.tableName,
    required this.enabled,
  });

  final String syncKey;
  final String tableName;
  final bool enabled;
}

class SymmetricDsConfigResult {
  const SymmetricDsConfigResult({
    required this.configured,
    required this.message,
    required this.propertiesPath,
    required this.tablesPath,
    required this.bootstrapSqlPath,
    required this.runtimeStatus,
    required this.runtimeMessage,
    required this.runtimeCommandPath,
  });

  final bool configured;
  final String message;
  final String propertiesPath;
  final String tablesPath;
  final String bootstrapSqlPath;
  final String runtimeStatus;
  final String runtimeMessage;
  final String runtimeCommandPath;
}

class SymmetricDsService {
  const SymmetricDsService();

  Future<SymmetricDsConfigResult> writeNodeConfig({
    required String clientName,
    required String machineName,
    required String server,
    required String database,
    required bool useWindowsAuth,
    required String username,
    required String password,
    required Uri registrationUrl,
    required Iterable<SymmetricDsTableConfig> tables,
  }) async {
    final root = await _configRoot();
    final enginesDir = Directory(path.join(root.path, 'engines'));
    await enginesDir.create(recursive: true);

    final sanitizedClient = _sanitizeNodeId(clientName);
    final selectedTables = tables
        .where((table) => table.enabled)
        .where((table) => table.syncKey.trim().isNotEmpty)
        .toList(growable: false)
      ..sort((left, right) => left.syncKey.compareTo(right.syncKey));
    final selectedTableKeys =
        selectedTables.map((table) => table.syncKey.trim()).toSet().toList()
          ..sort();

    final propertiesFile = File(
      path.join(enginesDir.path, '$sanitizedClient.properties'),
    );
    final tablesFile = File(
      path.join(enginesDir.path, '$sanitizedClient-tables.txt'),
    );
    final bootstrapSqlFile = File(
      path.join(enginesDir.path, '$sanitizedClient-bootstrap.sql'),
    );

    await propertiesFile.writeAsString(
      _nodeProperties(
        clientName: clientName,
        machineName: machineName,
        server: server,
        database: database,
        useWindowsAuth: useWindowsAuth,
        username: username,
        password: password,
        registrationUrl: registrationUrl,
      ),
      flush: true,
    );
    await tablesFile.writeAsString(
      '${selectedTableKeys.join('\n')}\n',
      flush: true,
    );
    await bootstrapSqlFile.writeAsString(
      _bootstrapSql(clientName: clientName, tables: selectedTables),
      flush: true,
    );

    final runtime = await _ensureRuntime(
      clientName: clientName,
      propertiesPath: propertiesFile.path,
    );
    final configMessage =
        selectedTableKeys.isEmpty
            ? 'SymmetricDS config written with no selected tables.'
            : 'SymmetricDS config written for ${selectedTableKeys.length} selected table${selectedTableKeys.length == 1 ? '' : 's'}; bootstrap SQL is ready.';

    return SymmetricDsConfigResult(
      configured: selectedTableKeys.isNotEmpty,
      message: '$configMessage ${runtime.message}',
      propertiesPath: propertiesFile.path,
      tablesPath: tablesFile.path,
      bootstrapSqlPath: bootstrapSqlFile.path,
      runtimeStatus: runtime.status,
      runtimeMessage: runtime.message,
      runtimeCommandPath: runtime.commandPath,
    );
  }

  Future<Directory> _configRoot() async {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      return Directory(path.join(appData, 'SqlSyncAgent', 'symmetricds'));
    }
    return Directory(path.join(Directory.current.path, 'symmetricds'));
  }

  String _nodeProperties({
    required String clientName,
    required String machineName,
    required String server,
    required String database,
    required bool useWindowsAuth,
    required String username,
    required String password,
    required Uri registrationUrl,
  }) {
    final nodeGroupId = 'client';
    final externalId = _sanitizeNodeId(clientName);
    final jdbcUrl = _jdbcUrl(
      server: server,
      database: database,
      useWindowsAuth: useWindowsAuth,
    );
    final userLine = useWindowsAuth ? '' : 'db.user=$username\n';
    final passwordLine = useWindowsAuth ? '' : 'db.password=$password\n';
    return '''
engine.name=$externalId
group.id=$nodeGroupId
external.id=$externalId
sync.url=$registrationUrl
registration.url=$registrationUrl
db.driver=com.microsoft.sqlserver.jdbc.SQLServerDriver
db.url=$jdbcUrl
$userLine${passwordLine}auto.registration=true
sqlsync.client.name=$clientName
sqlsync.machine.name=$machineName
sqlsync.table.selection.file=$externalId-tables.txt
''';
  }

  String _jdbcUrl({
    required String server,
    required String database,
    required bool useWindowsAuth,
  }) {
    final normalizedServer =
        server.trim().isEmpty ? 'localhost' : server.trim();
    final normalizedDatabase =
        database.trim().isEmpty ? 'master' : database.trim();
    final authSuffix =
        useWindowsAuth
            ? ';integratedSecurity=true;trustServerCertificate=true'
            : ';trustServerCertificate=true';
    return 'jdbc:sqlserver://$normalizedServer;databaseName=$normalizedDatabase$authSuffix';
  }

  String _sanitizeNodeId(String value) {
    final sanitized = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return sanitized.isEmpty ? 'client' : sanitized;
  }

  Future<_SymmetricDsRuntimeStatus> _ensureRuntime({
    required String clientName,
    required String propertiesPath,
  }) async {
    final command = _runtimeCommand();
    if (command == null) {
      return const _SymmetricDsRuntimeStatus(
        status: 'runtime-missing',
        message:
            'SymmetricDS runtime is not bundled yet; expected symmetricds/bin/sym.bat next to the agent.',
        commandPath: '',
      );
    }

    final pidFile = await _runtimePidFile(clientName);
    final existingPid = await _readPid(pidFile);
    if (existingPid != null && await _isPidRunning(existingPid)) {
      return _SymmetricDsRuntimeStatus(
        status: 'runtime-running',
        message: 'SymmetricDS runtime is already running.',
        commandPath: command.path,
      );
    }

    final port = _localRuntimePort(clientName);
    try {
      final process = await Process.start(
        command.path,
        ['--properties', propertiesPath, '--port', '$port', '--server'],
        mode: ProcessStartMode.detached,
        runInShell: Platform.isWindows,
        workingDirectory: command.installRoot,
      );
      await pidFile.parent.create(recursive: true);
      await pidFile.writeAsString('${process.pid}', flush: true);
      return _SymmetricDsRuntimeStatus(
        status: 'runtime-started',
        message: 'SymmetricDS runtime started on local port $port.',
        commandPath: command.path,
      );
    } on ProcessException catch (error) {
      return _SymmetricDsRuntimeStatus(
        status: 'runtime-start-failed',
        message: 'Unable to start SymmetricDS runtime: ${error.message}',
        commandPath: command.path,
      );
    } catch (error) {
      return _SymmetricDsRuntimeStatus(
        status: 'runtime-start-failed',
        message: 'Unable to start SymmetricDS runtime: $error',
        commandPath: command.path,
      );
    }
  }

  _SymmetricDsCommand? _runtimeCommand() {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      path.join(executableDir.path, 'symmetricds', 'bin', 'sym.bat'),
      path.join(executableDir.path, 'symmetricds', 'bin', 'sym'),
      path.join(Directory.current.path, 'symmetricds', 'bin', 'sym.bat'),
      path.join(Directory.current.path, 'symmetricds', 'bin', 'sym'),
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        return _SymmetricDsCommand(
          path: file.path,
          installRoot: file.parent.parent.path,
        );
      }
    }
    return null;
  }

  Future<File> _runtimePidFile(String clientName) async {
    final root = await _configRoot();
    return File(
      path.join(root.path, 'runtime', '${_sanitizeNodeId(clientName)}.pid'),
    );
  }

  Future<int?> _readPid(File pidFile) async {
    try {
      if (!await pidFile.exists()) {
        return null;
      }
      return int.tryParse((await pidFile.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isPidRunning(int pid) async {
    if (pid <= 0) {
      return false;
    }
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist.exe', [
          '/FI',
          'PID eq $pid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        return result.exitCode == 0 &&
            result.stdout.toString().contains('"$pid"');
      }
      final result = await Process.run('kill', ['-0', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  int _localRuntimePort(String clientName) {
    var hash = 0;
    for (final codeUnit in clientName.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return 15000 + (hash % 1000);
  }

  String _bootstrapSql({
    required String clientName,
    required List<SymmetricDsTableConfig> tables,
  }) {
    final buffer =
        StringBuffer()
          ..writeln('-- Generated by SQL Sync Windows Agent.')
          ..writeln('-- Apply after SymmetricDS creates the sym_* tables.')
          ..writeln('SET XACT_ABORT ON;')
          ..writeln('BEGIN TRANSACTION;')
          ..writeln()
          ..writeln(
            "IF NOT EXISTS (SELECT 1 FROM sym_node_group WHERE node_group_id = 'server')",
          )
          ..writeln(
            "  INSERT INTO sym_node_group (node_group_id, description, create_time, last_update_time) VALUES ('server', 'SQL Sync central node', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
          )
          ..writeln(
            "IF NOT EXISTS (SELECT 1 FROM sym_node_group WHERE node_group_id = 'client')",
          )
          ..writeln(
            "  INSERT INTO sym_node_group (node_group_id, description, create_time, last_update_time) VALUES ('client', 'SQL Sync Windows clients', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
          )
          ..writeln()
          ..writeln(
            "IF NOT EXISTS (SELECT 1 FROM sym_channel WHERE channel_id = 'default')",
          )
          ..writeln(
            "  INSERT INTO sym_channel (channel_id, processing_order, max_batch_size, enabled, description, create_time, last_update_time) VALUES ('default', 1, 100000, 1, 'Default SQL Sync data channel', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
          )
          ..writeln()
          ..writeln(_routerSql('client_2_server', 'client', 'server'))
          ..writeln(_routerSql('server_2_client', 'server', 'client'))
          ..writeln();

    for (final table in tables) {
      final parsed = _parseTableName(table.tableName);
      final triggerId = _sanitizeTriggerId(table.syncKey);
      buffer
        ..writeln(
          "IF NOT EXISTS (SELECT 1 FROM sym_trigger WHERE trigger_id = ${_sqlLiteral(triggerId)})",
        )
        ..writeln('BEGIN')
        ..writeln(
          '  INSERT INTO sym_trigger (trigger_id, source_schema_name, source_table_name, channel_id, sync_on_insert, sync_on_update, sync_on_delete, create_time, last_update_time)',
        )
        ..writeln(
          '  VALUES (${_sqlLiteral(triggerId)}, ${_sqlNullableLiteral(parsed.schema)}, ${_sqlLiteral(parsed.table)}, '
          "'default', 1, 1, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
        )
        ..writeln('END')
        ..writeln(
          "IF NOT EXISTS (SELECT 1 FROM sym_trigger_router WHERE trigger_id = ${_sqlLiteral(triggerId)} AND router_id = 'client_2_server')",
        )
        ..writeln(
          "  INSERT INTO sym_trigger_router (trigger_id, router_id, enabled, initial_load_order, create_time, last_update_time) VALUES (${_sqlLiteral(triggerId)}, 'client_2_server', 1, 100, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
        )
        ..writeln(
          "IF NOT EXISTS (SELECT 1 FROM sym_trigger_router WHERE trigger_id = ${_sqlLiteral(triggerId)} AND router_id = 'server_2_client')",
        )
        ..writeln(
          "  INSERT INTO sym_trigger_router (trigger_id, router_id, enabled, initial_load_order, create_time, last_update_time) VALUES (${_sqlLiteral(triggerId)}, 'server_2_client', 1, 100, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
        )
        ..writeln();
    }

    buffer
      ..writeln('COMMIT TRANSACTION;')
      ..writeln(
        "PRINT N'SymmetricDS bootstrap SQL generated for ${_escapeSqlText(clientName)}';",
      );
    return buffer.toString();
  }

  String _routerSql(
    String routerId,
    String sourceGroupId,
    String targetGroupId,
  ) {
    return '''
IF NOT EXISTS (SELECT 1 FROM sym_router WHERE router_id = ${_sqlLiteral(routerId)})
  INSERT INTO sym_router (router_id, source_node_group_id, target_node_group_id, router_type, create_time, last_update_time)
  VALUES (${_sqlLiteral(routerId)}, ${_sqlLiteral(sourceGroupId)}, ${_sqlLiteral(targetGroupId)}, 'default', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);''';
  }

  _ParsedTableName _parseTableName(String value) {
    final cleaned = value.trim().replaceAll('[', '').replaceAll(']', '');
    final parts =
        cleaned.split('.').where((part) => part.trim().isNotEmpty).toList();
    if (parts.length >= 2) {
      return _ParsedTableName(
        schema: parts[parts.length - 2].trim(),
        table: parts.last.trim(),
      );
    }
    return _ParsedTableName(schema: null, table: cleaned);
  }

  String _sanitizeTriggerId(String value) {
    final sanitized = _sanitizeNodeId(value).replaceAll('.', '_');
    return sanitized.length <= 128 ? sanitized : sanitized.substring(0, 128);
  }

  String _sqlLiteral(String value) => "'${_escapeSqlText(value)}'";

  String _sqlNullableLiteral(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'NULL';
    }
    return _sqlLiteral(value.trim());
  }

  String _escapeSqlText(String value) => value.replaceAll("'", "''");
}

class _ParsedTableName {
  const _ParsedTableName({required this.schema, required this.table});

  final String? schema;
  final String table;
}

class _SymmetricDsRuntimeStatus {
  const _SymmetricDsRuntimeStatus({
    required this.status,
    required this.message,
    required this.commandPath,
  });

  final String status;
  final String message;
  final String commandPath;
}

class _SymmetricDsCommand {
  const _SymmetricDsCommand({required this.path, required this.installRoot});

  final String path;
  final String installRoot;
}
