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

  String? _selectedDatabase;
  List<String> _databases = const [];
  Map<String, int> _databaseTableCounts = const {};
  List<String> _tables = const [];
  String? _selectedTable;
  List<String> _tableColumns = const [];
  List<List<String>> _tableRows = const [];
  int _rowOffset = 0;

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

  void _updateSyncEnabledTable(String table, bool enabled) {
    final syncKey = _syncTableKey(table);
    final current = _syncTableState(table, syncKey: syncKey);
    final now = DateTime.now().toIso8601String();
    final nextStatus = enabled ? 'Queued' : 'Paused';
    final syncMode = normalizeSyncMode(
      current.syncMode,
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
                ? _isMasterClient
                    ? 'Master override sync enabled for ${widget.clientName}.'
                    : syncMode == kSyncModeMasterMix
                    ? 'Master merge sync enabled for ${widget.clientName}.'
                    : 'Client sync enabled for ${widget.clientName}.'
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
        message:
            enabled
                ? _isMasterClient
                    ? 'Waiting for the next master override upload.'
                    : syncMode == kSyncModeMasterMix
                    ? 'Waiting for upload and merge.'
                    : 'Waiting for the next master snapshot download.'
                : 'Sync disabled.',
        history: nextHistory,
      ),
    );
    if (enabled) {
      unawaited(_queueEnabledRoleJobs(forceTables: {syncKey}));
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
    _ensureSyncTablesLoaded(result.values);

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
      _tableRows =
          reset
              ? List<List<String>>.from(result.rows)
              : <List<String>>[..._tableRows, ...result.rows];
      _rowOffset = nextOffset;
      _hasMoreRows = result.hasMoreRows;
      _totalTableRows = result.totalRows;
    });
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
    return '$day.$month.$year $hour:$minute:$second';
  }

  String _roleLabel(bool isMaster) => isMaster ? 'Master' : 'Slave';

  String _syncModeLabel(String syncMode) {
    switch (normalizeSyncMode(syncMode, fallbackIsMaster: _isMasterClient)) {
      case kSyncModeMaster:
        return 'Master (Override)';
      case kSyncModeMasterMix:
        return 'Master (Merge)';
      case kSyncModeClient:
      default:
        return 'Client';
    }
  }

  IconData _syncModeIcon(String syncMode) {
    switch (normalizeSyncMode(syncMode, fallbackIsMaster: _isMasterClient)) {
      case kSyncModeMaster:
        return Icons.upload_file_rounded;
      case kSyncModeMasterMix:
        return Icons.merge_type_rounded;
      case kSyncModeClient:
      default:
        return Icons.cloud_download_rounded;
    }
  }

  Color _syncModeColor(String syncMode) {
    switch (normalizeSyncMode(syncMode, fallbackIsMaster: _isMasterClient)) {
      case kSyncModeMaster:
        return const Color(0xFF2563EB);
      case kSyncModeMasterMix:
        return const Color(0xFF7C3AED);
      case kSyncModeClient:
      default:
        return const Color(0xFF0F766E);
    }
  }

  String _syncModeDescription(String syncMode) {
    switch (normalizeSyncMode(syncMode, fallbackIsMaster: _isMasterClient)) {
      case kSyncModeMaster:
        return 'Upload and replace client rows.';
      case kSyncModeMasterMix:
        return 'Upload and merge rows from other masters.';
      case kSyncModeClient:
      default:
        return 'Download this table from masters.';
    }
  }

  void _updateTableSyncMode(String table, String syncMode) {
    final normalizedMode = normalizeSyncMode(
      syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    final syncKey = _syncTableKey(table);
    final current = _syncTableState(table, syncKey: syncKey);
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

  List<_SyncTableRowData> _syncRows() => _tables
      .map((table) {
        final syncKey = _syncTableKey(table);
        return _SyncTableRowData(
          table: table,
          syncKey: syncKey,
          state: _syncTableState(table, syncKey: syncKey),
        );
      })
      .toList(growable: false);

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
    final syncMode = isMaster ? kSyncModeMaster : kSyncModeClient;
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
                ? isMaster
                    ? 'Waiting for the next master override upload.'
                    : 'Waiting for the next master snapshot download.'
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

  Widget _buildSyncModeOption(String syncMode, {bool selected = false}) {
    final normalizedMode = normalizeSyncMode(
      syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    final color = _syncModeColor(normalizedMode);
    final label = _syncModeLabel(normalizedMode);
    return Row(
      mainAxisSize: selected ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Container(
          width: selected ? 26 : 30,
          height: selected ? 26 : 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color.withValues(alpha: 0.18)),
          ),
          child: Icon(_syncModeIcon(normalizedMode), size: 17, color: color),
        ),
        SizedBox(width: selected ? 8 : 10),
        if (selected)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          )
        else
          SizedBox(
            width: 132,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  _syncModeDescription(normalizedMode),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSyncModeSelector(_SyncTableRowData row) {
    final value = normalizeSyncMode(
      row.state.syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    return DropdownButtonFormField<String>(
      value: value,
      isDense: true,
      isExpanded: true,
      decoration: _compactInputDecoration(
        '',
      ).copyWith(labelText: null, hintText: 'Mode'),
      selectedItemBuilder:
          (context) =>
              const [kSyncModeMaster, kSyncModeClient, kSyncModeMasterMix]
                  .map((mode) => _buildSyncModeOption(mode, selected: true))
                  .toList(),
      items: [
        DropdownMenuItem(
          value: kSyncModeMaster,
          child: _buildSyncModeOption(kSyncModeMaster),
        ),
        DropdownMenuItem(
          value: kSyncModeClient,
          child: _buildSyncModeOption(kSyncModeClient),
        ),
        DropdownMenuItem(
          value: kSyncModeMasterMix,
          child: _buildSyncModeOption(kSyncModeMasterMix),
        ),
      ],
      onChanged: (mode) {
        if (mode == null) {
          return;
        }
        _updateTableSyncMode(row.table, mode);
      },
    );
  }

  Future<void> _openSyncModeDialog(_SyncTableRowData row) async {
    var selectedMode = normalizeSyncMode(
      row.state.syncMode,
      fallbackIsMaster: _isMasterClient,
    );
    var saving = false;

    await showDialog<void>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text('Change Sync Mode: ${row.table}'),
                content: SizedBox(
                  width: 360,
                  child: DropdownButtonFormField<String>(
                    value: selectedMode,
                    isDense: true,
                    isExpanded: true,
                    decoration: _compactInputDecoration(
                      'Sync Mode',
                    ).copyWith(hintText: 'Select mode'),
                    selectedItemBuilder:
                        (context) => const [
                              kSyncModeMaster,
                              kSyncModeClient,
                              kSyncModeMasterMix,
                            ]
                            .map(
                              (mode) =>
                                  _buildSyncModeOption(mode, selected: true),
                            )
                            .toList(growable: false),
                    items: [
                      DropdownMenuItem(
                        value: kSyncModeMaster,
                        child: _buildSyncModeOption(kSyncModeMaster),
                      ),
                      DropdownMenuItem(
                        value: kSyncModeClient,
                        child: _buildSyncModeOption(kSyncModeClient),
                      ),
                      DropdownMenuItem(
                        value: kSyncModeMasterMix,
                        child: _buildSyncModeOption(kSyncModeMasterMix),
                      ),
                    ],
                    onChanged:
                        saving
                            ? null
                            : (mode) {
                              if (mode == null) {
                                return;
                              }
                              setDialogState(() {
                                selectedMode = mode;
                              });
                            },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        saving
                            ? null
                            : () {
                              setDialogState(() {
                                saving = true;
                              });
                              Navigator.of(context).pop();
                              _updateTableSyncMode(row.table, selectedMode);
                            },
                    child: Text(saving ? 'Saving...' : 'Save'),
                  ),
                ],
              );
            },
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
      ).showSnackBar(SnackBar(content: Text(error.toString())));
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
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      _setFileBusy(table, false);
    }
  }

  Future<void> _queueEnabledRoleJobs({Set<String>? forceTables}) async {
    if (_tables.isEmpty || _selectedDatabase == null) {
      return;
    }

    final activeTablesByDirection = {
      for (final job in _activeJobs) '${job.direction}:${job.table}',
    };
    final dueTablesByDirection = <String, List<String>>{};
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
      final syncMode = normalizeSyncMode(
        state.syncMode,
        fallbackIsMaster: _isMasterClient,
      );
      final directions =
          syncMode == kSyncModeMasterMix
              ? const <String>['upload', 'download']
              : <String>[syncDirectionForMode(syncMode)];
      for (final direction in directions) {
        if (activeTablesByDirection.contains('$direction:$syncKey')) {
          continue;
        }
        dueTablesByDirection
            .putIfAbsent(direction, () => <String>[])
            .add(syncKey);
      }
    }

    if (dueTablesByDirection.isEmpty) {
      return;
    }

    final queuedJobs = <RemoteSyncJob>[];
    for (final entry in dueTablesByDirection.entries) {
      queuedJobs.addAll(
        await _controlPlaneClient.createJobs(
          clientName: widget.clientName,
          tables: entry.value,
          direction: entry.key,
          syncMode:
              entry.key == 'download' &&
                      entry.value.any(
                        (syncKey) =>
                            normalizeSyncMode(
                              _syncState.tables[syncKey]?.syncMode,
                              fallbackIsMaster: _isMasterClient,
                            ) ==
                            kSyncModeMasterMix,
                      )
                  ? kSyncModeMasterMix
                  : null,
        ),
      );
    }

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

      final enabledTables = _applyRemoteSyncSettings(heartbeat.syncSettings);
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

      final backupFile = _createSnapshotFileDocument(
        clientName: widget.clientName,
        table: job.table,
        createdAt: snapshot.snapshotCreatedAt,
        rowCount: snapshot.totalRows,
        columns: snapshot.columns,
        rows: snapshot.rows,
      );
      final backupContent = _encodeSnapshotFileDocument(backupFile);
      final backupBytes = utf8.encode(backupContent).length;

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'uploading',
        progress: 70,
        message: 'Uploading compressed snapshot in 100 KB chunks.',
        rowCount: snapshot.totalRows,
        direction: 'upload',
      );
      _applyRemoteJobState(activeJob);

      final uploadResult = await _controlPlaneClient.uploadSnapshot(
        job.id,
        clientName: widget.clientName,
        table: job.table,
        rowCount: snapshot.totalRows,
        snapshotCreatedAt: snapshot.snapshotCreatedAt,
        snapshotBytes: backupBytes,
        snapshotJson: backupContent,
      );

      _applyRemoteJobState(
        uploadResult.job,
        appendHistory: true,
        success: true,
        historySnapshotCreatedAt: snapshot.snapshotCreatedAt,
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
      await _controlPlaneClient.failJob(
        job.id,
        error.toString(),
        progress: 100,
      );
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
      await _controlPlaneClient.failJob(
        job.id,
        error.toString(),
        progress: 100,
      );
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

    final hasIdentity = snapshot.columns.any(
      (column) => schemasByName[column]?.isIdentity ?? false,
    );
    final qualifiedTable = _quoteQualifiedIdentifier(table);
    final columnList = snapshot.columns.map(_quoteIdentifier).join(', ');
    final keyColumns = _mergeKeyColumns(schemas, snapshot.columns);
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
              columns: snapshot.columns,
              keyColumns: keyColumns,
            )
            : snapshot.rows;
    final statements = <String>[
      'SET NOCOUNT ON;',
      'BEGIN TRY',
      'BEGIN TRAN;',
      if (!mergeRows) 'DELETE FROM $qualifiedTable;',
      if (hasIdentity) 'SET IDENTITY_INSERT $qualifiedTable ON;',
    ];

    const rowsPerBatch = 100;
    for (var index = 0; index < rowsToApply.length; index += rowsPerBatch) {
      final chunk = rowsToApply.skip(index).take(rowsPerBatch);
      final values = chunk
          .map(
            (row) =>
                '(${snapshot.columns.map((column) => _sqlLiteral(row[column])).join(', ')})',
          )
          .join(', ');
      if (values.isNotEmpty) {
        if (mergeRows) {
          statements.add(
            _mergeSnapshotRowsStatement(
              qualifiedTable: qualifiedTable,
              columns: snapshot.columns,
              keyColumns: keyColumns,
              schemasByName: schemasByName,
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
      "DECLARE @errorMessage NVARCHAR(4000) = ERROR_MESSAGE(); "
      'RAISERROR(@errorMessage, 16, 1);',
    );
    statements.add('END CATCH;');

    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: statements.join(' '),
    );

    if (processResult == null) {
      throw Exception(
        'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
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
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
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
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
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
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
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
SELECT
  c.name,
  TYPE_NAME(c.user_type_id),
  c.is_nullable,
  c.is_identity,
  CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS is_primary_key
FROM ${_quoteIdentifier(database)}.sys.columns AS c
INNER JOIN ${_quoteIdentifier(database)}.sys.tables AS t ON t.object_id = c.object_id
INNER JOIN ${_quoteIdentifier(database)}.sys.schemas AS s ON s.schema_id = t.schema_id
LEFT JOIN (
  SELECT ic.object_id, ic.column_id
  FROM ${_quoteIdentifier(database)}.sys.indexes AS i
  INNER JOIN ${_quoteIdentifier(database)}.sys.index_columns AS ic
    ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  WHERE i.is_primary_key = 1
) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
WHERE s.name = '${_escapeSqlLiteral(schema)}'
  AND t.name = '${_escapeSqlLiteral(table)}'
ORDER BY c.column_id;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return const _ColumnSchemaResult(
        success: false,
        values: [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
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
      if (parts.length < 4) {
        continue;
      }
      values.add(
        _TableColumnSchema(
          name: parts[0],
          sqlType: parts[1],
          isNullable: parts[2] == '1' || parts[2].toLowerCase() == 'true',
          isIdentity: parts[3] == '1' || parts[3].toLowerCase() == 'true',
          isPrimaryKey:
              parts.length >= 5 &&
              (parts[4] == '1' || parts[4].toLowerCase() == 'true'),
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
      return const _SnapshotPageResult(
        success: false,
        rows: [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
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
    final normalizedQuery = query
        .trim()
        .replaceAll('\r\n', ' ')
        .replaceAll('\n', ' ');
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

  String _sqlLiteral(String? value) {
    if (value == null) {
      return 'NULL';
    }
    return "N'${_escapeSqlLiteral(value)}'";
  }

  List<String> _mergeKeyColumns(
    List<_TableColumnSchema> schemas,
    List<String> snapshotColumns,
  ) {
    final snapshotColumnSet = snapshotColumns.toSet();
    final primaryKeys = schemas
        .where(
          (schema) =>
              schema.isPrimaryKey && snapshotColumnSet.contains(schema.name),
        )
        .map((schema) => schema.name)
        .toList(growable: false);
    return primaryKeys;
  }

  String _mergeRowKey(Map<String, String?> row, List<String> keyColumns) =>
      keyColumns.map((column) => row[column] ?? '').join('\u001f');

  String _mergeRowSignature(Map<String, String?> row, List<String> columns) =>
      columns.map((column) => row[column] ?? '').join('\u001f');

  List<Map<String, String?>> _deduplicateMergeRows({
    required String table,
    required List<Map<String, String?>> rows,
    required List<String> columns,
    required List<String> keyColumns,
  }) {
    final rowsByKey = <String, Map<String, String?>>{};
    final signatureByKey = <String, String>{};

    for (final row in rows) {
      final rowKey = _mergeRowKey(row, keyColumns);
      final rowSignature = _mergeRowSignature(row, columns);
      final existingSignature = signatureByKey[rowKey];
      if (existingSignature == null) {
        signatureByKey[rowKey] = rowSignature;
        rowsByKey[rowKey] = row;
        continue;
      }
      if (existingSignature != rowSignature) {
        throw Exception(
          'Merge conflict detected in downloaded snapshot for $table. Multiple rows share the same primary key but contain different values.',
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

  String _sqlColumnDifferenceClause({
    required String leftAlias,
    required String rightAlias,
    required List<String> columns,
  }) {
    return columns
        .map((column) {
          final left = '$leftAlias.${_quoteIdentifier(column)}';
          final right = '$rightAlias.${_quoteIdentifier(column)}';
          return '($left <> $right OR ($left IS NULL AND $right IS NOT NULL) OR ($left IS NOT NULL AND $right IS NULL))';
        })
        .join(' OR ');
  }

  String _mergeSnapshotRowsStatement({
    required String qualifiedTable,
    required List<String> columns,
    required List<String> keyColumns,
    required Map<String, _TableColumnSchema> schemasByName,
    required String values,
  }) {
    if (columns.isEmpty || keyColumns.isEmpty) {
      return '';
    }
    final sourceColumns = columns.map(_quoteIdentifier).join(', ');
    final matchClause = _sqlColumnEqualityClause(
      leftAlias: 'target',
      rightAlias: 'source',
      columns: keyColumns,
    );
    final compareColumns = columns
        .where(
          (column) =>
              !keyColumns.contains(column) &&
              !(schemasByName[column]?.isIdentity ?? false),
        )
        .toList(growable: false);
    final insertColumns = columns.map(_quoteIdentifier).join(', ');
    final insertValues = columns
        .map((column) => 'source.${_quoteIdentifier(column)}')
        .join(', ');
    final duplicateSourceKeysClause = keyColumns
        .map((column) => 'source.${_quoteIdentifier(column)}')
        .join(', ');
    final differenceClause =
        compareColumns.isEmpty
            ? ''
            : _sqlColumnDifferenceClause(
              leftAlias: 'target',
              rightAlias: 'source',
              columns: compareColumns,
            );
    return '''
IF EXISTS (
  SELECT 1
  FROM (VALUES $values) AS source ($sourceColumns)
  GROUP BY $duplicateSourceKeysClause
  HAVING COUNT(*) > 1
)
BEGIN
  THROW 51001, N'Downloaded snapshot contains duplicate primary keys for $qualifiedTable.', 1;
END;
${differenceClause.isEmpty ? '' : '''
IF EXISTS (
  SELECT 1
  FROM (VALUES $values) AS source ($sourceColumns)
  INNER JOIN $qualifiedTable AS target
    ON $matchClause
  WHERE $differenceClause
)
BEGIN
  THROW 51000, N'Merge conflict detected for $qualifiedTable. A row with the same primary key already exists with different values.', 1;
END;
'''}
MERGE $qualifiedTable AS target
USING (VALUES $values) AS source ($sourceColumns)
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

                            if (!context.mounted || !mounted) {
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
                            Navigator.of(context).pop();
                            widget.onClientNameChanged(clientName);

                            await _loadDatabases(
                              profile: dialogProfile,
                              loadTables: true,
                              preserveSelection: false,
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

  Widget _buildSyncTableTile({
    required _SyncTableRowData row,
    required bool selected,
  }) {
    final statusColor = _statusColor(row.state.status);
    final lastSync = _formatTimestamp(row.state.lastSync);

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
            final showRowCount = constraints.maxWidth >= 560;
            final showLastSync = constraints.maxWidth >= 960;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Checkbox(
                  value: row.state.enabled,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    _updateSyncEnabledTable(row.table, value);
                  },
                ),
                Expanded(
                  child: Text(
                    row.table,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 30,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildSyncModeBadge(
                      row.state.syncMode,
                      showLabel: false,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 30,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildSyncStatusSymbol(row.state.status, size: 26),
                  ),
                ),
                if (showRowCount) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 72,
                    child: Text(
                      '${row.state.rowCount} rows',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                if (showLastSync) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      lastSync,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                AgentCircularProgressBadge(
                  progress: row.state.progress,
                  color: statusColor,
                  size: 32,
                  strokeWidth: 3,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCompactMetricPill({
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(
                color: Color(0xFF667085),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Color(0xFF18212B),
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        overflow: TextOverflow.ellipsis,
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
      title: selectedRow.table,
      subtitle: '',
      titleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            selectedRow.table,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildSyncStatusSymbol(selectedRow.state.status, size: 26),
              _buildSyncModeBadge(selectedRow.state.syncMode),
              _buildCompactMetricPill(
                label: 'Rows',
                value: '${selectedRow.state.rowCount}',
              ),
              _buildCompactMetricPill(
                label: 'Last Sync',
                value: _formatTimestamp(selectedRow.state.lastSync),
              ),
            ],
          ),
        ],
      ),
      headerTrailing: Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        runSpacing: 4,
        children: [
          OutlinedButton.icon(
            onPressed: () => _openSyncModeDialog(selectedRow),
            icon: const Icon(Icons.tune_rounded, size: 18),
            label: const Text('Edit Mode'),
          ),
          _buildSyncActionIconButton(
            tooltip: 'Open current table data',
            onPressed: () => _openTableDataDialog(selectedRow.table),
            icon: Icons.table_rows_outlined,
          ),
          _buildSyncActionIconButton(
            tooltip: 'Download backup',
            onPressed:
                _selectedDatabase == null || busy
                    ? null
                    : () => _exportTableBackup(selectedRow.table),
            icon: Icons.download_rounded,
          ),
          _buildSyncActionIconButton(
            tooltip: 'Upload backup',
            onPressed:
                _selectedDatabase == null || busy
                    ? null
                    : () => _importTableBackup(selectedRow.table),
            icon: Icons.upload_file_rounded,
          ),
          _buildSyncActionIconButton(
            tooltip: 'Push now',
            onPressed:
                selectedRow.state.enabled
                    ? () =>
                        _triggerSyncNow(selectedRow.table, direction: 'upload')
                    : null,
            icon: Icons.cloud_upload_rounded,
          ),
          _buildSyncActionIconButton(
            tooltip: 'Pull now',
            onPressed:
                selectedRow.state.enabled
                    ? () => _triggerSyncNow(
                      selectedRow.table,
                      direction: 'download',
                    )
                    : null,
            icon: Icons.cloud_download_rounded,
          ),
        ],
      ),
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: _buildMergedSyncDetailBody(selectedRow))],
      ),
    );
  }

  Widget _buildMergedSyncDetailBody(_SyncTableRowData row) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Overview'),
        const SizedBox(height: 10),
        _buildSyncOverviewSide(row),
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

  Widget _buildSyncOverviewSide(_SyncTableRowData row) {
    final statusColor = _statusColor(row.state.status);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stack = constraints.maxWidth < 720;
          final metrics = Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildSyncStatusSymbol(row.state.status, size: 28),
              _buildCompactMetricPill(
                label: 'Rows',
                value: '${row.state.rowCount}',
              ),
              _buildCompactMetricPill(
                label: 'Last Sync',
                value: _formatTimestamp(row.state.lastSync),
              ),
              _buildCompactMetricPill(
                label: 'Backup',
                value: _formatBytes(row.state.snapshotBytes),
              ),
              _buildCompactMetricPill(
                label: 'Enabled',
                value: row.state.enabled ? 'Yes' : 'No',
              ),
            ],
          );

          final selectorBlock = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: _buildSyncModeSelector(row),
          );

          final progressBlock = Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AgentCircularProgressBadge(
                  progress: row.state.progress,
                  color: statusColor,
                  size: 46,
                  strokeWidth: 4,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Progress',
                      style: TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${row.state.progress}% complete',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ],
            ),
          );

          final message = Text(
            row.state.message.isEmpty
                ? 'No sync message yet.'
                : row.state.message,
            maxLines: stack ? 4 : 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(height: 1.35, color: Color(0xFF475467)),
          );

          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [selectorBlock, progressBlock],
                ),
                const SizedBox(height: 10),
                metrics,
                const SizedBox(height: 10),
                message,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        selectorBlock,
                        const SizedBox(height: 10),
                        metrics,
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  progressBlock,
                ],
              ),
              const SizedBox(height: 10),
              message,
            ],
          );
        },
      ),
    );
  }

  Future<void> _triggerSyncNow(
    String table, {
    required String direction,
  }) async {
    if (_selectedDatabase == null) {
      return;
    }

    try {
      final queuedJobs = await _controlPlaneClient.createJobs(
        clientName: widget.clientName,
        tables: [_syncTableKey(table)],
        direction: direction,
        syncMode:
            direction == 'download' &&
                    normalizeSyncMode(
                          _syncTableState(table).syncMode,
                          fallbackIsMaster: _isMasterClient,
                        ) ==
                        kSyncModeMasterMix
                ? kSyncModeMasterMix
                : null,
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
      ).showSnackBar(SnackBar(content: Text(error.toString())));
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
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }

    if (loadingDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      loadingDialogOpen = false;
    }

    if (!mounted) {
      return;
    }

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
                        if (_errorMessage != null)
                          Container(
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
                              style: const TextStyle(color: Color(0xFFB42318)),
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
      _tableDataDialogRefresh = null;
      dialogScrollController.removeListener(handleDialogScroll);
      dialogScrollController.dispose();
    }
  }

  Widget _buildSyncHistorySide(_SyncTableRowData row) {
    final historyEntries = List<SyncHistoryEntry>.from(row.state.history)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

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
          Container(
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
            ? 'Checks the control plane health every minute.'
            : 'Last checked at ${_formatTimestamp(_lastServerCheck!.toIso8601String())}';

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
                                      controller: verticalScrollController,
                                      thumbVisibility:
                                          verticalScrollController != null,
                                      child: ListView.builder(
                                        controller: verticalScrollController,
                                        itemCount: _tableRows.length,
                                        itemBuilder: (context, index) {
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
    required this.rows,
    required this.totalRows,
    required this.snapshotCreatedAt,
    required this.errorText,
  });

  final bool success;
  final List<String> columns;
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
    required this.isPrimaryKey,
  });

  final String name;
  final String sqlType;
  final bool isNullable;
  final bool isIdentity;
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
