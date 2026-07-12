import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'agent_widgets.dart';
import 'live_sync_api.dart';
import 'sql_sync_fingerprint.dart';
import 'sql_sync_merge.dart';
import 'sql_sync_schema.dart';
import 'sync_state.dart';
import 'startup_log.dart';
import 'tray_progress.dart';
import 'window_settings.dart';

const String _agentAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0+2',
);
const String _clientUpdateBaseUrlOverride = String.fromEnvironment(
  'CLIENT_UPDATE_BASE_URL',
  defaultValue: '',
);
const String _liveClientUpdateBaseUrl = 'https://sync.velvet-leaf.com/client';
const String _agentBuildCommitHash = String.fromEnvironment(
  'BUILD_COMMIT_HASH',
  defaultValue: '',
);
const String _agentBuildReleaseDate = String.fromEnvironment(
  'BUILD_RELEASE_DATE',
  defaultValue: '',
);
const Duration _defaultSqlCmdTimeout = Duration(minutes: 2);
const Duration _snapshotSqlCmdTimeout = Duration(minutes: 10);
const Duration _diagnosticsChangeTrackingTimeout = Duration(seconds: 20);
const int _maxDiagnosticsUploadPayloadChars = 60000;
typedef _SqlColumnDefinition = SqlSyncColumnDefinition;

class _PendingWindowActionAck {
  const _PendingWindowActionAck({
    required this.requestId,
    required this.action,
    required this.status,
    required this.message,
  });

  final String requestId;
  final String action;
  final String status;
  final String message;
}

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
    required this.initialDatabase,
    required this.onDatabaseChanged,
    required this.lastAutoUpdateTarget,
    required this.lastAutoUpdateAttemptedAt,
    required this.onAutoUpdateAttempted,
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
  final String? initialDatabase;
  final ValueChanged<String> onDatabaseChanged;
  final String? lastAutoUpdateTarget;
  final String? lastAutoUpdateAttemptedAt;
  final Future<void> Function(String target) onAutoUpdateAttempted;

  @override
  State<AgentDashboardPage> createState() => _AgentDashboardPageState();
}

class _AgentDashboardPageState extends State<AgentDashboardPage> {
  static const int _rowsPerPage = 25;
  static const Duration _syncPollInterval = Duration(seconds: 15);
  static const Duration _autoUpdateRetryCooldown = Duration(minutes: 10);
  static const Duration _tableFingerprintRefreshCooldown = Duration(minutes: 5);
  static const int _heartbeatTablePayloadLimit = 150;
  static const int _targetSnapshotStageInsertBatchSize = 100;

  late final TextEditingController _serverController;
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final AgentControlPlaneClient _controlPlaneClient = AgentControlPlaneClient();
  late SyncClientState _syncState;
  Timer? _connectionCheckTimer;
  Timer? _syncPollTimer;
  Timer? _clientUpdateCheckTimer;

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
  bool? _lastTrayProgressActive;
  int? _lastTrayProgressValue;
  String? _lastTrayProgressStatus;
  bool _diagnosticsUploadBusy = false;
  String? _diagnosticsUploadRequestId;
  bool _rowCountsRefreshing = false;
  bool _markChangedTablesBusy = false;
  List<RemoteSyncJob> _activeJobs = const [];
  VoidCallback? _tableDataDialogRefresh;
  final Set<String> _processingJobIds = <String>{};
  String? _lastSqlCmdLaunchError;
  ClientUpdateInfo? _clientUpdateInfo;
  String? _clientUpdateError;
  bool _checkingClientUpdate = false;
  bool _applyingClientUpdate = false;
  ClientUpdateInfo? _pendingForcedClientUpdateInfo;
  _PendingWindowActionAck? _pendingWindowActionAck;
  bool _flushingPendingWindowActionAck = false;
  bool _refreshingTableFingerprints = false;
  DateTime? _lastTableFingerprintRefreshStartedAt;

  String? _selectedDatabase;
  List<String> _databases = const [];
  List<String> _tables = const [];
  Map<String, Set<String>> _localRelatedSyncTables = const {};
  Map<String, Set<String>> _relatedSyncTables = const {};
  List<RemoteTableDependency> _remoteTableDependencies = const [];
  String? _selectedTable;
  List<String> _tableColumns = const [];
  List<List<String>> _tableRows = const [];
  int _rowOffset = 0;
  String _tableSearchQuery = '';
  final ScrollController _tableHorizontalScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    logStartupEvent('AgentDashboardPage initState');
    _syncState = widget.initialSyncState;
    _selectedDatabase =
        widget.initialDatabase?.trim().isNotEmpty == true
            ? widget.initialDatabase!.trim()
            : null;
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
    _clientUpdateCheckTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(_checkClientUpdate()),
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
        unawaited(_checkClientUpdate());
      }
    });
  }

  @override
  void dispose() {
    _connectionCheckTimer?.cancel();
    _syncPollTimer?.cancel();
    _clientUpdateCheckTimer?.cancel();
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

  Future<void> _checkClientUpdate({bool showErrors = false}) async {
    if (!mounted || _checkingClientUpdate) {
      return;
    }

    setState(() {
      _checkingClientUpdate = true;
      _clientUpdateError = null;
    });

    try {
      final manifestUrl = _clientUpdateManifestUrl();
      logStartupEvent('Checking client update manifest: $manifestUrl');
      final updateInfo = await _controlPlaneClient.fetchClientUpdateInfo(
        manifestUrl: manifestUrl,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _clientUpdateInfo = updateInfo;
        _checkingClientUpdate = false;
      });
      if (updateInfo == null) {
        logStartupEvent('Client update manifest returned no update payload.');
      } else {
        logStartupEvent(
          'Client update manifest loaded: version=${updateInfo.version} '
          'commit=${updateInfo.commit}',
        );
      }
      if (updateInfo != null) {
        unawaited(_maybeAutoApplyClientUpdate(updateInfo));
      }
    } catch (error) {
      logStartupEvent('Client update check failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _clientUpdateError = error.toString();
        _checkingClientUpdate = false;
      });
      if (showErrors) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
      }
    } finally {
      _retryAutomaticClientUpdateIfReady();
    }
  }

  void _updateSyncTableState(String table, SyncTableState state) {
    final tables = Map<String, SyncTableState>.from(_syncState.tables);
    tables[table] = state;
    _replaceSyncState(_syncState.copyWith(tables: tables));
  }

  void _replaceSyncState(SyncClientState nextState) {
    setState(() {
      _syncState = nextState;
      _refreshVisibleTablesForSelectedDatabaseInState();
    });
    widget.onSyncStateChanged(nextState);
  }

  void _refreshVisibleTablesForSelectedDatabaseInState() {
    final selectedDatabase = _selectedDatabase?.trim() ?? '';
    if (selectedDatabase.isEmpty) {
      return;
    }
    final visibleTables = _stableVisibleTablesForDatabase(
      selectedDatabase,
      _tables,
    );
    final previousSelectedTable = _selectedTable;
    final nextSelectedTable =
        previousSelectedTable != null &&
                visibleTables.contains(previousSelectedTable)
            ? previousSelectedTable
            : visibleTables.isNotEmpty
            ? visibleTables.first
            : null;
    _tables = visibleTables;
    _selectedTable = nextSelectedTable;
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

  static const String _syncTableKeySeparator = '::';

  String _syncTableKey(String table, {String? database}) {
    final databaseName = (database ?? _selectedDatabase ?? '').trim();
    final tableName = _stripKnownDatabaseAndDefaultSchema(
      table,
      database: databaseName,
    );
    if (databaseName.isEmpty) {
      return tableName;
    }
    return '$databaseName$_syncTableKeySeparator$tableName';
  }

  String _localTableName(String syncTableKey) {
    final separatorIndex = syncTableKey.indexOf(_syncTableKeySeparator);
    if (separatorIndex < 0) {
      return _stripKnownDatabaseAndDefaultSchema(syncTableKey);
    }
    final databaseName = syncTableKey.substring(0, separatorIndex);
    return _stripKnownDatabaseAndDefaultSchema(
      syncTableKey.substring(separatorIndex + _syncTableKeySeparator.length),
      database: databaseName,
    );
  }

  String _stripDefaultSchema(String table) =>
      table.trim().replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');

  String _stripKnownDatabaseAndDefaultSchema(String table, {String? database}) {
    var tableName = table.trim();
    final databaseName = (database ?? _selectedDatabase ?? '').trim();
    if (databaseName.isNotEmpty) {
      final databasePrefix = '$databaseName.';
      if (tableName.toLowerCase().startsWith(databasePrefix.toLowerCase())) {
        tableName = tableName.substring(databasePrefix.length);
      }
    }
    return _stripDefaultSchema(tableName);
  }

  String _databaseNameFromSyncKey(String syncTableKey) {
    final separatorIndex = syncTableKey.indexOf(_syncTableKeySeparator);
    if (separatorIndex < 0) {
      final qualifiedName = _splitQualifiedName(syncTableKey);
      if (qualifiedName.database.isNotEmpty) {
        return qualifiedName.database;
      }
      return _selectedDatabase ?? '';
    }
    return syncTableKey.substring(0, separatorIndex);
  }

  bool _syncKeyMatchesSelectedDatabase(String syncTableKey) {
    final databaseName = _selectedDatabase?.trim() ?? '';
    if (databaseName.isEmpty) {
      return true;
    }
    if (!syncTableKey.contains(_syncTableKeySeparator)) {
      final qualifiedName = _splitQualifiedName(syncTableKey);
      if (qualifiedName.database.isEmpty) {
        return true;
      }
      return qualifiedName.database.toLowerCase() == databaseName.toLowerCase();
    }
    return syncTableKey.startsWith('$databaseName$_syncTableKeySeparator');
  }

  bool _syncKeyMatchesDatabase(String syncTableKey, String database) {
    final databaseName = database.trim();
    if (databaseName.isEmpty) {
      return true;
    }
    if (!syncTableKey.contains(_syncTableKeySeparator)) {
      final qualifiedName = _splitQualifiedName(syncTableKey);
      if (qualifiedName.database.isEmpty) {
        return true;
      }
      return qualifiedName.database.toLowerCase() == databaseName.toLowerCase();
    }
    return syncTableKey.startsWith('$databaseName$_syncTableKeySeparator');
  }

  List<String> _stableVisibleTablesForDatabase(
    String database,
    Iterable<String> discoveredTables,
  ) {
    final visible = <String>{
      ...discoveredTables.map(
        (table) =>
            _stripKnownDatabaseAndDefaultSchema(table, database: database),
      ),
      ..._syncState.tables.keys
          .where((key) => _syncKeyMatchesDatabase(key, database))
          .map(_localTableName),
      ..._activeJobs
          .map((job) => job.table)
          .where((key) => _syncKeyMatchesDatabase(key, database))
          .map(_localTableName),
      ..._relatedSyncTables.keys
          .where((key) => _syncKeyMatchesDatabase(key, database))
          .map(_localTableName),
      ..._relatedSyncTables.values
          .expand((values) => values)
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
    return _isTableSelectedForSync(state) || state.lastSync.trim().isNotEmpty;
  }

  SyncTableState _syncTableState(String table, {String? syncKey}) {
    final key = syncKey ?? _syncTableKey(table);
    return _syncState.tables[key] ?? _defaultSyncTableState(key);
  }

  void _updateSyncEnabledTable(String table, bool enabled) {
    final syncKey = _syncTableKey(table);
    final current = _syncTableState(table, syncKey: syncKey);
    final now = DateTime.now().toIso8601String();
    final nextStatus = enabled ? 'Queued' : 'Paused';
    final nextHistory = _appendHistory(
      current.history,
      SyncHistoryEntry(
        timestamp: now,
        table: syncKey,
        status: nextStatus,
        success: enabled,
        message:
            enabled
                ? 'Sync enabled for ${widget.clientName}.'
                : 'Remote sync paused for ${widget.clientName}.',
        rowCount: current.rowCount,
        progress: enabled ? 0 : current.progress,
      ),
    );
    _updateSyncTableState(
      syncKey,
      current.copyWith(
        enabled: enabled,
        status: nextStatus,
        lastSync: enabled ? current.lastSync : now,
        progress: enabled ? 0 : current.progress,
        autoRequired:
            current.autoRequired && enabled ? false : current.autoRequired,
        message: enabled ? 'Waiting for the next sync.' : 'Sync disabled.',
        history: nextHistory,
      ),
    );
    if (enabled) {
      unawaited(_syncWithControlPlane());
    }
  }

  Set<String> _relatedSyncKeysFor(String syncKey) {
    final pending = <String>{syncKey};
    final related = <String>{};
    while (pending.isNotEmpty) {
      final current = pending.first;
      pending.remove(current);
      final nextRelated = _relatedSyncTables[current] ?? const <String>{};
      for (final candidate in nextRelated) {
        if (candidate == syncKey || related.contains(candidate)) {
          continue;
        }
        related.add(candidate);
        pending.add(candidate);
      }
    }
    return related;
  }

  Future<void> _handleSyncEnabledChange(String table, bool enabled) async {
    final syncKey = _syncTableKey(table);
    try {
      await _controlPlaneClient.updateTableSyncPolicy(
        table: syncKey,
        enabled: enabled,
        cascadeRelated: false,
      );
      if (!mounted) {
        return;
      }
      _updateSyncEnabledTable(table, enabled);
      _refreshAutoRequiredTables();
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
      autoRequired: false,
      status: 'Paused',
      lastSync: '',
      progress: 0,
      rowCount: 0,
      savedRowCount: null,
      tableChecksum: '',
      changeTrackingVersion: null,
      changeTrackingStatus: 'unknown',
      changeTrackingMessage: '',
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
        nextTables[syncKey] = _defaultSyncTableState(syncKey);
        changed = true;
      }
    }
    if (changed) {
      _replaceSyncState(
        _syncState.copyWith(tables: _nextTablesWithAutoRequired(nextTables)),
      );
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
      _replaceSyncState(
        _syncState.copyWith(tables: _nextTablesWithAutoRequired(nextTables)),
      );
    }
  }

  void _applyTableFingerprints({
    required String database,
    required Map<String, _TableFingerprint> fingerprints,
  }) {
    if (fingerprints.isEmpty) {
      return;
    }

    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    var changed = false;
    for (final entry in fingerprints.entries) {
      final syncKey = _syncTableKey(entry.key, database: database);
      final current = _syncTableState(entry.key, syncKey: syncKey);
      final fingerprint = entry.value;
      if (current.rowCount == fingerprint.rowCount &&
          current.tableChecksum == fingerprint.checksum) {
        continue;
      }
      nextTables[syncKey] = current.copyWith(
        rowCount: fingerprint.rowCount,
        tableChecksum: fingerprint.checksum,
      );
      changed = true;
    }

    if (changed) {
      _replaceSyncState(
        _syncState.copyWith(tables: _nextTablesWithAutoRequired(nextTables)),
      );
    }
  }

  bool _isTableSelectedForSync(SyncTableState state) {
    return state.enabled || state.autoRequired;
  }

  Set<String> _autoRequiredSyncKeys([Map<String, SyncTableState>? tables]) {
    final states = tables ?? _syncState.tables;
    final autoRequired = <String>{};
    final manualRoots = states.entries
        .where((entry) => entry.value.enabled)
        .map((entry) => entry.key.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    for (final root in manualRoots) {
      autoRequired.addAll(_relatedSyncKeysFor(root));
    }
    autoRequired.removeAll(manualRoots);
    return autoRequired;
  }

  Map<String, SyncTableState> _nextTablesWithAutoRequired(
    Map<String, SyncTableState> sourceTables,
  ) {
    final nextTables = Map<String, SyncTableState>.from(sourceTables);
    final autoRequiredSyncKeys = _autoRequiredSyncKeys(nextTables);
    final knownKeys = <String>{
      ...nextTables.keys,
      ..._relatedSyncTables.keys,
      ..._relatedSyncTables.values.expand((values) => values),
    };
    for (final syncKey in knownKeys) {
      final current = nextTables[syncKey] ?? _defaultSyncTableState(syncKey);
      final nextAutoRequired =
          !current.enabled && autoRequiredSyncKeys.contains(syncKey);
      var nextStatus = current.status;
      var nextMessage = current.message;
      if (nextAutoRequired && current.status == 'Paused') {
        nextStatus = 'Auto';
        nextMessage = 'Required automatically by table dependency.';
      } else if (!nextAutoRequired &&
          current.autoRequired &&
          current.status == 'Auto') {
        nextStatus = 'Paused';
        nextMessage = 'Remote sync disabled.';
      }
      nextTables[syncKey] = current.copyWith(
        autoRequired: nextAutoRequired,
        status: nextStatus,
        message: nextMessage,
      );
    }
    return nextTables;
  }

  void _refreshAutoRequiredTables() {
    final nextTables = _nextTablesWithAutoRequired(_syncState.tables);
    if (_syncState.tables.length == nextTables.length) {
      var changed = false;
      for (final entry in nextTables.entries) {
        final current = _syncState.tables[entry.key];
        if (current == null || !_syncTableStatesEqual(current, entry.value)) {
          changed = true;
          break;
        }
      }
      if (!changed) {
        return;
      }
    }
    _replaceSyncState(_syncState.copyWith(tables: nextTables));
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
      });
      return;
    }

    final selectedDatabase = resolveSavedDatabaseSelection(
      saved: preserveSelection ? _selectedDatabase : null,
      available: result.values,
      defaultDatabase: _preferredDatabase(result.values),
    );

    setState(() {
      _databases = result.values;
      _selectedDatabase = selectedDatabase;
      if (selectedDatabase != previousDatabase) {
        _selectedTable = null;
      }
      _sortColumnIndex = null;
    });
    if (selectedDatabase != previousDatabase && selectedDatabase != null) {
      widget.onDatabaseChanged(selectedDatabase);
    }

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
      _localRelatedSyncTables = const {};
      _relatedSyncTables = const {};
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

    final relationships = await _queryTableRelationships(
      profile: profile,
      database: database,
      tables: result.values,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _localRelatedSyncTables = relationships;
      _relatedSyncTables = _mergeRelationshipGraphs([relationships]);
      _refreshVisibleTablesForSelectedDatabaseInState();
    });
    _refreshAutoRequiredTables();

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
    unawaited(_queryChangeTrackingDiagnostics());
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
      _localRelatedSyncTables = const {};
      _relatedSyncTables = const {};
    });
    widget.onDatabaseChanged(database);

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
      _retryAutomaticClientUpdateIfReady();
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
    _retryAutomaticClientUpdateIfReady();
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

  Future<void> _refreshLocalRowCounts() async {
    final database = _selectedDatabase;
    if (database == null || _rowCountsRefreshing) {
      return;
    }

    final tables = _stableVisibleTablesForDatabase(database, _tables);
    if (tables.isEmpty) {
      return;
    }

    setState(() {
      _rowCountsRefreshing = true;
      _errorMessage = null;
    });

    try {
      final rowCounts = await _queryTableRowCounts(
        profile: _activeProfile(),
        database: database,
        tables: tables,
      );
      if (!mounted) {
        return;
      }
      _applyTableRowCounts(database: database, rowCounts: rowCounts);
      final selectedTable = _selectedTable;
      if (selectedTable != null && rowCounts.containsKey(selectedTable)) {
        setState(() {
          _totalTableRows = rowCounts[selectedTable]!;
        });
      }
      _refreshTableDataDialog();
      unawaited(_syncWithControlPlane());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _rowCountsRefreshing = false;
        });
      }
    }
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
    final tableNames = _boundedHeartbeatTableNames();

    // Heartbeats only need live table metadata. Keep local history details
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

  List<String> _boundedHeartbeatTableNames() {
    final ordered = <String>[];
    final seen = <String>{};

    void addTableName(String table) {
      final trimmed = table.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        return;
      }
      ordered.add(trimmed);
    }

    if (_selectedTable != null) {
      addTableName(_syncTableKey(_selectedTable!));
    }
    for (final job in _activeJobs) {
      addTableName(job.table);
    }
    for (final entry in _syncState.tables.entries) {
      if (entry.value.enabled) {
        addTableName(entry.key);
      }
    }
    for (final table in _syncState.tables.keys) {
      addTableName(table);
      if (ordered.length >= _heartbeatTablePayloadLimit) {
        break;
      }
    }
    if (ordered.length < _heartbeatTablePayloadLimit) {
      for (final table in _tables) {
        addTableName(_syncTableKey(table));
        if (ordered.length >= _heartbeatTablePayloadLimit) {
          break;
        }
      }
    }
    if (ordered.length <= _heartbeatTablePayloadLimit) {
      return ordered;
    }
    return ordered.sublist(0, _heartbeatTablePayloadLimit);
  }

  List<Map<String, String>> _tableRelationshipsPayload() {
    final relationships = <Map<String, String>>[];
    final seen = <String>{};
    for (final entry in _localRelatedSyncTables.entries) {
      final table = entry.key.trim();
      if (table.isEmpty) {
        continue;
      }
      for (final relatedTable in entry.value) {
        final related = relatedTable.trim();
        if (related.isEmpty || related == table) {
          continue;
        }
        final signature = '$table\u0000$related';
        if (!seen.add(signature)) {
          continue;
        }
        relationships.add({
          'table': table,
          'relatedTable': related,
          'relationshipType': 'foreignKey',
        });
      }
    }
    return relationships;
  }

  Map<String, Set<String>> _mergeRelationshipGraphs(
    Iterable<Map<String, Set<String>>> graphs,
  ) {
    final merged = <String, Set<String>>{};
    for (final graph in graphs) {
      for (final entry in graph.entries) {
        final table = entry.key.trim();
        if (table.isEmpty) {
          continue;
        }
        for (final relatedTable in entry.value) {
          final related = relatedTable.trim();
          if (related.isEmpty || related == table) {
            continue;
          }
          merged.putIfAbsent(table, () => <String>{}).add(related);
        }
      }
    }
    return merged;
  }

  Map<String, Set<String>> _relationshipGraphFromRemoteDependencies(
    List<RemoteTableDependency> dependencies,
  ) {
    final graph = <String, Set<String>>{};
    for (final dependency in dependencies) {
      final table = dependency.table.trim();
      final related = dependency.relatedTable.trim();
      if (table.isEmpty || related.isEmpty || table == related) {
        continue;
      }
      graph.putIfAbsent(table, () => <String>{}).add(related);
    }
    return graph;
  }

  String _displayStatus(String status) {
    if (status.isEmpty) {
      return 'Idle';
    }
    final normalizedStatus = status.trim().toLowerCase();
    if (normalizedStatus == 'snapshotting' ||
        normalizedStatus == 'uploading' ||
        normalizedStatus == 'downloading') {
      return 'Applying';
    }
    final normalized = status.replaceAll('_', ' ').trim();
    return normalized.isEmpty
        ? 'Idle'
        : normalized[0].toUpperCase() + normalized.substring(1);
  }

  void _applyRemoteJobState(
    RemoteSyncJob job, {
    bool appendHistory = false,
    bool success = true,
    String? overrideMessage,
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
    final timestamp = job.completedAt ?? job.updatedAt;
    final nextStatus = _displayStatus(job.status);
    final nextMessage = overrideMessage ?? job.error ?? job.message;
    final shouldApplyLocalRowCount =
        success && job.status.trim().toLowerCase() == 'completed';
    final nextRowCount =
        shouldApplyLocalRowCount ? job.rowCount : current.rowCount;
    final nextState = current.copyWith(
      enabled: current.enabled,
      status: nextStatus,
      lastSync: timestamp.trim().isEmpty ? current.lastSync : timestamp,
      progress: job.progress,
      rowCount: nextRowCount,
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
                  rowCount: job.rowCount,
                  progress: job.progress,
                ),
              )
              : current.history,
    );
    _updateSyncTableState(job.table, nextState);
    _updateTraySyncIndicator();
  }

  void _updateTraySyncIndicator() {
    if (!Platform.isWindows) {
      return;
    }

    final trayProgress = calculateTraySyncProgress(
      syncLoopBusy: _syncLoopBusy,
      processingJobCount: _processingJobIds.length,
      jobs: _activeJobs,
    );
    if (trayProgress.active == _lastTrayProgressActive &&
        trayProgress.progress == _lastTrayProgressValue &&
        trayProgress.status == _lastTrayProgressStatus) {
      return;
    }
    _lastTrayProgressActive = trayProgress.active;
    _lastTrayProgressValue = trayProgress.progress;
    _lastTrayProgressStatus = trayProgress.status;
    unawaited(
      WindowsAgentWindowSettings.setTrayProgress(
        active: trayProgress.active,
        progress: trayProgress.progress,
        status: trayProgress.status,
      ).catchError((error) {
        logStartupEvent('Tray progress update failed: $error');
      }),
    );
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

  bool get _hasClientUpdate {
    final updateInfo = _clientUpdateInfo;
    if (updateInfo == null) {
      return false;
    }
    final currentVersion = _agentAppVersion.trim();
    final latestVersion = updateInfo.version.trim();
    final currentCommit = _agentBuildCommitHash.trim().toLowerCase();
    final latestCommit = updateInfo.commit.trim().toLowerCase();
    if (latestVersion.isNotEmpty &&
        currentVersion.isNotEmpty &&
        latestVersion != currentVersion) {
      return true;
    }
    if (latestCommit.isNotEmpty && currentCommit.isNotEmpty) {
      return latestCommit != currentCommit;
    }
    return latestVersion.isNotEmpty && latestVersion != currentVersion;
  }

  String _clientUpdateLabel() {
    final updateInfo = _clientUpdateInfo;
    if (_applyingClientUpdate) {
      return 'Installing';
    }
    if (_checkingClientUpdate) {
      return 'Checking';
    }
    if (_hasClientUpdate && updateInfo != null) {
      return 'Available v${updateInfo.version}';
    }
    if (_clientUpdateError != null) {
      return 'Check failed';
    }
    return 'Current';
  }

  String _clientUpdateManifestUrl() {
    final overrideBaseUrl =
        (Platform.environment['CLIENT_UPDATE_BASE_URL'] ??
                _clientUpdateBaseUrlOverride)
            .trim();
    if (overrideBaseUrl.isNotEmpty && !_isLocalHttpUrl(overrideBaseUrl)) {
      final normalizedBaseUrl =
          overrideBaseUrl.endsWith('/')
              ? overrideBaseUrl.substring(0, overrideBaseUrl.length - 1)
              : overrideBaseUrl;
      return '$normalizedBaseUrl/latest.json';
    }
    final manifestUrl = _controlPlaneClient.baseUrl.replaceFirst(
      RegExp(r'/call/?$'),
      '/client/latest.json',
    );
    if (_isLocalHttpUrl(manifestUrl)) {
      return '$_liveClientUpdateBaseUrl/latest.json';
    }
    return manifestUrl;
  }

  bool _isLocalHttpUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '0.0.0.0' ||
        uri?.port == 6006;
  }

  String _clientUpdateScriptUrl(ClientUpdateInfo updateInfo) {
    final scriptUrl = updateInfo.updateScriptUrl.trim();
    if (scriptUrl.isNotEmpty) {
      return scriptUrl;
    }
    return _clientUpdateManifestUrl().replaceFirst(
      '/latest.json',
      '/update.ps1',
    );
  }

  String _clientUpdateTargetId(ClientUpdateInfo updateInfo) {
    final version = updateInfo.version.trim();
    final commit = updateInfo.commit.trim().toLowerCase();
    final hash = updateInfo.sha256.trim().toLowerCase();
    return [version, commit, hash].where((part) => part.isNotEmpty).join('@');
  }

  bool _hasRecentAutoUpdateAttempt(String targetId) {
    final lastTarget = widget.lastAutoUpdateTarget?.trim() ?? '';
    if (targetId.isEmpty || lastTarget != targetId) {
      return false;
    }

    final attemptedAtRaw = widget.lastAutoUpdateAttemptedAt?.trim() ?? '';
    if (attemptedAtRaw.isEmpty) {
      return false;
    }

    final attemptedAt = DateTime.tryParse(attemptedAtRaw);
    if (attemptedAt == null) {
      return false;
    }

    return DateTime.now().difference(attemptedAt.toLocal()) <
        _autoUpdateRetryCooldown;
  }

  bool get _supportsAutomaticClientUpdate {
    if (!Platform.isWindows) {
      return false;
    }
    final executablePath =
        Platform.resolvedExecutable.replaceAll('/', r'\').toLowerCase();
    return !executablePath.contains(r'\build\windows\x64\runner\debug\');
  }

  String _powershellSingleQuoted(String value) => value.replaceAll("'", "''");

  String? _localClientUpdateScriptPath() {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final updateScript = File(path.join(executableDir.path, 'update.ps1'));
    if (!updateScript.existsSync()) {
      return null;
    }
    return updateScript.path.replaceAll('/', r'\');
  }

  List<String> _clientUpdatePowerShellArgs(ClientUpdateInfo updateInfo) {
    final manifestUrl = _clientUpdateManifestUrl();
    final scriptUrl = _clientUpdateScriptUrl(updateInfo);
    final installDir = File(
      Platform.resolvedExecutable,
    ).parent.path.replaceAll('/', r'\');
    final localScriptPath = _localClientUpdateScriptPath();
    if (scriptUrl.isNotEmpty) {
      return <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-Command',
        "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing "
            "-Uri '${_powershellSingleQuoted(scriptUrl)}').Content)) "
            "-ManifestUrl '${_powershellSingleQuoted(manifestUrl)}' "
            "-InstallDir '${_powershellSingleQuoted(installDir)}'",
      ];
    }
    if (localScriptPath != null) {
      return <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        localScriptPath,
        '-ManifestUrl',
        manifestUrl,
        '-InstallDir',
        installDir,
      ];
    }
    return <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-Command',
      "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing "
          "-Uri '${_powershellSingleQuoted(scriptUrl)}').Content)) "
          "-ManifestUrl '${_powershellSingleQuoted(manifestUrl)}' "
          "-InstallDir '${_powershellSingleQuoted(installDir)}'",
    ];
  }

  void _retryAutomaticClientUpdateIfReady() {
    final forcedUpdateInfo = _pendingForcedClientUpdateInfo;
    if (forcedUpdateInfo != null) {
      _pendingForcedClientUpdateInfo = null;
      unawaited(_maybeAutoApplyClientUpdate(forcedUpdateInfo, force: true));
      return;
    }
    final updateInfo = _clientUpdateInfo;
    if (updateInfo == null) {
      return;
    }
    unawaited(_maybeAutoApplyClientUpdate(updateInfo));
  }

  Future<void> _maybeAutoApplyClientUpdate(
    ClientUpdateInfo updateInfo, {
    bool force = false,
  }) async {
    if (!mounted || !_hasClientUpdate || !_supportsAutomaticClientUpdate) {
      return;
    }
    if (_applyingClientUpdate || _checkingClientUpdate) {
      if (force) {
        _pendingForcedClientUpdateInfo = updateInfo;
      }
      return;
    }

    final targetId = _clientUpdateTargetId(updateInfo);
    if (targetId.isEmpty) {
      return;
    }
    if (!force && _hasRecentAutoUpdateAttempt(targetId)) {
      return;
    }
    if (!force &&
        (_syncLoopBusy ||
            _rowsLoading ||
            _processingJobIds.isNotEmpty ||
            _activeJobs.any(
              (job) => job.status == 'running' || job.status == 'applying',
            ))) {
      return;
    }

    final manifestUrl = _clientUpdateManifestUrl();
    final psArgs = _clientUpdatePowerShellArgs(updateInfo);

    try {
      setState(() {
        _applyingClientUpdate = true;
        _clientUpdateError = null;
      });
      await widget.onAutoUpdateAttempted(targetId);
      logStartupEvent(
        'Applying client update automatically: $targetId from $manifestUrl force=$force',
      );
      final updaterCommandLine = [
        'start',
        '""',
        '/min',
        'powershell.exe',
        ...psArgs,
      ];
      await Process.start('cmd.exe', [
        '/c',
        ...updaterCommandLine,
      ], mode: ProcessStartMode.detached);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: SelectableText(
            'Installing client update v${updateInfo.version}. The agent will restart automatically.',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (mounted) {
        exit(0);
      }
    } catch (error) {
      logStartupEvent('Automatic client update failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _applyingClientUpdate = false;
        _clientUpdateError = error.toString();
      });
    }
  }

  String _clientUpdateCommand(ClientUpdateInfo updateInfo) {
    final manifestUrl = _clientUpdateManifestUrl();
    final scriptUrl = _clientUpdateScriptUrl(updateInfo);
    final installDir = File(
      Platform.resolvedExecutable,
    ).parent.path.replaceAll('/', r'\');
    final localScriptPath = _localClientUpdateScriptPath();
    if (scriptUrl.isNotEmpty) {
      return "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri '$scriptUrl').Content)) -ManifestUrl '$manifestUrl' -InstallDir '$installDir'\"";
    }
    if (localScriptPath != null) {
      return "powershell -ExecutionPolicy Bypass -NoProfile -File '$localScriptPath' -ManifestUrl '$manifestUrl' -InstallDir '$installDir'";
    }
    return "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri '$scriptUrl').Content)) -ManifestUrl '$manifestUrl' -InstallDir '$installDir'\"";
  }

  Future<void> _showClientUpdateDialog() async {
    final updateInfo = _clientUpdateInfo;
    if (updateInfo == null) {
      await _checkClientUpdate(showErrors: true);
      return;
    }
    final command = _clientUpdateCommand(updateInfo);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              _hasClientUpdate
                  ? 'Client update available'
                  : 'Client is current',
            ),
            content: SelectableText(
              [
                'Current: ${_buildSummaryLabel()}',
                'Latest: v${updateInfo.version} ${updateInfo.commit}',
                if (_supportsAutomaticClientUpdate)
                  'Automatic installation is enabled when the agent is idle.',
                if (updateInfo.releaseDate.trim().isNotEmpty)
                  'Released: ${_formatTimestamp(updateInfo.releaseDate)}',
                if (updateInfo.sizeBytes > 0)
                  'Download: ${_formatBytes(updateInfo.sizeBytes)}',
                '',
                'Run this command on the client machine:',
                command,
              ].join('\n'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: command));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Update command copied.')),
                  );
                },
                child: const Text('Copy command'),
              ),
              FilledButton(
                onPressed:
                    () => unawaited(_checkClientUpdate(showErrors: true)),
                child: const Text('Check again'),
              ),
            ],
          ),
    );
  }

  String _syncFlowLabel() {
    return 'Snapshot sync';
  }

  IconData _syncFlowIcon() {
    return Icons.sync_rounded;
  }

  Color _syncFlowColor() {
    return const Color(0xFF0F766E);
  }

  String _syncFlowDescription() {
    return 'Upload local rows and insert only missing cloud rows.';
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
        return 'Preparing: writing sync metadata.';
      case 'Uploading':
        return 'Uploading: sending local table changes.';
      case 'Downloading':
        return 'Downloading: receiving remote table changes.';
      case 'Applying':
        return 'Applying: waiting for background processing.';
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

  Set<String> _applyRemoteSyncSettings(RemoteAgentSyncSettings settings) {
    _applyHistoryLimit(settings.historyLimit);
    _applyAutoSyncInterval(settings.autoSyncIntervalMinutes);
    return <String>{};
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
          policy.enabled ? 'Waiting for the next sync.' : 'Sync disabled.';
      final nextState = current.copyWith(
        enabled: policy.enabled,
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
      _replaceSyncState(
        _syncState.copyWith(tables: _nextTablesWithAutoRequired(nextTables)),
      );
    } else {
      _refreshAutoRequiredTables();
    }
    return newlyEnabled;
  }

  bool _syncTableStatesEqual(SyncTableState left, SyncTableState right) {
    return left.enabled == right.enabled &&
        left.autoRequired == right.autoRequired &&
        left.status == right.status &&
        left.lastSync == right.lastSync &&
        left.progress == right.progress &&
        left.rowCount == right.rowCount &&
        left.tableChecksum == right.tableChecksum &&
        left.message == right.message;
  }

  Widget _buildSyncFlowBadge({bool showLabel = true}) {
    final color = _syncFlowColor();
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
          Icon(_syncFlowIcon(), size: 16, color: color),
          if (showLabel) ...[
            const SizedBox(width: 6),
            Text(
              _syncFlowLabel(),
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
          tooltip:
              _rowCountsRefreshing
                  ? 'Refreshing local row counts'
                  : 'Refresh local row counts',
          icon: Icons.refresh_rounded,
          onPressed:
              _selectedDatabase == null || _rowCountsRefreshing
                  ? null
                  : () => unawaited(_refreshLocalRowCounts()),
        ),
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

  Future<void> _refreshSelectedTableFingerprints() async {
    final tablesByDatabase = <String, List<String>>{};
    for (final entry in _syncState.tables.entries) {
      if (!_isTableSelectedForSync(entry.value)) {
        continue;
      }
      final database = _databaseNameFromSyncKey(entry.key).trim();
      final table = _localTableName(entry.key).trim();
      if (database.isEmpty || table.isEmpty) {
        continue;
      }
      tablesByDatabase.putIfAbsent(database, () => <String>[]).add(table);
    }
    if (tablesByDatabase.isEmpty) {
      return;
    }
    final profile = _activeProfile();
    for (final entry in tablesByDatabase.entries) {
      final fingerprints = await _queryTableFingerprints(
        profile: profile,
        database: entry.key,
        tables: entry.value,
      );
      if (!mounted) {
        return;
      }
      _applyTableFingerprints(database: entry.key, fingerprints: fingerprints);
    }
  }

  void _scheduleSelectedTableFingerprintRefresh({bool force = false}) {
    if (!mounted || _refreshingTableFingerprints) {
      return;
    }
    final lastStartedAt = _lastTableFingerprintRefreshStartedAt;
    if (!force &&
        lastStartedAt != null &&
        DateTime.now().difference(lastStartedAt) <
            _tableFingerprintRefreshCooldown) {
      return;
    }

    _refreshingTableFingerprints = true;
    _lastTableFingerprintRefreshStartedAt = DateTime.now();
    unawaited(
      _refreshSelectedTableFingerprints()
          .catchError((Object error, StackTrace stackTrace) {
            logStartupEvent(
              'Selected table fingerprint refresh failed: $error',
            );
          })
          .whenComplete(() {
            _refreshingTableFingerprints = false;
          }),
    );
  }

  bool _isTemporaryControlPlaneUnavailable(Object error) {
    return error is AgentControlPlaneException && error.statusCode == 503;
  }

  bool _matchesPendingWindowActionAck(RemoteAgentWindowAction windowAction) {
    final pendingAck = _pendingWindowActionAck;
    if (pendingAck == null) {
      return false;
    }
    final requestId = windowAction.requestId?.trim() ?? '';
    final action = windowAction.action?.trim().toLowerCase() ?? '';
    return requestId == pendingAck.requestId && action == pendingAck.action;
  }

  Future<void> _flushPendingWindowActionAck() async {
    final pendingAck = _pendingWindowActionAck;
    if (pendingAck == null || _flushingPendingWindowActionAck) {
      return;
    }
    _flushingPendingWindowActionAck = true;
    try {
      await _controlPlaneClient.acknowledgeWindowAction(
        clientName: widget.clientName,
        requestId: pendingAck.requestId,
        action: pendingAck.action,
        status: pendingAck.status,
        message: pendingAck.message,
      );
      if (_pendingWindowActionAck?.requestId == pendingAck.requestId) {
        _pendingWindowActionAck = null;
      }
    } catch (error) {
      logStartupEvent('Window action acknowledgement retry failed: $error');
    } finally {
      _flushingPendingWindowActionAck = false;
    }
  }

  Future<void> _queueWindowActionAck({
    required String requestId,
    required String action,
    required String status,
    required String message,
  }) async {
    _pendingWindowActionAck = _PendingWindowActionAck(
      requestId: requestId,
      action: action,
      status: status,
      message: message,
    );
    await _flushPendingWindowActionAck();
  }

  Future<void> _syncWithControlPlane() async {
    if (!mounted || _syncLoopBusy) {
      return;
    }

    _syncLoopBusy = true;
    _updateTraySyncIndicator();
    try {
      _scheduleSelectedTableFingerprintRefresh();
      final heartbeat = await _controlPlaneClient.heartbeat(
        clientName: widget.clientName,
        machineName: Platform.localHostname,
        historyLimit: _syncState.historyLimit,
        autoSyncIntervalMinutes: _syncState.autoSyncIntervalMinutes,
        server: _serverController.text.trim(),
        database: _selectedDatabase ?? '',
        replicationUseWindowsAuth: _useWindowsAuth,
        replicationUser: _userController.text.trim(),
        replicationPassword: _passwordController.text,
        serverConnected: _serverConnected,
        sqlConnected: _selectedDatabase != null,
        selectedTable:
            _selectedTable == null ? null : _syncTableKey(_selectedTable!),
        tables: _heartbeatTablesPayload(),
        tableRelationships: _tableRelationshipsPayload(),
        clientVersion: _agentAppVersion,
      );

      if (!mounted) {
        return;
      }

      final remoteRelationships = _relationshipGraphFromRemoteDependencies(
        heartbeat.tableDependencies,
      );
      _applyRemoteSyncSettings(heartbeat.syncSettings);
      _applyRemoteTablePolicies(heartbeat.tablePolicies);
      if (!mounted) {
        return;
      }

      setState(() {
        _serverConnected = true;
        _checkingServerConnection = false;
        _lastServerCheck = DateTime.now();
        _relatedSyncTables = _mergeRelationshipGraphs([
          _localRelatedSyncTables,
          remoteRelationships,
        ]);
        _remoteTableDependencies = heartbeat.tableDependencies;
        _activeJobs = heartbeat.jobs;
        _refreshVisibleTablesForSelectedDatabaseInState();
      });

      _scheduleRequestedDiagnosticsUpload(heartbeat.diagnostics);

      await _flushPendingWindowActionAck();

      if (heartbeat.windowAction.pending) {
        if (_matchesPendingWindowActionAck(heartbeat.windowAction)) {
          await _flushPendingWindowActionAck();
        } else {
          await _handleRequestedWindowAction(heartbeat.windowAction);
        }
      }

      if (heartbeat.clientUpdate.pending) {
        await _handleRequestedClientUpdate(heartbeat.clientUpdate);
      }

      for (final job in heartbeat.jobs) {
        _applyRemoteJobState(job);
      }

      _refreshAutoRequiredTables();

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
      _updateTraySyncIndicator();
      _retryAutomaticClientUpdateIfReady();
    }
  }

  Future<void> _uploadRequestedDiagnostics(
    RemoteAgentDiagnostics diagnostics,
  ) async {
    final payload = await _buildDiagnosticsPayload();
    final failedTableCount =
        _syncState.tables.values
            .where((table) => table.status.toLowerCase() == 'failed')
            .length;
    final summary =
        'Machine ${Platform.localHostname}, database ${_selectedDatabase ?? 'not selected'}, '
        'failed tables $failedTableCount, active jobs ${_activeJobs.length}, '
        'server connected ${_serverConnected ? 'yes' : 'no'}, sql connected ${_selectedDatabase != null ? 'yes' : 'no'}.';

    await _controlPlaneClient.uploadDiagnostics(
      clientName: widget.clientName,
      requestId: diagnostics.requestId,
      summary: summary,
      payload: payload,
    );
    logStartupEvent(
      'Uploaded diagnostics for ${widget.clientName} request ${diagnostics.requestId ?? 'manual'}.',
    );
  }

  void _scheduleRequestedDiagnosticsUpload(RemoteAgentDiagnostics diagnostics) {
    if (!diagnostics.pending || _diagnosticsUploadBusy) {
      return;
    }
    final requestId = diagnostics.requestId?.trim() ?? '';
    if (requestId.isNotEmpty && _diagnosticsUploadRequestId == requestId) {
      return;
    }

    _diagnosticsUploadBusy = true;
    _diagnosticsUploadRequestId = requestId.isEmpty ? null : requestId;
    unawaited(
      _uploadRequestedDiagnostics(diagnostics)
          .catchError((Object error, StackTrace stackTrace) {
            logStartupEvent('Diagnostics upload failed: $error');
            if (requestId.isNotEmpty &&
                _diagnosticsUploadRequestId == requestId) {
              _diagnosticsUploadRequestId = null;
            }
          })
          .whenComplete(() {
            _diagnosticsUploadBusy = false;
          }),
    );
  }

  Future<void> _handleRequestedWindowAction(
    RemoteAgentWindowAction windowAction,
  ) async {
    final requestId = windowAction.requestId?.trim() ?? '';
    final action = windowAction.action?.trim().toLowerCase() ?? '';
    if (requestId.isEmpty || action.isEmpty) {
      return;
    }

    try {
      switch (action) {
        case 'minimize':
          logStartupEvent(
            'Server requested window action $requestId for ${widget.clientName}: minimize.',
          );
          await WindowsAgentWindowSettings.minimizeWindow();
          await _queueWindowActionAck(
            requestId: requestId,
            action: action,
            status: 'completed',
            message: 'Window minimized to tray.',
          );
          return;
        default:
          await _queueWindowActionAck(
            requestId: requestId,
            action: action,
            status: 'failed',
            message: 'Unsupported window action $action.',
          );
      }
    } catch (error) {
      logStartupEvent('Server-requested window action failed: $error');
      try {
        await _queueWindowActionAck(
          requestId: requestId,
          action: action,
          status: 'failed',
          message: error.toString(),
        );
      } catch (ackError) {
        logStartupEvent(
          'Window action failure acknowledgement failed: $ackError',
        );
      }
    }
  }

  Future<void> _handleRequestedClientUpdate(
    RemoteAgentClientUpdate clientUpdate,
  ) async {
    final requestId = clientUpdate.requestId?.trim() ?? '';
    if (requestId.isEmpty) {
      return;
    }

    if (!_supportsAutomaticClientUpdate) {
      try {
        await _controlPlaneClient.acknowledgeClientUpdate(
          clientName: widget.clientName,
          requestId: requestId,
          status: 'unsupported',
          installedVersion: _agentAppVersion,
          message:
              'Automatic client updates are unavailable in this runtime. Start the packaged Windows client to apply live updates.',
        );
      } catch (error) {
        logStartupEvent(
          'Server-requested client update unsupported acknowledgement failed: $error',
        );
      }
      return;
    }

    try {
      final updateInfo = await _controlPlaneClient.fetchClientUpdateInfo(
        manifestUrl: _clientUpdateManifestUrl(),
      );
      if (updateInfo == null) {
        await _controlPlaneClient.acknowledgeClientUpdate(
          clientName: widget.clientName,
          requestId: requestId,
          status: 'failed',
          installedVersion: _agentAppVersion,
          message: 'No live client update manifest is available on the server.',
        );
        return;
      }

      final targetVersion = clientUpdate.targetVersion?.trim() ?? '';
      final manifestVersion = updateInfo.version.trim();
      if (targetVersion.isNotEmpty && manifestVersion != targetVersion) {
        await _controlPlaneClient.acknowledgeClientUpdate(
          clientName: widget.clientName,
          requestId: requestId,
          status: 'failed',
          installedVersion: _agentAppVersion,
          message:
              'Requested version $targetVersion is not the current live version $manifestVersion.',
        );
        return;
      }

      final currentVersion = _agentAppVersion.trim();
      if (currentVersion.isNotEmpty && currentVersion == manifestVersion) {
        await _controlPlaneClient.acknowledgeClientUpdate(
          clientName: widget.clientName,
          requestId: requestId,
          status: 'current',
          installedVersion: currentVersion,
          message: 'Client already matches live version $manifestVersion.',
        );
        return;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _clientUpdateInfo = updateInfo;
        _clientUpdateError = null;
      });
      logStartupEvent(
        'Server requested client update $requestId for ${widget.clientName}; live version=$manifestVersion current=${currentVersion.isEmpty ? 'unknown' : currentVersion}.',
      );
      if (_syncLoopBusy) {
        _pendingForcedClientUpdateInfo = updateInfo;
        return;
      }
      await _maybeAutoApplyClientUpdate(updateInfo, force: true);
    } catch (error) {
      logStartupEvent('Server-requested client update failed: $error');
      try {
        await _controlPlaneClient.acknowledgeClientUpdate(
          clientName: widget.clientName,
          requestId: requestId,
          status: 'failed',
          installedVersion: _agentAppVersion,
          message: error.toString(),
        );
      } catch (_) {}
    }
  }

  Future<String> _buildDiagnosticsPayload() async {
    final failedTables = _syncState.tables.entries
        .where((entry) => entry.value.status.toLowerCase() == 'failed')
        .take(25)
        .map(
          (entry) => {
            'table': entry.key,
            'status': entry.value.status,
            'lastSync': entry.value.lastSync,
            'progress': entry.value.progress,
            'rowCount': entry.value.rowCount,
            'tableChecksum': entry.value.tableChecksum,
            'changeTrackingStatus': entry.value.changeTrackingStatus,
            'changeTrackingMessage': entry.value.changeTrackingMessage,
            'message': entry.value.message,
          },
        )
        .toList(growable: false);
    final activeJobs = _activeJobs
        .take(25)
        .map(
          (job) => {
            'id': job.id,
            'table': job.table,
            'direction': job.direction,
            'status': job.status,
            'progress': job.progress,
            'message': job.message,
            'error': job.error,
            'updatedAt': job.updatedAt,
          },
        )
        .toList(growable: false);
    final tableSummaries = _syncState.tables.entries
        .take(50)
        .map(
          (entry) => {
            'table': entry.key,
            'enabled': entry.value.enabled,
            'status': entry.value.status,
            'lastSync': entry.value.lastSync,
            'progress': entry.value.progress,
            'rowCount': entry.value.rowCount,
            'tableChecksum': entry.value.tableChecksum,
            'changeTrackingStatus': entry.value.changeTrackingStatus,
            'changeTrackingMessage': entry.value.changeTrackingMessage,
            'message': entry.value.message,
          },
        )
        .toList(growable: false);

    final changeTracking = await _buildChangeTrackingDiagnosticsForUpload();

    final payload = <String, dynamic>{
      'capturedAt': DateTime.now().toIso8601String(),
      'clientName': widget.clientName,
      'machineName': Platform.localHostname,
      'app': {
        'version': _agentAppVersion,
        'buildCommitHash': _agentBuildCommitHash,
        'buildReleaseDate': _agentBuildReleaseDate,
      },
      'account': {
        'username': widget.authenticatedAccountUsername,
        'email': widget.authenticatedAccountEmail,
        'name': widget.authenticatedAccountName,
      },
      'controlPlane': {
        'baseUrl': _controlPlaneClient.baseUrl,
        'serverConnected': _serverConnected,
        'checkingServerConnection': _checkingServerConnection,
        'lastServerCheck': _lastServerCheck?.toIso8601String(),
      },
      'sql': {
        'server': _serverController.text.trim(),
        'database': _selectedDatabase,
        'selectedTable':
            _selectedTable == null ? null : _syncTableKey(_selectedTable!),
        'databaseCount': _databases.length,
        'tableCount': _tables.length,
        'changeTracking': changeTracking,
      },
      'syncSettings': {
        'historyLimit': _syncState.historyLimit,
        'autoSyncIntervalMinutes': _syncState.autoSyncIntervalMinutes,
      },
      'errors': {
        'errorMessage': _errorMessage,
        'lastSqlCmdLaunchError': _lastSqlCmdLaunchError,
      },
      'activeJobs': activeJobs,
      'failedTables': failedTables,
      'tableSummaries': tableSummaries,
      'startupLogTail': _readStartupLogTail(),
    };

    return _encodeDiagnosticsPayloadForUpload(payload);
  }

  Future<Map<String, dynamic>>
  _buildChangeTrackingDiagnosticsForUpload() async {
    try {
      final diagnostics = await _queryChangeTrackingDiagnostics().timeout(
        _diagnosticsChangeTrackingTimeout,
      );
      final compact = _compactChangeTrackingDiagnosticsForUpload(diagnostics);
      compact['captureStatus'] = 'completed';
      return compact;
    } on TimeoutException {
      return <String, dynamic>{
        'captureStatus': 'timeout',
        'message':
            'Change tracking diagnostics exceeded ${_diagnosticsChangeTrackingTimeout.inSeconds} seconds and were skipped.',
      };
    } catch (error) {
      return <String, dynamic>{
        'captureStatus': 'error',
        'message': error.toString(),
      };
    }
  }

  String _encodeDiagnosticsPayloadForUpload(Map<String, dynamic> payload) {
    String encode(Map<String, dynamic> value) => jsonEncode(value);

    var encoded = encode(payload);
    if (encoded.length <= _maxDiagnosticsUploadPayloadChars) {
      return encoded;
    }

    final reduced = Map<String, dynamic>.from(payload);
    reduced['activeJobs'] = _boundedUploadList(
      reduced['activeJobs'],
      maxItems: 10,
    );
    reduced['failedTables'] = _boundedUploadList(
      reduced['failedTables'],
      maxItems: 10,
    );
    reduced['tableSummaries'] = _boundedUploadList(
      reduced['tableSummaries'],
      maxItems: 20,
    );
    reduced['startupLogTail'] = _truncateUploadText(
      reduced['startupLogTail'],
      maxChars: 4000,
    );
    _compactChangeTrackingDatabasesForUpload(reduced, maxDatabases: 8);
    encoded = encode(reduced);
    if (encoded.length <= _maxDiagnosticsUploadPayloadChars) {
      return encoded;
    }

    final minimal = Map<String, dynamic>.from(reduced);
    minimal['activeJobs'] = _boundedUploadList(
      minimal['activeJobs'],
      maxItems: 5,
    );
    minimal['failedTables'] = _boundedUploadList(
      minimal['failedTables'],
      maxItems: 5,
    );
    minimal['tableSummaries'] = _boundedUploadList(
      minimal['tableSummaries'],
      maxItems: 10,
    );
    minimal['startupLogTail'] = _truncateUploadText(
      minimal['startupLogTail'],
      maxChars: 2000,
    );
    _compactChangeTrackingDatabasesForUpload(minimal, maxDatabases: 3);
    encoded = encode(minimal);
    if (encoded.length <= _maxDiagnosticsUploadPayloadChars) {
      return encoded;
    }

    final emergency = <String, dynamic>{
      'capturedAt': payload['capturedAt'],
      'clientName': payload['clientName'],
      'machineName': payload['machineName'],
      'app': payload['app'],
      'controlPlane': payload['controlPlane'],
      'sql': _minimalSqlDiagnosticsForUpload(payload['sql']),
      'syncSettings': payload['syncSettings'],
      'errors': payload['errors'],
      'activeJobs': _boundedUploadList(payload['activeJobs'], maxItems: 3),
      'failedTables': _boundedUploadList(payload['failedTables'], maxItems: 3),
      'tableSummaries': _boundedUploadList(
        payload['tableSummaries'],
        maxItems: 5,
      ),
      'startupLogTail': _truncateUploadText(
        payload['startupLogTail'],
        maxChars: 1000,
      ),
      'payloadReduced': true,
    };
    return encode(emergency);
  }

  List<dynamic> _boundedUploadList(dynamic value, {required int maxItems}) {
    if (value is! List || maxItems < 1) {
      return const <dynamic>[];
    }
    if (value.length <= maxItems) {
      return List<dynamic>.from(value, growable: false);
    }
    return List<dynamic>.from(value.take(maxItems), growable: false);
  }

  String _truncateUploadText(dynamic value, {required int maxChars}) {
    final text = value?.toString() ?? '';
    if (text.length <= maxChars) {
      return text;
    }
    return text.substring(text.length - maxChars);
  }

  void _compactChangeTrackingDatabasesForUpload(
    Map<String, dynamic> payload, {
    required int maxDatabases,
  }) {
    final sql = payload['sql'];
    if (sql is! Map) {
      return;
    }
    final nextSql = Map<String, dynamic>.from(sql);
    final changeTracking = nextSql['changeTracking'];
    if (changeTracking is! Map) {
      payload['sql'] = nextSql;
      return;
    }
    final nextChangeTracking = Map<String, dynamic>.from(changeTracking);
    final databases = nextChangeTracking['databases'];
    if (databases is List) {
      nextChangeTracking['databases'] = databases
          .whereType<Map>()
          .take(maxDatabases)
          .map(_minimalChangeTrackingDatabaseForUpload)
          .toList(growable: false);
    }
    nextSql['changeTracking'] = nextChangeTracking;
    payload['sql'] = nextSql;
  }

  Map<String, dynamic> _minimalSqlDiagnosticsForUpload(dynamic value) {
    if (value is! Map) {
      return const <String, dynamic>{};
    }
    final sql = Map<String, dynamic>.from(value);
    return <String, dynamic>{
      'server': sql['server'],
      'database': sql['database'],
      'selectedTable': sql['selectedTable'],
      'databaseCount': sql['databaseCount'],
      'tableCount': sql['tableCount'],
      'changeTracking':
          sql['changeTracking'] is Map
              ? _minimalChangeTrackingForUpload(sql['changeTracking'])
              : null,
    };
  }

  Map<String, dynamic> _minimalChangeTrackingForUpload(dynamic value) {
    if (value is! Map) {
      return const <String, dynamic>{};
    }
    final changeTracking = Map<String, dynamic>.from(value);
    final databases = changeTracking['databases'];
    return <String, dynamic>{
      'captureStatus': changeTracking['captureStatus'],
      'message': changeTracking['message'],
      'databaseCount': databases is List ? databases.length : 0,
      if (databases is List)
        'databases': databases
            .whereType<Map>()
            .take(3)
            .map(_minimalChangeTrackingDatabaseForUpload)
            .toList(growable: false),
    };
  }

  Map<String, dynamic> _minimalChangeTrackingDatabaseForUpload(
    Map<dynamic, dynamic> database,
  ) {
    return <String, dynamic>{
      'database': database['database'],
      'checked': database['checked'],
      'available': database['available'],
      'tableCount': database['tableCount'],
      'trackedTableCount': database['trackedTableCount'],
      'offlineChangesCanBeDetected': database['offlineChangesCanBeDetected'],
      if (database['error'] != null) 'error': database['error'],
    };
  }

  Map<String, dynamic> _compactChangeTrackingDiagnosticsForUpload(
    Map<String, dynamic> diagnostics,
  ) {
    final compact = Map<String, dynamic>.from(diagnostics);
    final databases = compact['databases'];
    if (databases is! List) {
      return compact;
    }

    compact['databases'] = databases
        .whereType<Map>()
        .map((database) {
          return _compactDatabaseChangeTrackingDiagnostics(database);
        })
        .toList(growable: false);

    final automaticEnable = compact['automaticEnable'];
    if (automaticEnable is Map) {
      compact['automaticEnable'] = _compactAutomaticChangeTrackingEnable(
        automaticEnable,
      );
    }
    compact.remove('trackedTables');
    compact.remove('offlineChangeDetectionNote');
    return compact;
  }

  Map<String, dynamic> _compactDatabaseChangeTrackingDiagnostics(
    Map<dynamic, dynamic> database,
  ) {
    final nextDatabase = <String, dynamic>{
      'checked': database['checked'],
      'available': database['available'],
      'database': database['database'],
      'currentVersion': database['currentVersion'],
      'tableCount': database['tableCount'],
      'primaryKeyTableCount': database['primaryKeyTableCount'],
      'trackedTableCount': database['trackedTableCount'],
      'offlineChangesCanBeDetected': database['offlineChangesCanBeDetected'],
      if (database['error'] != null) 'error': database['error'],
      if (database['serverEdition'] != null)
        'serverEdition': database['serverEdition'],
      if (database['productVersion'] != null)
        'productVersion': database['productVersion'],
      if (database['autoCleanup'] != null)
        'autoCleanup': database['autoCleanup'],
      if (database['retentionPeriod'] != null)
        'retentionPeriod': database['retentionPeriod'],
      if (database['retentionUnits'] != null)
        'retentionUnits': database['retentionUnits'],
    };
    final automaticEnable = database['automaticEnable'];
    if (automaticEnable is Map) {
      nextDatabase['automaticEnable'] = _compactAutomaticChangeTrackingEnable(
        automaticEnable,
      );
    }
    return nextDatabase;
  }

  Map<String, dynamic> _compactAutomaticChangeTrackingEnable(
    Map<dynamic, dynamic> automaticEnable,
  ) {
    final compact = Map<String, dynamic>.from(automaticEnable);
    final statuses = compact['tableStatuses'];
    if (statuses is! List) {
      return compact;
    }

    final statusCounts = <String, int>{};
    final sampleNonEnabled = <Map<String, dynamic>>[];
    for (final item in statuses) {
      if (item is! Map) {
        continue;
      }
      final status = (item['status'] as String? ?? 'unknown').trim();
      statusCounts[status] = (statusCounts[status] ?? 0) + 1;
      if (status != 'enabled' && sampleNonEnabled.length < 12) {
        sampleNonEnabled.add({
          'table': item['table'],
          'syncKey': item['syncKey'],
          'status': status,
          'message': item['message'],
        });
      }
    }

    compact['tableStatusCounts'] = statusCounts;
    compact['sampleNonEnabledTables'] = sampleNonEnabled;
    compact['tableStatusTotal'] = statuses.length;
    compact.remove('tableStatuses');
    return compact;
  }

  String _readStartupLogTail() {
    try {
      final executableDirectory = File(Platform.resolvedExecutable).parent;
      final logFile = File(
        '${executableDirectory.path}${Platform.pathSeparator}sync_windows_agent_startup.log',
      );
      if (!logFile.existsSync()) {
        return '';
      }
      final content = logFile.readAsStringSync();
      if (content.length <= 12000) {
        return content;
      }
      return content.substring(content.length - 12000);
    } catch (_) {
      return '';
    }
  }

  Future<void> _processPendingJobs() async {
    final pendingJobs = _activeJobs
        .where((job) => job.isActive)
        .toList(growable: false);
    final orderedPendingJobs = _sortPendingJobsByDependencies(pendingJobs);

    _updateTraySyncIndicator();
    try {
      for (final job in orderedPendingJobs) {
        if (_processingJobIds.contains(job.id)) {
          continue;
        }
        _processingJobIds.add(job.id);
        _updateTraySyncIndicator();
        try {
          await _processSnapshotJob(job);
        } catch (error, stackTrace) {
          final errorMessage = error.toString();
          logStartupEvent(
            'Remote job ${job.id} failed during snapshot processing: $errorMessage',
          );
          logStartupEvent(stackTrace.toString());
          await _markRemoteJobFailed(job, error);
          final failedJob = RemoteSyncJob(
            id: job.id,
            clientName: job.clientName,
            sourceClientName: job.sourceClientName,
            subscriberClientName: job.subscriberClientName,
            table: job.table,
            direction: job.direction,
            publisherServer: job.publisherServer,
            publisherDatabase: job.publisherDatabase,
            publisherUseWindowsAuth: job.publisherUseWindowsAuth,
            publisherUser: job.publisherUser,
            publisherPassword: job.publisherPassword,
            status: 'failed',
            progress: 100,
            rowCount: job.rowCount,
            snapshotBytes: job.snapshotBytes,
            snapshotCreatedAt: job.snapshotCreatedAt,
            snapshotId: job.snapshotId,
            createdAt: job.createdAt,
            updatedAt: DateTime.now().toIso8601String(),
            startedAt: job.startedAt,
            completedAt: DateTime.now().toIso8601String(),
            message: errorMessage,
            error: errorMessage,
          );
          _applyRemoteJobState(
            failedJob,
            appendHistory: true,
            success: false,
            overrideMessage: errorMessage,
          );
          if (job.direction == 'download') {
            unawaited(_refreshLocalRowCounts());
          }
        } finally {
          _processingJobIds.remove(job.id);
          _updateTraySyncIndicator();
        }
      }
    } finally {
      _updateTraySyncIndicator();
    }
  }

  List<RemoteSyncJob> _sortPendingJobsByDependencies(List<RemoteSyncJob> jobs) {
    if (jobs.length < 2 || _remoteTableDependencies.isEmpty) {
      return jobs;
    }

    final dependencyGraph = <String, Set<String>>{};
    for (final dependency in _remoteTableDependencies) {
      final table = dependency.table.trim();
      final relatedTable = dependency.relatedTable.trim();
      if (table.isEmpty || relatedTable.isEmpty || table == relatedTable) {
        continue;
      }
      dependencyGraph.putIfAbsent(table, () => <String>{}).add(relatedTable);
    }

    final depthCache = <String, int>{};
    final orderedJobs = jobs.toList(growable: false);
    orderedJobs.sort((left, right) {
      final leftDepth = _tableDependencyDepth(
        left.table,
        dependencyGraph,
        depthCache,
      );
      final rightDepth = _tableDependencyDepth(
        right.table,
        dependencyGraph,
        depthCache,
      );
      if (leftDepth != rightDepth) {
        return leftDepth.compareTo(rightDepth);
      }
      return left.createdAt.compareTo(right.createdAt);
    });
    return orderedJobs;
  }

  int _tableDependencyDepth(
    String table,
    Map<String, Set<String>> dependencyGraph,
    Map<String, int> cache, {
    Set<String>? visiting,
  }) {
    final normalizedTable = table.trim();
    final cached = cache[normalizedTable];
    if (cached != null) {
      return cached;
    }
    final activeStack = visiting ?? <String>{};
    if (!activeStack.add(normalizedTable)) {
      return 0;
    }

    var depth = 0;
    for (final relatedTable
        in dependencyGraph[normalizedTable] ?? const <String>{}) {
      depth = math.max(
        depth,
        1 +
            _tableDependencyDepth(
              relatedTable,
              dependencyGraph,
              cache,
              visiting: activeStack,
            ),
      );
    }

    activeStack.remove(normalizedTable);
    cache[normalizedTable] = depth;
    return depth;
  }

  Future<void> _processSnapshotJob(RemoteSyncJob job) async {
    if (job.direction == 'upload') {
      await _processSnapshotRelayUploadJob(job);
      return;
    }
    if (job.direction == 'download') {
      await _processSnapshotRelayDownloadJob(job);
      return;
    }
    throw Exception('Unsupported sync job direction: ${job.direction}');
  }

  Future<void> _processSnapshotRelayUploadJob(RemoteSyncJob job) async {
    var activeJob = await _controlPlaneClient.startJob(
      job.id,
      status: 'snapshotting',
      progress: 10,
      message: 'Creating a compressed snapshot for ${job.table}.',
    );
    _applyRemoteJobState(activeJob);

    final snapshot = await _createRelaySnapshotForJob(job);

    activeJob = await _controlPlaneClient.updateJobProgress(
      job.id,
      status: 'uploading',
      progress: 35,
      message: 'Uploading compressed snapshot for ${job.table}.',
      rowCount: snapshot.rowCount,
    );
    _applyRemoteJobState(activeJob);

    final uploadResult = await _controlPlaneClient.uploadSnapshot(
      job.id,
      clientName: widget.clientName,
      table: job.table,
      rowCount: snapshot.rowCount,
      snapshotCreatedAt: snapshot.createdAt,
      snapshotBytes: snapshot.snapshotBytes,
      snapshotJson: snapshot.snapshotJson,
    );

    _applyRemoteJobState(
      uploadResult.job,
      appendHistory: true,
      success: true,
      overrideMessage:
          'Uploaded ${snapshot.rowCount} row${snapshot.rowCount == 1 ? '' : 's'} for ${job.table}.',
    );
    if (snapshot.changeTrackingVersion != null) {
      _updateSyncTableState(
        job.table,
        (_syncState.tables[job.table] ?? _defaultSyncTableState(job.table))
            .copyWith(changeTrackingVersion: snapshot.changeTrackingVersion),
      );
    }
    final targetJob = uploadResult.targetJob;
    if (targetJob != null) {
      // The server queues the dependent download when upload completes. Keep
      // that transition locally so it runs in this sync cycle.
      _applyRemoteJobState(targetJob);
    }
  }

  Future<void> _processSnapshotRelayDownloadJob(RemoteSyncJob job) async {
    var activeJob = await _controlPlaneClient.startJob(
      job.id,
      status: 'downloading',
      progress: job.progress == 0 ? 10 : job.progress,
      message: 'Downloading compressed snapshot for ${job.table}.',
    );
    _applyRemoteJobState(activeJob);

    final snapshot = await _controlPlaneClient.downloadSnapshot(job.id);

    activeJob = await _controlPlaneClient.updateJobProgress(
      job.id,
      status: 'applying',
      progress: 80,
      message: 'Applying downloaded snapshot to ${_localTableName(job.table)}.',
      rowCount: snapshot.rowCount,
    );
    _applyRemoteJobState(activeJob);

    final targetRowCount = await _applyDownloadedSnapshotToTarget(
      job: job,
      snapshot: snapshot,
    );

    activeJob = await _controlPlaneClient.completeJob(
      job.id,
      status: 'completed',
      progress: 100,
      message:
          'Applied ${snapshot.rowCount} row${snapshot.rowCount == 1 ? '' : 's'} from ${job.sourceClientName} into ${_localTableName(job.table)}.',
      rowCount: targetRowCount,
      snapshotId: snapshot.id,
      snapshotCreatedAt: snapshot.createdAt,
      snapshotBytes: snapshot.snapshotBytes,
    );
    _applyRemoteJobState(
      activeJob,
      appendHistory: true,
      success: true,
      overrideMessage:
          'Applied ${snapshot.rowCount} row${snapshot.rowCount == 1 ? '' : 's'} from ${job.sourceClientName} into ${_localTableName(job.table)}.',
    );
    if (snapshot.changeTrackingVersion != null) {
      _updateSyncTableState(
        job.table,
        (_syncState.tables[job.table] ?? _defaultSyncTableState(job.table))
            .copyWith(changeTrackingVersion: snapshot.changeTrackingVersion),
      );
    }
  }

  Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(
    RemoteSyncJob job,
  ) async {
    final tableDatabase = _databaseNameFromSyncKey(job.table).trim();
    final database =
        tableDatabase.isNotEmpty ? tableDatabase : job.publisherDatabase.trim();
    if (database.isEmpty) {
      throw Exception(
        'Snapshot upload for ${job.table} is missing a database.',
      );
    }

    final localTableName = _localTableName(job.table);
    final tableParts = _splitQualifiedName(localTableName);
    final sourceProfile = _activeProfile();
    final columnDefinitions = await _querySyncColumnDefinitions(
      profile: sourceProfile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (columnDefinitions.isEmpty) {
      throw Exception(
        'No writable columns were found for ${tableParts.schema}.${tableParts.table}.',
      );
    }

    final columnAssessment = assessSqlSyncColumns(columnDefinitions);
    final unsupportedColumns = columnAssessment.unsupportedColumns;
    if (unsupportedColumns.isNotEmpty) {
      final names = unsupportedColumns.map((column) => column.name).join(', ');
      throw Exception(
        'Snapshot relay for ${tableParts.schema}.${tableParts.table} cannot run because these column types are not supported yet: $names.',
      );
    }

    final syncColumns = columnAssessment.writableColumns;
    if (syncColumns.isEmpty) {
      throw Exception(
        'Table ${tableParts.schema}.${tableParts.table} has no writable columns to sync.',
      );
    }

    final primaryKeyColumns = await _queryPrimaryKeyColumns(
      profile: sourceProfile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (primaryKeyColumns.isEmpty) {
      throw Exception(
        'Snapshot relay for ${tableParts.schema}.${tableParts.table} requires a primary key.',
      );
    }

    final rowCountResult = await _queryTableRowCount(
      profile: sourceProfile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!rowCountResult.success) {
      throw Exception(
        rowCountResult.errorText ?? 'Source row count lookup failed.',
      );
    }

    final rowCount = rowCountResult.value;
    final previousVersion = _syncState.tables[job.table]?.changeTrackingVersion;
    final tracking = await _queryChangeTrackingState(
      profile: sourceProfile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    final canUseDelta =
        tracking != null &&
        previousVersion != null &&
        previousVersion > 0 &&
        previousVersion >= tracking.minValidVersion;
    final rows = <Map<String, String?>>[];
    var isDelta = false;
    if (canUseDelta) {
      final deltaRows = await _fetchChangeTrackingRows(
        profile: sourceProfile,
        database: database,
        schema: tableParts.schema,
        table: tableParts.table,
        columns: syncColumns,
        primaryKeyColumns: primaryKeyColumns,
        previousVersion: previousVersion,
      );
      rows.addAll(deltaRows);
      isDelta = true;
    } else {
      const batchSize = 200;
      var processed = 0;
      while (processed < rowCount) {
        final batch = await _fetchSourceTableBatch(
          profile: sourceProfile,
          database: database,
          schema: tableParts.schema,
          table: tableParts.table,
          columns: syncColumns,
          orderColumns: primaryKeyColumns,
          offset: processed,
          batchSize: math.min(batchSize, rowCount - processed),
        );
        for (final row in batch) {
          rows.add({
            for (final column in syncColumns)
              column.name: row[column.name]?.toString(),
          });
        }
        processed += batch.length;
        if (batch.isEmpty) break;
      }
    }

    final createdAt = DateTime.now().toIso8601String();
    Map<String, dynamic> payload = {
      'id': '',
      'clientName': widget.clientName,
      'table': job.table,
      'createdAt': createdAt,
      'rowCount': rows.length,
      'checksum': '',
      'snapshotBytes': 0,
      'columns': syncColumns
          .map((column) => column.name)
          .toList(growable: false),
      'rows': rows,
      'sourceJobId': job.id,
      'changeTrackingVersion': tracking?.currentVersion,
      'delta': isDelta,
    };
    var snapshotJson = jsonEncode(payload);
    final snapshotBytes = utf8.encode(snapshotJson).length;
    payload = {...payload, 'snapshotBytes': snapshotBytes};
    snapshotJson = jsonEncode(payload);

    return _RelaySnapshotDocument(
      createdAt: createdAt,
      rowCount: rows.length,
      snapshotBytes: utf8.encode(snapshotJson).length,
      snapshotJson: snapshotJson,
      changeTrackingVersion: tracking?.currentVersion,
    );
  }

  Future<int> _applyDownloadedSnapshotToTarget({
    required RemoteSyncJob job,
    required RemoteSnapshot snapshot,
  }) async {
    final targetDatabase = _databaseNameFromSyncKey(job.table).trim();
    if (targetDatabase.isEmpty) {
      throw Exception(
        'Downloaded snapshot for ${job.table} is missing the target database name.',
      );
    }

    final localTableName = _localTableName(job.table);
    final targetTable = _splitQualifiedName(localTableName);
    final targetProfile = _activeProfile();
    final columnDefinitions = await _querySyncColumnDefinitions(
      profile: targetProfile,
      database: targetDatabase,
      schema: targetTable.schema,
      table: targetTable.table,
    );
    if (columnDefinitions.isEmpty) {
      throw Exception(
        'No writable columns were found for ${targetTable.schema}.${targetTable.table}.',
      );
    }

    final columnAssessment = assessSqlSyncColumns(columnDefinitions);
    final unsupportedColumns = columnAssessment.unsupportedColumns;
    if (unsupportedColumns.isNotEmpty) {
      final names = unsupportedColumns.map((column) => column.name).join(', ');
      throw Exception(
        'Snapshot apply for ${targetTable.schema}.${targetTable.table} cannot run because these column types are not supported yet: $names.',
      );
    }

    final availableColumns = {
      for (final column in columnDefinitions.where(
        (column) => column.isWritable,
      ))
        column.name: column,
    };
    final syncColumns = snapshot.columns
        .map((name) => availableColumns[name])
        .whereType<_SqlColumnDefinition>()
        .toList(growable: false);
    if (snapshot.rows.isNotEmpty && syncColumns.isEmpty) {
      throw Exception(
        'Downloaded snapshot for ${job.table} does not contain any writable target columns.',
      );
    }

    final primaryKeyColumns = await _queryPrimaryKeyColumns(
      profile: targetProfile,
      database: targetDatabase,
      schema: targetTable.schema,
      table: targetTable.table,
    );
    if (primaryKeyColumns.isEmpty) {
      throw Exception(
        'Snapshot apply for ${targetTable.schema}.${targetTable.table} requires a primary key.',
      );
    }
    final uniqueIndexColumnSets = await _queryUniqueIndexColumnSets(
      profile: targetProfile,
      database: targetDatabase,
      schema: targetTable.schema,
      table: targetTable.table,
    );
    final targetMatchColumnSets = _targetMatchColumnSets(
      primaryKeyColumns: primaryKeyColumns,
      uniqueIndexColumnSets: uniqueIndexColumnSets,
      columns: syncColumns,
    );
    final deleteRows = snapshot.rows
        .where((row) => row['__sync_op'] == 'D')
        .toList(growable: false);
    final upsertRows = snapshot.rows
        .where((row) => row['__sync_op'] != 'D')
        .toList(growable: false);
    if (upsertRows.isNotEmpty) {
      final rows = upsertRows
          .map(
            (row) => <String, dynamic>{
              for (final column in syncColumns) column.name: row[column.name],
            },
          )
          .toList(growable: false);
      await _applySourceRowsToTarget(
        profile: targetProfile,
        database: targetDatabase,
        schema: targetTable.schema,
        table: targetTable.table,
        columns: syncColumns,
        primaryKeyColumns: primaryKeyColumns,
        matchColumnSets: targetMatchColumnSets,
        rows: rows,
      );
    }
    if (deleteRows.isNotEmpty) {
      await _deleteSourceRowsFromTarget(
        profile: targetProfile,
        database: targetDatabase,
        schema: targetTable.schema,
        table: targetTable.table,
        primaryKeyColumns: primaryKeyColumns,
        rows: deleteRows,
      );
    }

    final targetRowCountResult = await _queryTableRowCount(
      profile: targetProfile,
      database: targetDatabase,
      schema: targetTable.schema,
      table: targetTable.table,
    );
    if (!targetRowCountResult.success) {
      throw Exception(
        targetRowCountResult.errorText ?? 'Target row count lookup failed.',
      );
    }

    final visibleTableName = _stripKnownDatabaseAndDefaultSchema(
      localTableName,
      database: targetDatabase,
    );
    final targetFingerprints = await _queryTableFingerprints(
      profile: targetProfile,
      database: targetDatabase,
      tables: [visibleTableName],
    );
    _applyTableFingerprints(
      database: targetDatabase,
      fingerprints: targetFingerprints,
    );

    if (_selectedDatabase == targetDatabase) {
      _applyTableRowCounts(
        database: targetDatabase,
        rowCounts: {visibleTableName: targetRowCountResult.value},
      );
      if (_selectedTable == visibleTableName) {
        setState(() {
          _totalTableRows = targetRowCountResult.value;
        });
      }
      unawaited(_syncWithControlPlane());
    }

    return targetRowCountResult.value;
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

  Future<List<_SqlColumnDefinition>> _querySyncColumnDefinitions({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT
  c.name,
  t.name,
  c.max_length,
  c.precision,
  c.scale,
  c.is_identity,
  c.is_computed
FROM sys.columns AS c
INNER JOIN sys.types AS t
  ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'${_escapeSqlLiteral(_quoteIdentifier(schema))}.${_escapeSqlLiteral(_quoteIdentifier(table))}')
ORDER BY c.column_id;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );
    if (processResult == null) {
      throw Exception(_sqlCmdUnavailableMessage(profile));
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed('column metadata lookup', processResult));
    }

    final definitions = <_SqlColumnDefinition>[];
    for (final line in _dataOutputLines(processResult.stdout.toString())) {
      final parts = _splitRowValues(line);
      if (parts.length < 7) {
        continue;
      }
      definitions.add(
        _SqlColumnDefinition(
          name: parts[0],
          sqlType: parts[1],
          maxLength: int.tryParse(parts[2]) ?? 0,
          precision: int.tryParse(parts[3]) ?? 0,
          scale: int.tryParse(parts[4]) ?? 0,
          isIdentity: parts[5] == '1' || parts[5].toLowerCase() == 'true',
          isComputed: parts[6] == '1' || parts[6].toLowerCase() == 'true',
        ),
      );
    }
    return definitions;
  }

  Future<List<String>> _queryPrimaryKeyColumns({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT c.name
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
  ON ic.object_id = i.object_id
 AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
  ON c.object_id = ic.object_id
 AND c.column_id = ic.column_id
WHERE i.is_primary_key = 1
  AND i.object_id = OBJECT_ID(N'${_escapeSqlLiteral(_quoteIdentifier(schema))}.${_escapeSqlLiteral(_quoteIdentifier(table))}')
ORDER BY ic.key_ordinal;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );
    if (processResult == null) {
      throw Exception(_sqlCmdUnavailableMessage(profile));
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed('primary key lookup', processResult));
    }
    return _parseSingleColumnOutput(processResult.stdout.toString());
  }

  Future<List<List<String>>> _queryUniqueIndexColumnSets({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT i.name, c.name
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
  ON ic.object_id = i.object_id
 AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
  ON c.object_id = ic.object_id
 AND c.column_id = ic.column_id
WHERE i.is_unique = 1
  AND i.is_primary_key = 0
  AND i.is_disabled = 0
  AND i.is_hypothetical = 0
  AND ic.is_included_column = 0
  AND i.object_id = OBJECT_ID(N'${_escapeSqlLiteral(_quoteIdentifier(schema))}.${_escapeSqlLiteral(_quoteIdentifier(table))}')
ORDER BY i.index_id, ic.key_ordinal;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );
    if (processResult == null) {
      throw Exception(_sqlCmdUnavailableMessage(profile));
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed('unique index lookup', processResult));
    }

    final orderedIndexNames = <String>[];
    final columnsByIndex = <String, List<String>>{};
    for (final line in _dataOutputLines(processResult.stdout.toString())) {
      final parts = _splitRowValues(line);
      if (parts.length < 2) {
        continue;
      }
      final indexName = parts[0];
      final columnName = parts[1];
      if (!columnsByIndex.containsKey(indexName)) {
        orderedIndexNames.add(indexName);
        columnsByIndex[indexName] = <String>[];
      }
      columnsByIndex[indexName]!.add(columnName);
    }
    return orderedIndexNames
        .map((indexName) => columnsByIndex[indexName] ?? const <String>[])
        .where((columns) => columns.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchSourceTableBatch({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
    required List<_SqlColumnDefinition> columns,
    required List<String> orderColumns,
    required int offset,
    required int batchSize,
  }) async {
    const fieldSeparator = 31;
    const rowSentinel = 29;
    final columnList = columns
        .map((column) => _quoteIdentifier(column.name))
        .join(', ');
    final orderClause = orderColumns
        .map((column) => _quoteIdentifier(column))
        .join(', ');
    final payloadExpression = columns
        .map(_sourceBatchEncodedColumnExpression)
        .join(' + NCHAR($fieldSeparator) + ');
    final firstRow = offset + 1;
    final lastRow = offset + batchSize;
    final query = '''
SET NOCOUNT ON;
WITH page_source AS (
  SELECT
    $columnList,
    ROW_NUMBER() OVER (ORDER BY $orderClause) AS [__sync_agent_row_number]
  FROM ${_quoteIdentifier(database)}.${_quoteIdentifier(schema)}.${_quoteIdentifier(table)}
)
SELECT ($payloadExpression + NCHAR($rowSentinel)) AS [__sync_agent_row_payload]
FROM page_source
WHERE [__sync_agent_row_number] BETWEEN $firstRow AND $lastRow
ORDER BY [__sync_agent_row_number];
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );
    if (processResult == null) {
      throw Exception(_sqlCmdUnavailableMessage(profile));
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed('source row fetch', processResult));
    }

    return _parseSourceBatchRows(
      processResult.stdout.toString(),
      columns: columns,
      fieldSeparator: String.fromCharCode(fieldSeparator),
      rowSentinel: String.fromCharCode(rowSentinel),
    );
  }

  Future<_ChangeTrackingState?> _queryChangeTrackingState({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final objectName =
        "${_escapeSqlLiteral(_quoteIdentifier(schema))}.${_escapeSqlLiteral(_quoteIdentifier(table))}";
    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT
  COALESCE(CAST(CHANGE_TRACKING_CURRENT_VERSION() AS nvarchar(40)), N'0'),
  COALESCE(CAST(CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'$objectName')) AS nvarchar(40)), N'0');
''';
    final result = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
      timeout: _snapshotSqlCmdTimeout,
    );
    if (result == null || result.exitCode != 0) return null;
    final lines = _dataOutputLines(result.stdout.toString());
    final line = lines.isEmpty ? null : lines.first;
    if (line == null) return null;
    final values = _splitRowValues(line);
    if (values.length < 2) return null;
    final current = int.tryParse(values[0]);
    final minimum = int.tryParse(values[1]);
    if (current == null || minimum == null || current <= 0) {
      return null;
    }
    return _ChangeTrackingState(
      currentVersion: current,
      minValidVersion: minimum,
    );
  }

  Future<List<Map<String, String?>>> _fetchChangeTrackingRows({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
    required List<_SqlColumnDefinition> columns,
    required List<String> primaryKeyColumns,
    required int previousVersion,
  }) async {
    const fieldSeparator = 31;
    const rowSentinel = 29;
    final source =
        '${_quoteIdentifier(database)}.${_quoteIdentifier(schema)}.${_quoteIdentifier(table)}';
    final join = primaryKeyColumns
        .map(
          (column) =>
              'ct.${_quoteIdentifier(column)} = current.${_quoteIdentifier(column)}',
        )
        .join(' AND ');
    final primaryKeySet =
        primaryKeyColumns.map((column) => column.toLowerCase()).toSet();
    final encoded = columns
        .map((column) {
          final isKey = primaryKeySet.contains(column.name.toLowerCase());
          if (isKey) {
            return _sourceBatchEncodedColumnExpression(
              column,
              columnReference: 'ct.${_quoteIdentifier(column.name)}',
            );
          }
          return '''CASE WHEN ct.SYS_CHANGE_OPERATION = N'D' THEN N'\\N'
ELSE ${_sourceBatchEncodedColumnExpression(column, columnReference: 'current.${_quoteIdentifier(column.name)}')}
END''';
        })
        .join(' + NCHAR($fieldSeparator) + ');
    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT
  ct.SYS_CHANGE_OPERATION + NCHAR($fieldSeparator) + $encoded + NCHAR($rowSentinel)
FROM CHANGETABLE(CHANGES $source, $previousVersion) AS ct
LEFT JOIN $source AS current ON $join
ORDER BY ct.SYS_CHANGE_VERSION;
''';
    final result = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
      timeout: _snapshotSqlCmdTimeout,
    );
    if (result == null) throw Exception(_sqlCmdUnavailableMessage(profile));
    if (result.exitCode != 0)
      throw Exception(_sqlCmdFailed('change tracking delta fetch', result));
    final rows = <Map<String, String?>>[];
    for (final line in _dataOutputLines(result.stdout.toString())) {
      final payload =
          line.endsWith(String.fromCharCode(rowSentinel))
              ? line.substring(0, line.length - 1)
              : line;
      final parts = payload.split(String.fromCharCode(fieldSeparator));
      if (parts.length != columns.length + 1) {
        throw Exception(
          'Change tracking delta returned ${parts.length - 1} field(s) for ${columns.length} column(s).',
        );
      }
      rows.add({
        '__sync_op': parts.first,
        for (var i = 0; i < columns.length; i++)
          columns[i].name: _decodeSourceBatchField(parts[i + 1]),
      });
    }
    return rows;
  }

  String _sourceBatchEncodedColumnExpression(
    _SqlColumnDefinition column, {
    String? columnReference,
  }) {
    final columnName = columnReference ?? _quoteIdentifier(column.name);
    final valueExpression = _sourceBatchColumnValueExpression(
      column,
      columnReference: columnReference,
    );
    return '''
CASE
  WHEN $columnName IS NULL THEN N'\\N'
  ELSE REPLACE(
    REPLACE(
      REPLACE(
        REPLACE(
          REPLACE(
            REPLACE($valueExpression, N'\\', N'\\\\'),
            NCHAR(13), N'\\r'
          ),
          NCHAR(10), N'\\n'
        ),
        NCHAR(31), N'\\u001f'
      ),
      NCHAR(30), N'\\u001e'
    ),
    NCHAR(29), N'\\u001d'
  )
END
''';
  }

  String _sourceBatchColumnValueExpression(
    _SqlColumnDefinition column, {
    String? columnReference,
  }) {
    final columnName = columnReference ?? _quoteIdentifier(column.name);
    final normalized = column.sqlType.trim().toLowerCase();
    if (normalized == 'binary' || normalized == 'varbinary') {
      return 'master.dbo.fn_varbintohexstr(CONVERT(varbinary(max), $columnName))';
    }
    if (normalized == 'date') {
      return 'CONVERT(nvarchar(10), $columnName, 23)';
    }
    if (normalized == 'datetimeoffset') {
      return 'CONVERT(nvarchar(48), $columnName, 127)';
    }
    if (normalized == 'datetime' ||
        normalized == 'smalldatetime' ||
        normalized == 'datetime2' ||
        normalized == 'time') {
      return 'CONVERT(nvarchar(33), $columnName, 126)';
    }
    if (normalized == 'money' || normalized == 'smallmoney') {
      return 'CONVERT(nvarchar(100), $columnName, 2)';
    }
    if (normalized == 'uniqueidentifier') {
      return 'CONVERT(nvarchar(36), $columnName)';
    }
    return 'CONVERT(nvarchar(max), $columnName)';
  }

  List<Map<String, dynamic>> _parseSourceBatchRows(
    String output, {
    required List<_SqlColumnDefinition> columns,
    required String fieldSeparator,
    required String rowSentinel,
  }) {
    final rows = <Map<String, dynamic>>[];
    final lines = output.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      final payload =
          line.endsWith(rowSentinel)
              ? line.substring(0, line.length - rowSentinel.length)
              : line;
      final parts = payload.split(fieldSeparator);
      if (parts.length != columns.length) {
        throw Exception(
          'Source row fetch returned ${parts.length} field(s) for ${columns.length} column(s).',
        );
      }
      rows.add({
        for (var index = 0; index < columns.length; index++)
          columns[index].name: _decodeSourceBatchField(parts[index]),
      });
    }
    return rows;
  }

  String? _decodeSourceBatchField(String raw) {
    if (raw == r'\N') {
      return null;
    }

    final buffer = StringBuffer();
    for (var index = 0; index < raw.length; index++) {
      final char = raw[index];
      if (char != r'\') {
        buffer.write(char);
        continue;
      }
      if (raw.startsWith(r'\\', index)) {
        buffer.write(r'\');
        index += 1;
        continue;
      }
      if (raw.startsWith(r'\r', index)) {
        buffer.write('\r');
        index += 1;
        continue;
      }
      if (raw.startsWith(r'\n', index)) {
        buffer.write('\n');
        index += 1;
        continue;
      }
      if (raw.startsWith(r'\u001f', index)) {
        buffer.writeCharCode(31);
        index += 5;
        continue;
      }
      if (raw.startsWith(r'\u001e', index)) {
        buffer.writeCharCode(30);
        index += 5;
        continue;
      }
      if (raw.startsWith(r'\u001d', index)) {
        buffer.writeCharCode(29);
        index += 5;
        continue;
      }
      buffer.write(char);
    }
    return buffer.toString();
  }

  Future<void> _applySourceRowsToTarget({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
    required List<_SqlColumnDefinition> columns,
    required List<String> primaryKeyColumns,
    required List<List<String>> matchColumnSets,
    required List<Map<String, dynamic>> rows,
  }) async {
    final stageTableName = _nextTargetSnapshotStageTableName(table);
    try {
      await _runSqlCmdOrThrow(
        profile: profile,
        database: database,
        query: buildTargetSnapshotStageSetupSql(
          stageTableName: stageTableName,
          columns: columns,
        ),
        context: 'target snapshot stage setup',
        timeout: _snapshotSqlCmdTimeout,
      );
      for (
        var offset = 0;
        offset < rows.length;
        offset += _targetSnapshotStageInsertBatchSize
      ) {
        final batch = rows
            .skip(offset)
            .take(_targetSnapshotStageInsertBatchSize)
            .toList(growable: false);
        await _runSqlCmdOrThrow(
          profile: profile,
          database: database,
          query: buildTargetSnapshotStageInsertSql(
            stageTableName: stageTableName,
            columns: columns,
            rows: batch,
          ),
          context: 'target snapshot stage load',
          timeout: _snapshotSqlCmdTimeout,
        );
      }
      await _runSqlCmdOrThrow(
        profile: profile,
        database: database,
        query: buildTargetSnapshotStageApplySql(
          database: database,
          schema: schema,
          table: table,
          stageTableName: stageTableName,
          columns: columns,
          primaryKeyColumns: primaryKeyColumns,
          matchColumnSets: matchColumnSets,
        ),
        context: 'target snapshot merge',
        timeout: _snapshotSqlCmdTimeout,
      );
    } finally {
      await _dropTargetSnapshotStage(
        profile: profile,
        database: database,
        stageTableName: stageTableName,
      );
    }
  }

  Future<void> _deleteSourceRowsFromTarget({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
    required List<String> primaryKeyColumns,
    required List<Map<String, String?>> rows,
  }) async {
    final target =
        '${_quoteIdentifier(database)}.${_quoteIdentifier(schema)}.${_quoteIdentifier(table)}';
    for (var offset = 0; offset < rows.length; offset += 100) {
      final batch = rows.skip(offset).take(100);
      final predicates = batch
          .map((row) {
            return '(${primaryKeyColumns.map((key) {
              final value = row[key];
              if (value == null) return '${_quoteIdentifier(key)} IS NULL';
              return "${_quoteIdentifier(key)} = N'${_escapeSqlLiteral(value)}'";
            }).join(' AND ')})';
          })
          .join(' OR ');
      await _runSqlCmdOrThrow(
        profile: profile,
        database: database,
        query: 'SET NOCOUNT ON; DELETE FROM $target WHERE $predicates;',
        context: 'target change tracking delete',
        timeout: _snapshotSqlCmdTimeout,
      );
    }
  }

  String _nextTargetSnapshotStageTableName(String table) {
    final normalizedTable = table.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    final randomSuffix = math.Random.secure().nextInt(0x7fffffff);
    return 'sqlsync_${normalizedTable}_$randomSuffix';
  }

  Future<void> _dropTargetSnapshotStage({
    required _SqlConnectionProfile profile,
    required String database,
    required String stageTableName,
  }) async {
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: buildTargetSnapshotStageDropSql(stageTableName: stageTableName),
      timeout: _snapshotSqlCmdTimeout,
    );
    if (processResult == null || processResult.exitCode == 0) {
      return;
    }
  }

  Future<void> _runSqlCmdOrThrow({
    required _SqlConnectionProfile profile,
    required String database,
    required String query,
    required String context,
    Duration timeout = _defaultSqlCmdTimeout,
  }) async {
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
      timeout: timeout,
    );
    if (processResult == null) {
      throw Exception(_sqlCmdUnavailableMessage(profile));
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed(context, processResult));
    }
  }

  List<List<String>> _targetMatchColumnSets({
    required List<String> primaryKeyColumns,
    required List<List<String>> uniqueIndexColumnSets,
    required List<_SqlColumnDefinition> columns,
  }) {
    final writableColumnNames = {
      for (final column in columns) column.name.toLowerCase(),
    };
    final sets = <List<String>>[primaryKeyColumns];
    for (final uniqueColumns in uniqueIndexColumnSets) {
      if (uniqueColumns.every(
        (column) => writableColumnNames.contains(column.toLowerCase()),
      )) {
        sets.add(uniqueColumns);
      }
    }

    final seen = <String>{};
    return sets
        .where((columns) {
          final key = columns.map((column) => column.toLowerCase()).join('|');
          if (key.isEmpty || seen.contains(key)) {
            return false;
          }
          seen.add(key);
          return true;
        })
        .toList(growable: false);
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

  Future<Map<String, _TableFingerprint>> _queryTableFingerprints({
    required _SqlConnectionProfile profile,
    required String database,
    required List<String> tables,
  }) async {
    if (database.isEmpty || tables.isEmpty) {
      return const <String, _TableFingerprint>{};
    }

    final fingerprints = <String, _TableFingerprint>{};
    for (final tableName in tables) {
      final parts = _splitQualifiedName(tableName);
      final definitions = await _querySyncColumnDefinitions(
        profile: profile,
        database: database,
        schema: parts.schema,
        table: parts.table,
      );
      final writableColumns = assessSqlSyncColumns(definitions).writableColumns;
      final primaryKeyColumns = await _queryPrimaryKeyColumns(
        profile: profile,
        database: database,
        schema: parts.schema,
        table: parts.table,
      );
      final uniqueIndexColumnSets = await _queryUniqueIndexColumnSets(
        profile: profile,
        database: database,
        schema: parts.schema,
        table: parts.table,
      );
      final orderColumns = _tableFingerprintOrderColumns(
        primaryKeyColumns: primaryKeyColumns,
        uniqueIndexColumnSets: uniqueIndexColumnSets,
        writableColumns: writableColumns,
      );
      final fingerprint = await _computeTableFingerprint(
        profile: profile,
        database: database,
        schema: parts.schema,
        table: parts.table,
        writableColumns: writableColumns,
        orderColumns: orderColumns,
      );
      if (fingerprint == null) {
        continue;
      }
      fingerprints[tableName] = fingerprint;
    }

    return fingerprints;
  }

  List<String> _tableFingerprintOrderColumns({
    required List<String> primaryKeyColumns,
    required List<List<String>> uniqueIndexColumnSets,
    required List<_SqlColumnDefinition> writableColumns,
  }) {
    if (primaryKeyColumns.isNotEmpty) {
      return primaryKeyColumns;
    }
    for (final columnSet in uniqueIndexColumnSets) {
      if (columnSet.isNotEmpty) {
        return columnSet;
      }
    }
    return writableColumns.map((column) => column.name).toList(growable: false);
  }

  Future<_TableFingerprint?> _computeTableFingerprint({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
    required List<_SqlColumnDefinition> writableColumns,
    required List<String> orderColumns,
  }) async {
    if (writableColumns.isEmpty) {
      final rowCountResult = await _queryTableRowCount(
        profile: profile,
        database: database,
        schema: schema,
        table: table,
      );
      if (!rowCountResult.success) {
        return null;
      }
      return _TableFingerprint(
        rowCount: rowCountResult.value,
        checksum: '${rowCountResult.value}:empty',
      );
    }
    if (orderColumns.isEmpty) {
      return null;
    }

    const batchSize = 200;
    final accumulator = SqlSyncFingerprintAccumulator();
    for (var offset = 0; true; offset += batchSize) {
      final rows = await _fetchSourceTableBatch(
        profile: profile,
        database: database,
        schema: schema,
        table: table,
        columns: writableColumns,
        orderColumns: orderColumns,
        offset: offset,
        batchSize: batchSize,
      );
      if (rows.isEmpty) {
        break;
      }
      for (final row in rows) {
        accumulator.addRow(writableColumns, row);
      }
      if (rows.length < batchSize) {
        break;
      }
    }

    return _TableFingerprint(
      rowCount: accumulator.rowCount,
      checksum: accumulator.build(),
    );
  }

  Future<Map<String, dynamic>> _queryChangeTrackingDiagnostics() async {
    final syncTablesByDatabase = _syncTablesByDatabase();
    final databasesToCheck = <String>{
      if ((_selectedDatabase?.trim() ?? '').isNotEmpty)
        _selectedDatabase!.trim(),
      ...syncTablesByDatabase.keys,
    }.take(10).toList(growable: false);

    if (databasesToCheck.isEmpty) {
      return {
        'checked': false,
        'available': false,
        'reason': 'No database selected or referenced by sync tables.',
        'databases': const <Map<String, dynamic>>[],
      };
    }

    final databaseResults = <Map<String, dynamic>>[];
    for (final database in databasesToCheck) {
      final ensureResult = await _ensureChangeTrackingEnabledForDatabase(
        database: database,
        tables: syncTablesByDatabase[database] ?? const <String>[],
      );
      final diagnostics = await _queryChangeTrackingDiagnosticsForDatabase(
        database,
      );
      databaseResults.add({...diagnostics, 'automaticEnable': ensureResult});
    }
    _applyChangeTrackingDiagnosticsToState(databaseResults);

    final selectedDatabase =
        (_selectedDatabase?.trim() ?? '').isEmpty
            ? databasesToCheck.first
            : _selectedDatabase!.trim();
    final selectedResult = databaseResults.firstWhere(
      (item) =>
          (item['database'] as String? ?? '').toLowerCase() ==
          selectedDatabase.toLowerCase(),
      orElse: () => databaseResults.first,
    );

    return {
      ...selectedResult,
      'selectedDatabase': selectedDatabase,
      'checkedDatabaseCount': databaseResults.length,
      'databases': databaseResults,
      'offlineChangesCanBeDetectedForAnyDatabase': databaseResults.any(
        (item) => item['offlineChangesCanBeDetected'] == true,
      ),
    };
  }

  Map<String, List<String>> _syncTablesByDatabase() {
    final tablesByDatabase = <String, Set<String>>{};
    for (final syncKey in _syncState.tables.keys) {
      final database = _databaseNameFromSyncKey(syncKey).trim();
      final table = _localTableName(syncKey).trim();
      if (database.isEmpty || table.isEmpty || _isSystemDatabase(database)) {
        continue;
      }
      tablesByDatabase.putIfAbsent(database, () => <String>{}).add(table);
    }
    return tablesByDatabase.map(
      (database, tables) => MapEntry(database, tables.toList(growable: false)),
    );
  }

  Future<Map<String, dynamic>> _ensureChangeTrackingEnabledForDatabase({
    required String database,
    required List<String> tables,
  }) async {
    final trimmedDatabase = database.trim();
    if (trimmedDatabase.isEmpty) {
      return {
        'attempted': false,
        'databaseEnabled': false,
        'tableStatuses': const <Map<String, dynamic>>[],
        'message': 'Database name is empty.',
      };
    }
    if (_isSystemDatabase(trimmedDatabase)) {
      return {
        'attempted': false,
        'databaseStatus': 'skipped',
        'databaseEnabled': false,
        'tableStatuses': const <Map<String, dynamic>>[],
        'message': 'System databases are not modified automatically.',
      };
    }

    final databaseQuery = '''
SET NOCOUNT ON;
IF DB_ID(N'${_escapeSqlLiteral(trimmedDatabase)}') IS NULL
BEGIN
  SELECT N'database', N'missing', N'Database not found.';
END
ELSE IF NOT EXISTS (
  SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID(N'${_escapeSqlLiteral(trimmedDatabase)}')
)
BEGIN
  ALTER DATABASE ${_quoteIdentifier(trimmedDatabase)}
    SET CHANGE_TRACKING = ON
    (CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);
  SELECT N'database', N'enabled', N'Change Tracking enabled automatically.';
END
ELSE
BEGIN
  SELECT N'database', N'already_enabled', N'Change Tracking was already enabled.';
END
''';
    final databaseResult = await _runSqlCmd(
      profile: _activeProfile(),
      database: 'master',
      query: databaseQuery,
    );
    var databaseStatus = 'unknown';
    var databaseMessage = '';
    if (databaseResult == null) {
      databaseStatus = 'failed';
      databaseMessage = _sqlCmdUnavailableMessage(_activeProfile());
    } else {
      final parsedStatus = _extractChangeTrackingDatabaseStatus(databaseResult);
      if (databaseResult.exitCode != 0) {
        if (_isAlreadyEnabledChangeTrackingFailure(databaseResult)) {
          databaseStatus = 'already_enabled';
          databaseMessage =
              parsedStatus?.message.isNotEmpty == true
                  ? parsedStatus!.message
                  : 'Change Tracking was already enabled.';
        } else {
          databaseStatus = 'failed';
          databaseMessage = _sqlCmdFailed(
            'enable database change tracking',
            databaseResult,
          );
        }
      } else if (parsedStatus != null) {
        databaseStatus = parsedStatus.status;
        databaseMessage = parsedStatus.message;
      }
    }

    final tableStatuses = <Map<String, dynamic>>[];
    if (databaseStatus == 'failed' || databaseStatus == 'missing') {
      for (final table in tables.take(600)) {
        tableStatuses.add({
          'table': table,
          'syncKey':
              '$trimmedDatabase$_syncTableKeySeparator${_stripDefaultSchema(table)}',
          'status': databaseStatus == 'missing' ? 'missing' : 'failed',
          'message': databaseMessage,
        });
      }
      return {
        'attempted': true,
        'databaseStatus': databaseStatus,
        'databaseEnabled': false,
        'message': databaseMessage,
        'tableStatuses': tableStatuses,
      };
    }

    for (final table in tables.take(600)) {
      final parts = _splitQualifiedName(table);
      final schema = parts.schema;
      final tableName = parts.table;
      final objectName = '$schema.$tableName';
      final tableQuery = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(trimmedDatabase)};
IF OBJECT_ID(N'${_escapeSqlLiteral(objectName)}', N'U') IS NULL
BEGIN
  SELECT N'table', N'${_escapeSqlLiteral(objectName)}', N'missing', N'Table not found.';
END
ELSE IF NOT EXISTS (
  SELECT 1
  FROM sys.indexes
  WHERE object_id = OBJECT_ID(N'${_escapeSqlLiteral(objectName)}', N'U')
    AND is_primary_key = 1
)
BEGIN
  SELECT N'table', N'${_escapeSqlLiteral(objectName)}', N'no_primary_key', N'Change Tracking requires a primary key.';
END
ELSE IF EXISTS (
  SELECT 1
  FROM sys.change_tracking_tables
  WHERE object_id = OBJECT_ID(N'${_escapeSqlLiteral(objectName)}', N'U')
)
BEGIN
  SELECT N'table', N'${_escapeSqlLiteral(objectName)}', N'enabled', N'Change Tracking is enabled.';
END
ELSE
BEGIN
  ALTER TABLE ${_quoteIdentifier(schema)}.${_quoteIdentifier(tableName)}
    ENABLE CHANGE_TRACKING
    WITH (TRACK_COLUMNS_UPDATED = ON);
  SELECT N'table', N'${_escapeSqlLiteral(objectName)}', N'enabled', N'Change Tracking enabled automatically.';
END
''';
      final tableResult = await _runSqlCmd(
        profile: _activeProfile(),
        database: trimmedDatabase,
        query: tableQuery,
      );
      var status = 'unknown';
      var message = '';
      if (tableResult == null) {
        status = 'failed';
        message = _sqlCmdUnavailableMessage(_activeProfile());
      } else if (tableResult.exitCode != 0) {
        status = 'failed';
        message = _sqlCmdFailed('enable table change tracking', tableResult);
      } else {
        for (final line in tableResult.stdout.toString().split(
          RegExp(r'\r?\n'),
        )) {
          final trimmed = line.trim();
          if (_isSkippableOutputLine(trimmed)) {
            continue;
          }
          final values = _splitRowValues(trimmed);
          if (values.length >= 4 && values.first == 'table') {
            status = values[2];
            message = values[3];
            break;
          }
        }
      }
      tableStatuses.add({
        'table': objectName,
        'syncKey':
            '$trimmedDatabase$_syncTableKeySeparator${_stripDefaultSchema(table)}',
        'status': status,
        'message': message,
      });
    }

    return {
      'attempted': true,
      'databaseStatus': databaseStatus,
      'databaseEnabled':
          databaseStatus == 'enabled' || databaseStatus == 'already_enabled',
      'message': databaseMessage,
      'tableStatuses': tableStatuses,
    };
  }

  void _applyChangeTrackingDiagnosticsToState(
    List<Map<String, dynamic>> databaseResults,
  ) {
    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    var changed = false;
    for (final databaseResult in databaseResults) {
      final automaticEnable = databaseResult['automaticEnable'];
      if (automaticEnable is! Map) {
        continue;
      }
      final statuses = automaticEnable['tableStatuses'];
      if (statuses is! List) {
        continue;
      }
      for (final item in statuses) {
        if (item is! Map) {
          continue;
        }
        final syncKey = (item['syncKey'] as String? ?? '').trim();
        final status = (item['status'] as String? ?? 'unknown').trim();
        final message = (item['message'] as String? ?? '').trim();
        final current = nextTables[syncKey];
        if (current == null) {
          continue;
        }
        if (current.changeTrackingStatus == status &&
            current.changeTrackingMessage == message) {
          continue;
        }
        nextTables[syncKey] = current.copyWith(
          changeTrackingStatus: status,
          changeTrackingMessage: message,
        );
        changed = true;
      }
    }
    if (changed && mounted) {
      _replaceSyncState(_syncState.copyWith(tables: nextTables));
    }
  }

  bool _isSystemDatabase(String database) {
    return const {
      'master',
      'model',
      'msdb',
      'tempdb',
    }.contains(database.trim().toLowerCase());
  }

  Future<Map<String, dynamic>> _queryChangeTrackingDiagnosticsForDatabase(
    String database,
  ) async {
    if (database.isEmpty) {
      return {
        'checked': false,
        'available': false,
        'reason': 'Database name is empty.',
      };
    }

    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT
  N'database',
  CAST(SERVERPROPERTY('Edition') AS nvarchar(128)),
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
  DB_NAME(),
  CASE WHEN ctd.database_id IS NULL THEN N'0' ELSE N'1' END,
  COALESCE(CAST(ctd.is_auto_cleanup_on AS nvarchar(20)), N''),
  COALESCE(CAST(ctd.retention_period AS nvarchar(20)), N''),
  COALESCE(CAST(ctd.retention_period_units_desc AS nvarchar(40)), N''),
  COALESCE(CAST(CHANGE_TRACKING_CURRENT_VERSION() AS nvarchar(40)), N'')
FROM (SELECT 1 AS marker) AS seed
LEFT JOIN sys.change_tracking_databases AS ctd
  ON ctd.database_id = DB_ID();

SELECT TOP (200)
  N'table',
  s.name + N'.' + t.name,
  CASE WHEN ct.object_id IS NULL THEN N'0' ELSE N'1' END,
  COALESCE(CAST(ct.is_track_columns_updated_on AS nvarchar(20)), N''),
  COALESCE(CAST(ct.begin_version AS nvarchar(40)), N''),
  CASE
    WHEN ct.object_id IS NULL THEN N''
    ELSE COALESCE(CAST(CHANGE_TRACKING_MIN_VALID_VERSION(t.object_id) AS nvarchar(40)), N'')
  END,
  CASE
    WHEN pk.object_id IS NULL THEN N'0'
    ELSE N'1'
  END
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
LEFT JOIN sys.change_tracking_tables AS ct ON ct.object_id = t.object_id
LEFT JOIN (
  SELECT DISTINCT i.object_id
  FROM sys.indexes AS i
  WHERE i.is_primary_key = 1
) AS pk ON pk.object_id = t.object_id
ORDER BY
  CASE WHEN ct.object_id IS NULL THEN 1 ELSE 0 END,
  s.name,
  t.name;
''';

    final result = await _runSqlCmd(
      profile: _activeProfile(),
      database: database,
      query: query,
    );
    if (result == null) {
      return {
        'checked': true,
        'available': false,
        'database': database,
        'error': _sqlCmdUnavailableMessage(_activeProfile()),
      };
    }
    if (result.exitCode != 0) {
      return {
        'checked': true,
        'available': false,
        'database': database,
        'error': _sqlCmdFailed('change tracking diagnostics', result),
      };
    }

    var edition = '';
    var productVersion = '';
    var databaseName = database;
    var databaseEnabled = false;
    var autoCleanup = '';
    var retentionPeriod = '';
    var retentionUnits = '';
    var currentVersion = '';
    final trackedTables = <Map<String, dynamic>>[];
    var tableCount = 0;
    var primaryKeyTableCount = 0;

    final lines = result.stdout.toString().split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmed = line.trim();
      if (_isSkippableOutputLine(trimmed)) {
        continue;
      }
      final values = _splitRowValues(trimmed);
      if (values.isEmpty) {
        continue;
      }
      if (values.first == 'database' && values.length >= 9) {
        edition = values[1];
        productVersion = values[2];
        databaseName = values[3].isEmpty ? database : values[3];
        databaseEnabled = values[4] == '1';
        autoCleanup = values[5];
        retentionPeriod = values[6];
        retentionUnits = values[7];
        currentVersion = values[8];
        continue;
      }
      if (values.first == 'table' && values.length >= 7) {
        tableCount += 1;
        final hasPrimaryKey = values[6] == '1';
        if (hasPrimaryKey) {
          primaryKeyTableCount += 1;
        }
        final trackingEnabled = values[2] == '1';
        if (trackingEnabled) {
          trackedTables.add({
            'table': values[1],
            'trackColumns': values[3] == '1',
            'beginVersion': values[4],
            'minValidVersion': values[5],
            'hasPrimaryKey': hasPrimaryKey,
          });
        }
      }
    }

    return {
      'checked': true,
      'available': databaseEnabled,
      'serverEdition': edition,
      'productVersion': productVersion,
      'database': databaseName,
      'currentVersion': currentVersion,
      'autoCleanup': autoCleanup == '1',
      'retentionPeriod': retentionPeriod,
      'retentionUnits': retentionUnits,
      'tableCount': tableCount,
      'primaryKeyTableCount': primaryKeyTableCount,
      'trackedTableCount': trackedTables.length,
      'trackedTables': trackedTables.take(100).toList(growable: false),
      'offlineChangesCanBeDetected': databaseEnabled,
      'offlineChangeDetectionNote':
          databaseEnabled
              ? 'Changes made while the client is closed can be detected after restart if the saved sync version is still >= each table minValidVersion.'
              : 'Change Tracking is not enabled on this database. Offline changes require full snapshot/hash fallback.',
    };
  }

  Future<Map<String, Set<String>>> _queryTableRelationships({
    required _SqlConnectionProfile profile,
    required String database,
    required List<String> tables,
  }) async {
    if (database.isEmpty || tables.isEmpty) {
      return const <String, Set<String>>{};
    }

    final knownTables = tables.toSet();
    final relationships = <String, Set<String>>{};
    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT
  CASE
    WHEN child_schema.name = 'dbo' THEN child_table.name
    ELSE child_schema.name + '.' + child_table.name
  END AS child_table,
  CASE
    WHEN parent_schema.name = 'dbo' THEN parent_table.name
    ELSE parent_schema.name + '.' + parent_table.name
  END AS parent_table
FROM sys.foreign_keys AS fk
INNER JOIN sys.tables AS child_table
  ON child_table.object_id = fk.parent_object_id
INNER JOIN sys.schemas AS child_schema
  ON child_schema.schema_id = child_table.schema_id
INNER JOIN sys.tables AS parent_table
  ON parent_table.object_id = fk.referenced_object_id
INNER JOIN sys.schemas AS parent_schema
  ON parent_schema.schema_id = parent_table.schema_id
ORDER BY child_table, parent_table;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );
    if (processResult == null || processResult.exitCode != 0) {
      return const <String, Set<String>>{};
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
      final child = parts[0].trim();
      final parent = parts[1].trim();
      if (child.isEmpty ||
          parent.isEmpty ||
          !knownTables.contains(child) ||
          !knownTables.contains(parent)) {
        continue;
      }
      final childKey = _syncTableKey(child, database: database);
      final parentKey = _syncTableKey(parent, database: database);
      relationships.putIfAbsent(childKey, () => <String>{}).add(parentKey);
    }

    return relationships;
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
    final resolvedDatabase =
        tableParts.database.isEmpty ? database : tableParts.database;
    final columnsResult = await _queryTableColumns(
      profile: profile,
      database: resolvedDatabase,
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
      database: resolvedDatabase,
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
  FROM ${_quoteIdentifier(resolvedDatabase)}.${_quoteIdentifier(tableParts.schema)}.${_quoteIdentifier(tableParts.table)}
)
SELECT $columnList
FROM page_source
WHERE [__sync_agent_row_number] BETWEEN $firstRowNumber AND $lastRowNumber
ORDER BY [__sync_agent_row_number];
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: resolvedDatabase,
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

  ({String status, String message})? _extractChangeTrackingDatabaseStatus(
    ProcessResult processResult,
  ) {
    for (final line in processResult.stdout.toString().split(
      RegExp(r'\r?\n'),
    )) {
      final trimmed = line.trim();
      if (_isSkippableOutputLine(trimmed)) {
        continue;
      }
      final values = _splitRowValues(trimmed);
      if (values.length >= 3 && values.first == 'database') {
        return (status: values[1], message: values[2]);
      }
    }
    return null;
  }

  bool _isAlreadyEnabledChangeTrackingFailure(ProcessResult processResult) {
    final details =
        '${processResult.stdout}\n${processResult.stderr}'.toLowerCase();
    return details.contains('change tracking is already enabled for database');
  }

  Future<ProcessResult?> _runSqlCmd({
    required _SqlConnectionProfile profile,
    String? database,
    required String query,
    Duration timeout = _defaultSqlCmdTimeout,
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
      '-w',
      '32767',
      '-y',
      '0',
      '-Y',
      '0',
      '-u',
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
      final process = await Process.start(
        executable,
        arguments,
        runInShell: false,
      );
      final stdoutFuture = process.stdout
          .fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, chunk) {
            buffer.add(chunk);
            return buffer;
          })
          .then((buffer) => buffer.takeBytes());
      final stderrFuture = process.stderr
          .fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, chunk) {
            buffer.add(chunk);
            return buffer;
          })
          .then((buffer) => buffer.takeBytes());
      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        process.kill();
        final stdoutBytes = await stdoutFuture;
        final stderrBytes = await stderrFuture;
        final timeoutText =
            'sqlcmd timed out after ${_formatDurationForLog(timeout)}.';
        return ProcessResult(
          process.pid,
          -1,
          _decodeSqlCmdOutput(stdoutBytes),
          [
            timeoutText,
            _decodeSqlCmdOutput(stderrBytes),
          ].where((part) => part.trim().isNotEmpty).join('\n'),
        );
      }
      final stdoutBytes = await stdoutFuture;
      final stderrBytes = await stderrFuture;
      return ProcessResult(
        process.pid,
        exitCode,
        _decodeSqlCmdOutput(stdoutBytes),
        _decodeSqlCmdOutput(stderrBytes),
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

  String _decodeSqlCmdOutput(List<int> bytes) {
    if (bytes.isEmpty) {
      return '';
    }

    final data = Uint8List.fromList(bytes);
    final utf16Likely = _looksLikeUtf16Le(data);
    if (data.length.isEven || utf16Likely) {
      // sqlcmd is invoked with -u, so its stdout/stderr are UTF-16LE. Do not
      // infer this from zero bytes: Arabic UTF-16 code units often have none.
      return _decodeUtf16Le(data);
    }
    return utf8.decode(data, allowMalformed: true);
  }

  String _formatDurationForLog(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    if (minutes > 0 && seconds > 0) {
      return '${minutes}m ${seconds}s';
    }
    if (minutes > 0) {
      return '${minutes}m';
    }
    return '${duration.inSeconds}s';
  }

  bool _looksLikeUtf16Le(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return true;
    }
    if (bytes.length < 4) {
      return false;
    }

    var oddZeroCount = 0;
    var sampledPairs = 0;
    for (var index = 1; index < bytes.length && sampledPairs < 32; index += 2) {
      sampledPairs += 1;
      if (bytes[index] == 0) {
        oddZeroCount += 1;
      }
    }
    return sampledPairs >= 4 && oddZeroCount * 2 >= sampledPairs;
  }

  String _decodeUtf16Le(Uint8List bytes) {
    var offset = 0;
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      offset = 2;
    }
    final usableLength = bytes.length - ((bytes.length - offset) % 2);
    final codeUnits = <int>[];
    for (var index = offset; index < usableLength; index += 2) {
      codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
    }
    return String.fromCharCodes(codeUnits);
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

  _QualifiedTableName _splitQualifiedName(String qualifiedName) {
    final parts = qualifiedName.split('.');
    if (parts.length >= 3) {
      return _QualifiedTableName(
        database: parts[parts.length - 3],
        schema: parts[parts.length - 2],
        table: parts.last,
      );
    }
    if (parts.length == 2) {
      return _QualifiedTableName(schema: parts.first, table: parts.last);
    }
    return _QualifiedTableName(schema: 'dbo', table: qualifiedName);
  }

  List<String> _splitRowValues(String line) =>
      line.split('|').map((value) => value.trim()).toList();

  List<String> _dataOutputLines(String output) {
    final dataLines = <String>[];
    final lines = output.split(RegExp(r'\r?\n'));

    for (var index = 0; index < lines.length; index++) {
      final trimmedLine = lines[index].trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      if (_looksLikeHeaderLine(lines, index)) {
        index += 1;
        continue;
      }
      dataLines.add(trimmedLine);
    }

    return dataLines;
  }

  bool _looksLikeHeaderLine(List<String> lines, int index) {
    if (index < 0 || index >= lines.length - 1) {
      return false;
    }

    final current = lines[index].trim();
    final next = lines[index + 1].trim();
    if (current.isEmpty || next.isEmpty) {
      return false;
    }

    return !_isSkippableOutputLine(current) && _isHeaderSeparatorLine(next);
  }

  bool _isHeaderSeparatorLine(String line) {
    if (line.isEmpty) {
      return false;
    }

    var sawDash = false;
    for (final codeUnit in line.codeUnits) {
      final char = String.fromCharCode(codeUnit);
      if (char == '-') {
        sawDash = true;
        continue;
      }
      if (char == '|' || char == ' ' || char == '\t') {
        continue;
      }
      return false;
    }

    return sawDash;
  }

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

    for (final line in _dataOutputLines(output)) {
      final split = _splitRowValues(line);
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
      initialValue: selectedValue,
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

  String _databaseDropdownLabel(String database) => database;

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
          _buildSyncTableSortBar(syncRows, selectedRow),
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

  Widget _buildSyncTableSortBar(
    List<_SyncTableRowData> syncRows,
    _SyncTableRowData? selectedRow,
  ) {
    final tableCount = syncRows.length;
    final changedCount =
        syncRows.where((row) => _hasSavedRowCountChange(row.state)).length;
    final selectedTable = selectedRow?.table;
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
          Tooltip(
            message:
                'Reset the saved row-count baseline for all visible tables',
            child: TextButton.icon(
              onPressed:
                  tableCount == 0 ? null : _saveVisibleTableRowCountBaselines,
              icon: const Icon(Icons.bookmark_add_outlined, size: 16),
              label: const Text('Reset counters'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF2563EB),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message:
                'Enable only visible tables whose current row count differs from the saved counter',
            child: TextButton.icon(
              onPressed:
                  tableCount == 0 || _markChangedTablesBusy
                      ? null
                      : () =>
                          unawaited(_markOnlyChangedCounterTables(syncRows)),
              icon:
                  _markChangedTablesBusy
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.fact_check_outlined, size: 16),
              label: Text('Mark changed ($changedCount)'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF0F766E),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message:
                selectedTable == null
                    ? 'Select a table first'
                    : 'Queue sync for $selectedTable and related tables',
            child: TextButton.icon(
              onPressed:
                  selectedTable == null
                      ? null
                      : () => unawaited(_triggerSyncNow(selectedTable)),
              icon: const Icon(Icons.play_arrow_rounded, size: 17),
              label: const Text('Sync selected'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1D4ED8),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
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
    final autoRequired = row.state.autoRequired && !row.state.enabled;
    final cardColor =
        selected
            ? const Color(0xFFE6F4F1)
            : autoRequired
            ? const Color(0xFFEFF6FF)
            : Colors.white;
    final borderColor =
        selected
            ? const Color(0xFF85C7BC)
            : autoRequired
            ? const Color(0xFF93C5FD)
            : const Color(0xFFDDE3EA);

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
          color: cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 560;
            final metrics = Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (autoRequired) _buildAutoRequiredBadge(),
                _buildSyncFlowBadge(showLabel: false),
                _buildSyncStatusSymbol(row.state.status, size: 26),
                _buildChangeTrackingBadge(row.state),
                _buildSyncTableRowCountMetric(row.state),
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
                              _buildSyncTableTitle(
                                row.table,
                                autoRequired: autoRequired,
                              ),
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
                                    _buildSyncTableTitle(
                                      row.table,
                                      autoRequired: autoRequired,
                                    ),
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
    final autoRequired = row.state.autoRequired && !row.state.enabled;
    final checkboxValue = row.state.enabled || row.state.autoRequired;
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            row.state.enabled
                ? const Color(0xFFE6F4F1)
                : autoRequired
                ? const Color(0xFFEFF6FF)
                : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              row.state.enabled
                  ? const Color(0xFF85C7BC)
                  : autoRequired
                  ? const Color(0xFF93C5FD)
                  : const Color(0xFFDDE3EA),
        ),
      ),
      child: Transform.scale(
        scale: 1.05,
        child: Checkbox(
          value: checkboxValue,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged:
              autoRequired
                  ? null
                  : (value) {
                    if (value == null) {
                      return;
                    }
                    unawaited(_handleSyncEnabledChange(row.table, value));
                  },
        ),
      ),
    );
  }

  Widget _buildSyncTableTitle(String table, {bool autoRequired = false}) {
    return Text(
      table,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13,
        color: autoRequired ? const Color(0xFF1D4ED8) : const Color(0xFF18212B),
      ),
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
    Color color = const Color(0xFF18212B),
    Color borderColor = const Color(0xFFDDE3EA),
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        constraints: const BoxConstraints(minHeight: 26),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoRequiredBadge() {
    return Container(
      constraints: const BoxConstraints(minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF93C5FD)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 14, color: Color(0xFF1D4ED8)),
          SizedBox(width: 5),
          Text(
            'AUTO',
            style: TextStyle(
              color: Color(0xFF1D4ED8),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChangeTrackingBadge(SyncTableState state) {
    final color = _changeTrackingColor(state.changeTrackingStatus);
    return Tooltip(
      message: _changeTrackingTooltip(state),
      child: Container(
        constraints: const BoxConstraints(minHeight: 26),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.32)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _changeTrackingIcon(state.changeTrackingStatus),
              size: 14,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              _changeTrackingLabel(state.changeTrackingStatus),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _changeTrackingIcon(String status) {
    return switch (status.toLowerCase()) {
      'enabled' => Icons.verified_user_rounded,
      'failed' => Icons.gpp_bad_rounded,
      'no_primary_key' => Icons.key_off_rounded,
      'missing' => Icons.help_outline_rounded,
      _ => Icons.shield_outlined,
    };
  }

  Color _changeTrackingColor(String status) {
    return switch (status.toLowerCase()) {
      'enabled' => const Color(0xFF15803D),
      'failed' => const Color(0xFFB42318),
      'no_primary_key' => const Color(0xFF667085),
      'missing' => const Color(0xFFB54708),
      _ => const Color(0xFFB54708),
    };
  }

  String _changeTrackingLabel(String status) {
    return switch (status.toLowerCase()) {
      'enabled' => 'CT',
      'failed' => 'CT!',
      'no_primary_key' => 'NO PK',
      'missing' => 'MISS',
      _ => 'CT?',
    };
  }

  String _changeTrackingTooltip(SyncTableState state) {
    final status = state.changeTrackingStatus.toLowerCase();
    final message = state.changeTrackingMessage.trim();
    final base = switch (status) {
      'enabled' => 'Change Tracking is enabled for this table.',
      'failed' => 'Change Tracking could not be enabled automatically.',
      'no_primary_key' => 'Change Tracking requires a primary key.',
      'missing' => 'The table was not found when checking Change Tracking.',
      _ => 'Change Tracking status has not been checked yet.',
    };
    return message.isEmpty ? base : '$base $message';
  }

  Widget _buildSyncTableRowCountMetric(SyncTableState state) {
    final color = _savedRowCountColor(state);
    return _buildSyncTableMetric(
      tooltip:
          state.savedRowCount == null
              ? 'Current rows'
              : 'Current rows / saved rows',
      icon: Icons.format_list_numbered_rounded,
      value:
          state.savedRowCount == null
              ? '${state.rowCount}'
              : '${state.rowCount} / ${state.savedRowCount}',
      color: color,
      borderColor: color.withValues(alpha: 0.28),
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

    return AgentSurfaceCard(
      title: 'Sync Details',
      subtitle: '',
      showHeader: false,
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
        _buildUnifiedSyncDetailHeader(row),
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

  Widget _buildUnifiedSyncDetailHeader(_SyncTableRowData row) {
    final statusColor = _statusColor(row.state.status);
    final normalizedProgress = row.state.progress.clamp(0, 100);
    final canRunSync = _isTableSelectedForSync(row.state);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final toolbar = _buildDetailToolbar(
          row: row,
          compact: compact,
          canRunSync: canRunSync,
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
  }) {
    final toolbarChildren = <Widget>[
      _buildSyncEnabledToolbarControl(row),
      _buildToolbarIconControl(
        tooltip: 'Sync now',
        icon: Icons.sync_rounded,
        onTap: canRunSync ? () => _triggerSyncNow(row.table) : null,
      ),
      _buildToolbarStat(
        tooltip: _changeTrackingTooltip(row.state),
        icon: _changeTrackingIcon(row.state.changeTrackingStatus),
        value: _changeTrackingLabel(row.state.changeTrackingStatus),
        color: _changeTrackingColor(row.state.changeTrackingStatus),
      ),
      _buildToolbarStat(
        tooltip:
            row.state.savedRowCount == null
                ? 'Current rows'
                : 'Current rows / saved rows',
        icon: Icons.format_list_numbered_rounded,
        value:
            row.state.savedRowCount == null
                ? '${row.state.rowCount}'
                : '${row.state.rowCount} / ${row.state.savedRowCount}',
        color: _savedRowCountColor(row.state),
      ),
      _buildToolbarIconControl(
        tooltip: 'Reset the saved row-count baseline for this table',
        icon: Icons.bookmark_add_outlined,
        onTap: () => _saveTableRowCountBaseline(row.table),
      ),
      _buildToolbarIconControl(
        tooltip: 'View table',
        icon: Icons.table_rows_outlined,
        onTap: () => _openTableDataDialog(row.table),
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

  void _saveVisibleTableRowCountBaselines() {
    final syncRows = _syncRows();
    if (syncRows.isEmpty) {
      return;
    }

    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    for (final row in syncRows) {
      nextTables[row.syncKey] = row.state.copyWith(
        savedRowCount: row.state.rowCount,
      );
    }
    _replaceSyncState(_syncState.copyWith(tables: nextTables));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reset counter baselines for ${syncRows.length} tables.'),
      ),
    );
  }

  void _saveTableRowCountBaseline(String table) {
    final syncKey = _syncTableKey(table);
    final current = _syncTableState(table, syncKey: syncKey);
    _updateSyncTableState(
      syncKey,
      current.copyWith(savedRowCount: current.rowCount),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Reset counter baseline for $table.')),
    );
  }

  Color _savedRowCountColor(SyncTableState state) {
    final savedRowCount = state.savedRowCount;
    if (savedRowCount == null) {
      return const Color(0xFF18212B);
    }
    if (savedRowCount == state.rowCount) {
      return const Color(0xFF15803D);
    }
    return const Color(0xFF2563EB);
  }

  bool _hasSavedRowCountChange(SyncTableState state) {
    final savedRowCount = state.savedRowCount;
    return savedRowCount != null && savedRowCount != state.rowCount;
  }

  Future<void> _markOnlyChangedCounterTables(
    List<_SyncTableRowData> rows,
  ) async {
    if (_markChangedTablesBusy || rows.isEmpty) {
      return;
    }

    setState(() {
      _markChangedTablesBusy = true;
    });

    var changedCount = 0;
    try {
      for (final row in rows) {
        final shouldEnable = _hasSavedRowCountChange(row.state);
        if (!shouldEnable) {
          continue;
        }
        changedCount += 1;
        await _controlPlaneClient.updateTableSyncPolicy(
          table: row.syncKey,
          enabled: true,
          cascadeRelated: false,
        );
      }

      if (!mounted) {
        return;
      }

      final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
      for (final row in rows) {
        final shouldEnable = _hasSavedRowCountChange(row.state);
        if (!shouldEnable) {
          continue;
        }
        nextTables[row.syncKey] = row.state.copyWith(
          enabled: true,
          autoRequired: false,
          status: 'Queued',
          progress: 0,
          message: 'Row counter changed. Waiting for snapshot sync.',
        );
      }
      _replaceSyncState(_syncState.copyWith(tables: nextTables));

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added $changedCount changed table${changedCount == 1 ? '' : 's'} to the current sync selection.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    } finally {
      if (mounted) {
        setState(() {
          _markChangedTablesBusy = false;
        });
      }
    }
  }

  Widget _buildSyncEnabledToolbarControl(_SyncTableRowData row) {
    final autoRequired = row.state.autoRequired && !row.state.enabled;
    final checkboxValue = row.state.enabled || row.state.autoRequired;
    return Tooltip(
      message:
          row.state.enabled
              ? 'Disable sync'
              : autoRequired
              ? 'Required automatically by dependency discovery'
              : 'Enable sync',
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              row.state.enabled
                  ? const Color(0xFFE6F4F1)
                  : autoRequired
                  ? const Color(0xFFEFF6FF)
                  : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                row.state.enabled
                    ? const Color(0xFF85C7BC)
                    : autoRequired
                    ? const Color(0xFF93C5FD)
                    : const Color(0xFFDDE3EA),
          ),
        ),
        child: Transform.scale(
          scale: 1.18,
          child: Checkbox(
            value: checkboxValue,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged:
                autoRequired
                    ? null
                    : (value) {
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
      message:
          '${_syncFlowLabel()} for ${row.table}: ${_syncFlowDescription()}',
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFDDE3EA)),
        ),
        child: Icon(
          Icons.info_outline_rounded,
          size: 20,
          color: _syncFlowColor(),
        ),
      ),
    );
  }

  Widget _buildToolbarStat({
    required String tooltip,
    required IconData icon,
    required String value,
    Color color = const Color(0xFF18212B),
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
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
            width: 36,
            height: 36,
            child: Icon(
              icon,
              size: 17,
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
      final syncKey = _syncTableKey(table);
      final tablesToQueue = <String>{
        syncKey,
        ..._relatedSyncKeysFor(syncKey),
      }.toList(growable: false);
      final queuedJobs = await _controlPlaneClient.createJobs(
        clientName: widget.clientName,
        tables: tablesToQueue,
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
        return Material(
          color: Colors.transparent,
          child: Ink(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            entry.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(height: 1.2, fontSize: 12.5),
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
        textDirection: directionForDisplayText(value),
        textAlign: TextAlign.start,
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
      _buildClientUpdateIndicator(),
      _InfoLine(label: 'Agent', value: agentStatus),
      _InfoLine(label: 'SQL', value: sqlStatus),
      _InfoLine(label: 'Database', value: _selectedDatabase ?? 'None'),
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

  Widget _buildClientUpdateIndicator() {
    final hasUpdate = _hasClientUpdate;
    final color =
        hasUpdate
            ? const Color(0xFFB45309)
            : _clientUpdateError != null
            ? const Color(0xFFB42318)
            : const Color(0xFF0F766E);
    final tooltip =
        hasUpdate
            ? 'A newer Windows client is available. Click for the update command.'
            : _clientUpdateError != null
            ? 'Could not check for a client update: $_clientUpdateError'
            : 'Windows client update status.';

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _showClientUpdateDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasUpdate
                    ? Icons.system_update_alt_rounded
                    : _clientUpdateError != null
                    ? Icons.warning_amber_rounded
                    : Icons.verified_rounded,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                'Update: ${_clientUpdateLabel()}',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
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

class _TableFingerprint {
  const _TableFingerprint({required this.rowCount, required this.checksum});

  final int rowCount;
  final String checksum;
}

class _RelaySnapshotDocument {
  const _RelaySnapshotDocument({
    required this.createdAt,
    required this.rowCount,
    required this.snapshotBytes,
    required this.snapshotJson,
    this.changeTrackingVersion,
  });

  final String createdAt;
  final int rowCount;
  final int snapshotBytes;
  final String snapshotJson;
  final int? changeTrackingVersion;
}

class _ChangeTrackingState {
  const _ChangeTrackingState({
    required this.currentVersion,
    required this.minValidVersion,
  });

  final int currentVersion;
  final int minValidVersion;
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
  const _QualifiedTableName({
    this.database = '',
    required this.schema,
    required this.table,
  });

  final String database;
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

enum _SyncTableSortField { name, lastSync, rows }

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
