import 'dart:math' as math;
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'agent_widgets.dart';
import 'models.dart';
import 'sample_data.dart';

class AgentDashboardPage extends StatefulWidget {
  const AgentDashboardPage({
    super.key,
    this.autoLoadOnStart = true,
    required this.clientName,
    required this.onClientNameChanged,
  });

  final bool autoLoadOnStart;
  final String clientName;
  final ValueChanged<String> onClientNameChanged;

  @override
  State<AgentDashboardPage> createState() => _AgentDashboardPageState();
}

class _AgentDashboardPageState extends State<AgentDashboardPage> {
  static const int _rowsPerPage = 25;

  final TextEditingController _serverController = TextEditingController(
    text: 'localhost',
  );
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ScrollController _tableScrollController = ScrollController();

  final bool _useWindowsAuth = true;
  bool _rowsLoading = false;
  bool _hasMoreRows = false;
  String? _errorMessage;
  int? _sortColumnIndex;
  bool _sortAscending = true;
  bool _showSyncView = false;
  int _totalTableRows = 0;

  List<String> _databases = const [];
  String? _selectedDatabase;
  List<String> _tables = const [];
  String? _selectedTable;
  List<String> _tableColumns = const [];
  List<List<String>> _tableRows = const [];
  int _rowOffset = 0;

  @override
  void initState() {
    super.initState();
    _tableScrollController.addListener(_onTableScroll);
    if (widget.autoLoadOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _refreshConnection(loadTables: true);
      });
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _tableScrollController.dispose();
    super.dispose();
  }

  Future<void> _onTableScroll() async {
    if (!_tableScrollController.hasClients ||
        _rowsLoading ||
        !_hasMoreRows ||
        _selectedDatabase == null ||
        _selectedTable == null) {
      return;
    }
    final position = _tableScrollController.position.pixels;
    final max = _tableScrollController.position.maxScrollExtent;
    if (max <= 0 || position < max - 200) {
      return;
    }
    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: _selectedTable!,
      reset: false,
      orderByColumn:
          _sortColumnIndex != null && _sortColumnIndex! < _tableColumns.length
              ? _tableColumns[_sortColumnIndex!]
              : null,
      orderAscending: _sortAscending,
    );
  }

  Future<void> _refreshConnection({bool loadTables = true}) async {
    await _loadDatabases(profile: _activeProfile(), loadTables: loadTables);
  }

  Future<void> _loadDatabases({
    required _SqlConnectionProfile profile,
    bool loadTables = true,
    bool preserveSelection = true,
  }) async {
    final previousDatabase = _selectedDatabase;

    setState(() {
      _errorMessage = null;
      _selectedDatabase = preserveSelection ? _selectedDatabase : null;
      _tables = const [];
      _selectedTable = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _totalTableRows = 0;
    });

    final result = await _queryDatabases(profile: profile);
    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _errorMessage = result.errorText;
        _databases = const [];
        _selectedDatabase = null;
      });
      return;
    }

    var selectedDatabase = _selectedDatabase;
    if (!preserveSelection ||
        selectedDatabase == null ||
        !result.values.contains(selectedDatabase)) {
      selectedDatabase = _preferredDatabase(result.values);
    }

    setState(() {
      _databases = result.values;
      _selectedDatabase = selectedDatabase;
      if (selectedDatabase != previousDatabase) {
        _selectedTable = null;
      }
      _sortColumnIndex = null;
    });

    if (loadTables && selectedDatabase != null) {
      await _loadTables(
        profile: profile,
        database: selectedDatabase,
        autoLoadRows: true,
      );
    }
  }

  void _selectDatabase(String? database) {
    if (database == null || database == _selectedDatabase) {
      return;
    }

    setState(() {
      _selectedDatabase = database;
      _selectedTable = null;
      _tables = const [];
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _sortColumnIndex = null;
      _totalTableRows = 0;
    });

    unawaited(
      _loadTables(
        profile: _activeProfile(),
        database: database,
        autoLoadRows: true,
      ),
    );
  }

  Future<void> _loadTables({
    required _SqlConnectionProfile profile,
    required String database,
    bool autoLoadRows = false,
  }) async {
    setState(() {
      _errorMessage = null;
      _tables = const [];
      _selectedTable = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _sortColumnIndex = null;
      _totalTableRows = 0;
    });

    final result = await _queryTables(profile: profile, database: database);
    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _errorMessage = result.errorText;
      });
      return;
    }

    String? selectedTable = _selectedTable;
    if (selectedTable != null && !result.values.contains(selectedTable)) {
      selectedTable = null;
    }
    if (selectedTable == null && result.values.isNotEmpty) {
      selectedTable = result.values.first;
    }

    setState(() {
      _tables = result.values;
      _selectedTable = selectedTable;
    });

    if (autoLoadRows && selectedTable != null) {
      await _loadTableRows(
        profile: profile,
        database: database,
        table: selectedTable,
        reset: true,
        orderByColumn: null,
        orderAscending: true,
      );
    }
  }

  String? _preferredDatabase(List<String> databases) {
    if (databases.contains('velvet')) {
      return 'velvet';
    }
    return databases.isNotEmpty ? databases.first : null;
  }

  void _selectTable(String? table) {
    if (table == null || _selectedDatabase == null) {
      return;
    }

    setState(() {
      _selectedTable = table;
      _errorMessage = null;
      _sortColumnIndex = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _totalTableRows = 0;
    });

    unawaited(
      _loadTableRows(
        profile: _activeProfile(),
        database: _selectedDatabase!,
        table: table,
        reset: true,
        orderByColumn: null,
        orderAscending: true,
      ),
    );
  }

  Future<void> _loadTableRows({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required bool reset,
    required String? orderByColumn,
    required bool orderAscending,
  }) async {
    if (reset) {
      _rowOffset = 0;
      _hasMoreRows = true;
    } else if (!_hasMoreRows) {
      return;
    }

    if (_rowsLoading) {
      return;
    }

    setState(() {
      _rowsLoading = true;
      _errorMessage = null;
      if (reset) {
        _tableColumns = const [];
        _tableRows = const [];
      }
    });

    final result = await _queryTableRows(
      profile: profile,
      database: database,
      table: table,
      offset: _rowOffset,
      pageSize: _rowsPerPage,
      orderByColumn: orderByColumn,
      orderAscending: orderAscending,
    );

    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _rowsLoading = false;
        _errorMessage = result.errorText;
        _hasMoreRows = false;
      });
      return;
    }

    final nextOffset = _rowOffset + result.rows.length;
    setState(() {
      _rowsLoading = false;
      _tableColumns = result.columns;
      _tableRows =
          reset
                ? List<List<String>>.from(result.rows)
                : List<List<String>>.from(_tableRows)
            ..addAll(result.rows);
      _rowOffset = nextOffset;
      _hasMoreRows = result.hasMoreRows;
      _totalTableRows = result.totalRows;
    });
  }

  Future<void> _reloadCurrentTableRows() async {
    if (_selectedDatabase == null || _selectedTable == null) {
      return;
    }

    final sortColumn =
        _sortColumnIndex != null && _sortColumnIndex! < _tableColumns.length
            ? _tableColumns[_sortColumnIndex!]
            : null;

    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: _selectedTable!,
      reset: true,
      orderByColumn: sortColumn,
      orderAscending: _sortAscending,
    );
  }

  Future<_StringQueryResult> _queryDatabases({
    required _SqlConnectionProfile profile,
  }) async {
    if (profile.server.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: 'Enter a SQL Server instance name.',
      );
    }

    final sql = 'SET NOCOUNT ON; SELECT name FROM sys.databases ORDER BY name;';
    final processResult = await _runSqlCmd(profile: profile, query: sql);
    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd failed (exit ${processResult.exitCode}): ${_formatSqlError(processResult)}',
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    if (values.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'No databases returned. Verify server access and permissions.',
      );
    }

    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_StringQueryResult> _queryTables({
    required _SqlConnectionProfile profile,
    required String database,
  }) async {
    if (database.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: 'Select a database first.',
      );
    }

    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT SCHEMA_NAME(schema_id) + '.' + name AS table_name
FROM sys.tables
ORDER BY table_name;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd failed (exit ${processResult.exitCode}): ${_formatSqlError(processResult)}',
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_TableRowsResult> _queryTableRows({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required int offset,
    required int pageSize,
    required String? orderByColumn,
    required bool orderAscending,
  }) async {
    if (database.isEmpty || table.isEmpty) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        hasMoreRows: false,
        errorText: 'Select database and table before loading rows.',
      );
    }

    final fetchSize = pageSize + 1;
    final tableParts = _splitQualifiedName(table);
    final columnsResult = await _queryTableColumns(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!columnsResult.success) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        hasMoreRows: false,
        errorText: columnsResult.errorText,
      );
    }

    final rowCountResult = await _queryTableRowCount(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!rowCountResult.success) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        hasMoreRows: false,
        errorText: rowCountResult.errorText,
      );
    }

    final orderClause =
        orderByColumn == null || orderByColumn.isEmpty
            ? _quoteIdentifier(
              columnsResult.values.isNotEmpty
                  ? columnsResult.values.first
                  : '1',
            )
            : _quoteIdentifier(orderByColumn);
    final direction = orderAscending ? 'ASC' : 'DESC';

    final query = '''
SET NOCOUNT ON;
SELECT * FROM ${_quoteQualifiedIdentifier(table)}
ORDER BY $orderClause $direction
OFFSET $offset ROWS FETCH NEXT $fetchSize ROWS ONLY;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: rowCountResult.value,
        hasMoreRows: false,
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _TableRowsResult(
        success: false,
        columns: columnsResult.values,
        rows: const [],
        totalRows: rowCountResult.value,
        hasMoreRows: false,
        errorText:
            'sqlcmd failed (exit ${processResult.exitCode}): ${_formatSqlError(processResult)}',
      );
    }

    return _parseTableOutput(
      output: processResult.stdout.toString(),
      columns: columnsResult.values,
      totalRows: rowCountResult.value,
      fetchSize: fetchSize,
    );
  }

  Future<_StringQueryResult> _queryTableColumns({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
SELECT COLUMN_NAME
FROM ${_quoteIdentifier(database)}.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = '${_escapeSqlLiteral(schema)}'
  AND TABLE_NAME = '${_escapeSqlLiteral(table)}'
ORDER BY ORDINAL_POSITION;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd failed (exit ${processResult.exitCode}): ${_formatSqlError(processResult)}',
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_IntQueryResult> _queryTableRowCount({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
SELECT COUNT_BIG(1) AS row_count
FROM ${_quoteIdentifier(database)}.${_quoteIdentifier(schema)}.${_quoteIdentifier(table)};
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return const _IntQueryResult(
        success: false,
        value: 0,
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _IntQueryResult(
        success: false,
        value: 0,
        errorText:
            'sqlcmd failed (exit ${processResult.exitCode}): ${_formatSqlError(processResult)}',
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    final parsed = values.isNotEmpty ? int.tryParse(values.first) : null;
    if (parsed == null) {
      return const _IntQueryResult(
        success: false,
        value: 0,
        errorText: 'Unable to read table row count from SQL Server.',
      );
    }

    return _IntQueryResult(success: true, value: parsed, errorText: null);
  }

  String _formatSqlError(ProcessResult processResult) {
    final details = <String>[];
    final stdout = processResult.stdout.toString().trim();
    final stderr = processResult.stderr.toString().trim();
    if (stdout.isNotEmpty) {
      details.add('stdout: $stdout');
    }
    if (stderr.isNotEmpty) {
      details.add('stderr: $stderr');
    }
    return details.isEmpty ? 'No output returned.' : details.join('\n');
  }

  Future<ProcessResult?> _runSqlCmd({
    required _SqlConnectionProfile profile,
    String? database,
    required String query,
  }) async {
    final normalizedQuery = query
        .trim()
        .replaceAll('\r\n', ' ')
        .replaceAll('\n', ' ');
    final arguments = <String>[
      '-S',
      profile.server,
      if (database != null && database.isNotEmpty) ...['-d', database],
      '-b',
      '-h',
      '-1',
      '-W',
      '-s',
      '|',
      '-Q',
      normalizedQuery,
    ];

    if (profile.useWindowsAuth) {
      arguments.insert(0, '-E');
    } else {
      if (profile.user.isEmpty || profile.password.isEmpty) {
        return null;
      }
      arguments.insertAll(0, ['-U', profile.user, '-P', profile.password]);
    }

    try {
      return await Process.run(
        'sqlcmd',
        arguments,
        runInShell: false,
        stdoutEncoding: SystemEncoding(),
        stderrEncoding: SystemEncoding(),
      );
    } on ProcessException {
      return null;
    }
  }

  String _quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

  String _escapeSqlLiteral(String value) => value.replaceAll("'", "''");

  _QualifiedTableName _splitQualifiedName(String qualifiedName) {
    final parts = qualifiedName.split('.');
    if (parts.length >= 2) {
      return _QualifiedTableName(schema: parts.first, table: parts.last);
    }
    return _QualifiedTableName(schema: 'dbo', table: qualifiedName);
  }

  String _quoteQualifiedIdentifier(String qualifiedName) =>
      qualifiedName.split('.').map(_quoteIdentifier).join('.');

  List<String> _splitRowValues(String line) =>
      line.split('|').map((value) => value.trim()).toList();

  bool _isSkippableOutputLine(String line) {
    if (line.isEmpty) return true;
    final normalized = line.toLowerCase();
    return line.startsWith('---') ||
        line.startsWith('(') ||
        normalized.contains('changed database context') ||
        normalized.contains('row') && normalized.contains('affected') ||
        normalized.contains('command') && normalized.contains('completed');
  }

  List<String> _parseSingleColumnOutput(String output) {
    final values = <String>[];
    final lines = output.split(RegExp(r'\r?\n'));

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      final split = _splitRowValues(trimmedLine);
      if (split.isNotEmpty) {
        values.add(split.first);
      }
    }

    return values;
  }

  _TableRowsResult _parseTableOutput({
    required String output,
    required List<String> columns,
    required int totalRows,
    required int fetchSize,
  }) {
    final lines = output.split(RegExp(r'\r?\n'));
    final rows = <List<String>>[];

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }

      final split = _splitRowValues(trimmedLine);
      if (split.length == columns.length) {
        rows.add(split);
      } else {
        final padded = List<String>.from(split);
        while (padded.length < columns.length) {
          padded.add('');
        }
        rows.add(padded.take(columns.length).toList());
      }
    }

    var hasMoreRows = false;
    if (rows.length > fetchSize - 1) {
      rows.removeRange(fetchSize - 1, rows.length);
      hasMoreRows = true;
    }

    return _TableRowsResult(
      success: true,
      columns: columns,
      rows: rows,
      totalRows: totalRows,
      hasMoreRows: hasMoreRows,
      errorText: null,
    );
  }

  _SqlConnectionProfile _activeProfile() => _SqlConnectionProfile(
    server: _serverController.text.trim(),
    useWindowsAuth: _useWindowsAuth,
    user: _userController.text.trim(),
    password: _passwordController.text,
  );

  Future<void> _openSettingsDialog() async {
    final clientNameController = TextEditingController(text: widget.clientName);
    final serverController = TextEditingController(
      text: _serverController.text,
    );
    String? selectedDatabase = _selectedDatabase;
    List<String> dbCache = List.of(_databases);
    bool loading = false;
    String? dialogError;

    _SqlConnectionProfile readDialogProfile() => _SqlConnectionProfile(
      server: serverController.text.trim(),
      useWindowsAuth: _useWindowsAuth,
      user: _userController.text.trim(),
      password: _passwordController.text,
    );

    Future<void> loadDatabases(
      BuildContext context,
      StateSetter setDialogState,
    ) async {
      setDialogState(() {
        loading = true;
        dialogError = null;
      });

      final dialogProfile = readDialogProfile();
      final databaseResult = await _queryDatabases(profile: dialogProfile);

      if (!context.mounted) {
        return;
      }
      if (!databaseResult.success) {
        setDialogState(() {
          loading = false;
          dbCache = const [];
          selectedDatabase = null;
          dialogError = databaseResult.errorText;
        });
        return;
      }

      selectedDatabase =
          selectedDatabase != null &&
                  databaseResult.values.contains(selectedDatabase)
              ? selectedDatabase
              : _preferredDatabase(databaseResult.values);

      setDialogState(() {
        dbCache = databaseResult.values;
        loading = false;
      });
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: const Text('Database'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: clientNameController,
                        decoration: _compactInputDecoration('Client Name'),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _InfoLine(
                            label: 'Auth',
                            value: _useWindowsAuth ? 'Windows' : 'SQL',
                          ),
                          _InfoLine(
                            label: 'Server',
                            value:
                                serverController.text.trim().isEmpty
                                    ? 'Not set'
                                    : serverController.text.trim(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                        onPressed:
                            loading
                                ? null
                                : () => loadDatabases(context, setDialogState),
                        icon:
                            loading
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.refresh, size: 18),
                        label: Text(loading ? 'Loading...' : 'Read metadata'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: selectedDatabase,
                        isDense: true,
                        iconSize: 18,
                        borderRadius: BorderRadius.circular(12),
                        items:
                            dbCache
                                .map(
                                  (database) => DropdownMenuItem(
                                    value: database,
                                    child: Text(database),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            dbCache.isEmpty
                                ? null
                                : (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  selectedDatabase = value;
                                },
                        decoration: _compactInputDecoration('Database'),
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          dialogError!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final dialogProfile = readDialogProfile();
                    final clientName =
                        clientNameController.text.trim().isEmpty
                            ? 'Local Agent'
                            : clientNameController.text.trim();
                    final hasDatabase =
                        selectedDatabase != null &&
                        dbCache.contains(selectedDatabase);

                    setState(() {
                      _serverController.text = dialogProfile.server;
                      _databases = dbCache;
                      _selectedDatabase = hasDatabase ? selectedDatabase : null;
                      _tables = const [];
                      _selectedTable = null;
                      _tableColumns = const [];
                      _tableRows = const [];
                      _hasMoreRows = false;
                      _rowOffset = 0;
                      _errorMessage = null;
                    });
                    widget.onClientNameChanged(clientName);

                    Navigator.of(context).pop();

                    if (hasDatabase) {
                      await _loadTables(
                        profile: dialogProfile,
                        database: _selectedDatabase!,
                        autoLoadRows: true,
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    clientNameController.dispose();
    serverController.dispose();
  }

  Widget _buildTablePanel() {
    if (_databases.isEmpty && _selectedDatabase == null) {
      return Center(
        child: Text(
          'Open the settings dialog to read database metadata.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child:
              _selectedTable == null
                  ? Center(
                    child: Text(
                      _tables.isEmpty
                          ? 'Load tables from the selected database.'
                          : 'Select a table to view data.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  )
                  : _buildSpreadsheetTable(),
        ),
      ],
    );
  }

  Widget _buildSyncPanel() {
    final syncRows = discoveredTables
        .asMap()
        .entries
        .map((entry) {
          final event = recentEvents[entry.key % recentEvents.length];
          final mode = entry.key.isEven ? 'Upload' : 'Download';
          final state =
              event.level == AgentEventLevel.error
                  ? 'Failed'
                  : entry.key == 1
                  ? 'Retrying'
                  : 'Synced';
          return (
            table: entry.value.name,
            mode: mode,
            rows: entry.value.rows,
            lastSync: event.time,
            state: state,
            changeColumn: entry.value.changeColumn,
          );
        })
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AgentSectionShell(
          title: 'Sync Table',
          subtitle:
              'Periodic upload and download batches for ${widget.clientName}.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  AgentMetricCard(
                    title: 'Client',
                    value: widget.clientName,
                    detail: 'This name is shown to the control plane.',
                  ),
                  AgentMetricCard(
                    title: 'Tables',
                    value: syncRows.length.toString(),
                    detail: 'Tables participating in the sync table.',
                  ),
                  AgentMetricCard(
                    title: 'Modes',
                    value: 'Upload / Download',
                    detail: 'The table tracks both directions.',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStatePropertyAll(
                    const Color(0xFFE7ECE6),
                  ),
                  columns: const [
                    DataColumn(label: Text('Table')),
                    DataColumn(label: Text('Mode')),
                    DataColumn(label: Text('Rows')),
                    DataColumn(label: Text('Last Sync')),
                    DataColumn(label: Text('State')),
                  ],
                  rows:
                      syncRows
                          .map(
                            (row) => DataRow(
                              cells: [
                                DataCell(Text(row.table)),
                                DataCell(Text(row.mode)),
                                DataCell(Text(row.rows.toString())),
                                DataCell(Text(row.lastSync)),
                                DataCell(
                                  AgentStatusPill(
                                    label: row.state,
                                    color:
                                        row.state == 'Failed'
                                            ? const Color(0xFFC53030)
                                            : row.state == 'Retrying'
                                            ? const Color(0xFFD69E2E)
                                            : const Color(0xFF2F855A),
                                  ),
                                ),
                              ],
                            ),
                          )
                          .toList(),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Change marker: ${syncRows.first.changeColumn}',
                style: const TextStyle(color: Color(0xFF58656B)),
              ),
              const SizedBox(height: 14),
              Text(
                'Latest sync feed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              ...recentEvents.map(
                (event) => Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFE2D8CB)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AgentEventDot(level: event.level),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              event.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(event.message),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        event.time,
                        style: const TextStyle(color: Color(0xFF5F6B76)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSelectionHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: DropdownButtonFormField<String>(
                value: _selectedDatabase,
                isDense: true,
                iconSize: 18,
                borderRadius: BorderRadius.circular(12),
                items:
                    _databases
                        .map(
                          (database) => DropdownMenuItem(
                            value: database,
                            child: Text(database),
                          ),
                        )
                        .toList(),
                onChanged: _databases.isEmpty ? null : _selectDatabase,
                decoration: _compactInputDecoration('Database'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            fit: FlexFit.loose,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: DropdownButtonFormField<String>(
                value: _selectedTable,
                isDense: true,
                iconSize: 18,
                borderRadius: BorderRadius.circular(12),
                items:
                    _tables
                        .map(
                          (table) => DropdownMenuItem(
                            value: table,
                            child: Text(table),
                          ),
                        )
                        .toList(),
                onChanged: _tables.isEmpty ? null : _selectTable,
                decoration: _compactInputDecoration('Table'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _compactInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      filled: true,
      fillColor: const Color(0xFFF6F7F5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFD9DDD8)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFD9DDD8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF7C8A7A)),
      ),
    );
  }

  Widget _buildTableCell(String value, double cellWidth, {required bool alt}) {
    return Container(
      width: cellWidth,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: alt ? Colors.white : const Color(0xFFFAFBF9),
        border: const Border(bottom: BorderSide(color: Color(0xFFE4E8E3))),
      ),
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildTableRow(List<String> row, double cellWidth, int index) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 64,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: index.isOdd ? Colors.white : const Color(0xFFFAFBF9),
            border: const Border(bottom: BorderSide(color: Color(0xFFE4E8E3))),
          ),
          child: Text(
            '${index + 1}',
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        ...List.generate(_tableColumns.length, (columnIndex) {
          final value = columnIndex < row.length ? row[columnIndex] : '';
          return _buildTableCell(value, cellWidth, alt: index.isOdd);
        }),
      ],
    );
  }

  Widget _buildPinnedSummaryBar() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFC9D2C7))),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Total rows: $_totalTableRows',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpreadsheetTable() {
    if (_tableColumns.isEmpty) {
      return Center(
        child:
            _rowsLoading
                ? const CircularProgressIndicator()
                : Text(
                  'No columns returned for $_selectedTable.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
      );
    }

    final cellWidth = 180.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9F6),
              border: Border.all(color: const Color(0xFFD9DDD8)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final panelWidth =
                    constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(context).width;
                final columnWidth = math.max(
                  panelWidth,
                  64 + (_tableColumns.length * cellWidth),
                );
                final panelHeight =
                    constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : MediaQuery.sizeOf(context).height * 0.7;

                return ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: columnWidth,
                      height: panelHeight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: 64,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 12,
                                ),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFE3E8E1),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Color(0xFFBFC9BE),
                                    ),
                                  ),
                                ),
                                child: const Text(
                                  '#',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              ..._tableColumns.asMap().entries.map((entry) {
                                final isSortedColumn =
                                    _sortColumnIndex == entry.key;
                                final icon =
                                    isSortedColumn
                                        ? (_sortAscending
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward)
                                        : Icons.unfold_more;

                                return InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () {
                                    final ascending =
                                        isSortedColumn ? !_sortAscending : true;
                                    setState(() {
                                      _sortColumnIndex = entry.key;
                                      _sortAscending = ascending;
                                    });
                                    unawaited(_reloadCurrentTableRows());
                                  },
                                  child: Container(
                                    width: cellWidth,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFE3E8E1),
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Color(0xFFBFC9BE),
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            entry.value,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          icon,
                                          size: 16,
                                          color: Colors.black54,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                          Expanded(
                            child:
                                _tableRows.isEmpty && !_rowsLoading
                                    ? Center(
                                      child: Text(
                                        '0 rows found in $_selectedTable.',
                                        style:
                                            Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                      ),
                                    )
                                    : Scrollbar(
                                      controller: _tableScrollController,
                                      thumbVisibility: true,
                                      child: ListView.builder(
                                        controller: _tableScrollController,
                                        itemCount:
                                            _tableRows.length +
                                            (_rowsLoading ? 1 : 0),
                                        itemBuilder: (context, index) {
                                          if (index >= _tableRows.length) {
                                            return const Padding(
                                              padding: EdgeInsets.symmetric(
                                                vertical: 16,
                                              ),
                                              child: Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                            );
                                          }
                                          return _buildTableRow(
                                            _tableRows[index],
                                            cellWidth,
                                            index,
                                          );
                                        },
                                      ),
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.clientName == 'Local Agent'
              ? 'SQL Sync Agent'
              : '${widget.clientName} · SQL Sync Agent',
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                _showSyncView = !_showSyncView;
              });
            },
            icon: Icon(_showSyncView ? Icons.table_rows : Icons.sync),
            label: Text(_showSyncView ? 'Tables' : 'Sync'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF17313A),
              visualDensity: VisualDensity.compact,
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.more_vert),
            style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _openSettingsDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSelectionHeader(),
            const SizedBox(height: 12),
            if (_errorMessage != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: const Color(0xFFFFEEEE),
                ),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: _showSyncView ? _buildSyncPanel() : _buildTablePanel(),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildPinnedSummaryBar(),
    );
  }
}

class _SqlConnectionProfile {
  const _SqlConnectionProfile({
    required this.server,
    required this.useWindowsAuth,
    required this.user,
    required this.password,
  });

  final String server;
  final bool useWindowsAuth;
  final String user;
  final String password;
}

class _StringQueryResult {
  const _StringQueryResult({
    required this.success,
    required this.values,
    required this.errorText,
  });

  final bool success;
  final List<String> values;
  final String? errorText;
}

class _QualifiedTableName {
  const _QualifiedTableName({required this.schema, required this.table});

  final String schema;
  final String table;
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: const TextStyle(
        color: Color(0xFF374151),
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _TableRowsResult {
  const _TableRowsResult({
    required this.success,
    required this.columns,
    required this.rows,
    required this.totalRows,
    required this.hasMoreRows,
    required this.errorText,
  });

  final bool success;
  final List<String> columns;
  final List<List<String>> rows;
  final int totalRows;
  final bool hasMoreRows;
  final String? errorText;
}

class _IntQueryResult {
  const _IntQueryResult({
    required this.success,
    required this.value,
    required this.errorText,
  });

  final bool success;
  final int value;
  final String? errorText;
}
