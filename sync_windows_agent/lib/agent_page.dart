import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'agent_widgets.dart';
import 'live_sync_api.dart';
import 'sync_state.dart';
import 'startup_log.dart';

const String _agentAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0+1',
);
const String _agentBuildCommitHash = String.fromEnvironment(
  'BUILD_COMMIT_HASH',
  defaultValue: '',
);
const String _agentBuildReleaseDate = String.fromEnvironment(
  'BUILD_RELEASE_DATE',
  defaultValue: '',
);

class AgentDashboardPage extends StatefulWidget {
  const AgentDashboardPage({
    super.key,
    this.autoLoadOnStart = true,
    required this.authToken,
    required this.authenticatedAccountUsername,
    required this.authenticatedAccountEmail,
    required this.authenticatedAccountName,
    required this.onLogout,
    required this.clientNameLocked,
    required this.clientName,
    required this.onClientNameChanged,
    required this.initialSyncState,
    required this.onSyncStateChanged,
    required this.startMinimized,
    required this.startOnStartup,
    required this.onStartMinimizedChanged,
    required this.onStartOnStartupChanged,
    required this.onMinimizeWindow,
    required this.initialServer,
    required this.onServerChanged,
  });

  final bool autoLoadOnStart;
  final String authToken;
  final String? authenticatedAccountUsername;
  final String? authenticatedAccountEmail;
  final String? authenticatedAccountName;
  final VoidCallback onLogout;
  final bool clientNameLocked;
  final String clientName;
  final ValueChanged<String> onClientNameChanged;
  final SyncClientState initialSyncState;
  final ValueChanged<SyncClientState> onSyncStateChanged;
  final bool startMinimized;
  final bool startOnStartup;
  final ValueChanged<bool> onStartMinimizedChanged;
  final Future<void> Function(bool value) onStartOnStartupChanged;
  final Future<void> Function() onMinimizeWindow;
  final String initialServer;
  final ValueChanged<String> onServerChanged;

  @override
  State<AgentDashboardPage> createState() => _AgentDashboardPageState();
}

class _AgentDashboardPageState extends State<AgentDashboardPage> {
  static const int _rowsPerPage = 25;
  static const Duration _syncPollInterval = Duration(seconds: 15);

  late final TextEditingController _serverController;
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final AgentControlPlaneClient _controlPlaneClient = AgentControlPlaneClient();
  late SyncClientState _syncState;
  Timer? _connectionCheckTimer;
  Timer? _syncPollTimer;

  final bool _useWindowsAuth = true;
  bool _rowsLoading = false;
  bool _hasMoreRows = false;
  String? _errorMessage;
  int? _sortColumnIndex;
  bool _sortAscending = true;
  _SyncTableSortField _syncTableSortField = _SyncTableSortField.rows;
  bool _syncTableSortAscending = true;
  String? _selectedSyncTable;
  int _totalTableRows = 0;
  bool _serverConnected = false;
  bool _checkingServerConnection = false;
  DateTime? _lastServerCheck;
  bool _syncLoopBusy = false;
  List<RemoteSyncJob> _activeJobs = const [];
  VoidCallback? _tableDataDialogRefresh;
  final Set<String> _processingJobIds = <String>{};
  final Set<String> _busyFileTables = <String>{};
  String? _lastSqlCmdLaunchError;
  String? _activeUploadTable;
  DateTime? _uploadMeterStartedAt;
  int _uploadMeterBytesTransferred = 0;
  double _uploadBytesPerSecond = 0;
  int _uploadMeterCurrentChunk = 0;
  int _uploadMeterTotalChunks = 0;

  String? _selectedDatabase;
  List<String> _databases = const [];
  Map<String, int> _databaseTableCounts = const {};
  List<String> _tables = const [];
  String? _selectedTable;
  List<String> _tableColumns = const [];
  List<List<String>> _tableRows = const [];
  int _rowOffset = 0;
  String _tableSearchQuery = '';
  final ScrollController _tableHorizontalScrollController = ScrollController();

  bool get _isMasterClient => _syncState.isMaster;
  Duration get _autoSyncInterval =>
      Duration(minutes: _syncState.autoSyncIntervalMinutes);
  String get _defaultTableSyncMode =>
      _isMasterClient ? kSyncModeMaster : kSyncModeClient;

  @override
  void initState() {
    super.initState();
    logStartupEvent('AgentDashboardPage initState');
    _syncState = widget.initialSyncState;
    _serverController = TextEditingController(
      text:
          widget.initialServer.trim().isEmpty
              ? 'localhost'
              : widget.initialServer.trim(),
    );
    _controlPlaneClient.setAuthToken(widget.authToken);
    _connectionCheckTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_checkServerConnection()),
    );
    _syncPollTimer = Timer.periodic(
      _syncPollInterval,
      (_) => unawaited(_syncWithControlPlane()),
    );
    if (widget.autoLoadOnStart) {
      logStartupEvent('AgentDashboardPage autoLoadOnStart scheduled');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        logStartupEvent('AgentDashboardPage autoLoadOnStart refresh');
        unawaited(_refreshConnection(loadTables: true));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        logStartupEvent('AgentDashboardPage initial connection check');
        unawaited(_checkServerConnection());
        logStartupEvent('AgentDashboardPage initial sync sync');
        unawaited(_syncWithControlPlane());
      }
    });
  }

  @override
  void dispose() {
    _connectionCheckTimer?.cancel();
    _syncPollTimer?.cancel();
    _controlPlaneClient.dispose();
    _serverController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _tableHorizontalScrollController.dispose();
    super.dispose();
  }

  Future<void> _checkServerConnection() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _checkingServerConnection = true;
    });

    final online = await _controlPlaneClient.checkHealth();

    if (!mounted) {
      return;
    }

    setState(() {
      _serverConnected = online;
      _checkingServerConnection = false;
      _lastServerCheck = DateTime.now();
    });
  }

  void _updateSyncTableState(String table, SyncTableState state) {
    final tables = Map<String, SyncTableState>.from(_syncState.tables);
    tables[table] = state;
    final nextState = _syncState.copyWith(tables: tables);
    setState(() {
      _syncState = nextState;
    });
    widget.onSyncStateChanged(nextState);
  }

  void _replaceSyncState(SyncClientState nextState) {
    setState(() {
      _syncState = nextState;
    });
    widget.onSyncStateChanged(nextState);
  }

  List<SyncHistoryEntry> _appendHistory(
    List<SyncHistoryEntry> current,
    SyncHistoryEntry entry,
  ) {
    final next = List<SyncHistoryEntry>.from(current)..insert(0, entry);
    final limit = _syncState.historyLimit.clamp(1, kMaxHistoryLimit);
    if (next.length > limit) {
      next.removeRange(limit, next.length);
    }
    return next;
  }

  List<SyncHistoryEntry> _trimHistoryEntries(
    List<SyncHistoryEntry> entries, {
    int? limit,
  }) {
    final normalizedLimit =
        (limit ?? _syncState.historyLimit).clamp(1, kMaxHistoryLimit).toInt();
    if (entries.length <= normalizedLimit) {
      return List<SyncHistoryEntry>.from(entries);
    }
    return List<SyncHistoryEntry>.from(
      entries.take(normalizedLimit),
      growable: false,
    );
  }

  void _applyHistoryLimit(int nextLimit) {
    final normalizedLimit = nextLimit.clamp(1, kMaxHistoryLimit).toInt();
    if (normalizedLimit == _syncState.historyLimit) {
      return;
    }

    final nextTables = Map<String, SyncTableState>.fromEntries(
      _syncState.tables.entries.map(
        (entry) => MapEntry(
          entry.key,
          entry.value.copyWith(
            history: _trimHistoryEntries(
              entry.value.history,
              limit: normalizedLimit,
            ),
          ),
        ),
      ),
    );

    _replaceSyncState(
      _syncState.copyWith(historyLimit: normalizedLimit, tables: nextTables),
    );
  }

  void _applyAutoSyncInterval(int nextMinutes) {
    final normalizedMinutes =
        nextMinutes
            .clamp(kMinAutoSyncIntervalMinutes, kMaxAutoSyncIntervalMinutes)
            .toInt();
    if (normalizedMinutes == _syncState.autoSyncIntervalMinutes) {
      return;
    }

    _replaceSyncState(
      _syncState.copyWith(autoSyncIntervalMinutes: normalizedMinutes),
    );
  }

  SyncHistorySnapshotData _createHistorySnapshotData({
    required List<String> columns,
    required List<Map<String, String?>> rows,
  }) {
    return SyncHistorySnapshotData(
      columns: List<String>.from(columns),
      rows: rows
          .map(
            (row) => Map<String, String?>.fromEntries(
              columns.map((column) => MapEntry(column, row[column])),
            ),
          )
          .toList(growable: false),
    );
  }

  static const String _syncTableKeySeparator = '::';

  String _syncTableKey(String table, {String? database}) {
    final databaseName = (database ?? _selectedDatabase ?? '').trim();
    final tableName = _stripDefaultSchema(table);
    if (databaseName.isEmpty) {
      return tableName;
    }
    return '$databaseName$_syncTableKeySeparator$tableName';
  }

  String _localTableName(String syncTableKey) {
    final separatorIndex = syncTableKey.indexOf(_syncTableKeySeparator);
    if (separatorIndex < 0) {
      return _stripDefaultSchema(syncTableKey);
    }
    return _stripDefaultSchema(
      syncTableKey.substring(separatorIndex + _syncTableKeySeparator.length),
    );
  }

  String _stripDefaultSchema(String table) =>
      table.trim().replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');

  String _databaseNameFromSyncKey(String syncTableKey) {
    final separatorIndex = syncTableKey.indexOf(_syncTableKeySeparator);
    if (separatorIndex < 0) {
      return _selectedDatabase ?? '';
    }
    return syncTableKey.substring(0, separatorIndex);
  }

  bool _syncKeyMatchesSelectedDatabase(String syncTableKey) {
    final databaseName = _selectedDatabase?.trim() ?? '';
    if (databaseName.isEmpty ||
        !syncTableKey.contains(_syncTableKeySeparator)) {
      return true;
    }
    return syncTableKey.startsWith('$databaseName$_syncTableKeySeparator');
  }

  bool _syncKeyMatchesDatabase(String syncTableKey, String database) {
    final databaseName = database.trim();
    if (databaseName.isEmpty ||
        !syncTableKey.contains(_syncTableKeySeparator)) {
      return true;
    }
    return syncTableKey.startsWith('$databaseName$_syncTableKeySeparator');
  }

  List<String> _stableVisibleTablesForDatabase(
    String database,
    Iterable<String> discoveredTables,
  ) {
    final visible = <String>{
      ...discoveredTables.map(_stripDefaultSchema),
      ..._syncState.tables.keys
          .where((key) => _syncKeyMatchesDatabase(key, database))
          .map(_localTableName),
      ..._activeJobs
          .map((job) => job.table)
          .where((key) => _syncKeyMatchesDatabase(key, database))
          .map(_localTableName),
    };
    final tables = visible.toList(growable: false);
    tables.sort((left, right) {
      final leftState = _syncTableState(left);
      final rightState = _syncTableState(right);
      final leftPriority = _isPrioritySyncTable(leftState);
      final rightPriority = _isPrioritySyncTable(rightState);
      if (leftPriority != rightPriority) {
        return leftPriority ? -1 : 1;
      }
      return left.toLowerCase().compareTo(right.toLowerCase());
    });
    return tables;
  }

  bool _isPrioritySyncTable(SyncTableState state) {
    return state.enabled ||
        state.lastSync.trim().isNotEmpty ||
        (state.snapshotId?.trim().isNotEmpty ?? false) ||
        (state.snapshotCreatedAt?.trim().isNotEmpty ?? false);
  }

  SyncTableState _syncTableState(String table, {String? syncKey}) {
    final key = syncKey ?? _syncTableKey(table);
    final databaseName = _databaseNameFromSyncKey(key);
    final localTable = _localTableName(key);
    final legacyKey =
        databaseName.isEmpty
            ? 'dbo.$localTable'
            : '$databaseName$_syncTableKeySeparator'
                'dbo.$localTable';
    return _syncState.tables[key] ??
        _syncState.tables[table] ??
        _syncState.tables[legacyKey] ??
        _defaultSyncTableState(key);
  }

  void _updateSyncEnabledTable(
    String table,
    bool enabled, {
    String? selectedSyncMode,
  }) {
    final syncKey = _syncTableKey(table);
    final current = _syncTableState(table, syncKey: syncKey);
    final now = DateTime.now().toIso8601String();
    final nextStatus = enabled ? 'Queued' : 'Paused';
    final syncMode = normalizeSyncMode(
      selectedSyncMode ?? current.syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    final syncDirection = syncDirectionForMode(syncMode);
    final nextHistory = _appendHistory(
      current.history,
      SyncHistoryEntry(
        timestamp: now,
        table: syncKey,
        status: nextStatus,
        success: enabled,
        message:
            enabled
                ? 'Two-way sync enabled for ${widget.clientName}.'
                : 'Remote sync paused for ${widget.clientName}.',
        direction: syncDirection,
        rowCount: current.rowCount,
        progress: enabled ? 0 : current.progress,
        snapshotId: current.snapshotId,
        snapshotBytes: current.snapshotBytes,
      ),
    );
    _updateSyncTableState(
      syncKey,
      current.copyWith(
        enabled: enabled,
        status: nextStatus,
        lastSync: enabled ? current.lastSync : now,
        progress: enabled ? 0 : current.progress,
        direction: syncDirection,
        syncMode: syncMode,
        message:
            enabled ? 'Waiting for the next two-way sync.' : 'Sync disabled.',
        history: nextHistory,
      ),
    );
    if (enabled) {
      unawaited(_queueEnabledRoleJobs(forceTables: {syncKey}));
    }
  }

  Future<void> _handleSyncEnabledChange(String table, bool enabled) async {
    final current = _syncTableState(table);
    String? selectedMode = current.syncMode;
    if (enabled) {
      selectedMode = await _openSyncModeDialog(
        table: table,
        initialMode: current.syncMode,
        title: 'Start sync',
        confirmLabel: 'Enable sync',
      );
      if (!mounted || selectedMode == null) {
        return;
      }
    }

    final normalizedMode = normalizeSyncMode(
      selectedMode,
      fallbackIsMaster: _isMasterClient,
    );
    final syncKey = _syncTableKey(table);
    try {
      await _controlPlaneClient.updateTableSyncPolicy(
        table: syncKey,
        enabled: enabled,
        syncMode: normalizedMode,
      );
      if (!mounted) {
        return;
      }
      _updateSyncEnabledTable(table, enabled, selectedSyncMode: normalizedMode);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    }
  }

  SyncTableState _defaultSyncTableState(String table) {
    return SyncTableState(
      enabled: false,
      status: 'Paused',
      lastSync: '',
      progress: 0,
      direction: syncDirectionForMode(_defaultTableSyncMode),
      syncMode: _defaultTableSyncMode,
      rowCount: 0,
      snapshotId: null,
      snapshotCreatedAt: null,
      snapshotBytes: 0,
      message: 'Remote sync disabled.',
      history: const [],
    );
  }

  void _ensureSyncTablesLoaded(Iterable<String> tableNames) {
    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    var changed = false;
    for (final table in tableNames) {
      final syncKey = _syncTableKey(table);
      if (!nextTables.containsKey(syncKey)) {
        final databaseName = _databaseNameFromSyncKey(syncKey);
        final localTable = _localTableName(syncKey);
        final legacyKey =
            databaseName.isEmpty
                ? 'dbo.$localTable'
                : '$databaseName$_syncTableKeySeparator'
                    'dbo.$localTable';
        nextTables[syncKey] =
            nextTables[table] ??
            nextTables[legacyKey] ??
            _defaultSyncTableState(syncKey);
        changed = true;
      }
    }
    if (changed) {
      _replaceSyncState(_syncState.copyWith(tables: nextTables));
    }
  }

  void _applyTableRowCounts({
    required String database,
    required Map<String, int> rowCounts,
  }) {
    if (rowCounts.isEmpty) {
      return;
    }

    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    var changed = false;
    for (final entry in rowCounts.entries) {
      final syncKey = _syncTableKey(entry.key, database: database);
      final current = _syncTableState(entry.key, syncKey: syncKey);
      if (current.rowCount == entry.value) {
        continue;
      }
      nextTables[syncKey] = current.copyWith(rowCount: entry.value);
      changed = true;
    }

    if (changed) {
      _replaceSyncState(_syncState.copyWith(tables: nextTables));
    }
  }

  @override
  void didUpdateWidget(covariant AgentDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authToken != widget.authToken) {
      _controlPlaneClient.setAuthToken(widget.authToken);
      unawaited(_syncWithControlPlane());
    }
    if (oldWidget.clientName != widget.clientName) {
      _syncState = widget.initialSyncState;
      unawaited(_syncWithControlPlane());
    }
  }

  String? _selectedSyncTableName(List<String> tableNames) {
    if (_selectedSyncTable != null && tableNames.contains(_selectedSyncTable)) {
      return _selectedSyncTable;
    }
    if (_selectedTable != null) {
      final selectedKey = _syncTableKey(_selectedTable!);
      if (tableNames.contains(selectedKey)) {
        return selectedKey;
      }
    }
    return tableNames.isNotEmpty ? tableNames.first : null;
  }

  Future<void> _refreshConnection({bool loadTables = true}) async {
    await _loadDatabases(profile: _activeProfile(), loadTables: loadTables);
  }

  Future<void> _loadDatabases({
    required _SqlConnectionProfile profile,
    bool loadTables = true,
    bool preserveSelection = true,
  }) async {
    logStartupEvent(
      'AgentDashboardPage loadDatabases start: ${profile.server}',
    );
    final resolvedProfile = await _resolveSqlConnectionProfile(profile);
    if (!mounted) {
      return;
    }
    logStartupEvent(
      'AgentDashboardPage loadDatabases resolved: ${resolvedProfile.server}',
    );

    final previousDatabase = _selectedDatabase;

    setState(() {
      _errorMessage = null;
      _selectedDatabase = preserveSelection ? _selectedDatabase : null;
      _databases = const [];
      _databaseTableCounts = const {};
      _tables = const [];
      _selectedTable = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _totalTableRows = 0;
    });

    final result = await _queryDatabases(profile: resolvedProfile);
    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _errorMessage = result.errorText;
        _selectedDatabase = null;
        _databases = const [];
        _databaseTableCounts = const {};
      });
      return;
    }

    var selectedDatabase = _selectedDatabase;
    if (!preserveSelection ||
        selectedDatabase == null ||
        !result.values.contains(selectedDatabase)) {
      selectedDatabase = _preferredDatabase(result.values);
    }

    final tableCounts = await _queryDatabaseTableCounts(
      profile: resolvedProfile,
      databases: result.values,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _databases = result.values;
      _databaseTableCounts = tableCounts;
      _selectedDatabase = selectedDatabase;
      if (selectedDatabase != previousDatabase) {
        _selectedTable = null;
      }
      _sortColumnIndex = null;
    });

    if (loadTables && selectedDatabase != null) {
      await _loadTables(
        profile: resolvedProfile,
        database: selectedDatabase,
        autoLoadRows: true,
      );
    }
  }

  Future<void> _loadTables({
    required _SqlConnectionProfile profile,
    required String database,
    bool autoLoadRows = false,
  }) async {
    setState(() {
      _errorMessage = null;
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

    final visibleTables = _stableVisibleTablesForDatabase(
      database,
      result.values,
    );
    if (selectedTable != null && !visibleTables.contains(selectedTable)) {
      selectedTable = visibleTables.isNotEmpty ? visibleTables.first : null;
    }

    setState(() {
      _tables = visibleTables;
      _selectedTable = selectedTable;
    });
    _ensureSyncTablesLoaded(visibleTables);

    final rowCounts = await _queryTableRowCounts(
      profile: profile,
      database: database,
      tables: result.values,
    );
    if (!mounted) {
      return;
    }
    _applyTableRowCounts(database: database, rowCounts: rowCounts);

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
    unawaited(_syncWithControlPlane());
  }

  Future<void> _selectDatabase(String database) async {
    if (database == _selectedDatabase) {
      return;
    }

    setState(() {
      _selectedDatabase = database;
      _tables = const [];
      _selectedTable = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _totalTableRows = 0;
      _sortColumnIndex = null;
      _errorMessage = null;
    });

    await _loadTables(
      profile: _activeProfile(),
      database: database,
      autoLoadRows: true,
    );
  }

  String? _preferredDatabase(List<String> databases) {
    if (databases.contains('velvet')) {
      return 'velvet';
    }
    return databases.isNotEmpty ? databases.first : null;
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
    _refreshTableDataDialog();

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
      _refreshTableDataDialog();
      return;
    }

    final nextOffset = _rowOffset + result.rows.length;
    setState(() {
      _rowsLoading = false;
      _tableColumns = result.columns;
      if (_sortColumnIndex == null && result.columns.isNotEmpty) {
        _sortColumnIndex = 0;
      }
      _tableRows =
          reset
              ? List<List<String>>.from(result.rows)
              : <List<String>>[..._tableRows, ...result.rows];
      _rowOffset = nextOffset;
      _hasMoreRows = result.hasMoreRows;
      _totalTableRows = result.totalRows;
    });
    _applyTableRowCounts(
      database: database,
      rowCounts: {table: result.totalRows},
    );
    _refreshTableDataDialog();
  }

  Future<void> _reloadCurrentTableRows() async {
    if (_selectedDatabase == null || _selectedTable == null) {
      return;
    }

    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: _selectedTable!,
      reset: true,
      orderByColumn: _currentTableSortColumn(),
      orderAscending: _sortAscending,
    );
  }

  Future<void> _loadMoreCurrentTableRows() async {
    if (_selectedDatabase == null || _selectedTable == null || !_hasMoreRows) {
      return;
    }

    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: _selectedTable!,
      reset: false,
      orderByColumn: _currentTableSortColumn(),
      orderAscending: _sortAscending,
    );
  }

  String? _currentTableSortColumn() {
    if (_sortColumnIndex == null || _sortColumnIndex! >= _tableColumns.length) {
      return null;
    }
    return _tableColumns[_sortColumnIndex!];
  }

  void _refreshTableDataDialog() {
    final refresh = _tableDataDialogRefresh;
    if (refresh == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tableDataDialogRefresh != refresh) {
        return;
      }
      refresh();
    });
  }

  Map<String, SyncTableState> _heartbeatTablesPayload() {
    final tableNames =
        _tables.isNotEmpty
            ? _tables
            : _syncState.tables.keys.toList(growable: false);

    // Heartbeats only need live table metadata. Keep the local history and snapshots
    // out of the request body so the control-plane payload stays bounded.
    return Map<String, SyncTableState>.fromEntries(
      tableNames.map((table) {
        final syncKey =
            table.contains(_syncTableKeySeparator)
                ? table
                : _syncTableKey(table);
        final current = _syncTableState(table, syncKey: syncKey);
        return MapEntry(
          syncKey,
          current.copyWith(history: const <SyncHistoryEntry>[]),
        );
      }),
    );
  }

  String _displayStatus(String status) {
    if (status.isEmpty) {
      return 'Idle';
    }
    final normalized = status.replaceAll('_', ' ').trim();
    return normalized.isEmpty
        ? 'Idle'
        : normalized[0].toUpperCase() + normalized.substring(1);
  }

  bool _isTableDueForRoleSync(SyncTableState state) {
    if (!state.enabled) {
      return false;
    }
    if (state.lastSync.trim().isEmpty) {
      return true;
    }
    final parsed = DateTime.tryParse(state.lastSync);
    if (parsed == null) {
      return true;
    }
    return DateTime.now().difference(parsed).abs() >= _autoSyncInterval;
  }

  void _applyRemoteJobState(
    RemoteSyncJob job, {
    bool appendHistory = false,
    bool success = true,
    String? overrideMessage,
    String? historySnapshotCreatedAt,
    SyncHistorySnapshotData? historySnapshotData,
  }) {
    setState(() {
      final nextJobs = <String, RemoteSyncJob>{
        for (final item in _activeJobs)
          if (item.id != job.id) item.id: item,
      };
      if (job.isActive) {
        nextJobs[job.id] = job;
      }
      _activeJobs = nextJobs.values.toList(growable: false);
    });

    final current =
        _syncState.tables[job.table] ?? _defaultSyncTableState(job.table);
    final timestamp = job.completedAt ?? job.snapshotCreatedAt ?? job.updatedAt;
    final nextStatus = _displayStatus(job.status);
    final nextMessage = overrideMessage ?? job.error ?? job.message;
    final nextState = current.copyWith(
      enabled: current.enabled,
      status: nextStatus,
      lastSync: timestamp.trim().isEmpty ? current.lastSync : timestamp,
      progress: job.progress,
      direction: job.direction,
      rowCount: job.rowCount,
      snapshotId: job.snapshotId,
      snapshotCreatedAt: job.snapshotCreatedAt ?? current.snapshotCreatedAt,
      snapshotBytes:
          job.snapshotBytes > 0 ? job.snapshotBytes : current.snapshotBytes,
      message: nextMessage,
      history:
          appendHistory
              ? _appendHistory(
                current.history,
                SyncHistoryEntry(
                  timestamp: timestamp,
                  table: job.table,
                  status: nextStatus,
                  success: success,
                  message: nextMessage,
                  direction: job.direction,
                  rowCount: job.rowCount,
                  progress: job.progress,
                  snapshotId: job.snapshotId,
                  snapshotCreatedAt:
                      historySnapshotCreatedAt ?? job.snapshotCreatedAt,
                  snapshotBytes: job.snapshotBytes,
                  snapshotData: historySnapshotData,
                ),
              )
              : current.history,
    );
    _updateSyncTableState(job.table, nextState);
  }

  bool _isFileBusy(String table) => _busyFileTables.contains(table);

  void _setFileBusy(String table, bool busy) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (busy) {
        _busyFileTables.add(table);
      } else {
        _busyFileTables.remove(table);
      }
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '--';
    }

    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }

    final decimals =
        value >= 100 || unitIndex == 0
            ? 0
            : value >= 10
            ? 1
            : 2;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String _formatTransferRate(double bytesPerSecond) {
    if (bytesPerSecond <= 0) {
      return '--';
    }
    return '${_formatBytes(bytesPerSecond.round())}/s';
  }

  void _beginUploadMeter(String table) {
    if (!mounted) {
      return;
    }
    setState(() {
      _activeUploadTable = table;
      _uploadMeterStartedAt = DateTime.now();
      _uploadMeterBytesTransferred = 0;
      _uploadBytesPerSecond = 0;
      _uploadMeterCurrentChunk = 0;
      _uploadMeterTotalChunks = 0;
    });
  }

  void _updateUploadMeter(TransferProgressSnapshot progress) {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    final startedAt = _uploadMeterStartedAt ?? now;
    final elapsedSeconds =
        math
            .max(now.difference(startedAt).inMilliseconds / 1000, 0.001)
            .toDouble();
    final averageBytesPerSecond = progress.bytesTransferred / elapsedSeconds;
    setState(() {
      _uploadMeterStartedAt ??= startedAt;
      _uploadMeterBytesTransferred = progress.bytesTransferred;
      _uploadBytesPerSecond = averageBytesPerSecond;
      _uploadMeterCurrentChunk = progress.currentChunk;
      _uploadMeterTotalChunks = progress.totalChunks;
    });
  }

  void _endUploadMeter() {
    if (!mounted) {
      return;
    }
    setState(() {
      _activeUploadTable = null;
      _uploadMeterStartedAt = null;
      _uploadMeterBytesTransferred = 0;
      _uploadBytesPerSecond = 0;
      _uploadMeterCurrentChunk = 0;
      _uploadMeterTotalChunks = 0;
    });
  }

  String _formatTimestamp(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return raw.isEmpty ? 'Never' : raw;
    }
    final local = parsed.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    const monthNames = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final month = monthNames[local.month - 1];
    final year = local.year.toString().padLeft(4, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    final timeZoneName = local.timeZoneName.trim();
    final offset = local.timeZoneOffset;
    final offsetSign = offset.isNegative ? '-' : '+';
    final offsetHours = offset.inHours.abs().toString().padLeft(2, '0');
    final offsetMinutes = (offset.inMinutes.abs() % 60).toString().padLeft(
      2,
      '0',
    );
    final offsetLabel = 'UTC$offsetSign$offsetHours:$offsetMinutes';
    final zoneLabel =
        timeZoneName.isEmpty || timeZoneName == offsetLabel
            ? offsetLabel
            : '$timeZoneName ($offsetLabel)';
    return '$day.$month.$year $hour:$minute:$second $zoneLabel';
  }

  String _buildSummaryLabel() {
    final version =
        _agentAppVersion.trim().isEmpty ? 'dev' : _agentAppVersion.trim();
    final releaseDate = _agentBuildReleaseDate.trim();
    final commitHash = _agentBuildCommitHash.trim();
    final shortHash =
        commitHash.length > 7 ? commitHash.substring(0, 7) : commitHash;
    final hashSuffix = shortHash.isEmpty ? '' : ' $shortHash';
    if (releaseDate.isEmpty) {
      return 'v$version dev$hashSuffix';
    }
    return 'v$version ${_formatTimestamp(releaseDate)}$hashSuffix';
  }

  String _roleLabel(bool isMaster) => 'Two-way';

  String _syncModeLabel(String syncMode) {
    return 'Two-way';
  }

  IconData _syncModeIcon(String syncMode) {
    return Icons.sync_rounded;
  }

  Color _syncModeColor(String syncMode) {
    return const Color(0xFF0F766E);
  }

  String _syncModeDescription(String syncMode) {
    return 'Upload local rows, download missing owner rows.';
  }

  Future<void> _updateTableSyncMode(String table, String syncMode) async {
    final normalizedMode = normalizeSyncMode(
      syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    final syncKey = _syncTableKey(table);
    final current = _syncTableState(table, syncKey: syncKey);
    try {
      await _controlPlaneClient.updateTableSyncPolicy(
        table: syncKey,
        enabled: current.enabled,
        syncMode: normalizedMode,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
      return;
    }
    final direction = syncDirectionForMode(normalizedMode);
    _updateSyncTableState(
      syncKey,
      current.copyWith(
        syncMode: normalizedMode,
        direction: direction,
        status: current.enabled ? 'Queued' : current.status,
        progress: current.enabled ? 0 : current.progress,
        message:
            current.enabled
                ? _syncModeDescription(normalizedMode)
                : current.message,
      ),
    );
    if (current.enabled) {
      unawaited(_queueEnabledRoleJobs(forceTables: {syncKey}));
    }
  }

  Future<void> _showSyncModeEditDialog(_SyncTableRowData row) async {
    final selectedMode = await _openSyncModeDialog(
      table: row.table,
      initialMode: row.state.syncMode,
      title: 'Sync type',
      confirmLabel: 'Apply type',
    );
    if (!mounted || selectedMode == null) {
      return;
    }

    await _updateTableSyncMode(row.table, selectedMode);
  }

  Future<String?> _openSyncModeDialog({
    required String table,
    required String initialMode,
    required String title,
    required String confirmLabel,
  }) {
    const modes = [kSyncModeTwoWay];
    var selectedMode = normalizeSyncMode(
      initialMode,
      fallbackIsMaster: _isMasterClient,
    );

    return showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      table,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ...modes.map(
                      (mode) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildSyncModeChoice(
                          mode: mode,
                          selected: selectedMode == mode,
                          onTap: () {
                            setDialogState(() {
                              selectedMode = mode;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Choose the sync behavior before this table starts. You can change it later from the three-dot menu.',
                      style: TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(selectedMode),
                  child: Text(confirmLabel),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Paused':
        return const Color(0xFF718096);
      case 'Failed':
        return const Color(0xFFB42318);
      case 'Queued':
      case 'Snapshotting':
      case 'Uploading':
      case 'Downloading':
      case 'Applying':
        return const Color(0xFFB7791F);
      default:
        return const Color(0xFF0F766E);
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'Paused':
        return Icons.pause_circle_filled_rounded;
      case 'Failed':
        return Icons.error_rounded;
      case 'Queued':
        return Icons.schedule_rounded;
      case 'Snapshotting':
        return Icons.photo_camera_back_rounded;
      case 'Uploading':
        return Icons.cloud_upload_rounded;
      case 'Downloading':
        return Icons.cloud_download_rounded;
      case 'Applying':
        return Icons.system_update_alt_rounded;
      case 'Completed':
      case 'Success':
      case 'Idle':
      default:
        return Icons.check_circle_rounded;
    }
  }

  String _statusTooltip(String status) {
    switch (status) {
      case 'Paused':
        return 'Paused: syncing is turned off for this table.';
      case 'Failed':
        return 'Failed: the last sync attempt ended with an error.';
      case 'Queued':
        return 'Queued: this table is waiting for the next sync job.';
      case 'Snapshotting':
        return 'Snapshotting: preparing table rows for transfer.';
      case 'Uploading':
        return 'Uploading: sending the local snapshot to the control plane.';
      case 'Downloading':
        return 'Downloading: fetching the remote snapshot.';
      case 'Applying':
        return 'Applying: writing downloaded rows into local SQL Server.';
      case 'Completed':
      case 'Success':
        return 'Success: the last sync completed successfully.';
      case 'Idle':
      default:
        return 'Idle: no sync job is currently running.';
    }
  }

  Widget _buildSyncStatusSymbol(String status, {double size = 26}) {
    final color = _statusColor(status);
    return Tooltip(
      message: _statusTooltip(status),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Icon(_statusIcon(status), size: size * 0.58, color: color),
      ),
    );
  }

  bool _shouldAutoDetectLocalSqlServer(String server) {
    final normalized = server.trim().toLowerCase();
    return normalized.isEmpty ||
        normalized == 'localhost' ||
        normalized == '.' ||
        normalized == '127.0.0.1' ||
        normalized == '(localdb)\\mssqllocaldb';
  }

  Future<_SqlConnectionProfile> _resolveSqlConnectionProfile(
    _SqlConnectionProfile profile,
  ) async {
    if (!_shouldAutoDetectLocalSqlServer(profile.server)) {
      return profile;
    }

    final detectedServer = await _discoverLocalSqlServer(profile);
    if (!mounted ||
        detectedServer == null ||
        detectedServer.trim().isEmpty ||
        detectedServer == profile.server) {
      return profile;
    }

    setState(() {
      _serverController.text = detectedServer;
    });
    widget.onServerChanged(detectedServer);

    return _SqlConnectionProfile(
      server: detectedServer,
      useWindowsAuth: profile.useWindowsAuth,
      user: profile.user,
      password: profile.password,
    );
  }

  Future<String?> _discoverLocalSqlServer(_SqlConnectionProfile profile) async {
    final candidates = <String>{};
    final installedInstances = await _readInstalledSqlServerInstanceNames();

    for (final instance in installedInstances) {
      final normalizedInstance = instance.trim();
      if (normalizedInstance.isEmpty) {
        continue;
      }

      if (normalizedInstance.toUpperCase() == 'MSSQLSERVER') {
        candidates.add('localhost');
        candidates.add('.');
        candidates.add('127.0.0.1');
        continue;
      }

      candidates.add('.\\$normalizedInstance');
      candidates.add('localhost\\$normalizedInstance');
    }

    candidates.addAll(const <String>[
      r'.\SQLEXPRESS',
      r'localhost\SQLEXPRESS',
      r'(localdb)\MSSQLLocalDB',
      'localhost',
      '.',
      '127.0.0.1',
    ]);

    for (final server in candidates) {
      final probeProfile = _SqlConnectionProfile(
        server: server,
        useWindowsAuth: profile.useWindowsAuth,
        user: profile.user,
        password: profile.password,
      );
      if (await _canOpenSqlServer(probeProfile)) {
        return server;
      }
    }

    return null;
  }

  Future<List<String>> _readInstalledSqlServerInstanceNames() async {
    if (!Platform.isWindows) {
      return const [];
    }

    final registryPaths = <String>[
      r'HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL',
    ];
    final instances = <String>{};

    for (final registryPath in registryPaths) {
      try {
        final result = await Process.run(
          'reg',
          ['query', registryPath],
          runInShell: false,
          stdoutEncoding: SystemEncoding(),
          stderrEncoding: SystemEncoding(),
        );
        if (result.exitCode != 0) {
          continue;
        }

        for (final line in result.stdout.toString().split(RegExp(r'\r?\n'))) {
          final trimmed = line.trim();
          if (trimmed.isEmpty ||
              trimmed.startsWith('HKEY_') ||
              trimmed.startsWith(registryPath)) {
            continue;
          }

          final parts = trimmed.split(RegExp(r'\s{2,}'));
          final name = parts.isNotEmpty ? parts.first.trim() : '';
          if (name.isNotEmpty) {
            instances.add(name);
          }
        }
      } catch (_) {
        // Ignore registry probing failures and fall back to common local instances.
      }
    }

    return instances.toList(growable: false);
  }

  Future<bool> _canOpenSqlServer(_SqlConnectionProfile profile) async {
    final result = await _runSqlCmd(
      profile: profile,
      database: 'master',
      query: 'SET NOCOUNT ON; SELECT 1;',
    );
    return result != null && result.exitCode == 0;
  }

  bool _isSyncBusyStatus(String status) {
    switch (status) {
      case 'Queued':
      case 'Snapshotting':
      case 'Uploading':
      case 'Downloading':
      case 'Applying':
        return true;
      default:
        return false;
    }
  }

  List<_SyncTableRowData> _syncRows() {
    final visibleTables = <String>{
      ..._tables,
      ..._syncState.tables.keys
          .where(_syncKeyMatchesSelectedDatabase)
          .map(_localTableName),
    }.toList(growable: false);
    final rows = visibleTables
        .map((table) {
          final syncKey = _syncTableKey(table);
          return _SyncTableRowData(
            table: table,
            syncKey: syncKey,
            state: _syncTableState(table, syncKey: syncKey),
          );
        })
        .toList(growable: false);
    rows.sort(_compareSyncRowsByActiveSort);
    return rows;
  }

  int _compareSyncRowsByActiveSort(
    _SyncTableRowData left,
    _SyncTableRowData right,
  ) {
    final leftPriority = _isPrioritySyncTable(left.state);
    final rightPriority = _isPrioritySyncTable(right.state);
    if (leftPriority != rightPriority) {
      return leftPriority ? -1 : 1;
    }

    final comparison = switch (_syncTableSortField) {
      _SyncTableSortField.name => left.table.toLowerCase().compareTo(
        right.table.toLowerCase(),
      ),
      _SyncTableSortField.lastSync => _timestampSortValue(
        left.state.lastSync,
      ).compareTo(_timestampSortValue(right.state.lastSync)),
      _SyncTableSortField.rows => left.state.rowCount.compareTo(
        right.state.rowCount,
      ),
    };
    if (comparison != 0) {
      return _syncTableSortAscending ? comparison : -comparison;
    }
    return left.table.toLowerCase().compareTo(right.table.toLowerCase());
  }

  int _timestampSortValue(String raw) {
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed != null) {
      return parsed.toUtc().microsecondsSinceEpoch;
    }
    return raw.trim().isEmpty ? -1 : 0;
  }

  _SyncTableRowData? _selectedSyncRow(List<_SyncTableRowData> syncRows) {
    final selectedTableName = _selectedSyncTableName(
      syncRows.map((row) => row.syncKey).toList(growable: false),
    );
    if (selectedTableName == null) {
      return null;
    }
    for (final row in syncRows) {
      if (row.syncKey == selectedTableName) {
        return row;
      }
    }
    return syncRows.isEmpty ? null : syncRows.first;
  }

  Set<String> _setClientRole(bool isMaster) {
    final enabledTables = <String>{};
    const syncMode = kSyncModeTwoWay;
    final direction = syncDirectionForMode(syncMode);
    final nextTables = Map<String, SyncTableState>.fromEntries(
      _syncState.tables.entries.map((entry) {
        final tableState = entry.value;
        if (tableState.enabled) {
          enabledTables.add(entry.key);
        }
        final nextStatus =
            tableState.enabled &&
                    !tableState.status.toLowerCase().contains('ing')
                ? 'Queued'
                : tableState.status;
        final nextMessage =
            tableState.enabled
                ? 'Waiting for the next two-way sync.'
                : tableState.message;
        return MapEntry(
          entry.key,
          tableState.copyWith(
            direction: direction,
            syncMode: syncMode,
            status: nextStatus,
            progress:
                tableState.enabled && nextStatus == 'Queued'
                    ? 0
                    : tableState.progress,
            message: nextMessage,
          ),
        );
      }),
    );
    _replaceSyncState(
      _syncState.copyWith(isMaster: isMaster, tables: nextTables),
    );
    return enabledTables;
  }

  Set<String> _applyRemoteSyncSettings(RemoteAgentSyncSettings settings) {
    final enabledTables =
        settings.isMaster == _isMasterClient
            ? <String>{}
            : _setClientRole(settings.isMaster);
    _applyHistoryLimit(settings.historyLimit);
    _applyAutoSyncInterval(settings.autoSyncIntervalMinutes);
    return enabledTables;
  }

  Set<String> _applyRemoteTablePolicies(List<RemoteTableSyncPolicy> policies) {
    if (policies.isEmpty) {
      return <String>{};
    }

    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    final newlyEnabled = <String>{};
    var changed = false;

    for (final policy in policies) {
      final syncKey = policy.table.trim();
      if (syncKey.isEmpty) {
        continue;
      }
      final current = _syncTableState(syncKey, syncKey: syncKey);
      final nextStatus =
          policy.enabled
              ? (current.status.toLowerCase().contains('ing')
                  ? current.status
                  : 'Queued')
              : 'Paused';
      final nextMessage =
          policy.enabled
              ? 'Waiting for the next two-way sync.'
              : 'Sync disabled.';
      final nextDirection = syncDirectionForMode(policy.syncMode);
      final nextState = current.copyWith(
        enabled: policy.enabled,
        syncMode: policy.syncMode,
        direction: nextDirection,
        status: nextStatus,
        progress:
            policy.enabled
                ? (nextStatus == 'Queued' ? 0 : current.progress)
                : current.progress,
        message: nextMessage,
      );
      if (_syncTableStatesEqual(current, nextState)) {
        continue;
      }
      if (!current.enabled && policy.enabled) {
        newlyEnabled.add(syncKey);
      }
      nextTables[syncKey] = nextState;
      changed = true;
    }

    if (changed) {
      _replaceSyncState(_syncState.copyWith(tables: nextTables));
    }
    return newlyEnabled;
  }

  bool _syncTableStatesEqual(SyncTableState left, SyncTableState right) {
    return left.enabled == right.enabled &&
        left.status == right.status &&
        left.lastSync == right.lastSync &&
        left.progress == right.progress &&
        left.direction == right.direction &&
        left.syncMode == right.syncMode &&
        left.rowCount == right.rowCount &&
        left.snapshotId == right.snapshotId &&
        left.snapshotCreatedAt == right.snapshotCreatedAt &&
        left.snapshotBytes == right.snapshotBytes &&
        left.message == right.message;
  }

  Widget _buildSyncModeBadge(String syncMode, {bool showLabel = true}) {
    final normalizedMode = normalizeSyncMode(
      syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    final color = _syncModeColor(normalizedMode);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: showLabel ? 10 : 6,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_syncModeIcon(normalizedMode), size: 16, color: color),
          if (showLabel) ...[
            const SizedBox(width: 6),
            Text(
              _syncModeLabel(normalizedMode),
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSyncActionIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon),
      ),
    );
  }

  Widget _buildAgentActionButtons() {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 2,
      runSpacing: 2,
      children: [
        _buildSyncActionIconButton(
          tooltip: 'Settings',
          icon: Icons.settings_outlined,
          onPressed: _openSettingsDialog,
        ),
        _buildSyncActionIconButton(
          tooltip: 'Minimize',
          icon: Icons.minimize_rounded,
          onPressed: () => unawaited(widget.onMinimizeWindow()),
        ),
        _buildSyncActionIconButton(
          tooltip: 'Sign out',
          icon: Icons.logout_rounded,
          onPressed: widget.onLogout,
        ),
      ],
    );
  }

  double _bestRowMatchScore(String query, String candidate) {
    final normalizedQuery = query.trim().toLowerCase();
    final normalizedCandidate = candidate.trim().toLowerCase();

    if (normalizedQuery.isEmpty) {
      return 1.0;
    }
    if (normalizedCandidate.isEmpty) {
      return 0.0;
    }
    if (normalizedCandidate == normalizedQuery) {
      return 1000.0;
    }
    if (normalizedCandidate.startsWith(normalizedQuery)) {
      return 850 - normalizedCandidate.length / 1000;
    }

    final exactIndex = normalizedCandidate.indexOf(normalizedQuery);
    if (exactIndex >= 0) {
      return 700.0 - exactIndex;
    }

    final tokens = normalizedQuery
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    var tokenHits = 0;
    var tokenScore = 0.0;
    for (final token in tokens) {
      final index = normalizedCandidate.indexOf(token);
      if (index >= 0) {
        tokenHits += 1;
        tokenScore += 140 - math.min(index.toDouble(), 120);
      }
    }

    final subsequenceScore = _rowSubsequenceScore(
      normalizedQuery,
      normalizedCandidate,
    );
    if (tokenHits == 0 && subsequenceScore == 0) {
      return 0.0;
    }

    if (tokens.isNotEmpty && tokenHits == tokens.length) {
      tokenScore += 120;
    }
    return tokenScore + subsequenceScore;
  }

  double _rowSubsequenceScore(String query, String candidate) {
    var matched = 0;
    var start = 0;

    for (final codePoint in query.runes) {
      final char = String.fromCharCode(codePoint);
      final index = candidate.indexOf(char, start);
      if (index == -1) {
        continue;
      }
      matched += 1;
      start = index + 1;
    }

    if (matched == 0) {
      return 0.0;
    }
    return matched / query.length * 90;
  }

  List<_ScoredHistorySnapshotRow> _filteredHistorySnapshotRows(
    SyncHistorySnapshotData snapshot,
    String query,
  ) {
    final normalizedQuery = query.trim();
    final matches = snapshot.rows
        .asMap()
        .entries
        .map((entry) {
          final rowText = snapshot.columns
              .map((column) => '$column ${entry.value[column] ?? 'NULL'}')
              .join(' ');
          return _ScoredHistorySnapshotRow(
            originalIndex: entry.key,
            row: entry.value,
            score:
                normalizedQuery.isEmpty
                    ? 1
                    : _bestRowMatchScore(normalizedQuery, rowText),
          );
        })
        .where((match) => match.score > 0)
        .toList(growable: false);

    if (normalizedQuery.isEmpty) {
      return matches;
    }

    matches.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) {
        return byScore;
      }
      return left.originalIndex.compareTo(right.originalIndex);
    });
    return matches;
  }

  Future<void> _openHistorySnapshotDialog(SyncHistoryEntry entry) async {
    final snapshot = entry.snapshotData;
    if (snapshot == null || snapshot.columns.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No snapshot data is stored for this history item.'),
        ),
      );
      return;
    }

    final searchController = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final filteredRows = _filteredHistorySnapshotRows(
                snapshot,
                searchController.text,
              );

              return Dialog(
                insetPadding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 1180,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${entry.table} Data',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _InfoLine(label: 'Status', value: entry.status),
                            _InfoLine(
                              label: 'Date',
                              value: _formatTimestamp(
                                entry.snapshotCreatedAt ?? entry.timestamp,
                              ),
                            ),
                            _InfoLine(
                              label: 'Rows',
                              value:
                                  '${filteredRows.length} / ${snapshot.rows.length}',
                            ),
                            _InfoLine(
                              label: 'Size',
                              value: _formatBytes(entry.snapshotBytes),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: searchController,
                          onChanged: (_) => setDialogState(() {}),
                          decoration: _compactInputDecoration(
                            'Search Rows',
                          ).copyWith(
                            hintText:
                                'Search across all visible columns for the best matching row.',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon:
                                searchController.text.isEmpty
                                    ? null
                                    : IconButton(
                                      tooltip: 'Clear search',
                                      onPressed: () {
                                        searchController.clear();
                                        setDialogState(() {});
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child:
                              filteredRows.isEmpty
                                  ? AgentEmptyStateCard(
                                    message:
                                        searchController.text.trim().isEmpty
                                            ? 'This snapshot has no rows.'
                                            : 'No rows matched your search. Try a broader term or clear the search box.',
                                  )
                                  : _buildHistorySnapshotGrid(
                                    snapshot,
                                    filteredRows,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      searchController.dispose();
    }
  }

  _SnapshotFileDocument _createSnapshotFileDocument({
    required String clientName,
    required String table,
    required String createdAt,
    required int rowCount,
    required List<String> columns,
    required List<Map<String, String?>> rows,
    String? id,
    String checksum = '',
    String? sourceJobId,
  }) {
    return _SnapshotFileDocument(
      id: id ?? '${clientName}_${table}_${createdAt.hashCode}',
      clientName: clientName,
      table: table,
      createdAt: createdAt,
      rowCount: rowCount,
      checksum: checksum,
      snapshotBytes: 0,
      columns: columns,
      rows: rows,
      sourceJobId: sourceJobId,
    );
  }

  String _encodeSnapshotFileDocument(_SnapshotFileDocument document) {
    var snapshotBytes = 0;
    var encoded = jsonEncode(
      document.copyWith(snapshotBytes: snapshotBytes).toJson(),
    );

    for (var index = 0; index < 3; index += 1) {
      final nextBytes = utf8.encode(encoded).length;
      if (nextBytes == snapshotBytes) {
        snapshotBytes = nextBytes;
        break;
      }
      snapshotBytes = nextBytes;
      encoded = jsonEncode(
        document.copyWith(snapshotBytes: snapshotBytes).toJson(),
      );
    }

    return encoded;
  }

  String _backupFileName(String table, String createdAt) {
    String sanitize(String value) {
      final normalized = value
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
          .replaceAll(RegExp(r'-+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      return normalized.isEmpty ? 'snapshot' : normalized;
    }

    return '${sanitize(widget.clientName)}-${sanitize(table)}-${sanitize(createdAt)}.json';
  }

  Future<void> _exportTableBackup(String table) async {
    if (_selectedDatabase == null || _isFileBusy(table)) {
      return;
    }

    final syncKey = _syncTableKey(table);
    _setFileBusy(table, true);
    try {
      final snapshot = await _createTableSnapshot(
        profile: _activeProfile(),
        database: _selectedDatabase!,
        table: table,
      );
      if (!snapshot.success) {
        throw Exception(snapshot.errorText);
      }

      final document = _createSnapshotFileDocument(
        clientName: widget.clientName,
        table: syncKey,
        createdAt: snapshot.snapshotCreatedAt,
        rowCount: snapshot.totalRows,
        columns: snapshot.columns,
        rows: snapshot.rows,
      );
      final content = _encodeSnapshotFileDocument(document);
      final bytes = utf8.encode(content).length;

      final location = await getSaveLocation(
        suggestedName: _backupFileName(syncKey, snapshot.snapshotCreatedAt),
        acceptedTypeGroups: <XTypeGroup>[
          const XTypeGroup(label: 'JSON backup', extensions: <String>['json']),
        ],
      );
      if (location == null) {
        return;
      }

      await File(location.path).writeAsString(content);

      final current = _syncTableState(table, syncKey: syncKey);
      final history = _appendHistory(
        current.history,
        SyncHistoryEntry(
          timestamp: DateTime.now().toIso8601String(),
          table: syncKey,
          status: 'Backup saved',
          success: true,
          message: 'Saved a backup file with ${snapshot.totalRows} rows.',
          direction: 'file',
          rowCount: snapshot.totalRows,
          progress: current.progress,
          snapshotId: document.id,
          snapshotCreatedAt: snapshot.snapshotCreatedAt,
          snapshotBytes: bytes,
          snapshotData: _createHistorySnapshotData(
            columns: snapshot.columns,
            rows: snapshot.rows,
          ),
        ),
      );
      _updateSyncTableState(
        syncKey,
        current.copyWith(
          rowCount: snapshot.totalRows,
          snapshotCreatedAt: snapshot.snapshotCreatedAt,
          snapshotBytes: bytes,
          message: 'Backup file saved for $table.',
          history: history,
        ),
      );

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved backup file for $table.')));
    } catch (error) {
      final syncKey = _syncTableKey(table);
      final current = _syncTableState(table, syncKey: syncKey);
      _updateSyncTableState(
        syncKey,
        current.copyWith(
          status: 'Failed',
          message: error.toString(),
          history: _appendHistory(
            current.history,
            SyncHistoryEntry(
              timestamp: DateTime.now().toIso8601String(),
              table: syncKey,
              status: 'Backup save failed',
              success: false,
              message: error.toString(),
              direction: 'file',
              rowCount: current.rowCount,
              progress: current.progress,
              snapshotId: current.snapshotId,
              snapshotCreatedAt: current.snapshotCreatedAt,
              snapshotBytes: current.snapshotBytes,
            ),
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    } finally {
      _setFileBusy(table, false);
    }
  }

  Future<void> _importTableBackup(String table) async {
    if (_selectedDatabase == null || _isFileBusy(table)) {
      return;
    }

    final syncKey = _syncTableKey(table);
    _setFileBusy(table, true);
    try {
      final pickedFile = await openFile(
        acceptedTypeGroups: <XTypeGroup>[
          const XTypeGroup(label: 'JSON backup', extensions: <String>['json']),
        ],
      );
      if (pickedFile == null) {
        return;
      }

      final content = await pickedFile.readAsString();
      final bytes = utf8.encode(content).length;
      final document = _SnapshotFileDocument.fromJson(
        Map<String, dynamic>.from(jsonDecode(content) as Map),
      );

      final snapshot = RemoteSnapshot(
        id: document.id,
        clientName: widget.clientName,
        table: syncKey,
        createdAt: document.createdAt,
        rowCount: document.rowCount,
        checksum: document.checksum,
        snapshotBytes: bytes,
        columns: document.columns,
        rows: document.rows,
        sourceJobId: document.sourceJobId,
      );

      await _applySnapshotToTable(
        profile: _activeProfile(),
        database: _selectedDatabase!,
        table: table,
        snapshot: snapshot,
      );

      final current = _syncTableState(table, syncKey: syncKey);
      final history = _appendHistory(
        current.history,
        SyncHistoryEntry(
          timestamp: DateTime.now().toIso8601String(),
          table: syncKey,
          status: 'Backup applied',
          success: true,
          message: 'Applied a backup file with ${document.rowCount} rows.',
          direction: 'file',
          rowCount: document.rowCount,
          progress: current.progress,
          snapshotId: document.id,
          snapshotCreatedAt: document.createdAt,
          snapshotBytes: bytes,
          snapshotData: _createHistorySnapshotData(
            columns: document.columns,
            rows: document.rows,
          ),
        ),
      );
      _updateSyncTableState(
        syncKey,
        current.copyWith(
          rowCount: document.rowCount,
          snapshotId: document.id,
          snapshotCreatedAt: document.createdAt,
          snapshotBytes: bytes,
          message: 'Backup file applied to $table.',
          history: history,
        ),
      );

      if (_selectedTable == table) {
        await _reloadCurrentTableRows();
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Applied backup file to $table.')));
    } catch (error) {
      final syncKey = _syncTableKey(table);
      final current = _syncTableState(table, syncKey: syncKey);
      _updateSyncTableState(
        syncKey,
        current.copyWith(
          status: 'Failed',
          message: error.toString(),
          history: _appendHistory(
            current.history,
            SyncHistoryEntry(
              timestamp: DateTime.now().toIso8601String(),
              table: syncKey,
              status: 'Backup apply failed',
              success: false,
              message: error.toString(),
              direction: 'file',
              rowCount: current.rowCount,
              progress: current.progress,
              snapshotId: current.snapshotId,
              snapshotCreatedAt: current.snapshotCreatedAt,
              snapshotBytes: current.snapshotBytes,
            ),
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    } finally {
      _setFileBusy(table, false);
    }
  }

  Future<void> _queueEnabledRoleJobs({Set<String>? forceTables}) async {
    if (_tables.isEmpty || _selectedDatabase == null) {
      return;
    }

    final activeTables = {for (final job in _activeJobs) job.table};
    final dueTables = <String>[];
    for (final table in _tables) {
      final syncKey = _syncTableKey(table);
      final state = _syncTableState(table, syncKey: syncKey);
      if (!state.enabled) {
        continue;
      }
      final isDue =
          forceTables?.contains(syncKey) ?? _isTableDueForRoleSync(state);
      if (!isDue) {
        continue;
      }
      if (activeTables.contains(syncKey)) {
        continue;
      }
      dueTables.add(syncKey);
    }

    if (dueTables.isEmpty) {
      return;
    }

    final queuedJobs = await _controlPlaneClient.createJobs(
      clientName: widget.clientName,
      tables: dueTables,
      direction: 'sync',
      syncMode: kSyncModeTwoWay,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      final merged = <String, RemoteSyncJob>{
        for (final job in _activeJobs) job.id: job,
        for (final job in queuedJobs) job.id: job,
      };
      _activeJobs = merged.values.toList(growable: false);
    });

    for (final job in queuedJobs) {
      _applyRemoteJobState(job);
    }
  }

  bool _isTemporaryControlPlaneUnavailable(Object error) {
    return error is AgentControlPlaneException && error.statusCode == 503;
  }

  void _markControlPlaneTemporarilyUnavailable() {
    if (!mounted) {
      return;
    }
    setState(() {
      _serverConnected = false;
      _checkingServerConnection = false;
      _lastServerCheck = DateTime.now();
      _errorMessage = null;
    });
  }

  Future<void> _syncWithControlPlane() async {
    if (!mounted || _syncLoopBusy) {
      return;
    }

    _syncLoopBusy = true;
    try {
      final heartbeat = await _controlPlaneClient.heartbeat(
        clientName: widget.clientName,
        machineName: Platform.localHostname,
        isMaster: _isMasterClient,
        historyLimit: _syncState.historyLimit,
        autoSyncIntervalMinutes: _syncState.autoSyncIntervalMinutes,
        server: _serverController.text.trim(),
        database: _selectedDatabase ?? '',
        serverConnected: _serverConnected,
        sqlConnected: _selectedDatabase != null,
        selectedTable:
            _selectedTable == null ? null : _syncTableKey(_selectedTable!),
        tables: _heartbeatTablesPayload(),
      );

      if (!mounted) {
        return;
      }

      final enabledTables = {
        ..._applyRemoteSyncSettings(heartbeat.syncSettings),
        ..._applyRemoteTablePolicies(heartbeat.tablePolicies),
      };
      if (!mounted) {
        return;
      }

      setState(() {
        _serverConnected = true;
        _checkingServerConnection = false;
        _lastServerCheck = DateTime.now();
        _activeJobs = heartbeat.jobs;
      });

      for (final job in heartbeat.jobs) {
        _applyRemoteJobState(job);
      }

      if (enabledTables.isEmpty) {
        await _queueEnabledRoleJobs();
      } else {
        await _queueEnabledRoleJobs(forceTables: enabledTables);
      }
      await _processPendingJobs();
    } catch (error) {
      if (!mounted) {
        return;
      }
      final temporaryControlPlaneUnavailable =
          _isTemporaryControlPlaneUnavailable(error);
      setState(() {
        _serverConnected = false;
        _checkingServerConnection = false;
        _lastServerCheck = DateTime.now();
        _errorMessage =
            temporaryControlPlaneUnavailable ? null : error.toString();
      });
    } finally {
      _syncLoopBusy = false;
    }
  }

  Future<void> _processPendingJobs() async {
    final pendingJobs = _activeJobs
        .where(
          (job) => job.isActive && _syncKeyMatchesSelectedDatabase(job.table),
        )
        .toList(growable: false);

    for (final job in pendingJobs) {
      if (_processingJobIds.contains(job.id)) {
        continue;
      }
      _processingJobIds.add(job.id);
      try {
        if (job.direction == 'download') {
          await _processDownloadJob(job);
        } else {
          await _processUploadJob(job);
        }
      } finally {
        _processingJobIds.remove(job.id);
      }
    }
  }

  Future<void> _processUploadJob(RemoteSyncJob job) async {
    try {
      _beginUploadMeter(job.table);
      final localDatabase = _databaseNameFromSyncKey(job.table);
      final localTable = _localTableName(job.table);
      var activeJob = await _controlPlaneClient.startJob(
        job.id,
        status: 'snapshotting',
        progress: 10,
        message: 'Creating a local snapshot before upload.',
      );
      _applyRemoteJobState(activeJob);

      final snapshot = await _createTableSnapshot(
        profile: _activeProfile(),
        database: localDatabase,
        table: localTable,
      );

      if (!snapshot.success) {
        throw Exception(snapshot.errorText);
      }

      RemoteSnapshot? ownerSnapshotBeforeUpload;
      try {
        ownerSnapshotBeforeUpload = await _controlPlaneClient.downloadSnapshot(
          job.id,
        );
      } catch (error) {
        if (!_isMissingOwnerSnapshotError(error)) {
          rethrow;
        }
      }

      final rowsToUpload =
          ownerSnapshotBeforeUpload == null
              ? snapshot.rows
              : _rowsMissingOrChangedInOwnerSnapshot(
                localRows: snapshot.rows,
                ownerRows: ownerSnapshotBeforeUpload.rows,
                columns: snapshot.columns,
                keyColumns: snapshot.keyColumns,
                signatureColumns: snapshot.signatureColumns,
              );
      final ownerRowsToPublish =
          ownerSnapshotBeforeUpload == null
              ? snapshot.rows
              : _mergeOwnerSnapshotRows(
                ownerRows: ownerSnapshotBeforeUpload.rows,
                changedLocalRows: rowsToUpload,
                keyColumns: snapshot.keyColumns,
              );

      final backupFile = _createSnapshotFileDocument(
        clientName: widget.clientName,
        table: job.table,
        createdAt: snapshot.snapshotCreatedAt,
        rowCount: ownerRowsToPublish.length,
        columns: snapshot.columns,
        rows: ownerRowsToPublish,
      );
      final backupContent = _encodeSnapshotFileDocument(backupFile);
      final backupBytes = utf8.encode(backupContent).length;

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'uploading',
        progress: 70,
        message: 'Uploading compressed owner namespace snapshot.',
        rowCount: ownerRowsToPublish.length,
        direction: 'sync',
      );
      _applyRemoteJobState(activeJob);

      final uploadResult = await _controlPlaneClient.uploadSnapshot(
        job.id,
        clientName: widget.clientName,
        table: job.table,
        rowCount: ownerRowsToPublish.length,
        snapshotCreatedAt: snapshot.snapshotCreatedAt,
        snapshotBytes: backupBytes,
        snapshotJson: backupContent,
        publishOwnerSnapshot: true,
        onProgress: _updateUploadMeter,
      );

      _applyRemoteJobState(uploadResult.job);

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'downloading',
        progress: 80,
        message: 'Downloading owner namespace rows.',
        rowCount: uploadResult.snapshot.rowCount,
        direction: 'sync',
      );
      _applyRemoteJobState(activeJob);

      final ownerSnapshot = await _controlPlaneClient.downloadSnapshot(job.id);

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'applying',
        progress: 90,
        message: 'Merging owner namespace rows into local SQL Server.',
        rowCount: ownerSnapshot.rowCount,
        direction: 'sync',
      );
      _applyRemoteJobState(activeJob);

      await _applySnapshotToTable(
        profile: _activeProfile(),
        database: localDatabase,
        table: localTable,
        snapshot: ownerSnapshot,
        mergeRows: true,
      );

      activeJob = await _controlPlaneClient.completeJob(
        job.id,
        status: 'completed',
        progress: 100,
        message:
            'Two-way sync completed with ${ownerSnapshot.rowCount} owner namespace rows.',
        rowCount: ownerSnapshot.rowCount,
        snapshotId: ownerSnapshot.id,
        snapshotCreatedAt: ownerSnapshot.createdAt,
        snapshotBytes: ownerSnapshot.snapshotBytes,
      );

      _applyRemoteJobState(
        activeJob,
        appendHistory: true,
        success: true,
        overrideMessage:
            'Uploaded ${rowsToUpload.length} changed local rows and merged ${ownerSnapshot.rowCount} owner namespace rows.',
        historySnapshotCreatedAt: ownerSnapshot.createdAt,
        historySnapshotData: _createHistorySnapshotData(
          columns: ownerSnapshot.columns,
          rows: ownerSnapshot.rows,
        ),
      );
      _endUploadMeter();
    } catch (error) {
      _endUploadMeter();
      if (_isTemporaryControlPlaneUnavailable(error)) {
        _markControlPlaneTemporarilyUnavailable();
        return;
      }
      logStartupEvent('Upload sync job ${job.id} failed: $error');
      await _markRemoteJobFailed(job, error);
      final failedJob = RemoteSyncJob(
        id: job.id,
        clientName: job.clientName,
        sourceClientName: job.sourceClientName,
        table: job.table,
        direction: job.direction,
        status: 'failed',
        progress: 100,
        rowCount: job.rowCount,
        createdAt: job.createdAt,
        updatedAt: DateTime.now().toIso8601String(),
        startedAt: job.startedAt,
        completedAt: DateTime.now().toIso8601String(),
        snapshotId: job.snapshotId,
        snapshotCreatedAt: job.snapshotCreatedAt,
        snapshotBytes: job.snapshotBytes,
        message: error.toString(),
        error: error.toString(),
      );
      _applyRemoteJobState(
        failedJob,
        appendHistory: true,
        success: false,
        overrideMessage: error.toString(),
      );
    }
  }

  Future<void> _markRemoteJobFailed(RemoteSyncJob job, Object error) async {
    try {
      await _controlPlaneClient.failJob(
        job.id,
        error.toString(),
        progress: 100,
      );
    } catch (failError) {
      logStartupEvent('Unable to mark remote job ${job.id} failed: $failError');
    }
  }

  Future<void> _processDownloadJob(RemoteSyncJob job) async {
    try {
      final localDatabase = _databaseNameFromSyncKey(job.table);
      final localTable = _localTableName(job.table);
      var activeJob = await _controlPlaneClient.startJob(
        job.id,
        status: 'snapshotting',
        progress: 10,
        message: 'Creating a local snapshot before download apply.',
      );
      _applyRemoteJobState(activeJob);

      final localSnapshot = await _createTableSnapshot(
        profile: _activeProfile(),
        database: localDatabase,
        table: localTable,
      );
      if (!localSnapshot.success) {
        throw Exception(localSnapshot.errorText);
      }

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'downloading',
        progress: 40,
        message: 'Downloading compressed snapshot in 100 KB chunks.',
        rowCount: localSnapshot.totalRows,
        direction: 'download',
      );
      _applyRemoteJobState(activeJob);

      final snapshot = await _controlPlaneClient.downloadSnapshot(job.id);

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'applying',
        progress: 75,
        message: 'Applying the remote snapshot to local SQL Server.',
        rowCount: snapshot.rowCount,
        direction: 'download',
      );
      _applyRemoteJobState(activeJob);

      await _applySnapshotToTable(
        profile: _activeProfile(),
        database: localDatabase,
        table: localTable,
        snapshot: snapshot,
        mergeRows:
            normalizeSyncMode(
              _syncState.tables[job.table]?.syncMode,
              fallbackIsMaster: _isMasterClient,
            ) ==
            kSyncModeMasterMix,
      );

      activeJob = await _controlPlaneClient.completeJob(
        job.id,
        status: 'completed',
        progress: 100,
        message:
            'Applied snapshot ${snapshot.id} with ${snapshot.rowCount} rows to local SQL Server.',
        rowCount: snapshot.rowCount,
        snapshotId: snapshot.id,
        snapshotCreatedAt: snapshot.createdAt,
        snapshotBytes: snapshot.snapshotBytes,
      );

      _applyRemoteJobState(
        activeJob,
        appendHistory: true,
        success: true,
        overrideMessage:
            'Applied remote snapshot ${snapshot.id} with ${snapshot.rowCount} rows. Local pre-apply snapshot captured ${localSnapshot.totalRows} rows.',
        historySnapshotCreatedAt: snapshot.createdAt,
        historySnapshotData: _createHistorySnapshotData(
          columns: snapshot.columns,
          rows: snapshot.rows,
        ),
      );
    } catch (error) {
      if (_isTemporaryControlPlaneUnavailable(error)) {
        _markControlPlaneTemporarilyUnavailable();
        return;
      }
      logStartupEvent('Download sync job ${job.id} failed: $error');
      await _markRemoteJobFailed(job, error);
      final failedJob = RemoteSyncJob(
        id: job.id,
        clientName: job.clientName,
        sourceClientName: job.sourceClientName,
        table: job.table,
        direction: job.direction,
        status: 'failed',
        progress: 100,
        rowCount: job.rowCount,
        createdAt: job.createdAt,
        updatedAt: DateTime.now().toIso8601String(),
        startedAt: job.startedAt,
        completedAt: DateTime.now().toIso8601String(),
        snapshotId: job.snapshotId,
        snapshotCreatedAt: job.snapshotCreatedAt,
        snapshotBytes: job.snapshotBytes,
        message: error.toString(),
        error: error.toString(),
      );
      _applyRemoteJobState(
        failedJob,
        appendHistory: true,
        success: false,
        overrideMessage: error.toString(),
      );
    }
  }

  Future<void> _applySnapshotToTable({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required RemoteSnapshot snapshot,
    bool mergeRows = false,
  }) async {
    if (database.isEmpty) {
      throw Exception(
        'Select a database before applying a downloaded snapshot.',
      );
    }

    final tableParts = _splitQualifiedName(table);
    final schemaResult = await _queryTableColumnSchemas(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!schemaResult.success) {
      throw Exception(schemaResult.errorText);
    }

    final schemas = schemaResult.values;
    if (schemas.isEmpty) {
      throw Exception('No column metadata was found for $table.');
    }

    final schemasByName = {for (final schema in schemas) schema.name: schema};
    final missingColumns =
        snapshot.columns
            .where((column) => !schemasByName.containsKey(column))
            .toList();
    if (missingColumns.isNotEmpty) {
      throw Exception(
        'Downloaded snapshot columns do not exist locally: ${missingColumns.join(', ')}',
      );
    }

    final writableSnapshotColumns = snapshot.columns
        .where((column) => _isWritableSyncColumn(schemasByName[column]!))
        .toList(growable: false);
    final writeColumns =
        mergeRows
            ? writableSnapshotColumns
                .where(
                  (column) => !(schemasByName[column]?.isIdentity ?? false),
                )
                .toList(growable: false)
            : writableSnapshotColumns;
    if (snapshot.rows.isNotEmpty && writeColumns.isEmpty) {
      throw Exception(
        'Downloaded snapshot for $table has no writable local columns. Computed, rowversion, and generated columns cannot be applied.',
      );
    }

    final hasIdentity = writeColumns.any(
      (column) => schemasByName[column]?.isIdentity ?? false,
    );
    final qualifiedTable = _quoteQualifiedIdentifier(table);
    final columnList = writeColumns.map(_quoteIdentifier).join(', ');
    final keyColumns = _mergeKeyColumns(
      schemas,
      snapshot.columns,
      mergeRows: mergeRows,
      writableColumns: writeColumns,
    );
    if (mergeRows && keyColumns.isEmpty) {
      throw Exception(
        'Merge sync requires a primary key on $table. No primary key columns were found in the local table schema and downloaded snapshot.',
      );
    }
    final rowsToApply =
        mergeRows
            ? _deduplicateMergeRows(
              table: table,
              rows: snapshot.rows,
              signatureColumns: writeColumns,
              keyColumns: keyColumns,
            )
            : snapshot.rows;
    final statements = <String>[
      'SET ANSI_NULLS ON;',
      'SET QUOTED_IDENTIFIER ON;',
      'SET ANSI_PADDING ON;',
      'SET ANSI_WARNINGS ON;',
      'SET CONCAT_NULL_YIELDS_NULL ON;',
      'SET ARITHABORT ON;',
      'SET NUMERIC_ROUNDABORT OFF;',
      'SET NOCOUNT ON;',
      'BEGIN TRY',
      'BEGIN TRAN;',
      if (!mergeRows) 'DELETE FROM $qualifiedTable;',
      if (hasIdentity) 'SET IDENTITY_INSERT $qualifiedTable ON;',
    ];

    const rowsPerBatch = 100;
    for (var index = 0; index < rowsToApply.length; index += rowsPerBatch) {
      final chunk = rowsToApply.skip(index).take(rowsPerBatch);
      final sourceColumns =
          mergeRows ? snapshot.columns : writableSnapshotColumns;
      final values = chunk
          .map(
            (row) =>
                '(${sourceColumns.map((column) => _sqlLiteral(row[column])).join(', ')})',
          )
          .join(', ');
      if (values.isNotEmpty) {
        if (mergeRows) {
          statements.add(
            _mergeSnapshotRowsStatement(
              qualifiedTable: qualifiedTable,
              sourceColumns: snapshot.columns,
              writeColumns: writeColumns,
              keyColumns: keyColumns,
              values: values,
            ),
          );
        } else {
          statements.add(
            'INSERT INTO $qualifiedTable ($columnList) VALUES $values;',
          );
        }
      }
    }

    if (hasIdentity) {
      statements.add('SET IDENTITY_INSERT $qualifiedTable OFF;');
    }
    statements.add('COMMIT TRAN;');
    statements.add('END TRY');
    statements.add('BEGIN CATCH');
    statements.add('IF @@TRANCOUNT > 0 ROLLBACK TRAN;');
    statements.add(
      'DECLARE @errorMessage NVARCHAR(4000); '
      'SET @errorMessage = ERROR_MESSAGE(); '
      'RAISERROR(@errorMessage, 16, 1);',
    );
    statements.add('END CATCH;');

    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: statements.join(' '),
    );

    if (processResult == null) {
      throw Exception(_sqlCmdUnavailableMessage(profile));
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed('download apply', processResult));
    }
  }

  Future<_TableSnapshotResult> _createTableSnapshot({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
  }) async {
    if (database.isEmpty || table.isEmpty) {
      return const _TableSnapshotResult(
        success: false,
        columns: [],
        keyColumns: [],
        signatureColumns: [],
        rows: [],
        totalRows: 0,
        snapshotCreatedAt: '',
        errorText: 'Load a database and table before syncing.',
      );
    }

    final tableParts = _splitQualifiedName(table);
    final schemaResult = await _queryTableColumnSchemas(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!schemaResult.success || schemaResult.values.isEmpty) {
      return _TableSnapshotResult(
        success: false,
        columns: const [],
        keyColumns: const [],
        signatureColumns: const [],
        rows: const [],
        totalRows: 0,
        snapshotCreatedAt: '',
        errorText:
            schemaResult.errorText ?? 'No columns were returned for $table.',
      );
    }
    final columns = schemaResult.values
        .map((schema) => schema.name)
        .toList(growable: false);
    final schemasByName = {
      for (final schema in schemaResult.values) schema.name: schema,
    };
    final writableColumns = columns
        .where((column) => _isWritableSyncColumn(schemasByName[column]!))
        .toList(growable: false);
    final signatureColumns = writableColumns
        .where((column) => !(schemasByName[column]?.isIdentity ?? false))
        .toList(growable: false);

    final rowCountResult = await _queryTableRowCount(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!rowCountResult.success) {
      return _TableSnapshotResult(
        success: false,
        columns: columns,
        keyColumns: const [],
        signatureColumns: const [],
        rows: const [],
        totalRows: 0,
        snapshotCreatedAt: '',
        errorText: rowCountResult.errorText,
      );
    }

    final orderByColumn = _quoteIdentifier(columns.first);
    final rows = <Map<String, String?>>[];
    const pageSize = 200;
    for (var offset = 0; offset < rowCountResult.value; offset += pageSize) {
      final pageResult = await _querySnapshotPage(
        profile: profile,
        database: database,
        table: table,
        columns: columns,
        orderByColumn: orderByColumn,
        offset: offset,
        pageSize: pageSize,
      );
      if (!pageResult.success) {
        return _TableSnapshotResult(
          success: false,
          columns: columns,
          keyColumns: const [],
          signatureColumns: const [],
          rows: const [],
          totalRows: rowCountResult.value,
          snapshotCreatedAt: '',
          errorText: pageResult.errorText,
        );
      }
      rows.addAll(pageResult.rows);
    }

    return _TableSnapshotResult(
      success: true,
      columns: columns,
      keyColumns: _mergeKeyColumns(
        schemaResult.values,
        columns,
        mergeRows: true,
        writableColumns: writableColumns,
      ),
      signatureColumns: signatureColumns,
      rows: rows,
      totalRows: rowCountResult.value,
      snapshotCreatedAt: DateTime.now().toIso8601String(),
      errorText: null,
    );
  }

  Future<_StringQueryResult> _queryDatabases({
    required _SqlConnectionProfile profile,
  }) async {
    if (profile.server.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'Enter a SQL Server instance name or leave it blank to auto-detect this PC.',
      );
    }

    final sql = 'SET NOCOUNT ON; SELECT name FROM sys.databases ORDER BY name;';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: 'master',
      query: sql,
    );
    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('database discovery', processResult),
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
SELECT
  CASE
    WHEN SCHEMA_NAME(schema_id) = 'dbo' THEN name
    ELSE SCHEMA_NAME(schema_id) + '.' + name
  END AS table_name
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
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('table discovery', processResult),
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<Map<String, int>> _queryDatabaseTableCounts({
    required _SqlConnectionProfile profile,
    required List<String> databases,
  }) async {
    final counts = <String, int>{};
    for (final database in databases) {
      final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT COUNT(1)
FROM sys.tables;
''';
      final processResult = await _runSqlCmd(
        profile: profile,
        database: database,
        query: query,
      );
      if (processResult == null || processResult.exitCode != 0) {
        counts[database] = 0;
        continue;
      }
      final values = _parseSingleColumnOutput(processResult.stdout.toString());
      counts[database] = int.tryParse(values.isEmpty ? '' : values.first) ?? 0;
    }
    return counts;
  }

  Future<Map<String, int>> _queryTableRowCounts({
    required _SqlConnectionProfile profile,
    required String database,
    required List<String> tables,
  }) async {
    if (database.isEmpty || tables.isEmpty) {
      return const <String, int>{};
    }

    final counts = <String, int>{};
    const chunkSize = 150;
    for (var offset = 0; offset < tables.length; offset += chunkSize) {
      final chunk = tables.skip(offset).take(chunkSize).toList(growable: false);
      final requestedValues = chunk
          .map((tableName) {
            final parts = _splitQualifiedName(tableName);
            return '(N\'${_escapeSqlLiteral(parts.schema)}\', '
                'N\'${_escapeSqlLiteral(parts.table)}\', '
                'N\'${_escapeSqlLiteral(tableName)}\')';
          })
          .join(',\n');

      final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
WITH requested(schema_name, table_name, display_name) AS (
  SELECT *
  FROM (VALUES
$requestedValues
  ) AS v(schema_name, table_name, display_name)
)
SELECT
  r.display_name,
  CONVERT(varchar(40), COALESCE(SUM(ps.row_count), 0)) AS row_count
FROM requested AS r
LEFT JOIN sys.schemas AS s ON s.name = r.schema_name
LEFT JOIN sys.tables AS t
  ON t.name = r.table_name AND t.schema_id = s.schema_id
LEFT JOIN sys.dm_db_partition_stats AS ps
  ON ps.object_id = t.object_id AND ps.index_id IN (0, 1)
GROUP BY r.display_name
ORDER BY r.display_name;
''';
      final processResult = await _runSqlCmd(
        profile: profile,
        database: database,
        query: query,
      );
      if (processResult == null || processResult.exitCode != 0) {
        continue;
      }

      final lines = processResult.stdout.toString().split(RegExp(r'\r?\n'));
      for (final line in lines) {
        final trimmedLine = line.trim();
        if (_isSkippableOutputLine(trimmedLine)) {
          continue;
        }
        final parts = _splitRowValues(trimmedLine);
        if (parts.length < 2) {
          continue;
        }
        counts[parts[0]] = int.tryParse(parts[1]) ?? 0;
      }
    }

    return counts;
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
    final columnList = columnsResult.values.map(_quoteIdentifier).join(', ');
    final firstRowNumber = offset + 1;
    final lastRowNumber = offset + fetchSize;

    final query = '''
SET NOCOUNT ON;
WITH page_source AS (
  SELECT
    $columnList,
    ROW_NUMBER() OVER (ORDER BY $orderClause $direction) AS [__sync_agent_row_number]
  FROM ${_quoteQualifiedIdentifier(table)}
)
SELECT $columnList
FROM page_source
WHERE [__sync_agent_row_number] BETWEEN $firstRowNumber AND $lastRowNumber
ORDER BY [__sync_agent_row_number];
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
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _TableRowsResult(
        success: false,
        columns: columnsResult.values,
        rows: const [],
        totalRows: rowCountResult.value,
        hasMoreRows: false,
        errorText: _sqlCmdFailed('row fetch', processResult),
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
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('column discovery', processResult),
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_ColumnSchemaResult> _queryTableColumnSchemas({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
DECLARE @schemaName sysname = N'${_escapeSqlLiteral(schema)}';
DECLARE @tableName sysname = N'${_escapeSqlLiteral(table)}';
DECLARE @generatedAlwaysExpression nvarchar(80) =
  CASE
    WHEN COL_LENGTH('sys.columns', 'generated_always_type') IS NULL THEN N'0'
    ELSE N'c.generated_always_type'
  END;
DECLARE @schemaSql nvarchar(max) = N'
SELECT
  c.name,
  TYPE_NAME(c.user_type_id),
  c.is_nullable,
  c.is_identity,
  c.is_computed,
  ' + @generatedAlwaysExpression + N',
  CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS is_primary_key
FROM sys.columns AS c
INNER JOIN sys.tables AS t ON t.object_id = c.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
LEFT JOIN (
  SELECT ic.object_id, ic.column_id
  FROM sys.indexes AS i
  INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  WHERE i.is_primary_key = 1
) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
WHERE s.name = @schemaName
  AND t.name = @tableName
ORDER BY c.column_id;';
EXEC sp_executesql
  @schemaSql,
  N'@schemaName sysname, @tableName sysname',
  @schemaName = @schemaName,
  @tableName = @tableName;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _ColumnSchemaResult(
        success: false,
        values: [],
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _ColumnSchemaResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('column schema discovery', processResult),
      );
    }

    final values = <_TableColumnSchema>[];
    final lines = processResult.stdout.toString().split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      final parts = _splitRowValues(trimmedLine);
      if (parts.length < 6) {
        continue;
      }
      values.add(
        _TableColumnSchema(
          name: parts[0],
          sqlType: parts[1],
          isNullable: parts[2] == '1' || parts[2].toLowerCase() == 'true',
          isIdentity: parts[3] == '1' || parts[3].toLowerCase() == 'true',
          isComputed: parts[4] == '1' || parts[4].toLowerCase() == 'true',
          generatedAlwaysType: int.tryParse(parts[5]) ?? 0,
          isPrimaryKey:
              parts.length >= 7 &&
              (parts[6] == '1' || parts[6].toLowerCase() == 'true'),
        ),
      );
    }

    return _ColumnSchemaResult(success: true, values: values, errorText: null);
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
      return _IntQueryResult(
        success: false,
        value: 0,
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _IntQueryResult(
        success: false,
        value: 0,
        errorText: _sqlCmdFailed('row count lookup', processResult),
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

  Future<_SnapshotPageResult> _querySnapshotPage({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required List<String> columns,
    required String orderByColumn,
    required int offset,
    required int pageSize,
  }) async {
    final columnList = columns.map(_quoteIdentifier).join(', ');
    final firstRowNumber = offset + 1;
    final lastRowNumber = offset + pageSize;

    final query = '''
SET NOCOUNT ON;
WITH page_source AS (
  SELECT
    $columnList,
    ROW_NUMBER() OVER (ORDER BY $orderByColumn ASC) AS [__sync_agent_row_number]
  FROM ${_quoteQualifiedIdentifier(table)}
)
SELECT $columnList
FROM page_source
WHERE [__sync_agent_row_number] BETWEEN $firstRowNumber AND $lastRowNumber
ORDER BY [__sync_agent_row_number];
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _SnapshotPageResult(
        success: false,
        rows: [],
        errorText: _sqlCmdUnavailableMessage(profile),
      );
    }
    if (processResult.exitCode != 0) {
      return _SnapshotPageResult(
        success: false,
        rows: const [],
        errorText: _sqlCmdFailed('snapshot page fetch', processResult),
      );
    }

    final rows = _parseSnapshotPageOutput(
      output: processResult.stdout.toString(),
      columns: columns,
    );
    return _SnapshotPageResult(success: true, rows: rows, errorText: null);
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

  String _sqlCmdFailed(String phase, ProcessResult processResult) {
    return 'sqlcmd failed during $phase (exit ${processResult.exitCode}): '
        '${_formatSqlError(processResult)}';
  }

  Future<ProcessResult?> _runSqlCmd({
    required _SqlConnectionProfile profile,
    String? database,
    required String query,
  }) async {
    _lastSqlCmdLaunchError = null;
    final rawQuery = query.trim();
    const maxInlineQueryLength = 24000;
    final useInputFile = rawQuery.length > maxInlineQueryLength;
    final arguments = <String>[
      '-S',
      profile.server,
      if (database != null && database.isNotEmpty) ...['-d', database],
      '-C',
      '-b',
      '-h',
      '-1',
      '-W',
      '-w',
      '32767',
      '-f',
      '65001',
      '-s',
      '|',
    ];

    if (profile.useWindowsAuth) {
      arguments.insert(0, '-E');
    } else {
      if (profile.user.isEmpty || profile.password.isEmpty) {
        _lastSqlCmdLaunchError =
            'SQL authentication is incomplete. Enter a SQL username and password, or use Windows authentication.';
        return null;
      }
      arguments.insertAll(0, ['-U', profile.user, '-P', profile.password]);
    }

    final executable = _sqlCmdExecutable();
    Directory? queryDirectory;
    try {
      if (useInputFile) {
        queryDirectory = await Directory.systemTemp.createTemp(
          'sync_agent_sqlcmd_',
        );
        final queryFile = File(
          '${queryDirectory.path}${Platform.pathSeparator}query.sql',
        );
        await queryFile.writeAsString(rawQuery, encoding: utf8);
        arguments.addAll(['-i', queryFile.path]);
      } else {
        final normalizedQuery = rawQuery
            .replaceAll('\r\n', ' ')
            .replaceAll('\n', ' ');
        arguments.addAll(['-Q', normalizedQuery]);
      }
      return await Process.run(
        executable,
        arguments,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (error) {
      _lastSqlCmdLaunchError =
          'Unable to start sqlcmd from "$executable": ${error.message}';
      logStartupEvent(_lastSqlCmdLaunchError!);
      return null;
    } finally {
      if (queryDirectory != null) {
        try {
          await queryDirectory.delete(recursive: true);
        } catch (_) {
          // Best effort cleanup for a temporary sqlcmd input file.
        }
      }
    }
  }

  String _sqlCmdUnavailableMessage(_SqlConnectionProfile profile) {
    if (_lastSqlCmdLaunchError != null &&
        _lastSqlCmdLaunchError!.trim().isNotEmpty) {
      return _lastSqlCmdLaunchError!;
    }
    if (!profile.useWindowsAuth &&
        (profile.user.isEmpty || profile.password.isEmpty)) {
      return 'SQL authentication is incomplete. Enter a SQL username and password, or use Windows authentication.';
    }
    final executable = _sqlCmdExecutable();
    if (Platform.isWindows &&
        executable.toLowerCase() != 'sqlcmd' &&
        !File(executable).existsSync()) {
      return 'sqlcmd was not found at "$executable". Install SQL Server Command Line Utilities or repair the SQL Server client tools installation.';
    }
    return 'sqlcmd is not available. Install SQL Server Command Line Utilities.';
  }

  String _sqlCmdExecutable() {
    const executableName = 'sqlcmd';
    if (!Platform.isWindows) {
      return executableName;
    }

    final pathEnvironment = Platform.environment['PATH'] ?? '';
    for (final directory in pathEnvironment.split(';')) {
      final normalizedDirectory = directory.trim();
      if (normalizedDirectory.isEmpty) {
        continue;
      }
      final candidate = File(
        '$normalizedDirectory${Platform.pathSeparator}SQLCMD.EXE',
      );
      if (candidate.existsSync()) {
        return candidate.path;
      }
    }

    final programFiles = <String>[
      Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
    ];
    const odbcVersions = ['180', '170', '160', '150', '130', '110'];
    for (final base in programFiles) {
      for (final version in odbcVersions) {
        final candidate = File(
          '$base${Platform.pathSeparator}Microsoft SQL Server'
          '${Platform.pathSeparator}Client SDK${Platform.pathSeparator}ODBC'
          '${Platform.pathSeparator}$version${Platform.pathSeparator}Tools'
          '${Platform.pathSeparator}Binn${Platform.pathSeparator}SQLCMD.EXE',
        );
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
    }

    return executableName;
  }

  String _quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

  String _escapeSqlLiteral(String value) => value.replaceAll("'", "''");

  String _sqlLiteral(String? value) {
    if (value == null) {
      return 'NULL';
    }
    return "N'${_escapeSqlLiteral(value)}'";
  }

  List<String> _mergeKeyColumns(
    List<_TableColumnSchema> schemas,
    List<String> snapshotColumns, {
    bool mergeRows = false,
    List<String> writableColumns = const [],
  }) {
    final snapshotColumnSet = snapshotColumns.toSet();
    final schemasByName = {for (final schema in schemas) schema.name: schema};
    final primaryKeys = schemas
        .where(
          (schema) =>
              schema.isPrimaryKey && snapshotColumnSet.contains(schema.name),
        )
        .map((schema) => schema.name)
        .toList(growable: false);
    if (!mergeRows) {
      return primaryKeys.isEmpty ? snapshotColumns : primaryKeys;
    }
    if (primaryKeys.isNotEmpty &&
        primaryKeys.every(
          (column) => !(schemasByName[column]?.isIdentity ?? false),
        )) {
      return primaryKeys;
    }

    final nonIdentityWritableColumns = writableColumns
        .where((column) => !(schemasByName[column]?.isIdentity ?? false))
        .toList(growable: false);
    if (nonIdentityWritableColumns.isNotEmpty) {
      return nonIdentityWritableColumns;
    }

    return primaryKeys
        .where((column) => !(schemasByName[column]?.isIdentity ?? false))
        .toList(growable: false);
  }

  bool _isWritableSyncColumn(_TableColumnSchema schema) {
    final sqlType = schema.sqlType.toLowerCase();
    return !schema.isComputed &&
        schema.generatedAlwaysType == 0 &&
        sqlType != 'timestamp' &&
        sqlType != 'rowversion';
  }

  String _mergeRowKey(Map<String, String?> row, List<String> keyColumns) =>
      keyColumns.map((column) => row[column] ?? '').join('\u001f');

  String _mergeRowSignature(Map<String, String?> row, List<String> columns) =>
      columns.map((column) => row[column] ?? '').join('\u001f');

  bool _isMissingOwnerSnapshotError(Object error) {
    if (error is! AgentControlPlaneException) {
      return false;
    }
    final message = error.message.toLowerCase();
    return message.contains('not found') ||
        message.contains('no completed snapshot') ||
        message.contains('snapshot is not available');
  }

  List<Map<String, String?>> _rowsMissingOrChangedInOwnerSnapshot({
    required List<Map<String, String?>> localRows,
    required List<Map<String, String?>> ownerRows,
    required List<String> columns,
    required List<String> keyColumns,
    required List<String> signatureColumns,
  }) {
    if (ownerRows.isEmpty) {
      return localRows;
    }
    final comparableColumns =
        signatureColumns.isEmpty ? columns : signatureColumns;

    final ownerSignatureByKey = <String, String>{};
    for (final ownerRow in ownerRows) {
      ownerSignatureByKey[_mergeRowKey(
        ownerRow,
        keyColumns,
      )] = _mergeRowSignature(ownerRow, comparableColumns);
    }

    return localRows
        .where((localRow) {
          final rowKey = _mergeRowKey(localRow, keyColumns);
          final ownerSignature = ownerSignatureByKey[rowKey];
          if (ownerSignature == null) {
            return true;
          }
          return ownerSignature !=
              _mergeRowSignature(localRow, comparableColumns);
        })
        .toList(growable: false);
  }

  List<Map<String, String?>> _mergeOwnerSnapshotRows({
    required List<Map<String, String?>> ownerRows,
    required List<Map<String, String?>> changedLocalRows,
    required List<String> keyColumns,
  }) {
    if (changedLocalRows.isEmpty) {
      return ownerRows;
    }
    if (ownerRows.isEmpty) {
      return changedLocalRows;
    }

    final incomingKeys =
        changedLocalRows.map((row) => _mergeRowKey(row, keyColumns)).toSet();
    return <Map<String, String?>>[
      for (final ownerRow in ownerRows)
        if (!incomingKeys.contains(_mergeRowKey(ownerRow, keyColumns)))
          ownerRow,
      ...changedLocalRows,
    ];
  }

  List<Map<String, String?>> _deduplicateMergeRows({
    required String table,
    required List<Map<String, String?>> rows,
    required List<String> signatureColumns,
    required List<String> keyColumns,
  }) {
    final comparableColumns =
        signatureColumns.isEmpty ? keyColumns : signatureColumns;
    final rowsByKey = <String, Map<String, String?>>{};
    final signatureByKey = <String, String>{};

    for (final row in rows) {
      final rowKey = _mergeRowKey(row, keyColumns);
      final rowSignature = _mergeRowSignature(row, comparableColumns);
      final existingSignature = signatureByKey[rowKey];
      if (existingSignature == null) {
        signatureByKey[rowKey] = rowSignature;
        rowsByKey[rowKey] = row;
        continue;
      }
      if (existingSignature != rowSignature) {
        throw Exception(
          'Merge conflict detected in downloaded snapshot for $table. Multiple rows share the same merge key but contain different writable values.',
        );
      }
    }

    return rowsByKey.values.toList(growable: false);
  }

  String _sqlColumnEqualityClause({
    required String leftAlias,
    required String rightAlias,
    required List<String> columns,
  }) {
    return columns
        .map(
          (column) =>
              '$leftAlias.${_quoteIdentifier(column)} = $rightAlias.${_quoteIdentifier(column)}',
        )
        .join(' AND ');
  }

  String _mergeSnapshotRowsStatement({
    required String qualifiedTable,
    required List<String> sourceColumns,
    required List<String> writeColumns,
    required List<String> keyColumns,
    required String values,
  }) {
    if (sourceColumns.isEmpty || writeColumns.isEmpty || keyColumns.isEmpty) {
      return '';
    }
    final sourceColumnList = sourceColumns.map(_quoteIdentifier).join(', ');
    final matchClause = _sqlColumnEqualityClause(
      leftAlias: 'target',
      rightAlias: 'source',
      columns: keyColumns,
    );
    final insertColumns = writeColumns.map(_quoteIdentifier).join(', ');
    final insertValues = writeColumns
        .map((column) => 'source.${_quoteIdentifier(column)}')
        .join(', ');
    final duplicateSourceKeysClause = keyColumns
        .map((column) => 'source.${_quoteIdentifier(column)}')
        .join(', ');
    return '''
IF EXISTS (
  SELECT 1
  FROM (VALUES $values) AS source ($sourceColumnList)
  GROUP BY $duplicateSourceKeysClause
  HAVING COUNT(*) > 1
)
BEGIN
  RAISERROR(N'Downloaded snapshot contains duplicate primary keys for $qualifiedTable.', 16, 1);
END;
MERGE $qualifiedTable AS target
USING (VALUES $values) AS source ($sourceColumnList)
ON $matchClause
WHEN NOT MATCHED BY TARGET THEN
  INSERT ($insertColumns) VALUES ($insertValues);
''';
  }

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

  List<Map<String, String?>> _parseSnapshotPageOutput({
    required String output,
    required List<String> columns,
  }) {
    final lines = output.split(RegExp(r'\r?\n'));
    final rows = <Map<String, String?>>[];

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }

      final split = _splitRowValues(trimmedLine);
      final row = <String, String?>{};
      for (var index = 0; index < columns.length; index += 1) {
        final value = index < split.length ? split[index] : '';
        row[columns[index]] = value.isEmpty ? null : value;
      }
      rows.add(row);
    }

    return rows;
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
    var startMinimized = widget.startMinimized;
    var startOnStartup = widget.startOnStartup;
    var saving = false;
    String? startupError;

    _SqlConnectionProfile readDialogProfile() => _SqlConnectionProfile(
      server: serverController.text.trim(),
      useWindowsAuth: _useWindowsAuth,
      user: _userController.text.trim(),
      password: _passwordController.text,
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: const Text('Settings'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.clientNameLocked)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFDDE3EA)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Client Account',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF101828),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                widget.authenticatedAccountName
                                            ?.trim()
                                            .isNotEmpty ==
                                        true
                                    ? widget.authenticatedAccountName!.trim()
                                    : widget.clientName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (widget.authenticatedAccountEmail
                                      ?.trim()
                                      .isNotEmpty ==
                                  true) ...[
                                const SizedBox(height: 4),
                                Text(
                                  widget.authenticatedAccountEmail!.trim(),
                                  style: const TextStyle(
                                    color: Color(0xFF667085),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              const Text(
                                'Client identity is managed by the website and cannot be changed here.',
                                style: TextStyle(
                                  color: Color(0xFF667085),
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        TextField(
                          controller: clientNameController,
                          decoration: _compactInputDecoration('Client Name'),
                        ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        value: startMinimized,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Start Minimized'),
                        subtitle: const Text(
                          'Open the app minimized to the taskbar after launch.',
                        ),
                        onChanged: (value) {
                          setDialogState(() {
                            startMinimized = value;
                          });
                        },
                      ),
                      SwitchListTile(
                        value: startOnStartup,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Start On Windows Startup'),
                        subtitle: const Text(
                          'Launch SQL Sync Agent when this Windows user signs in.',
                        ),
                        onChanged: (value) {
                          setDialogState(() {
                            startOnStartup = value;
                            startupError = null;
                          });
                        },
                      ),
                      if (startupError != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          startupError!,
                          style: const TextStyle(
                            color: Color(0xFFB42318),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: serverController,
                        textInputAction: TextInputAction.done,
                        decoration: _compactInputDecoration(
                          'SQL Server instance',
                        ).copyWith(hintText: r'.\SQLEXPRESS'),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Leave blank to auto-detect this PC.',
                        style: TextStyle(
                          color: Color(0xFF667085),
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: widget.onMinimizeWindow,
                          icon: const Icon(Icons.minimize_rounded, size: 16),
                          label: const Text('Minimize Now'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _InfoLine(
                            label: 'Auth',
                            value: _useWindowsAuth ? 'Windows' : 'SQL',
                          ),
                          _InfoLine(
                            label: 'Startup',
                            value: startOnStartup ? 'On' : 'Off',
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
                  onPressed:
                      saving
                          ? null
                          : () async {
                            final dialogProfile = readDialogProfile();
                            final navigator = Navigator.of(context);
                            final clientName =
                                widget.clientNameLocked
                                    ? widget.clientName
                                    : (clientNameController.text.trim().isEmpty
                                        ? 'Local Agent'
                                        : clientNameController.text.trim());

                            setDialogState(() {
                              saving = true;
                              startupError = null;
                            });

                            try {
                              if (startOnStartup != widget.startOnStartup) {
                                await widget.onStartOnStartupChanged(
                                  startOnStartup,
                                );
                              }
                              widget.onStartMinimizedChanged(startMinimized);
                            } catch (error) {
                              setDialogState(() {
                                saving = false;
                                startupError = error.toString();
                              });
                              return;
                            }

                            if (!mounted) {
                              return;
                            }

                            navigator.pop();

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              _serverController.text = dialogProfile.server;
                              _selectedDatabase = null;
                              _databases = const [];
                              _databaseTableCounts = const {};
                              _tables = const [];
                              _selectedTable = null;
                              _tableColumns = const [];
                              _tableRows = const [];
                              _hasMoreRows = false;
                              _rowOffset = 0;
                              _errorMessage = null;
                            });

                            widget.onServerChanged(dialogProfile.server);
                            widget.onClientNameChanged(clientName);

                            unawaited(
                              _loadDatabases(
                                profile: dialogProfile,
                                loadTables: true,
                                preserveSelection: false,
                              ),
                            );
                          },
                  child: Text(saving ? 'Saving...' : 'Save'),
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

  Widget _buildDatabaseDropdown() {
    final selectedValue =
        _selectedDatabase != null && _databases.contains(_selectedDatabase)
            ? _selectedDatabase
            : null;

    return DropdownButtonFormField<String>(
      value: selectedValue,
      isExpanded: true,
      decoration: _compactInputDecoration(
        '',
      ).copyWith(labelText: null, hintText: 'Database'),
      hint: const Text('Select a local database'),
      items: _databases
          .map(
            (database) => DropdownMenuItem<String>(
              value: database,
              child: Text(
                _databaseDropdownLabel(database),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(growable: false),
      onChanged:
          _databases.isEmpty
              ? null
              : (database) {
                if (database == null) {
                  return;
                }
                unawaited(_selectDatabase(database));
              },
    );
  }

  String _databaseDropdownLabel(String database) =>
      '$database (${_databaseTableCounts[database] ?? 0})';

  Widget _buildSyncTablesHeader() {
    final title = Text(
      'Sync Tables',
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
    );
    final actions = _buildAgentActionButtons();

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        if (compact) {
          return Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                title,
                if (_databases.isNotEmpty)
                  SizedBox(
                    width: constraints.maxWidth.clamp(0, 360).toDouble(),
                    child: _buildDatabaseDropdown(),
                  ),
                actions,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              title,
              if (_databases.isNotEmpty) ...[
                const SizedBox(width: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: _buildDatabaseDropdown(),
                ),
              ],
              const Spacer(),
              const SizedBox(width: 12),
              actions,
            ],
          ),
        );
      },
    );
  }

  Widget _buildSyncPanel() {
    final syncRows = _syncRows();

    if (syncRows.isEmpty) {
      return Column(
        children: [
          _buildSyncTablesHeader(),
          const SizedBox(height: 8),
          AgentSurfaceCard(
            title: 'Sync Tables',
            subtitle: 'Load local SQL tables first.',
            showHeader: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AgentEmptyStateCard(
                  message:
                      'Open settings, confirm SQL access, and load the table list.',
                ),
              ],
            ),
          ),
        ],
      );
    }

    final selectedRow = _selectedSyncRow(syncRows);
    return Column(
      children: [
        _buildSyncTablesHeader(),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stackPanels = constraints.maxWidth < 1100;
              final tableListCard = _buildSyncTableListCard(
                syncRows,
                selectedRow,
              );
              final detailCard = _buildSyncDetailCard(selectedRow);

              if (stackPanels) {
                return Column(
                  children: [
                    Expanded(flex: 7, child: tableListCard),
                    const SizedBox(height: 16),
                    Expanded(flex: 6, child: detailCard),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: tableListCard),
                  const SizedBox(width: 16),
                  Expanded(flex: 5, child: detailCard),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSyncTableListCard(
    List<_SyncTableRowData> syncRows,
    _SyncTableRowData? selectedRow,
  ) {
    return AgentSurfaceCard(
      title: 'Sync Tables',
      subtitle: '',
      expandChild: true,
      showHeader: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSyncTableSortBar(syncRows.length),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.separated(
              itemCount: syncRows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder:
                  (context, index) => _buildSyncTableTile(
                    row: syncRows[index],
                    selected: syncRows[index].syncKey == selectedRow?.syncKey,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncTableSortBar(int tableCount) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$tableCount tables',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF667085),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          _buildSyncTableSortMenu(),
          const SizedBox(width: 6),
          _buildSyncTableSortDirectionButton(),
        ],
      ),
    );
  }

  Widget _buildSyncTableSortMenu() {
    return Tooltip(
      message: 'Sort by ${_syncTableSortLabel(_syncTableSortField)}',
      child: PopupMenuButton<_SyncTableSortField>(
        tooltip: '',
        initialValue: _syncTableSortField,
        onSelected: (field) {
          setState(() {
            if (_syncTableSortField == field) {
              _syncTableSortAscending = !_syncTableSortAscending;
            } else {
              _syncTableSortField = field;
              _syncTableSortAscending = true;
            }
          });
        },
        itemBuilder:
            (context) => _SyncTableSortField.values
                .map(
                  (field) => PopupMenuItem<_SyncTableSortField>(
                    value: field,
                    child: Row(
                      children: [
                        Icon(
                          _syncTableSortIcon(field),
                          size: 18,
                          color:
                              field == _syncTableSortField
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFF667085),
                        ),
                        const SizedBox(width: 10),
                        Text(_syncTableSortLabel(field)),
                      ],
                    ),
                  ),
                )
                .toList(growable: false),
        child: _buildSortToolbarBox(
          icon: _syncTableSortIcon(_syncTableSortField),
        ),
      ),
    );
  }

  Widget _buildSyncTableSortDirectionButton() {
    return Tooltip(
      message: _syncTableSortAscending ? 'Ascending' : 'Descending',
      child: Material(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            setState(() {
              _syncTableSortAscending = !_syncTableSortAscending;
            });
          },
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              _syncTableSortAscending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              size: 18,
              color: const Color(0xFF2563EB),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSortToolbarBox({required IconData icon}) {
    return Container(
      height: 42,
      width: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD7E4FF)),
      ),
      child: Icon(icon, size: 18, color: const Color(0xFF2563EB)),
    );
  }

  IconData _syncTableSortIcon(_SyncTableSortField field) {
    return switch (field) {
      _SyncTableSortField.name => Icons.sort_by_alpha_rounded,
      _SyncTableSortField.lastSync => Icons.schedule_rounded,
      _SyncTableSortField.rows => Icons.format_list_numbered_rounded,
    };
  }

  String _syncTableSortLabel(_SyncTableSortField field) {
    return switch (field) {
      _SyncTableSortField.name => 'Name',
      _SyncTableSortField.lastSync => 'Last update',
      _SyncTableSortField.rows => 'Row count',
    };
  }

  Widget _buildSyncTableTile({
    required _SyncTableRowData row,
    required bool selected,
  }) {
    final statusColor = _statusColor(row.state.status);
    final lastSync = _formatTimestamp(row.state.lastSync);
    final progress = row.state.progress.clamp(0, 100);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        setState(() {
          _selectedSyncTable = row.syncKey;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE6F4F1) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF85C7BC) : const Color(0xFFDDE3EA),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 560;
            final metrics = Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildSyncModeBadge(row.state.syncMode, showLabel: false),
                _buildSyncStatusSymbol(row.state.status, size: 26),
                _buildSyncTableMetric(
                  tooltip: 'Rows',
                  icon: Icons.format_list_numbered_rounded,
                  value: '${row.state.rowCount}',
                ),
                _buildFixedProgressPill(progress, statusColor),
                _buildOpenLiveTableButton(row.table),
              ],
            );

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildSyncTableCheckbox(row),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      stack
                          ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSyncTableTitle(row.table),
                              const SizedBox(height: 4),
                              _buildSyncTableSubline(lastSync),
                              const SizedBox(height: 8),
                              metrics,
                            ],
                          )
                          : Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _buildSyncTableTitle(row.table),
                                    const SizedBox(height: 4),
                                    _buildSyncTableSubline(lastSync),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              metrics,
                            ],
                          ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFixedProgressPill(int progress, Color color) {
    final normalizedProgress = progress.clamp(0, 100);
    return SizedBox(
      width: 48,
      child: AgentStatusPill(label: '$normalizedProgress%', color: color),
    );
  }

  Widget _buildOpenLiveTableButton(String table) {
    return Tooltip(
      message: 'Open live DB table',
      child: SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: () => _openTableDataDialog(table),
          icon: const Icon(Icons.table_rows_outlined),
        ),
      ),
    );
  }

  Widget _buildSyncTableCheckbox(_SyncTableRowData row) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: row.state.enabled ? const Color(0xFFE6F4F1) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              row.state.enabled
                  ? const Color(0xFF85C7BC)
                  : const Color(0xFFDDE3EA),
        ),
      ),
      child: Transform.scale(
        scale: 1.05,
        child: Checkbox(
          value: row.state.enabled,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (value) {
            if (value == null) {
              return;
            }
            unawaited(_handleSyncEnabledChange(row.table, value));
          },
        ),
      ),
    );
  }

  Widget _buildSyncTableTitle(String table) {
    return Text(
      table,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
    );
  }

  Widget _buildSyncTableSubline(String lastSync) {
    return Text(
      'Last update $lastSync',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Color(0xFF667085),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildSyncTableMetric({
    required String tooltip,
    required IconData icon,
    required String value,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        constraints: const BoxConstraints(minHeight: 26),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFDDE3EA)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFF667085)),
            const SizedBox(width: 5),
            Text(
              value,
              style: const TextStyle(
                color: Color(0xFF18212B),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncDetailCard(_SyncTableRowData? selectedRow) {
    if (selectedRow == null) {
      return const AgentSurfaceCard(
        title: 'Sync Details',
        subtitle: '',
        child: AgentEmptyStateCard(
          message:
              'No sync table is selected yet. Click a table row on the left to open its side detail card.',
        ),
      );
    }

    final busy = _isFileBusy(selectedRow.table);

    return AgentSurfaceCard(
      title: 'Sync Details',
      subtitle: '',
      showHeader: false,
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildMergedSyncDetailBody(selectedRow, busy: busy)),
        ],
      ),
    );
  }

  Widget _buildMergedSyncDetailBody(
    _SyncTableRowData row, {
    required bool busy,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildUnifiedSyncDetailHeader(row, busy: busy),
        const SizedBox(height: 18),
        _buildSectionLabel('History'),
        const SizedBox(height: 10),
        Expanded(child: _buildSyncHistorySide(row)),
      ],
    );
  }

  Widget _buildSectionLabel(String value) {
    return Text(
      value,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: Color(0xFF667085),
      ),
    );
  }

  Widget _buildUnifiedSyncDetailHeader(
    _SyncTableRowData row, {
    required bool busy,
  }) {
    final statusColor = _statusColor(row.state.status);
    final normalizedProgress = row.state.progress.clamp(0, 100);
    final canRunSync = row.state.enabled;
    final canTransferBackup = _selectedDatabase != null && !busy;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final toolbar = _buildDetailToolbar(
          row: row,
          compact: compact,
          canRunSync: canRunSync,
          canTransferBackup: canTransferBackup,
        );

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDDE3EA)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.table,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  _buildFixedProgressPill(normalizedProgress, statusColor),
                  const SizedBox(width: 6),
                  _buildSyncDetailMenu(row),
                ],
              ),
              const SizedBox(height: 10),
              toolbar,
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailToolbar({
    required _SyncTableRowData row,
    required bool compact,
    required bool canRunSync,
    required bool canTransferBackup,
  }) {
    final toolbarChildren = <Widget>[
      _buildSyncEnabledToolbarControl(row),
      _buildToolbarIconControl(
        tooltip: 'Sync now',
        icon: Icons.sync_rounded,
        onTap: canRunSync ? () => _triggerSyncNow(row.table) : null,
      ),
      _buildModeReadOnlyControl(row),
      _buildToolbarStat(
        tooltip: 'Rows',
        icon: Icons.format_list_numbered_rounded,
        value: '${row.state.rowCount}',
      ),
      _buildToolbarStat(
        tooltip: 'Backup size',
        icon: Icons.inventory_2_outlined,
        value: _formatBytes(row.state.snapshotBytes),
      ),
      _buildToolbarIconControl(
        tooltip: 'View table',
        icon: Icons.table_rows_outlined,
        onTap: () => _openTableDataDialog(row.table),
      ),
      _buildToolbarIconControl(
        tooltip: 'Download backup',
        icon: Icons.download_rounded,
        onTap: canTransferBackup ? () => _exportTableBackup(row.table) : null,
      ),
      _buildToolbarIconControl(
        tooltip: 'Upload backup',
        icon: Icons.upload_file_rounded,
        onTap: canTransferBackup ? () => _importTableBackup(row.table) : null,
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Wrap(
        spacing: compact ? 6 : 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: toolbarChildren,
      ),
    );
  }

  Widget _buildSyncEnabledToolbarControl(_SyncTableRowData row) {
    return Tooltip(
      message: row.state.enabled ? 'Disable sync' : 'Enable sync',
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              row.state.enabled
                  ? const Color(0xFFE6F4F1)
                  : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                row.state.enabled
                    ? const Color(0xFF85C7BC)
                    : const Color(0xFFDDE3EA),
          ),
        ),
        child: Transform.scale(
          scale: 1.18,
          child: Checkbox(
            value: row.state.enabled,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) {
              if (value == null) {
                return;
              }
              unawaited(_handleSyncEnabledChange(row.table, value));
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSyncDetailMenu(_SyncTableRowData row) {
    return Tooltip(
      message: 'More table actions',
      child: PopupMenuButton<String>(
        tooltip: '',
        onSelected: (value) {
          if (value == 'syncType') {
            unawaited(_showSyncModeEditDialog(row));
          }
        },
        itemBuilder:
            (context) => [
              PopupMenuItem<String>(
                value: 'syncType',
                child: Row(
                  children: [
                    const Icon(
                      Icons.tune_rounded,
                      size: 18,
                      color: Color(0xFF475467),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Change sync type',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _syncModeLabel(row.state.syncMode),
                            style: const TextStyle(
                              color: Color(0xFF667085),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFFDDE3EA)),
          ),
          child: const Icon(
            Icons.more_vert_rounded,
            size: 20,
            color: Color(0xFF475467),
          ),
        ),
      ),
    );
  }

  Widget _buildModeReadOnlyControl(_SyncTableRowData row) {
    final value = normalizeSyncMode(
      row.state.syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    final color = _syncModeColor(value);

    return Tooltip(
      message: '${_syncModeDescription(value)} Change from the three-dot menu.',
      child: Container(
        height: 42,
        constraints: const BoxConstraints(minWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_syncModeIcon(value), size: 17, color: color),
            const SizedBox(width: 8),
            Text(
              _syncModeLabel(value),
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.lock_outline_rounded, size: 15, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncModeChoice({
    required String mode,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final color = _syncModeColor(mode);
    return Material(
      color: selected ? color.withValues(alpha: 0.11) : const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  selected
                      ? color.withValues(alpha: 0.55)
                      : const Color(0xFFDDE3EA),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(_syncModeIcon(mode), size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _syncModeLabel(mode),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _syncModeDescription(mode),
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? color : const Color(0xFF98A2B3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbarStat({
    required String tooltip,
    required IconData icon,
    required String value,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: const Color(0xFF667085)),
            const SizedBox(width: 6),
            Text(
              value,
              style: const TextStyle(
                color: Color(0xFF18212B),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarIconControl({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled ? const Color(0xFFEFF6FF) : const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 18,
              color:
                  enabled ? const Color(0xFF1D4ED8) : const Color(0xFF98A2B3),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _triggerSyncNow(String table) async {
    if (_selectedDatabase == null) {
      return;
    }

    try {
      final queuedJobs = await _controlPlaneClient.createJobs(
        clientName: widget.clientName,
        tables: [_syncTableKey(table)],
        direction: 'sync',
        syncMode: kSyncModeTwoWay,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        final merged = <String, RemoteSyncJob>{
          for (final job in _activeJobs) job.id: job,
          for (final job in queuedJobs) job.id: job,
        };
        _activeJobs = merged.values.toList(growable: false);
      });

      for (final job in queuedJobs) {
        _applyRemoteJobState(job);
      }

      await _processPendingJobs();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    }
  }

  Future<void> _prepareTableData(String table) async {
    if (_selectedDatabase == null) {
      throw Exception(
        'Open settings first so the app can load database tables.',
      );
    }

    final needsReload =
        _selectedTable != table || _tableColumns.isEmpty || _tableRows.isEmpty;
    if (!needsReload) {
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

    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: table,
      reset: true,
      orderByColumn: null,
      orderAscending: true,
    );
  }

  Future<void> _openTableDataDialog(String table) async {
    if (_selectedDatabase == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Open settings first so the app can load database metadata.',
          ),
        ),
      );
      return;
    }

    final needsReload =
        _selectedTable != table || _tableColumns.isEmpty || _tableRows.isEmpty;
    var loadingDialogOpen = false;
    if (needsReload && mounted) {
      loadingDialogOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return const Dialog(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 16),
                    Text('Loading table data...'),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    try {
      await _prepareTableData(table);
    } catch (error) {
      if (loadingDialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingDialogOpen = false;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
      return;
    }

    if (loadingDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      loadingDialogOpen = false;
    }

    if (!mounted) {
      return;
    }

    _tableSearchQuery = '';
    final dialogScrollController = ScrollController();

    Future<void> handleDialogScroll() async {
      if (!dialogScrollController.hasClients ||
          _rowsLoading ||
          !_hasMoreRows ||
          _selectedDatabase == null ||
          _selectedTable == null) {
        return;
      }
      final position = dialogScrollController.position.pixels;
      final max = dialogScrollController.position.maxScrollExtent;
      if (max <= 0 || position < max - 200) {
        return;
      }
      await _loadMoreCurrentTableRows();
    }

    dialogScrollController.addListener(handleDialogScroll);

    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              _tableDataDialogRefresh = () => setDialogState(() {});

              return Dialog(
                insetPadding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 1200,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$table Data',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _InfoLine(
                              label: 'Database',
                              value: _selectedDatabase!,
                            ),
                            _InfoLine(label: 'Table', value: table),
                            _InfoLine(
                              label: 'Rows',
                              value: _totalTableRows.toString(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          onChanged: (value) {
                            setState(() {
                              _tableSearchQuery = value;
                            });
                            _refreshTableDataDialog();
                          },
                          decoration: InputDecoration(
                            labelText: 'Search rows',
                            hintText: 'Type any part of a cell value...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon:
                                _tableSearchQuery.trim().isEmpty
                                    ? null
                                    : IconButton(
                                      tooltip: 'Clear search',
                                      onPressed: () {
                                        setState(() {
                                          _tableSearchQuery = '';
                                        });
                                        _refreshTableDataDialog();
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_errorMessage != null)
                          SelectionArea(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: const Color(0xFFFEF3F2),
                                border: Border.all(
                                  color: const Color(0xFFF7C9C4),
                                ),
                              ),
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Color(0xFFB42318),
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          child: _buildSpreadsheetTable(
                            verticalScrollController: dialogScrollController,
                          ),
                        ),
                        if (_rowsLoading && _tableRows.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Center(child: CircularProgressIndicator()),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _tableSearchQuery = '';
        });
      }
      _tableDataDialogRefresh = null;
      dialogScrollController.removeListener(handleDialogScroll);
      dialogScrollController.dispose();
    }
  }

  Widget _buildSyncHistorySide(_SyncTableRowData row) {
    final historyEntries = List<SyncHistoryEntry>.from(row.state.history)
      ..sort((a, b) {
        final comparison = _timestampSortValue(
          b.timestamp,
        ).compareTo(_timestampSortValue(a.timestamp));
        if (comparison != 0) {
          return comparison;
        }
        return b.timestamp.compareTo(a.timestamp);
      });

    if (historyEntries.isEmpty) {
      return const AgentEmptyStateCard(
        message: 'No sync history recorded for this table yet.',
      );
    }

    return ListView.separated(
      itemCount: historyEntries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = historyEntries[index];
        final canOpenSnapshot =
            entry.snapshotData != null &&
            entry.snapshotData!.columns.isNotEmpty;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap:
                canOpenSnapshot
                    ? () => _openHistorySnapshotDialog(entry)
                    : null,
            child: Ink(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDDE3EA)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final stack = constraints.maxWidth < 540;

                    return stack
                        ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                AgentStatusPill(
                                  label: entry.success ? 'Success' : 'Failed',
                                  color:
                                      entry.success
                                          ? const Color(0xFF0F766E)
                                          : const Color(0xFFB42318),
                                ),
                                Text(
                                  entry.status,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  _formatTimestamp(entry.timestamp),
                                  style: const TextStyle(
                                    color: Color(0xFF5F6B76),
                                    fontSize: 12,
                                  ),
                                ),
                                if (canOpenSnapshot)
                                  const Icon(
                                    Icons.table_rows_outlined,
                                    size: 16,
                                    color: Color(0xFF667085),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              entry.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                height: 1.2,
                                fontSize: 12.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Text(
                                  '${entry.rowCount} rows',
                                  style: const TextStyle(
                                    color: Color(0xFF5F6B76),
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  _formatBytes(entry.snapshotBytes),
                                  style: const TextStyle(
                                    color: Color(0xFF5F6B76),
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  '${entry.progress}%',
                                  style: const TextStyle(
                                    color: Color(0xFF5F6B76),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        )
                        : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            AgentStatusPill(
                              label: entry.success ? 'Success' : 'Failed',
                              color:
                                  entry.success
                                      ? const Color(0xFF0F766E)
                                      : const Color(0xFFB42318),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          entry.status,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        _formatTimestamp(entry.timestamp),
                                        style: const TextStyle(
                                          color: Color(0xFF5F6B76),
                                          fontSize: 12,
                                        ),
                                      ),
                                      if (canOpenSnapshot) ...[
                                        const SizedBox(width: 8),
                                        const Icon(
                                          Icons.table_rows_outlined,
                                          size: 16,
                                          color: Color(0xFF667085),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    entry.message,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      height: 1.2,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      Text(
                                        '${entry.rowCount} rows',
                                        style: const TextStyle(
                                          color: Color(0xFF5F6B76),
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        _formatBytes(entry.snapshotBytes),
                                        style: const TextStyle(
                                          color: Color(0xFF5F6B76),
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        '${entry.progress}%',
                                        style: const TextStyle(
                                          color: Color(0xFF5F6B76),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSyncTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_errorMessage != null)
          SelectionArea(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFFFEF3F2),
                border: Border.all(color: const Color(0xFFF7C9C4)),
              ),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Color(0xFFB42318)),
              ),
            ),
          ),
        Expanded(child: _buildSyncPanel()),
      ],
    );
  }

  InputDecoration _compactInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFDDE3EA)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFDDE3EA)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF0F766E)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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

  Widget _buildHistorySnapshotGrid(
    SyncHistorySnapshotData snapshot,
    List<_ScoredHistorySnapshotRow> filteredRows,
  ) {
    const rowNumberWidth = 72.0;
    const cellWidth = 220.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth =
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
        final totalWidth = math.max(
          panelWidth,
          rowNumberWidth + (snapshot.columns.length * cellWidth),
        );
        final panelHeight =
            constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.sizeOf(context).height * 0.65;

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            border: Border.all(color: const Color(0xFFDDE3EA)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: totalWidth,
                height: panelHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildHistorySnapshotHeaderCell('#', rowNumberWidth),
                        ...snapshot.columns.map(
                          (column) => _buildHistorySnapshotHeaderCell(
                            column,
                            cellWidth,
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filteredRows.length,
                        itemBuilder: (context, index) {
                          final match = filteredRows[index];
                          return _buildHistorySnapshotRow(
                            columns: snapshot.columns,
                            row: match.row,
                            rowNumber: match.originalIndex + 1,
                            rowNumberWidth: rowNumberWidth,
                            cellWidth: cellWidth,
                            alternate: index.isOdd,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistorySnapshotHeaderCell(String value, double width) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFFE3E8E1),
        border: Border(bottom: BorderSide(color: Color(0xFFBFC9BE))),
      ),
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildHistorySnapshotRow({
    required List<String> columns,
    required Map<String, String?> row,
    required int rowNumber,
    required double rowNumberWidth,
    required double cellWidth,
    required bool alternate,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: rowNumberWidth,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: alternate ? Colors.white : const Color(0xFFFAFBF9),
            border: const Border(bottom: BorderSide(color: Color(0xFFE4E8E3))),
          ),
          child: Text(
            '$rowNumber',
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        ...columns.map(
          (column) =>
              _buildTableCell(row[column] ?? '', cellWidth, alt: alternate),
        ),
      ],
    );
  }

  Widget _buildPinnedSummaryBar() {
    final syncRows = _tables
        .map((table) {
          final syncKey = _syncTableKey(table);
          final state = _syncTableState(table, syncKey: syncKey);
          return (table: table, syncKey: syncKey, state: state);
        })
        .toList(growable: false);

    final selectedSyncTableName = _selectedSyncTableName(
      syncRows.map((row) => row.syncKey).toList(growable: false),
    );
    final selectedSyncRow =
        syncRows.isEmpty
            ? null
            : syncRows.firstWhere(
              (row) => row.syncKey == selectedSyncTableName,
              orElse: () => syncRows.first,
            );
    final activeSyncCount =
        syncRows.where((row) => _isSyncBusyStatus(row.state.status)).length;
    final agentStatus =
        _checkingServerConnection
            ? 'Checking'
            : _serverConnected
            ? 'Online'
            : 'Offline';
    final sqlStatus = _selectedDatabase == null ? 'SQL pending' : 'SQL ready';

    final footerItems = <Widget>[
      _InfoLine(label: 'Client', value: widget.clientName),
      _InfoLine(label: 'Build', value: _buildSummaryLabel()),
      _InfoLine(label: 'Agent', value: agentStatus),
      _InfoLine(label: 'SQL', value: sqlStatus),
      _InfoLine(label: 'Database', value: _selectedDatabase ?? 'None'),
      _InfoLine(label: 'Role', value: _roleLabel(_isMasterClient)),
      _InfoLine(label: 'Tables', value: syncRows.length.toString()),
      _InfoLine(
        label: 'Interval',
        value: '${_syncState.autoSyncIntervalMinutes} min',
      ),
      _InfoLine(label: 'Table', value: selectedSyncRow?.table ?? 'None'),
      _InfoLine(label: 'Active', value: activeSyncCount.toString()),
      _InfoLine(
        label: 'Status',
        value: selectedSyncRow?.state.status ?? 'Idle',
      ),
      if (_activeUploadTable != null)
        _InfoLine(label: 'Upload', value: _uploadFooterValue()),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 760;

        return Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFDDE3EA))),
            color: Color(0xFFF6F7F9),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child:
                  stack
                      ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 14,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: footerItems,
                          ),
                          const SizedBox(height: 10),
                          _buildServerStatusIndicator(),
                        ],
                      )
                      : Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 14,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: footerItems,
                            ),
                          ),
                          const SizedBox(width: 16),
                          _buildServerStatusIndicator(),
                        ],
                      ),
            ),
          ),
        );
      },
    );
  }

  String _uploadFooterValue() {
    final chunkLabel =
        _uploadMeterCurrentChunk > 0 && _uploadMeterTotalChunks > 0
            ? '[${_uploadMeterCurrentChunk.toString()}/${_uploadMeterTotalChunks.toString()}] '
            : '';
    return '$chunkLabel${_formatTransferRate(_uploadBytesPerSecond)} (${_formatBytes(_uploadMeterBytesTransferred)})';
  }

  Widget _buildServerStatusIndicator() {
    final color =
        _checkingServerConnection
            ? const Color(0xFFB7791F)
            : _serverConnected
            ? const Color(0xFF0F766E)
            : const Color(0xFFB42318);
    final label =
        _checkingServerConnection
            ? 'Checking'
            : _serverConnected
            ? 'Online'
            : 'Offline';
    final tooltip =
        _lastServerCheck == null
            ? 'Checks the control plane health every minute.\nLive server: ${_controlPlaneClient.baseUrl}'
            : 'Last checked at ${_formatTimestamp(_lastServerCheck!.toIso8601String())}\nLive server: ${_controlPlaneClient.baseUrl}';

    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: color, size: 12),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildSpreadsheetTable({ScrollController? verticalScrollController}) {
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
    final tableSearch = _tableSearchQuery.trim().toLowerCase();
    final filteredRows =
        tableSearch.isEmpty
            ? _tableRows
            : _tableRows
                .where((row) {
                  for (final cell in row) {
                    if (cell.toLowerCase().contains(tableSearch)) {
                      return true;
                    }
                  }
                  return false;
                })
                .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              border: Border.all(color: const Color(0xFFDDE3EA)),
              borderRadius: BorderRadius.circular(8),
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
                  borderRadius: BorderRadius.circular(8),
                  child: Scrollbar(
                    controller: _tableHorizontalScrollController,
                    thumbVisibility: true,
                    notificationPredicate:
                        (notification) =>
                            notification.metrics.axis == Axis.horizontal,
                    child: SingleChildScrollView(
                      controller: _tableHorizontalScrollController,
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
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
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
                                          isSortedColumn
                                              ? !_sortAscending
                                              : true;
                                      setState(() {
                                        _sortColumnIndex = entry.key;
                                        _sortAscending = ascending;
                                      });
                                      _refreshTableDataDialog();
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
                                  filteredRows.isEmpty && !_rowsLoading
                                      ? Center(
                                        child: Text(
                                          _tableSearchQuery.trim().isEmpty
                                              ? '0 rows found in $_selectedTable.'
                                              : 'No rows matched your search.',
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
                                        ),
                                      )
                                      : Scrollbar(
                                        controller: verticalScrollController,
                                        thumbVisibility:
                                            verticalScrollController != null,
                                        child: ListView.builder(
                                          controller: verticalScrollController,
                                          itemCount: filteredRows.length,
                                          itemBuilder: (context, index) {
                                            return _buildTableRow(
                                              filteredRows[index],
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final pagePadding =
        screenWidth < 480
            ? const EdgeInsets.fromLTRB(12, 0, 12, 12)
            : (screenWidth < 760
                ? const EdgeInsets.fromLTRB(14, 0, 14, 14)
                : const EdgeInsets.fromLTRB(16, 0, 16, 16));
    return Scaffold(
      body: Padding(padding: pagePadding, child: _buildSyncTab()),
      bottomNavigationBar: _buildPinnedSummaryBar(),
    );
  }
}

class _SyncTableRowData {
  const _SyncTableRowData({
    required this.table,
    required this.syncKey,
    required this.state,
  });

  final String table;
  final String syncKey;
  final SyncTableState state;
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

class _ColumnSchemaResult {
  const _ColumnSchemaResult({
    required this.success,
    required this.values,
    required this.errorText,
  });

  final bool success;
  final List<_TableColumnSchema> values;
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
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
              color: Color(0xFF5E6C73),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xFF18212B),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoredHistorySnapshotRow {
  const _ScoredHistorySnapshotRow({
    required this.originalIndex,
    required this.row,
    required this.score,
  });

  final int originalIndex;
  final Map<String, String?> row;
  final double score;
}

enum _SyncTableSortField { name, lastSync, rows }

class _SnapshotFileDocument {
  const _SnapshotFileDocument({
    required this.id,
    required this.clientName,
    required this.table,
    required this.createdAt,
    required this.rowCount,
    required this.checksum,
    required this.snapshotBytes,
    required this.columns,
    required this.rows,
    required this.sourceJobId,
  });

  final String id;
  final String clientName;
  final String table;
  final String createdAt;
  final int rowCount;
  final String checksum;
  final int snapshotBytes;
  final List<String> columns;
  final List<Map<String, String?>> rows;
  final String? sourceJobId;

  factory _SnapshotFileDocument.fromJson(Map<String, dynamic> json) {
    final columns = (json['columns'] as List<dynamic>? ?? const [])
        .map((item) => item.toString())
        .toList(growable: false);
    final rawRows = json['rows'] as List<dynamic>? ?? const [];
    return _SnapshotFileDocument(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      rowCount: (json['rowCount'] as num? ?? rawRows.length).round(),
      checksum: json['checksum'] as String? ?? '',
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      columns: columns,
      rows: rawRows
          .map(
            (row) => Map<String, String?>.fromEntries(
              columns.map((column) {
                final value =
                    row is Map && row.containsKey(column) ? row[column] : null;
                return MapEntry(column, value?.toString());
              }),
            ),
          )
          .toList(growable: false),
      sourceJobId: json['sourceJobId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'formatVersion': 1,
    'id': id,
    'clientName': clientName,
    'table': table,
    'createdAt': createdAt,
    'rowCount': rowCount,
    'checksum': checksum,
    'snapshotBytes': snapshotBytes,
    'columns': columns,
    'rows': rows,
    'sourceJobId': sourceJobId,
  };

  _SnapshotFileDocument copyWith({int? snapshotBytes}) {
    return _SnapshotFileDocument(
      id: id,
      clientName: clientName,
      table: table,
      createdAt: createdAt,
      rowCount: rowCount,
      checksum: checksum,
      snapshotBytes: snapshotBytes ?? this.snapshotBytes,
      columns: columns,
      rows: rows,
      sourceJobId: sourceJobId,
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

class _TableSnapshotResult {
  const _TableSnapshotResult({
    required this.success,
    required this.columns,
    required this.keyColumns,
    required this.signatureColumns,
    required this.rows,
    required this.totalRows,
    required this.snapshotCreatedAt,
    required this.errorText,
  });

  final bool success;
  final List<String> columns;
  final List<String> keyColumns;
  final List<String> signatureColumns;
  final List<Map<String, String?>> rows;
  final int totalRows;
  final String snapshotCreatedAt;
  final String? errorText;
}

class _SnapshotPageResult {
  const _SnapshotPageResult({
    required this.success,
    required this.rows,
    required this.errorText,
  });

  final bool success;
  final List<Map<String, String?>> rows;
  final String? errorText;
}

class _TableColumnSchema {
  const _TableColumnSchema({
    required this.name,
    required this.sqlType,
    required this.isNullable,
    required this.isIdentity,
    required this.isComputed,
    required this.generatedAlwaysType,
    required this.isPrimaryKey,
  });

  final String name;
  final String sqlType;
  final bool isNullable;
  final bool isIdentity;
  final bool isComputed;
  final int generatedAlwaysType;
  final bool isPrimaryKey;
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
