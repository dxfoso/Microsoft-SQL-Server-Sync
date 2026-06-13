import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'browser_bridge.dart';
import 'dashboard_widgets.dart';
import 'live_sync_api.dart';
import 'models.dart';

const String _historyLimitStorageKey = 'sync_admin_web.history_limit';
const int _defaultHistoryLimit = 5;
const int _maxHistoryLimit = 100;
const int _defaultAutoSyncIntervalMinutes = 15;
const int _minAutoSyncIntervalMinutes = 1;
const int _maxAutoSyncIntervalMinutes = 1440;
const Duration _dashboardRefreshInterval = Duration(seconds: 5);
const Duration _dashboardReconnectDelay = Duration(minutes: 1);
const String _buildCommitHash = String.fromEnvironment(
  'BUILD_COMMIT_HASH',
  defaultValue: 'd6ad13468380fff48127806b860e02c2b8cee659',
);
const String _buildCommitDate = String.fromEnvironment(
  'BUILD_COMMIT_DATE',
  defaultValue: '2026-04-14 11:12:09 +0200',
);
const String _buildReleaseDate = String.fromEnvironment(
  'BUILD_RELEASE_DATE',
  defaultValue: '2026-04-14 11:12:09 +0200',
);
const String _buildCommitMessage = 'Update web about dialog commit metadata';

enum _ProfileMenuAction { settings, users, about, signOut }

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({
    super.key,
    required this.authenticatedUser,
    required this.authToken,
    required this.onLogout,
  });

  final AuthenticatedUser authenticatedUser;
  final String authToken;
  final VoidCallback onLogout;

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final LiveSyncApiClient _api = LiveSyncApiClient();
  final TextEditingController _syncSearchController = TextEditingController();
  Timer? _refreshTimer;
  Timer? _reconnectTimer;

  AdminLiveState? _state;
  AdminLiveState? _derivedStateSource;
  List<_TableAggregateSummary> _derivedTableSummaries =
      const <_TableAggregateSummary>[];
  Map<String, _TableAggregateSummary> _derivedSummaryByTable =
      const <String, _TableAggregateSummary>{};
  Map<String, List<_TableClientEntry>> _derivedClientsByTable =
      const <String, List<_TableClientEntry>>{};
  List<String> _derivedDatabaseNames = const <String>[];
  Map<String, int> _derivedDatabaseTableCounts = const <String, int>{};
  Map<String, _TableSnapshotSource> _derivedSnapshotSourcesByTable =
      const <String, _TableSnapshotSource>{};
  Map<String, List<AdminJob>> _derivedJobsByTable =
      const <String, List<AdminJob>>{};
  Map<String, List<AdminJob>> _derivedJobsByTableClient =
      const <String, List<AdminJob>>{};
  AdminSnapshotDetail? _snapshot;
  bool _loading = true;
  bool _connected = false;
  String? _error;
  String? _selectedClientName;
  String? _selectedTableName;
  String? _selectedDatabaseName;
  String? _selectedServerKey;
  String? _selectedPageClientName;
  bool _sortLastSyncAscending = false;
  int _detailTabIndex = 0;
  int _historyLimit = _defaultHistoryLimit;
  final Set<String> _busyBackupKeys = <String>{};
  @override
  void initState() {
    super.initState();
    _api.setAuthToken(widget.authToken);
    _historyLimit = _readStoredHistoryLimit();
    _syncSearchController.addListener(_handleSearchChange);
    _startRefreshPolling();
    unawaited(_refreshState());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _reconnectTimer?.cancel();
    _syncSearchController.removeListener(_handleSearchChange);
    _syncSearchController.dispose();
    _api.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AdminDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authToken != widget.authToken) {
      _api.setAuthToken(widget.authToken);
    }
  }

  void _handleSearchChange() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  int _readStoredHistoryLimit() {
    final raw = readBrowserStorage(_historyLimitStorageKey);
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null) {
      return _defaultHistoryLimit;
    }
    return parsed.clamp(1, _maxHistoryLimit);
  }

  bool _isAuthFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('authentication required') ||
        message.contains('session required') ||
        message.contains('unauthorized') ||
        message.contains('forbidden');
  }

  void _startRefreshPolling() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      _dashboardRefreshInterval,
      (_) => unawaited(_refreshState(silent: true)),
    );
  }

  void _scheduleReconnectRetry() {
    if (_reconnectTimer?.isActive ?? false) {
      return;
    }
    _refreshTimer?.cancel();
    _reconnectTimer = Timer(_dashboardReconnectDelay, () {
      _reconnectTimer = null;
      if (!mounted) {
        return;
      }
      unawaited(_refreshState());
    });
  }

  Future<void> _refreshState({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
      });
    }

    try {
      final nextState = await _api.fetchLiveState();
      if (!mounted) {
        return;
      }

      _ensureDerivedState(nextState);
      final nextServerItems = _serverInventoryItemsFromState(nextState);
      final nextDatabaseName = _resolveSelectedDatabase(nextState);
      final nextTableName = _resolveSelectedTable(
        nextState,
        databaseName: nextDatabaseName,
      );
      final nextClientName = _resolveSelectedClientForTable(
        nextState,
        nextTableName,
      );
      var nextServerKey = _selectedServerKey;
      var nextPageClientName = _selectedPageClientName;
      if (nextPageClientName != null) {
        final serverItem = _serverItemForClientName(
          nextPageClientName,
          items: nextServerItems,
        );
        if (serverItem == null) {
          nextPageClientName = null;
        } else {
          nextServerKey = serverItem.key;
        }
      }
      if (nextServerKey != null &&
          !nextServerItems.any((item) => item.key == nextServerKey)) {
        nextServerKey = null;
      }

      setState(() {
        _state = nextState;
        _selectedDatabaseName = nextDatabaseName;
        _selectedTableName = nextTableName;
        _selectedClientName = nextClientName;
        _selectedServerKey = nextServerKey;
        _selectedPageClientName = nextPageClientName;
        _connected = true;
        _loading = false;
        _error = null;
      });
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _startRefreshPolling();
    } catch (error) {
      if (!mounted) {
        return;
      }

      if (_isAuthFailure(error)) {
        widget.onLogout();
        return;
      }

      final backendHealthy = await _api.checkHealth();
      if (!mounted) {
        return;
      }

      setState(() {
        _connected = backendHealthy;
        _loading = false;
        _error = error.toString();
      });
      _scheduleReconnectRetry();
    }
  }

  List<AdminJob> get _jobs => _state?.jobs ?? const <AdminJob>[];

  List<_ServerInventoryItem> get _serverInventoryItems =>
      _serverInventoryItemsFromState(_state);

  List<_ServerInventoryItem> _serverInventoryItemsFromState(
    AdminLiveState? state,
  ) {
    final machineLabel = _localMachineLabelFromState(state);
    final agents = state?.agents ?? const <AdminAgent>[];
    final groupedAgents = <String, List<AdminAgent>>{};
    for (final agent in agents) {
      final serverName = _serverListTitleForAgent(agent, machineLabel);
      groupedAgents.putIfAbsent(serverName, () => <AdminAgent>[]).add(agent);
    }

    final items = groupedAgents.entries
        .map(
          (entry) => _buildServerInventoryItem(
            key: entry.key,
            title: entry.key,
            platformLabel: _platformLabelForServerAgents(entry.value),
            fallbackMachineName:
                entry.value.first.machineName.trim().isEmpty
                    ? machineLabel
                    : entry.value.first.machineName.trim(),
            fallbackRole: 'Server',
            agents: entry.value,
            isLocal: entry.value.any(
              (agent) =>
                  agent.machineName.trim().isEmpty ||
                  agent.machineName.trim() == machineLabel,
            ),
          ),
        )
        .toList(growable: false)
      ..sort((left, right) => left.title.compareTo(right.title));

    return items;
  }

  List<_TableAggregateSummary> get _tableSummaries {
    _ensureDerivedState(_state);
    return _derivedTableSummaries;
  }

  String _localMachineLabelFromState(AdminLiveState? state) {
    for (final agent in state?.agents ?? const <AdminAgent>[]) {
      final machineName = agent.machineName.trim();
      if (machineName.isNotEmpty) {
        return machineName;
      }
    }
    return 'This machine';
  }

  _ServerInventoryItem _buildServerInventoryItem({
    required String key,
    required String title,
    required String platformLabel,
    required String fallbackMachineName,
    required String fallbackRole,
    required List<AdminAgent> agents,
    required bool isLocal,
  }) {
    final sample = agents.isEmpty ? null : agents.first;
    final serverName = _serverDisplayName(agents);
    final machineName =
        sample?.machineName.trim().isNotEmpty == true
            ? sample!.machineName.trim()
            : fallbackMachineName;
    final databases = <String>{
      for (final agent in agents)
        if (agent.database.trim().isNotEmpty) agent.database.trim(),
    }.toList(growable: false)..sort();
    final clientNames = <String>{
      for (final agent in agents)
        if (agent.clientName.trim().isNotEmpty) agent.clientName.trim(),
    }.toList(growable: false)..sort();
    final onlineClients = agents.where((agent) => agent.isOnline).length;
    final serverConnectedClients =
        agents.where((agent) => agent.serverConnected).length;
    final sqlConnectedClients =
        agents.where((agent) => agent.sqlConnected).length;
    final available =
        agents.isEmpty ||
        onlineClients > 0 ||
        serverConnectedClients > 0 ||
        sqlConnectedClients > 0;
    final lastHeartbeat = _latestHeartbeat(agents);

    return _ServerInventoryItem(
      key: key,
      title: title,
      serverName: serverName,
      machineName: machineName,
      platformLabel: platformLabel,
      roleLabel: fallbackRole,
      statusLabel: available ? 'Available' : 'Offline',
      available: available,
      isLocal: isLocal,
      connectedClients: agents.length,
      onlineClients: onlineClients,
      serverConnectedClients: serverConnectedClients,
      sqlConnectedClients: sqlConnectedClients,
      databases: databases,
      clientNames: clientNames,
      lastHeartbeat: lastHeartbeat,
      agents: List<AdminAgent>.unmodifiable(agents),
    );
  }

  String _serverDisplayName(List<AdminAgent> agents) {
    for (final agent in agents) {
      final serverName = agent.server.trim();
      if (serverName.isNotEmpty) {
        return serverName;
      }
    }
    return 'Not reported';
  }

  String _serverListTitleForAgent(AdminAgent agent, String machineLabel) {
    final serverName = agent.server.trim();
    if (serverName.isNotEmpty) {
      return serverName;
    }
    final machineName = agent.machineName.trim();
    if (machineName.isNotEmpty) {
      return machineName;
    }
    return machineLabel;
  }

  String _platformLabelForServerAgents(List<AdminAgent> agents) {
    final hasLocalMachine = agents.any(
      (agent) => agent.machineName.trim().isNotEmpty,
    );
    return hasLocalMachine ? 'Connected' : 'Unknown';
  }

  String _latestHeartbeat(List<AdminAgent> agents) {
    String latest = '';
    for (final agent in agents) {
      final heartbeat = agent.lastHeartbeat.trim();
      if (heartbeat.isEmpty) {
        continue;
      }
      if (latest.isEmpty || _compareTimestamps(heartbeat, latest) > 0) {
        latest = heartbeat;
      }
    }
    return latest;
  }

  _ServerInventoryItem? get _selectedServerInventoryItem {
    final serverKey = _selectedServerKey;
    if (serverKey == null) {
      return null;
    }
    for (final item in _serverInventoryItems) {
      if (item.key == serverKey) {
        return item;
      }
    }
    return null;
  }

  AdminAgent? get _selectedPageClientAgent {
    final clientName = _selectedPageClientName;
    if (clientName == null) {
      return null;
    }
    return _agentForClientName(clientName);
  }

  _TableAggregateSummary? get _selectedTableSummary {
    final tableName = _selectedTableName;
    if (tableName == null) {
      return null;
    }
    _ensureDerivedState(_state);
    return _derivedSummaryByTable[tableName];
  }

  List<_TableClientEntry> get _selectedTableClients {
    _ensureDerivedState(_state);
    return _derivedClientsByTable[_selectedTableName] ??
        const <_TableClientEntry>[];
  }

  _TableClientEntry? get _selectedClientEntry {
    final clientName = _selectedClientName;
    if (clientName == null) {
      return null;
    }
    for (final entry in _selectedTableClients) {
      if (entry.agent.clientName == clientName) {
        return entry;
      }
    }
    return null;
  }

  void _ensureDerivedState(AdminLiveState? state) {
    if (identical(_derivedStateSource, state)) {
      return;
    }

    _derivedStateSource = state;
    if (state == null) {
      _derivedTableSummaries = const <_TableAggregateSummary>[];
      _derivedSummaryByTable = const <String, _TableAggregateSummary>{};
      _derivedClientsByTable = const <String, List<_TableClientEntry>>{};
      _derivedDatabaseNames = const <String>[];
      _derivedDatabaseTableCounts = const <String, int>{};
      _derivedSnapshotSourcesByTable = const <String, _TableSnapshotSource>{};
      _derivedJobsByTable = const <String, List<AdminJob>>{};
      _derivedJobsByTableClient = const <String, List<AdminJob>>{};
      return;
    }

    final buckets = <String, List<_TableClientEntry>>{};
    for (final agent in state.agents) {
      for (final tableState in agent.tables) {
        final tableKey = _tableKeyForAgent(agent, tableState);
        buckets
            .putIfAbsent(tableKey, () => <_TableClientEntry>[])
            .add(_TableClientEntry(agent: agent, tableState: tableState));
      }
    }

    final clientsByTable = <String, List<_TableClientEntry>>{};
    final summaries = <_TableAggregateSummary>[];
    for (final entry in buckets.entries) {
      final clients = List<_TableClientEntry>.from(entry.value)
        ..sort(_compareClientEntries);
      clientsByTable[entry.key] = clients;

      var latestClient = clients.first;
      for (final client in clients.skip(1)) {
        if (_compareTimestamps(
              _tableTimestampToken(client.tableState),
              _tableTimestampToken(latestClient.tableState),
            ) >
            0) {
          latestClient = client;
        }
      }

      summaries.add(
        _TableAggregateSummary(
          table: entry.key,
          lastSync: _tableTimestampToken(latestClient.tableState),
          clientCount: clients.length,
          masterCount: clients.where((item) => item.agent.isMaster).length,
          slaveCount: clients.where((item) => !item.agent.isMaster).length,
          latestRowCount: latestClient.tableState.rowCount,
          latestSnapshotBytes: latestClient.tableState.snapshotBytes,
          sourceClientName: latestClient.agent.clientName,
          clients: clients,
        ),
      );
    }

    summaries.sort(_compareSummariesByLastSyncDesc);
    _derivedTableSummaries = summaries;
    _derivedSummaryByTable = {
      for (final summary in summaries) summary.table: summary,
    };
    _derivedClientsByTable = clientsByTable;

    final snapshotSources = <String, _TableSnapshotSource>{};
    for (final snapshot in state.snapshots) {
      final existing = snapshotSources[snapshot.table];
      if (existing == null ||
          _compareTimestamps(snapshot.createdAt, existing.createdAt) > 0) {
        snapshotSources[snapshot.table] = _TableSnapshotSource(
          clientName: snapshot.clientName,
          table: snapshot.table,
          createdAt: snapshot.createdAt,
          rowCount: snapshot.rowCount,
          snapshotBytes: snapshot.snapshotBytes,
        );
      }
    }
    for (final summary in summaries) {
      snapshotSources.putIfAbsent(summary.table, () {
        final clients = clientsByTable[summary.table]!;
        _TableClientEntry? latestEntry;
        for (final entry in clients) {
          final token = _tableTimestampToken(entry.tableState);
          if (token.isEmpty) {
            continue;
          }
          if (latestEntry == null ||
              _compareTimestamps(
                    token,
                    _tableTimestampToken(latestEntry.tableState),
                  ) >
                  0) {
            latestEntry = entry;
          }
        }
        final fallback = latestEntry ?? clients.first;
        return _TableSnapshotSource(
          clientName: fallback.agent.clientName,
          table: summary.table,
          createdAt: _tableTimestampToken(fallback.tableState),
          rowCount: fallback.tableState.rowCount,
          snapshotBytes: fallback.tableState.snapshotBytes,
        );
      });
    }
    _derivedSnapshotSourcesByTable = snapshotSources;

    final databaseTableSets = <String, Set<String>>{};
    for (final summary in summaries.where(
      (summary) =>
          _summaryHasDataRows(summary, snapshotSources: snapshotSources),
    )) {
      final database = summary.database.trim();
      if (database.isEmpty) {
        continue;
      }
      databaseTableSets
          .putIfAbsent(database, () => <String>{})
          .add(summary.displayTable);
    }
    final databaseNames = databaseTableSets.keys.toList(growable: false)
      ..sort();
    _derivedDatabaseNames = databaseNames;
    _derivedDatabaseTableCounts = {
      for (final entry in databaseTableSets.entries)
        entry.key: entry.value.length,
    };

    final jobsByTable = <String, List<AdminJob>>{};
    final jobsByTableClient = <String, List<AdminJob>>{};
    for (final job in state.jobs) {
      jobsByTable.putIfAbsent(job.table, () => <AdminJob>[]).add(job);
      jobsByTableClient
          .putIfAbsent(
            _historyClientKey(table: job.table, clientName: job.clientName),
            () => <AdminJob>[],
          )
          .add(job);
    }
    for (final jobs in jobsByTable.values) {
      jobs.sort(_compareJobsByUpdatedAtDesc);
    }
    for (final jobs in jobsByTableClient.values) {
      jobs.sort(_compareJobsByUpdatedAtDesc);
    }
    _derivedJobsByTable = {
      for (final entry in jobsByTable.entries)
        entry.key: List<AdminJob>.unmodifiable(entry.value),
    };
    _derivedJobsByTableClient = {
      for (final entry in jobsByTableClient.entries)
        entry.key: List<AdminJob>.unmodifiable(entry.value),
    };
  }

  List<String> _databaseNamesFromState(AdminLiveState? state) {
    _ensureDerivedState(state);
    return _derivedDatabaseNames;
  }

  Map<String, int> _databaseTableCountsFromState(AdminLiveState? state) {
    _ensureDerivedState(state);
    return _derivedDatabaseTableCounts;
  }

  String _databaseDropdownLabel(String database) {
    final count = _databaseTableCountsFromState(_state)[database] ?? 0;
    return '$database ($count)';
  }

  List<_TableAggregateSummary> _tableSummariesForDatabase(
    List<_TableAggregateSummary> summaries,
  ) {
    final databaseName = _selectedDatabaseName?.trim();
    return summaries
        .where(
          (summary) =>
              _summaryHasDataRows(summary) &&
              (databaseName == null ||
                  databaseName.isEmpty ||
                  summary.database == databaseName),
        )
        .toList(growable: false);
  }

  String? _resolveSelectedDatabase(AdminLiveState state) {
    final databases = _databaseNamesFromState(state);
    if (databases.isEmpty) {
      return null;
    }
    if (_selectedDatabaseName != null &&
        databases.contains(_selectedDatabaseName)) {
      return _selectedDatabaseName;
    }
    return databases.first;
  }

  String? _resolveSelectedTable(AdminLiveState state, {String? databaseName}) {
    final summaries = _tableSummariesFromState(state)
        .where(
          (summary) =>
              _summaryHasDataRows(summary) &&
              (databaseName == null ||
                  databaseName.isEmpty ||
                  summary.database == databaseName),
        )
        .toList(growable: false);
    if (summaries.isEmpty) {
      return null;
    }
    if (_selectedTableName != null &&
        summaries.any((summary) => summary.table == _selectedTableName)) {
      return _selectedTableName;
    }
    return summaries.first.table;
  }

  bool _summaryHasDataRows(
    _TableAggregateSummary summary, {
    Map<String, _TableSnapshotSource>? snapshotSources,
  }) {
    final sourceRows =
        (snapshotSources ?? _derivedSnapshotSourcesByTable)[summary.table]
            ?.rowCount ??
        0;
    return summary.latestRowCount > 0 ||
        sourceRows > 0 ||
        summary.clients.any((entry) => entry.tableState.rowCount > 0);
  }

  void _selectDatabase(String? databaseName) {
    if (databaseName == _selectedDatabaseName) {
      return;
    }
    final nextTableName =
        _state == null
            ? null
            : _resolveSelectedTable(_state!, databaseName: databaseName);
    final nextClientName =
        _state == null
            ? null
            : _resolveSelectedClientForTable(_state!, nextTableName);
    setState(() {
      _selectedDatabaseName = databaseName;
      _selectedTableName = nextTableName;
      _selectedClientName = nextClientName;
      _snapshot = null;
      _detailTabIndex = 0;
    });
  }

  String? _resolveSelectedClientForTable(
    AdminLiveState state,
    String? tableName,
  ) {
    final clients = _clientsForTableFromState(state, tableName);
    if (clients.isEmpty) {
      return null;
    }
    if (_selectedClientName != null &&
        clients.any((entry) => entry.agent.clientName == _selectedClientName)) {
      return _selectedClientName;
    }
    final snapshotSource = _snapshotSourceForTable(state, tableName);
    if (snapshotSource != null &&
        clients.any(
          (entry) => entry.agent.clientName == snapshotSource.clientName,
        )) {
      return snapshotSource.clientName;
    }
    return clients.first.agent.clientName;
  }

  List<_TableAggregateSummary> _tableSummariesFromState(AdminLiveState? state) {
    _ensureDerivedState(state);
    return _derivedTableSummaries;
  }

  String _tableKeyForAgent(AdminAgent agent, AdminTableState tableState) {
    final table = tableState.table.trim();
    if (table.isEmpty) {
      return table;
    }
    if (table.contains(_TableAggregateSummary.separator)) {
      final separatorIndex = table.indexOf(_TableAggregateSummary.separator);
      final database = table.substring(0, separatorIndex);
      final localTable = _stripDefaultSchema(
        table.substring(
          separatorIndex + _TableAggregateSummary.separator.length,
        ),
      );
      return '$database${_TableAggregateSummary.separator}$localTable';
    }
    final database = agent.database.trim();
    final localTable = _stripDefaultSchema(table);
    return database.isEmpty
        ? localTable
        : '$database${_TableAggregateSummary.separator}$localTable';
  }

  String _stripDefaultSchema(String table) =>
      table.trim().replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');

  List<_TableClientEntry> _clientsForTableFromState(
    AdminLiveState? state,
    String? tableName,
  ) {
    if (tableName == null) {
      return const <_TableClientEntry>[];
    }
    _ensureDerivedState(state);
    return _derivedClientsByTable[tableName] ?? const <_TableClientEntry>[];
  }

  int _compareClientEntries(_TableClientEntry left, _TableClientEntry right) {
    final byRole = (right.agent.isMaster ? 1 : 0).compareTo(
      left.agent.isMaster ? 1 : 0,
    );
    if (byRole != 0) {
      return byRole;
    }

    final byTimestamp = _compareTimestamps(
      _tableTimestampToken(right.tableState),
      _tableTimestampToken(left.tableState),
    );
    if (byTimestamp != 0) {
      return byTimestamp;
    }
    return left.agent.clientName.compareTo(right.agent.clientName);
  }

  _TableSnapshotSource? _snapshotSourceForTable(
    AdminLiveState? state,
    String? tableName,
  ) {
    if (tableName == null) {
      return null;
    }
    _ensureDerivedState(state);
    return _derivedSnapshotSourcesByTable[tableName];
  }

  String _tableTimestampToken(AdminTableState tableState) {
    final snapshotCreatedAt = tableState.snapshotCreatedAt?.trim() ?? '';
    if (snapshotCreatedAt.isNotEmpty) {
      return snapshotCreatedAt;
    }
    return tableState.lastSync.trim();
  }

  int _compareTimestamps(String left, String right) {
    return _timestampSortValue(left).compareTo(_timestampSortValue(right));
  }

  int _compareSummariesByLastSyncDesc(
    _TableAggregateSummary left,
    _TableAggregateSummary right,
  ) {
    final byTimestamp = _compareTimestamps(right.lastSync, left.lastSync);
    if (byTimestamp != 0) {
      return byTimestamp;
    }
    return left.table.compareTo(right.table);
  }

  int _compareSummariesByActiveSort(
    _TableAggregateSummary left,
    _TableAggregateSummary right,
  ) {
    final byTimestamp =
        _sortLastSyncAscending
            ? _compareTimestamps(left.lastSync, right.lastSync)
            : _compareTimestamps(right.lastSync, left.lastSync);
    if (byTimestamp != 0) {
      return byTimestamp;
    }
    return left.table.compareTo(right.table);
  }

  int _compareJobsByUpdatedAtDesc(AdminJob left, AdminJob right) {
    return _compareTimestamps(right.updatedAt, left.updatedAt);
  }

  String _historyClientKey({
    required String table,
    required String clientName,
  }) {
    return '$table\x1F$clientName';
  }

  List<_TableAggregateSummary> _sortSummariesByActiveSort(
    List<_TableAggregateSummary> summaries,
  ) {
    return List<_TableAggregateSummary>.from(summaries)
      ..sort(_compareSummariesByActiveSort);
  }

  int _timestampSortValue(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      return parsed.toUtc().microsecondsSinceEpoch;
    }
    return raw.trim().isEmpty ? -1 : 0;
  }

  void _selectClient(String? clientName) {
    if (clientName == null || clientName == _selectedClientName) {
      return;
    }
    setState(() {
      _selectedClientName = clientName;
    });
  }

  void _selectTable(String? tableName) {
    if (tableName == null || tableName == _selectedTableName) {
      return;
    }
    final nextClientName =
        _state == null
            ? null
            : _resolveSelectedClientForTable(_state!, tableName);
    setState(() {
      _selectedTableName = tableName;
      _selectedClientName = nextClientName;
      _snapshot = null;
      _detailTabIndex = 0;
    });
  }

  AdminAgent? _agentForClientName(String clientName) {
    for (final agent in _state?.agents ?? const <AdminAgent>[]) {
      if (agent.clientName == clientName) {
        return agent;
      }
    }
    return null;
  }

  _ServerInventoryItem? _serverItemForClientName(
    String clientName, {
    List<_ServerInventoryItem>? items,
  }) {
    for (final item in items ?? _serverInventoryItems) {
      for (final agent in item.agents) {
        if (agent.clientName == clientName) {
          return item;
        }
      }
    }
    return null;
  }

  void _selectOverviewPage() {
    setState(() {
      _selectedServerKey = null;
      _selectedPageClientName = null;
    });
  }

  void _selectServerPage(String serverKey) {
    setState(() {
      _selectedServerKey = serverKey;
      _selectedPageClientName = null;
    });
  }

  void _openClientPage(String clientName) {
    final serverItem = _serverItemForClientName(clientName);
    setState(() {
      _selectedServerKey = serverItem?.key;
      _selectedPageClientName = clientName;
    });
  }

  void _toggleTableLastSyncSort() {
    setState(() {
      _sortLastSyncAscending = !_sortLastSyncAscending;
    });
  }

  Future<void> _openSettingsDialog() async {
    final webHistoryController = TextEditingController(
      text: _historyLimit.toString(),
    );
    final agents = List<AdminAgent>.from(_state?.agents ?? const [])
      ..sort((left, right) => left.clientName.compareTo(right.clientName));
    AdminAgent? findAgent(String? clientName) {
      if (clientName == null) {
        return null;
      }
      for (final agent in agents) {
        if (agent.clientName == clientName) {
          return agent;
        }
      }
      return null;
    }

    var selectedAgent = findAgent(_selectedClientName);
    selectedAgent ??= agents.isEmpty ? null : agents.first;
    var selectedClientName = selectedAgent?.clientName;
    final agentHistoryController = TextEditingController(
      text: (selectedAgent?.historyLimit ?? _defaultHistoryLimit).toString(),
    );
    final autoSyncIntervalController = TextEditingController(
      text:
          (selectedAgent?.autoSyncIntervalMinutes ??
                  _defaultAutoSyncIntervalMinutes)
              .toString(),
    );
    var isMaster = selectedAgent?.isMaster ?? true;
    var saving = false;
    String? webHistoryError;
    String? agentHistoryError;
    String? autoSyncIntervalError;
    String? saveError;

    void selectAgent(AdminAgent agent) {
      selectedAgent = agent;
      selectedClientName = agent.clientName;
      agentHistoryController.text = agent.historyLimit.toString();
      autoSyncIntervalController.text =
          agent.autoSyncIntervalMinutes.toString();
      isMaster = agent.isMaster;
      agentHistoryError = null;
      autoSyncIntervalError = null;
      saveError = null;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Settings'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: webHistoryController,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Web History Items',
                          hintText: '5',
                          errorText: webHistoryError,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Sync Settings',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      if (agents.isEmpty)
                        const Text('No client agents are available yet.')
                      else ...[
                        DropdownButtonFormField<String>(
                          value: selectedClientName,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Sync Client',
                            prefixIcon: Icon(Icons.desktop_windows_rounded),
                          ),
                          selectedItemBuilder:
                              (context) => agents
                                  .map(
                                    (agent) => _buildAgentDropdownOption(
                                      agent,
                                      selected: true,
                                    ),
                                  )
                                  .toList(growable: false),
                          items: agents
                              .map(
                                (agent) => DropdownMenuItem<String>(
                                  value: agent.clientName,
                                  child: _buildAgentDropdownOption(agent),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (value) {
                            final agent = findAgent(value);
                            if (agent == null) {
                              return;
                            }
                            setDialogState(() {
                              selectAgent(agent);
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<bool>(
                          value: isMaster,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Client Type',
                            prefixIcon: Icon(Icons.sync_alt_rounded),
                          ),
                          selectedItemBuilder:
                              (context) => const [true, false]
                                  .map(
                                    (value) => _buildSyncRoleDropdownOption(
                                      value,
                                      selected: true,
                                    ),
                                  )
                                  .toList(growable: false),
                          items: [
                            DropdownMenuItem<bool>(
                              value: true,
                              child: _buildSyncRoleDropdownOption(true),
                            ),
                            DropdownMenuItem<bool>(
                              value: false,
                              child: _buildSyncRoleDropdownOption(false),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setDialogState(() {
                              isMaster = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: autoSyncIntervalController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Sync Interval (Minutes)',
                            hintText: '15',
                            errorText: autoSyncIntervalError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: agentHistoryController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Agent History Items',
                            hintText: '5',
                            errorText: agentHistoryError,
                          ),
                        ),
                      ],
                      if (saveError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          saveError!,
                          style: const TextStyle(
                            color: Color(0xFFB42318),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      saving
                          ? null
                          : () async {
                            final nextWebHistoryLimit = int.tryParse(
                              webHistoryController.text.trim(),
                            );
                            if (nextWebHistoryLimit == null ||
                                nextWebHistoryLimit < 1 ||
                                nextWebHistoryLimit > _maxHistoryLimit) {
                              setDialogState(() {
                                webHistoryError =
                                    'Enter a number between 1 and $_maxHistoryLimit.';
                                agentHistoryError = null;
                                autoSyncIntervalError = null;
                                saveError = null;
                              });
                              return;
                            }

                            int? nextAgentHistoryLimit;
                            int? nextAutoSyncInterval;
                            if (selectedClientName != null) {
                              nextAgentHistoryLimit = int.tryParse(
                                agentHistoryController.text.trim(),
                              );
                              if (nextAgentHistoryLimit == null ||
                                  nextAgentHistoryLimit < 1 ||
                                  nextAgentHistoryLimit > _maxHistoryLimit) {
                                setDialogState(() {
                                  webHistoryError = null;
                                  agentHistoryError =
                                      'Enter a number between 1 and $_maxHistoryLimit.';
                                  autoSyncIntervalError = null;
                                  saveError = null;
                                });
                                return;
                              }

                              nextAutoSyncInterval = int.tryParse(
                                autoSyncIntervalController.text.trim(),
                              );
                              if (nextAutoSyncInterval == null ||
                                  nextAutoSyncInterval <
                                      _minAutoSyncIntervalMinutes ||
                                  nextAutoSyncInterval >
                                      _maxAutoSyncIntervalMinutes) {
                                setDialogState(() {
                                  webHistoryError = null;
                                  agentHistoryError = null;
                                  autoSyncIntervalError =
                                      'Enter a number between $_minAutoSyncIntervalMinutes and $_maxAutoSyncIntervalMinutes.';
                                  saveError = null;
                                });
                                return;
                              }
                            }

                            setDialogState(() {
                              saving = true;
                              webHistoryError = null;
                              agentHistoryError = null;
                              autoSyncIntervalError = null;
                              saveError = null;
                            });

                            try {
                              if (selectedClientName != null &&
                                  nextAgentHistoryLimit != null &&
                                  nextAutoSyncInterval != null) {
                                await _api.updateAgentSyncSettings(
                                  clientName: selectedClientName!,
                                  isMaster: isMaster,
                                  historyLimit: nextAgentHistoryLimit,
                                  autoSyncIntervalMinutes: nextAutoSyncInterval,
                                );
                              }
                            } catch (error) {
                              if (!context.mounted) {
                                return;
                              }
                              setDialogState(() {
                                saving = false;
                                saveError = error.toString();
                              });
                              return;
                            }

                            if (!mounted || !context.mounted) {
                              return;
                            }

                            writeBrowserStorage(
                              _historyLimitStorageKey,
                              nextWebHistoryLimit.toString(),
                            );
                            setState(() {
                              _historyLimit = nextWebHistoryLimit;
                            });
                            Navigator.of(context).pop();
                            await _refreshState();
                          },
                  child: Text(saving ? 'Saving...' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    webHistoryController.dispose();
    agentHistoryController.dispose();
    autoSyncIntervalController.dispose();
  }

  Future<void> _openUserManagementDialog() async {
    if (!widget.authenticatedUser.canManageUsers) {
      return;
    }

    List<AuthenticatedUser> users;
    try {
      users = await _api.listUsers();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }

    if (!mounted) {
      return;
    }

    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    var dialogUsers = List<AuthenticatedUser>.from(users);
    var selectedRole = widget.authenticatedUser.isAdmin ? 'owner' : 'client';
    var selectedOwnerUserId =
        widget.authenticatedUser.isOwner ? widget.authenticatedUser.id : null;
    String? errorText;
    bool submitting = false;
    bool showPassword = false;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final owners = dialogUsers
                .where((user) => user.isOwner)
                .toList(growable: false);
            if (widget.authenticatedUser.isAdmin &&
                selectedRole == 'client' &&
                owners.isNotEmpty &&
                (selectedOwnerUserId == null ||
                    !owners.any((owner) => owner.id == selectedOwnerUserId))) {
              selectedOwnerUserId = owners.first.id;
            }

            Future<void> submit() async {
              final name = nameController.text.trim();
              final email = emailController.text.trim();
              final password = passwordController.text;

              if (name.isEmpty || password.isEmpty || selectedRole.isEmpty) {
                setDialogState(() {
                  errorText = 'Name, password, and role are required.';
                });
                return;
              }

              if (selectedRole == 'client' &&
                  widget.authenticatedUser.isAdmin &&
                  (selectedOwnerUserId == null ||
                      selectedOwnerUserId!.trim().isEmpty)) {
                setDialogState(() {
                  errorText = 'Select a server for the client account.';
                });
                return;
              }

              setDialogState(() {
                submitting = true;
                errorText = null;
              });

              try {
                final createdUser = await _api.createUser(
                  name: name,
                  email: email.isEmpty ? null : email,
                  password: password,
                  role: selectedRole,
                  ownerUserId:
                      selectedRole == 'client'
                          ? (widget.authenticatedUser.isOwner
                              ? widget.authenticatedUser.id
                              : selectedOwnerUserId)
                          : null,
                );
                setDialogState(() {
                  dialogUsers = <AuthenticatedUser>[
                    createdUser,
                    ...dialogUsers,
                  ];
                  selectedRole =
                      widget.authenticatedUser.isAdmin ? 'owner' : 'client';
                  selectedOwnerUserId =
                      widget.authenticatedUser.isOwner
                          ? widget.authenticatedUser.id
                          : (owners.isNotEmpty ? owners.first.id : null);
                  submitting = false;
                  errorText = null;
                  nameController.clear();
                  emailController.clear();
                  passwordController.clear();
                });
              } catch (error) {
                setDialogState(() {
                  submitting = false;
                  errorText = error.toString();
                });
              }
            }

            Future<void> openResetPasswordDialog(AuthenticatedUser user) async {
              if (!widget.authenticatedUser.isAdmin) {
                return;
              }

              final newPasswordController = TextEditingController();
              final confirmPasswordController = TextEditingController();
              final confirmPasswordFocusNode = FocusNode();
              String? resetErrorText;
              bool resetSubmitting = false;
              bool showNewPassword = false;
              bool showConfirmPassword = false;

              try {
                await showDialog<void>(
                  context: context,
                  builder: (context) {
                    return StatefulBuilder(
                      builder: (context, setResetState) {
                        Future<void> submitReset() async {
                          final scaffoldMessenger = ScaffoldMessenger.of(
                            this.context,
                          );
                          final newPassword = newPasswordController.text;
                          final confirmPassword =
                              confirmPasswordController.text;

                          if (newPassword.isEmpty || confirmPassword.isEmpty) {
                            setResetState(() {
                              resetErrorText =
                                  'New password and confirm password are required.';
                            });
                            return;
                          }

                          if (newPassword != confirmPassword) {
                            setResetState(() {
                              resetErrorText =
                                  'New password and confirm password must match.';
                            });
                            return;
                          }

                          setResetState(() {
                            resetSubmitting = true;
                            resetErrorText = null;
                          });

                          try {
                            await _api.resetUserPassword(
                              userId: user.id,
                              newPassword: newPassword,
                            );
                            if (!context.mounted) {
                              return;
                            }
                            Navigator.of(context).pop();
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Password reset for ${user.name}.',
                                ),
                              ),
                            );
                          } catch (error) {
                            setResetState(() {
                              resetSubmitting = false;
                              resetErrorText = error.toString();
                            });
                          }
                        }

                        return AlertDialog(
                          title: Text('Reset Password for ${user.name}'),
                          content: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 380),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextField(
                                  controller: newPasswordController,
                                  obscureText: !showNewPassword,
                                  enableSuggestions: false,
                                  autocorrect: false,
                                  textInputAction: TextInputAction.next,
                                  decoration: InputDecoration(
                                    labelText: 'New Password',
                                    suffixIcon: IconButton(
                                      tooltip:
                                          showNewPassword
                                              ? 'Hide password'
                                              : 'Show password',
                                      onPressed: () {
                                        setResetState(() {
                                          showNewPassword = !showNewPassword;
                                        });
                                      },
                                      icon: Icon(
                                        showNewPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ),
                                  onSubmitted:
                                      (_) =>
                                          confirmPasswordFocusNode
                                              .requestFocus(),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: confirmPasswordController,
                                  focusNode: confirmPasswordFocusNode,
                                  obscureText: !showConfirmPassword,
                                  enableSuggestions: false,
                                  autocorrect: false,
                                  textInputAction: TextInputAction.done,
                                  decoration: InputDecoration(
                                    labelText: 'Confirm Password',
                                    suffixIcon: IconButton(
                                      tooltip:
                                          showConfirmPassword
                                              ? 'Hide password'
                                              : 'Show password',
                                      onPressed: () {
                                        setResetState(() {
                                          showConfirmPassword =
                                              !showConfirmPassword;
                                        });
                                      },
                                      icon: Icon(
                                        showConfirmPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ),
                                  onSubmitted: (_) => unawaited(submitReset()),
                                ),
                                if (resetErrorText != null) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    resetErrorText!,
                                    style: const TextStyle(
                                      color: Color(0xFFB42318),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed:
                                  resetSubmitting
                                      ? null
                                      : () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed:
                                  resetSubmitting
                                      ? null
                                      : () => unawaited(submitReset()),
                              child: Text(
                                resetSubmitting
                                    ? 'Resetting...'
                                    : 'Reset Password',
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              } finally {
                newPasswordController.dispose();
                confirmPasswordController.dispose();
                confirmPasswordFocusNode.dispose();
              }
            }

            return Dialog(
              insetPadding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 880,
                  maxHeight: 720,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'User Management',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.authenticatedUser.isAdmin
                            ? 'Admin can create server or client accounts. Server accounts can create client accounts only.'
                            : 'Server accounts can create client accounts for the Windows app.',
                        style: const TextStyle(
                          color: Color(0xFF58656B),
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: 260,
                            child: TextField(
                              controller: nameController,
                              decoration: const InputDecoration(
                                labelText: 'Name',
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 260,
                            child: TextField(
                              controller: emailController,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Email (Optional)',
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: TextField(
                              controller: passwordController,
                              obscureText: !showPassword,
                              enableSuggestions: false,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                suffixIcon: IconButton(
                                  tooltip:
                                      showPassword
                                          ? 'Hide password'
                                          : 'Show password',
                                  onPressed: () {
                                    setDialogState(() {
                                      showPassword = !showPassword;
                                    });
                                  },
                                  icon: Icon(
                                    showPassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              onSubmitted: (_) => unawaited(submit()),
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: DropdownButtonFormField<String>(
                              value: selectedRole,
                              decoration: const InputDecoration(
                                labelText: 'Role',
                                prefixIcon: Icon(
                                  Icons.admin_panel_settings_rounded,
                                ),
                              ),
                              selectedItemBuilder:
                                  (context) => [
                                        if (widget.authenticatedUser.isAdmin)
                                          'owner',
                                        'client',
                                      ]
                                      .map(
                                        (role) => _buildUserRoleDropdownOption(
                                          role,
                                          selected: true,
                                        ),
                                      )
                                      .toList(growable: false),
                              items: [
                                if (widget.authenticatedUser.isAdmin)
                                  DropdownMenuItem(
                                    value: 'owner',
                                    child: _buildUserRoleDropdownOption(
                                      'owner',
                                    ),
                                  ),
                                DropdownMenuItem(
                                  value: 'client',
                                  child: _buildUserRoleDropdownOption('client'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) {
                                  return;
                                }
                                setDialogState(() {
                                  selectedRole = value;
                                });
                              },
                            ),
                          ),
                          if (widget.authenticatedUser.isAdmin &&
                              selectedRole == 'client')
                            SizedBox(
                              width: 220,
                              child: DropdownButtonFormField<String>(
                                value: selectedOwnerUserId,
                                decoration: const InputDecoration(
                                  labelText: 'Server',
                                ),
                                items: owners
                                    .map(
                                      (owner) => DropdownMenuItem(
                                        value: owner.id,
                                        child: Text(owner.name),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) {
                                  setDialogState(() {
                                    selectedOwnerUserId = value;
                                  });
                                },
                              ),
                            ),
                          FilledButton(
                            onPressed:
                                submitting ? null : () => unawaited(submit()),
                            child: Text(
                              submitting ? 'Creating...' : 'Create User',
                            ),
                          ),
                        ],
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          errorText!,
                          style: const TextStyle(
                            color: Color(0xFFB42318),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Text(
                        'Visible Users',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child:
                            dialogUsers.isEmpty
                                ? const EmptyStateCard(
                                  message:
                                      'No accounts are visible for this user.',
                                )
                                : ListView.separated(
                                  itemCount: dialogUsers.length,
                                  separatorBuilder:
                                      (_, _) => const SizedBox(height: 8),
                                  itemBuilder: (context, index) {
                                    final user = dialogUsers[index];
                                    final serverLabel =
                                        user.ownerName ??
                                        user.ownerUsername ??
                                        user.ownerEmail ??
                                        (user.isOwner ? 'Self' : 'Unassigned');
                                    return Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFFDDE3EA),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  user.name,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                if (user.email
                                                    .trim()
                                                    .isNotEmpty)
                                                  Text(
                                                    user.email,
                                                    style: const TextStyle(
                                                      color: Color(0xFF8A949A),
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          StatusBadge(
                                            label: user.role.toUpperCase(),
                                            color:
                                                user.isAdmin
                                                    ? const Color(0xFF143842)
                                                    : user.isOwner
                                                    ? const Color(0xFF2B6F73)
                                                    : const Color(0xFFD8A23A),
                                          ),
                                          const SizedBox(width: 12),
                                          SizedBox(
                                            width: 180,
                                            child: Text(
                                              user.isClient
                                                  ? 'Server: $serverLabel'
                                                  : 'Web account',
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(
                                                color: Color(0xFF58656B),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          if (widget
                                              .authenticatedUser
                                              .isAdmin) ...[
                                            const SizedBox(width: 12),
                                            OutlinedButton(
                                              onPressed:
                                                  () => unawaited(
                                                    openResetPasswordDialog(
                                                      user,
                                                    ),
                                                  ),
                                              child: const Text(
                                                'Reset Password',
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    );
                                  },
                                ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
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

    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
  }

  Future<void> _openHistoryDialog({
    required String clientName,
    required String table,
    String? backLabel,
  }) async {
    _selectClient(clientName);
    final jobs = _jobsForClientAndTable(clientName: clientName, table: table);
    final searchController = TextEditingController();
    AdminJob? selectedJob;
    Future<AdminSnapshotDetail?>? selectedSnapshotFuture;

    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final job = selectedJob;
              final showingData = job != null;
              final canGoBackToDetails =
                  !showingData && (backLabel?.trim().isNotEmpty ?? false);

              return Dialog(
                insetPadding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: showingData ? 1180 : 860,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.84,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (showingData || canGoBackToDetails) ...[
                              IconButton(
                                tooltip:
                                    showingData
                                        ? 'Back to history'
                                        : backLabel!.trim(),
                                onPressed: () {
                                  if (!showingData) {
                                    Navigator.of(context).pop();
                                    return;
                                  }
                                  setDialogState(() {
                                    selectedJob = null;
                                    selectedSnapshotFuture = null;
                                    searchController.clear();
                                  });
                                },
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                showingData
                                    ? '${job.table} Data'
                                    : '$clientName History',
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
                        const SizedBox(height: 12),
                        Expanded(
                          child:
                              showingData
                                  ? FutureBuilder<AdminSnapshotDetail?>(
                                    future: selectedSnapshotFuture,
                                    builder: (context, snapshotState) {
                                      return _buildSnapshotDataContent(
                                        job: job,
                                        snapshotState: snapshotState,
                                        searchController: searchController,
                                        onSearchChanged:
                                            () => setDialogState(() {}),
                                      );
                                    },
                                  )
                                  : jobs.isEmpty
                                  ? const EmptyStateCard(
                                    message:
                                        'No sync jobs have been recorded yet for this client or table.',
                                  )
                                  : ListView.separated(
                                    itemCount: jobs.length,
                                    separatorBuilder:
                                        (_, _) => const SizedBox(height: 6),
                                    itemBuilder: (context, index) {
                                      final historyJob = jobs[index];
                                      return _buildJobCard(
                                        historyJob,
                                        onOpenSnapshot: () {
                                          final snapshotId =
                                              historyJob.snapshotId?.trim() ??
                                              '';
                                          if (snapshotId.isEmpty) {
                                            return;
                                          }
                                          setDialogState(() {
                                            selectedJob = historyJob;
                                            selectedSnapshotFuture = _api
                                                .fetchSnapshotById(snapshotId);
                                            searchController.clear();
                                          });
                                        },
                                      );
                                    },
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

  Future<void> _openAboutDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('About'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoLine(
                  label: 'Commit date',
                  value: _formatTimestamp(_buildCommitDate),
                ),
                const SizedBox(height: 10),
                InfoLine(
                  label: 'Release date',
                  value: _formatTimestamp(_buildReleaseDate),
                ),
                const SizedBox(height: 10),
                InfoLine(label: 'Commit message', value: _buildCommitMessage),
                const SizedBox(height: 10),
                InfoLine(label: 'Commit hash', value: _buildCommitHash),
                const SizedBox(height: 10),
                InfoLine(label: 'Build', value: 'Web control plane'),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openJobSnapshotDialog(AdminJob job) async {
    final snapshotId = job.snapshotId?.trim() ?? '';
    if (snapshotId.isEmpty) {
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
    final snapshotFuture = _api.fetchSnapshotById(snapshotId);

    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return Dialog(
                insetPadding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 1180,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FutureBuilder<AdminSnapshotDetail?>(
                      future: snapshotFuture,
                      builder: (context, snapshotState) {
                        final snapshot = snapshotState.data;
                        final filteredRows =
                            snapshot == null
                                ? const <_ScoredSnapshotRow>[]
                                : _filteredSnapshotRowsForQuery(
                                  snapshot,
                                  searchController.text,
                                );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${job.table} Data',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
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
                                MetricPill(
                                  label: 'Client',
                                  value: job.clientName,
                                ),
                                MetricPill(
                                  label: 'Status',
                                  value: job.status.toUpperCase(),
                                ),
                                MetricPill(
                                  label: 'Date',
                                  value: _formatTimestamp(
                                    job.completedAt ?? job.updatedAt,
                                  ),
                                ),
                                MetricPill(
                                  label: 'Rows',
                                  value:
                                      snapshot == null
                                          ? '${job.rowCount}'
                                          : '${filteredRows.length} / ${snapshot.rowCount}',
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: searchController,
                              onChanged: (_) => setDialogState(() {}),
                              decoration: InputDecoration(
                                labelText: 'Search Rows',
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
                                  snapshotState.connectionState ==
                                              ConnectionState.waiting &&
                                          snapshot == null
                                      ? const Center(
                                        child: CircularProgressIndicator(),
                                      )
                                      : snapshotState.hasError
                                      ? EmptyStateCard(
                                        message: snapshotState.error.toString(),
                                      )
                                      : snapshot == null
                                      ? const EmptyStateCard(
                                        message:
                                            'No snapshot data is available for this history item.',
                                      )
                                      : filteredRows.isEmpty
                                      ? EmptyStateCard(
                                        message:
                                            searchController.text.trim().isEmpty
                                                ? 'This snapshot has no rows.'
                                                : 'No rows matched your search. Try a broader term or clear the search box.',
                                      )
                                      : _buildSnapshotGrid(
                                        snapshot,
                                        filteredRows,
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
        },
      );
    } finally {
      searchController.dispose();
    }
  }

  Future<void> _openClientDetailDialog({
    required _TableAggregateSummary summary,
    required _TableClientEntry entry,
  }) async {
    _selectClient(entry.agent.clientName);
    final jobs = _jobsForClientAndTable(
      clientName: entry.agent.clientName,
      table: summary.table,
    );
    final recentJobs = jobs.take(_historyLimit).toList(growable: false);
    final searchController = TextEditingController();
    final latestSnapshotFuture = _api.fetchLatestSnapshot(
      clientName: entry.agent.clientName,
      table: summary.table,
    );

    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final busy = _isBackupBusy(entry.agent.clientName, summary.table);

              return Dialog(
                insetPadding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 1180,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.88,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildClientDetailDialogHeader(
                          summary: summary,
                          entry: entry,
                        ),
                        const SizedBox(height: 8),
                        _buildSelectedClientInfo(
                          entry,
                          tableName: summary.displayTitle,
                          busy: busy,
                          recentHistoryCount: recentJobs.length,
                          totalHistoryCount: jobs.length,
                          onDownload:
                              () => _downloadSnapshotFile(
                                clientName: entry.agent.clientName,
                                table: summary.table,
                              ),
                          onUpload:
                              () => _uploadSnapshotFile(
                                clientName: entry.agent.clientName,
                                table: summary.table,
                              ),
                          onPush:
                              entry.tableState.enabled
                                  ? () => _triggerJob(
                                    clientName: entry.agent.clientName,
                                    table: summary.table,
                                    direction: 'upload',
                                  )
                                  : null,
                          onPull:
                              entry.tableState.enabled
                                  ? () => _triggerJob(
                                    clientName: entry.agent.clientName,
                                    table: summary.table,
                                    direction: 'download',
                                  )
                                  : null,
                          onOpenHistory:
                              () => _openHistoryDialog(
                                clientName: entry.agent.clientName,
                                table: summary.table,
                                backLabel: 'Back to details',
                              ),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final stack = constraints.maxWidth < 900;
                              final snapshotPanel =
                                  FutureBuilder<AdminSnapshotDetail?>(
                                    future: latestSnapshotFuture,
                                    builder:
                                        (context, snapshotState) =>
                                            _buildLatestSnapshotPanel(
                                              snapshotState: snapshotState,
                                              searchController:
                                                  searchController,
                                              onSearchChanged:
                                                  () => setDialogState(() {}),
                                            ),
                                  );
                              final historyPanel = _buildRecentHistoryPanel(
                                recentJobs,
                              );

                              if (stack) {
                                return Column(
                                  children: [
                                    Expanded(flex: 3, child: snapshotPanel),
                                    const SizedBox(height: 12),
                                    Expanded(flex: 2, child: historyPanel),
                                  ],
                                );
                              }

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 7, child: snapshotPanel),
                                  const SizedBox(width: 12),
                                  Expanded(flex: 4, child: historyPanel),
                                ],
                              );
                            },
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

  Future<void> _openTableDataDialog(_TableAggregateSummary summary) async {
    final source = _snapshotSourceForTable(_state, summary.table);
    final clientName = source?.clientName ?? summary.sourceClientName;
    final searchController = TextEditingController();
    final latestSnapshotFuture = _api.fetchLatestSnapshot(
      clientName: clientName,
      table: summary.table,
    );
    final masterSnapshotsFuture = _loadLatestMasterSnapshotsForTable(
      summary.table,
    );

    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return Dialog(
                insetPadding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 1180,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.88,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE6F4F1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFB8DDD6),
                                ),
                              ),
                              child: const Icon(
                                Icons.table_rows_outlined,
                                color: Color(0xFF0F766E),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    summary.displayTitle,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Latest rows from $clientName',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF667085),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: FutureBuilder<AdminSnapshotDetail?>(
                            future: latestSnapshotFuture,
                            builder:
                                (context, snapshotState) =>
                                    _buildLatestSnapshotPanel(
                                      snapshotState: snapshotState,
                                      searchController: searchController,
                                      onSearchChanged:
                                          () => setDialogState(() {}),
                                      rowMasterSnapshotsFuture:
                                          masterSnapshotsFuture,
                                    ),
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

  Widget _buildLatestSnapshotPanel({
    required AsyncSnapshot<AdminSnapshotDetail?> snapshotState,
    required TextEditingController searchController,
    required VoidCallback onSearchChanged,
    Future<List<AdminSnapshotDetail>>? rowMasterSnapshotsFuture,
  }) {
    final snapshot = snapshotState.data;
    final filteredRows =
        snapshot == null
            ? const <_ScoredSnapshotRow>[]
            : _filteredSnapshotRowsForQuery(snapshot, searchController.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Snapshot Data'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            MetricPill(label: 'Rows', value: '${snapshot?.rowCount ?? 0}'),
            MetricPill(
              label: 'Columns',
              value: '${snapshot?.columns.length ?? 0}',
            ),
            MetricPill(
              label: 'Size',
              value: _formatBytes(snapshot?.snapshotBytes ?? 0),
            ),
            MetricPill(
              label: 'Created',
              value: _formatTimestamp(snapshot?.createdAt ?? ''),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: searchController,
          onChanged: (_) => onSearchChanged(),
          decoration: InputDecoration(
            labelText: 'Search Snapshot Rows',
            hintText: 'Search across loaded snapshot columns.',
            prefixIcon: const Icon(Icons.search),
            suffixIcon:
                searchController.text.isEmpty
                    ? null
                    : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged();
                      },
                      icon: const Icon(Icons.close),
                    ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child:
              snapshotState.connectionState == ConnectionState.waiting &&
                      snapshot == null
                  ? const Center(child: CircularProgressIndicator())
                  : snapshotState.hasError
                  ? EmptyStateCard(message: snapshotState.error.toString())
                  : snapshot == null
                  ? const EmptyStateCard(
                    message:
                        'No snapshot data is stored yet for this client and table.',
                  )
                  : filteredRows.isEmpty
                  ? EmptyStateCard(
                    message:
                        searchController.text.trim().isEmpty
                            ? 'This snapshot has no rows.'
                            : 'No rows matched your search. Try a broader term or clear the search box.',
                  )
                  : rowMasterSnapshotsFuture == null
                  ? _buildSnapshotGrid(snapshot, filteredRows)
                  : FutureBuilder<List<AdminSnapshotDetail>>(
                    future: rowMasterSnapshotsFuture,
                    builder: (context, masterState) {
                      final rowMasterCounts =
                          masterState.hasData
                              ? _masterRowCountsForSnapshot(
                                snapshot,
                                masterState.data!,
                              )
                              : null;
                      return _buildSnapshotGrid(
                        snapshot,
                        filteredRows,
                        showMasterMatchColumn: true,
                        rowMasterCounts: rowMasterCounts,
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Widget _buildRecentHistoryPanel(List<AdminJob> recentJobs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Recent History'),
        const SizedBox(height: 8),
        Expanded(
          child:
              recentJobs.isEmpty
                  ? const EmptyStateCard(
                    message:
                        'No sync jobs have been recorded yet for this client or table.',
                  )
                  : ListView.separated(
                    itemCount: recentJobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder:
                        (context, index) => _buildJobCard(recentJobs[index]),
                  ),
        ),
      ],
    );
  }

  Widget _buildSnapshotDataContent({
    required AdminJob job,
    required AsyncSnapshot<AdminSnapshotDetail?> snapshotState,
    required TextEditingController searchController,
    required VoidCallback onSearchChanged,
  }) {
    final snapshot = snapshotState.data;
    final filteredRows =
        snapshot == null
            ? const <_ScoredSnapshotRow>[]
            : _filteredSnapshotRowsForQuery(snapshot, searchController.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            MetricPill(label: 'Client', value: job.clientName),
            MetricPill(label: 'Status', value: job.status.toUpperCase()),
            MetricPill(
              label: 'Date',
              value: _formatTimestamp(job.completedAt ?? job.updatedAt),
            ),
            MetricPill(
              label: 'Rows',
              value:
                  snapshot == null
                      ? '${job.rowCount}'
                      : '${filteredRows.length} / ${snapshot.rowCount}',
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: searchController,
          onChanged: (_) => onSearchChanged(),
          decoration: InputDecoration(
            labelText: 'Search Rows',
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
                        onSearchChanged();
                      },
                      icon: const Icon(Icons.close),
                    ),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child:
              snapshotState.connectionState == ConnectionState.waiting &&
                      snapshot == null
                  ? const Center(child: CircularProgressIndicator())
                  : snapshotState.hasError
                  ? EmptyStateCard(message: snapshotState.error.toString())
                  : snapshot == null
                  ? const EmptyStateCard(
                    message:
                        'No snapshot data is available for this history item.',
                  )
                  : filteredRows.isEmpty
                  ? EmptyStateCard(
                    message:
                        searchController.text.trim().isEmpty
                            ? 'This snapshot has no rows.'
                            : 'No rows matched your search. Try a broader term or clear the search box.',
                  )
                  : _buildSnapshotGrid(snapshot, filteredRows),
        ),
      ],
    );
  }

  Future<void> _triggerJob({
    required String clientName,
    required String table,
    required String direction,
  }) async {
    try {
      await _api.triggerJob(
        clientName: clientName,
        table: table,
        direction: direction,
      );
      if (!mounted) {
        return;
      }
      final action = direction == 'download' ? 'Pull' : 'Push';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$action queued for $table on $clientName.')),
      );
      await _refreshState(silent: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  String _backupKey(String clientName, String table) => '$clientName::$table';

  bool _isBackupBusy(String clientName, String table) =>
      _busyBackupKeys.contains(_backupKey(clientName, table));

  void _setBackupBusy(String clientName, String table, bool busy) {
    final key = _backupKey(clientName, table);
    if (!mounted) {
      return;
    }
    setState(() {
      if (busy) {
        _busyBackupKeys.add(key);
      } else {
        _busyBackupKeys.remove(key);
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

  String _snapshotFilename(String clientName, String table, String createdAt) {
    String sanitize(String value) {
      final normalized = value
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
          .replaceAll(RegExp(r'-+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      return normalized.isEmpty ? 'snapshot' : normalized;
    }

    return '${sanitize(clientName)}-${sanitize(table)}-${sanitize(createdAt)}.json';
  }

  Map<String, dynamic> _snapshotFilePayload(
    AdminSnapshotDetail snapshot, {
    required int snapshotBytes,
  }) {
    return <String, dynamic>{
      'formatVersion': 1,
      'id': snapshot.id,
      'clientName': snapshot.clientName,
      'table': snapshot.table,
      'createdAt': snapshot.createdAt,
      'rowCount': snapshot.rowCount,
      'checksum': snapshot.checksum,
      'snapshotBytes': snapshotBytes,
      'columns': snapshot.columns,
      'rows': snapshot.rows,
      'sourceJobId': snapshot.sourceJobId,
    };
  }

  String _encodeSnapshotFile(AdminSnapshotDetail snapshot) {
    var snapshotBytes = 0;
    var encoded = jsonEncode(
      _snapshotFilePayload(snapshot, snapshotBytes: snapshotBytes),
    );

    for (var index = 0; index < 3; index += 1) {
      final nextBytes = utf8.encode(encoded).length;
      if (nextBytes == snapshotBytes) {
        snapshotBytes = nextBytes;
        break;
      }
      snapshotBytes = nextBytes;
      encoded = jsonEncode(
        _snapshotFilePayload(snapshot, snapshotBytes: snapshotBytes),
      );
    }

    return encoded;
  }

  Future<void> _downloadSnapshotFile({
    required String clientName,
    required String table,
  }) async {
    _setBackupBusy(clientName, table, true);
    try {
      final snapshot =
          _selectedClientName == clientName &&
                  _selectedTableName == table &&
                  _snapshot != null
              ? _snapshot
              : await _api.fetchLatestSnapshot(
                clientName: clientName,
                table: table,
              );

      if (!mounted) {
        return;
      }
      if (snapshot == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No backup file is available yet for $table.'),
          ),
        );
        return;
      }

      await downloadBrowserTextFile(
        filename: _snapshotFilename(clientName, table, snapshot.createdAt),
        content: _encodeSnapshotFile(snapshot),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded backup file for $table.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      _setBackupBusy(clientName, table, false);
    }
  }

  Future<void> _uploadSnapshotFile({
    required String clientName,
    required String table,
  }) async {
    _setBackupBusy(clientName, table, true);
    try {
      final pickedFile = await pickBrowserTextFile();
      if (pickedFile == null) {
        return;
      }

      final decoded = jsonDecode(pickedFile.content);
      if (decoded is! Map) {
        throw const FormatException('Backup file must contain a JSON object.');
      }

      await _api.importSnapshot(
        clientName: clientName,
        table: table,
        snapshot: Map<String, dynamic>.from(decoded),
      );
      await _refreshState(silent: true);
      if (_selectedClientName == clientName && _selectedTableName == table) {
        setState(() {
          _snapshot = null;
        });
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploaded backup file to $table.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      _setBackupBusy(clientName, table, false);
    }
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
    return '$day.$month.$year  $hour:$minute:$second';
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
      case 'synced':
        return const Color(0xFF0F766E);
      case 'failed':
        return const Color(0xFFB42318);
      case 'paused':
        return const Color(0xFF718096);
      default:
        return const Color(0xFFB7791F);
    }
  }

  Color _roleColor(bool isMaster) =>
      isMaster ? const Color(0xFF2563EB) : const Color(0xFF0F766E);

  IconData _roleIcon(bool isMaster) =>
      isMaster ? Icons.upload_rounded : Icons.download_done_rounded;

  String _roleLabel(bool isMaster) => isMaster ? 'Master' : 'Slave';

  String _roleDescription(bool isMaster) =>
      isMaster ? 'Uploads table snapshots.' : 'Downloads from masters.';

  Color _userRoleColor(String role) {
    switch (role) {
      case 'owner':
        return const Color(0xFF7C3AED);
      case 'admin':
        return const Color(0xFFB7791F);
      case 'client':
      default:
        return const Color(0xFF0F766E);
    }
  }

  IconData _userRoleIcon(String role) {
    switch (role) {
      case 'owner':
        return Icons.workspace_premium_rounded;
      case 'admin':
        return Icons.admin_panel_settings_rounded;
      case 'client':
      default:
        return Icons.desktop_windows_rounded;
    }
  }

  String _userRoleLabel(String role) {
    switch (role) {
      case 'owner':
        return 'Server';
      case 'admin':
        return 'Admin';
      case 'client':
      default:
        return 'Client';
    }
  }

  String _userRoleDescription(String role) {
    switch (role) {
      case 'owner':
        return 'Manages client accounts as a server.';
      case 'admin':
        return 'Full control plane access.';
      case 'client':
      default:
        return 'Signs in from Windows.';
    }
  }

  Widget _buildIconDropdownOption({
    required IconData icon,
    required String label,
    required String description,
    required Color color,
    bool selected = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color.withValues(alpha: 0.18)),
          ),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 10),
        Flexible(
          child:
              selected
                  ? Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  )
                  : Column(
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
                        description,
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

  Widget _buildSyncRoleDropdownOption(bool isMaster, {bool selected = false}) {
    return _buildIconDropdownOption(
      icon: _roleIcon(isMaster),
      label: _roleLabel(isMaster),
      description: _roleDescription(isMaster),
      color: _roleColor(isMaster),
      selected: selected,
    );
  }

  Widget _buildUserRoleDropdownOption(String role, {bool selected = false}) {
    return _buildIconDropdownOption(
      icon: _userRoleIcon(role),
      label: _userRoleLabel(role),
      description: _userRoleDescription(role),
      color: _userRoleColor(role),
      selected: selected,
    );
  }

  Widget _buildAgentDropdownOption(AdminAgent agent, {bool selected = false}) {
    return _buildIconDropdownOption(
      icon:
          agent.isMaster
              ? Icons.cloud_upload_rounded
              : Icons.cloud_done_rounded,
      label: agent.clientName,
      description:
          '${_roleLabel(agent.isMaster)} - ${agent.isOnline ? 'Online' : 'Offline'}',
      color: _roleColor(agent.isMaster),
      selected: selected,
    );
  }

  Widget _buildRoleBadge(bool isMaster, {bool compact = false}) {
    final color = _roleColor(isMaster);
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 24 : 26),
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 8, vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(_roleIcon(isMaster), size: compact ? 14 : 16, color: color),
          const SizedBox(width: 5),
          Text(
            _roleLabel(isMaster),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 11 : 12,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  double _bestMatchScore(String query, String candidate) {
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

    final subsequenceScore = _subsequenceScore(
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

  double _subsequenceScore(String query, String candidate) {
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

  List<_TableAggregateSummary> _filteredTableSummaries(
    List<_TableAggregateSummary> summaries,
  ) {
    final query = _syncSearchController.text.trim();
    if (query.isEmpty) {
      return _sortSummariesByActiveSort(summaries);
    }

    final matches = summaries
        .map((summary) {
          final score = _bestMatchScore(
            query,
            [
              summary.table,
              summary.database,
              summary.displayTable,
              summary.sourceClientName,
              _formatTimestamp(summary.lastSync),
              '${summary.clientCount}',
              '${summary.masterCount}',
              '${summary.slaveCount}',
              ...summary.clients.map((entry) {
                return [
                  entry.agent.clientName,
                  entry.agent.machineName,
                  _roleLabel(entry.agent.isMaster),
                  _tableKeyForAgent(entry.agent, entry.tableState),
                  entry.tableState.status,
                  entry.tableState.message,
                ].join(' ');
              }),
            ].join(' '),
          );
          return _ScoredTableSummary(summary: summary, score: score);
        })
        .where((match) => match.score > 0)
        .map((match) => match.summary)
        .toList(growable: false);

    return _sortSummariesByActiveSort(matches);
  }

  List<_TableClientEntry> _filteredTableClients(
    List<_TableClientEntry> entries,
  ) {
    return entries;
  }

  List<_ScoredSnapshotRow> _filteredSnapshotRowsForQuery(
    AdminSnapshotDetail snapshot,
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
          return _ScoredSnapshotRow(
            originalIndex: entry.key,
            row: entry.value,
            score:
                normalizedQuery.isEmpty
                    ? 1
                    : _bestMatchScore(normalizedQuery, rowText),
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

  List<AdminJob> _jobsForClientAndTable({
    required String clientName,
    required String table,
  }) {
    _ensureDerivedState(_state);
    return (_derivedJobsByTableClient[_historyClientKey(
              table: table,
              clientName: clientName,
            )] ??
            const <AdminJob>[])
        .take(_historyLimit)
        .toList(growable: false);
  }

  List<AdminJob> _filteredHistoryJobs({
    required String table,
    String? clientName,
    bool limit = true,
  }) {
    _ensureDerivedState(_state);
    final jobs =
        clientName == null
            ? _derivedJobsByTable[table] ?? const <AdminJob>[]
            : _derivedJobsByTableClient[_historyClientKey(
                  table: table,
                  clientName: clientName,
                )] ??
                const <AdminJob>[];

    return limit ? jobs.take(_historyLimit).toList(growable: false) : jobs;
  }

  int _syncedClientCountForSummary(_TableAggregateSummary summary) {
    return summary.clients
        .where((entry) => _tableStateHasSynced(entry.tableState))
        .length;
  }

  int _mergedClientCountForSummary(_TableAggregateSummary summary) {
    return summary.clients
        .where((entry) => _tableStateHasMerged(entry.tableState))
        .length;
  }

  int _attemptedClientCountForTable(String table) {
    _ensureDerivedState(_state);
    final names = <String>{};
    for (final job in _derivedJobsByTable[table] ?? const <AdminJob>[]) {
      final name = job.clientName.trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    return names.length;
  }

  bool _tableStateHasSynced(AdminTableState tableState) {
    final status = tableState.status.toLowerCase();
    return status == 'synced' ||
        tableState.lastSync.trim().isNotEmpty ||
        (tableState.snapshotId?.trim().isNotEmpty ?? false) ||
        (tableState.snapshotCreatedAt?.trim().isNotEmpty ?? false);
  }

  bool _tableStateHasMerged(AdminTableState tableState) {
    return tableState.mergedSnapshotSources.isNotEmpty ||
        (tableState.syncMode == 'masterMix' &&
            _tableStateHasSynced(tableState));
  }

  Widget _buildSearchField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.search),
        suffixIcon:
            controller.text.isEmpty
                ? null
                : IconButton(
                  tooltip: 'Clear search',
                  onPressed: controller.clear,
                  icon: const Icon(Icons.close),
                ),
      ),
    );
  }

  Widget _buildLastSyncSortButton() {
    final tooltip =
        _sortLastSyncAscending
            ? 'Last sync: oldest first'
            : 'Last sync: newest first';
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        onPressed: _toggleTableLastSyncSort,
        icon: Icon(
          _sortLastSyncAscending
              ? Icons.arrow_upward_rounded
              : Icons.arrow_downward_rounded,
        ),
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildDatabaseSelector() {
    final databases = _databaseNamesFromState(_state);
    final selectedValue =
        _selectedDatabaseName != null &&
                databases.contains(_selectedDatabaseName)
            ? _selectedDatabaseName
            : null;

    return DropdownButtonFormField<String>(
      value: selectedValue,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Database',
        prefixIcon: Icon(Icons.storage_rounded),
      ),
      hint: const Text('Select database'),
      items: databases
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
      onChanged: databases.isEmpty ? null : _selectDatabase,
    );
  }

  Widget _buildTableListCard() {
    final summaries = _filteredTableSummaries(
      _tableSummariesForDatabase(_tableSummaries),
    );

    return SurfaceCard(
      title: 'Tables',
      subtitle: '',
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final stack = constraints.maxWidth < 620;
              final search = _buildSearchField(
                controller: _syncSearchController,
                label: 'Search Tables',
                hint: 'Search table names, databases, and clients.',
              );
              final database = _buildDatabaseSelector();
              final sort = _buildLastSyncSortButton();
              if (stack) {
                return Column(
                  children: [
                    database,
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: search),
                        const SizedBox(width: 8),
                        sort,
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  SizedBox(width: 260, child: database),
                  const SizedBox(width: 10),
                  Expanded(child: search),
                  const SizedBox(width: 8),
                  sort,
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          Expanded(
            child:
                summaries.isEmpty
                    ? EmptyStateCard(
                      message:
                          _syncSearchController.text.trim().isEmpty
                              ? 'No synced tables are available yet.'
                              : 'No tables matched your search.',
                    )
                    : ListView.separated(
                      itemCount: summaries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder:
                          (context, index) =>
                              _buildTableSummaryTile(summaries[index]),
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableSummaryTile(_TableAggregateSummary summary) {
    final selected = summary.table == _selectedTableName;
    final sourceEntry = _sourceEntryForSummary(summary);
    final statusColor = _statusColor(sourceEntry.tableState.status);
    final lastSync = _formatTimestamp(summary.lastSync);
    final progress = sourceEntry.tableState.progress.clamp(0, 100);
    final syncedClients = _syncedClientCountForSummary(summary);
    final mergedClients = _mergedClientCountForSummary(summary);
    final attemptedClients = _attemptedClientCountForTable(summary.table);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectTable(summary.table),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                _buildTableListMetric(
                  tooltip: 'Rows',
                  icon: Icons.format_list_numbered_rounded,
                  value: '${summary.latestRowCount}',
                ),
                _buildTableListMetric(
                  tooltip: 'Clients with synced data',
                  icon: Icons.sync_rounded,
                  value: '$syncedClients/${summary.clientCount}',
                  onPressed:
                      () => _openTableMetricDialog(
                        summary,
                        _TableMetricKind.synced,
                      ),
                ),
                _buildTableListMetric(
                  tooltip: 'Clients with merged data',
                  icon: Icons.merge_type_rounded,
                  value: '$mergedClients',
                  onPressed:
                      () => _openTableMetricDialog(
                        summary,
                        _TableMetricKind.merged,
                      ),
                ),
                _buildTableListMetric(
                  tooltip: 'Clients that tried to sync this table',
                  icon: Icons.history_rounded,
                  value: '$attemptedClients',
                  onPressed:
                      () => _openTableMetricDialog(
                        summary,
                        _TableMetricKind.attempted,
                      ),
                ),
                _buildProgressStatusBadge(progress, statusColor),
                _buildOpenTableDataButton(summary),
              ],
            );

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE6F4F1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFB8DDD6)),
                  ),
                  child: const Icon(
                    Icons.table_chart_outlined,
                    size: 18,
                    color: Color(0xFF0F766E),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      stack
                          ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTableListTitle(summary.displayTitle),
                              const SizedBox(height: 4),
                              _buildTableListSubline(lastSync),
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
                                    _buildTableListTitle(summary.displayTitle),
                                    const SizedBox(height: 4),
                                    _buildTableListSubline(lastSync),
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

  Widget _buildProgressStatusBadge(int progress, Color color) {
    final normalizedProgress = progress.clamp(0, 100);
    return SizedBox(
      width: 48,
      child: StatusBadge(label: '$normalizedProgress%', color: color),
    );
  }

  Widget _buildOpenTableDataButton(_TableAggregateSummary summary) {
    return Tooltip(
      message: 'Open table rows',
      child: SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: () => _openTableDataDialog(summary),
          icon: const Icon(Icons.table_rows_outlined),
        ),
      ),
    );
  }

  _TableClientEntry _sourceEntryForSummary(_TableAggregateSummary summary) {
    for (final entry in summary.clients) {
      if (entry.agent.clientName == summary.sourceClientName) {
        return entry;
      }
    }
    return summary.clients.first;
  }

  Widget _buildTableListTitle(String table) {
    return Text(
      table,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
    );
  }

  Widget _buildTableListSubline(String lastSync) {
    return Text(
      'Last update $lastSync',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Color(0xFF667085),
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildTableListMetric({
    required String tooltip,
    required IconData icon,
    required String value,
    VoidCallback? onPressed,
  }) {
    final content = Container(
      constraints: const BoxConstraints(minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: onPressed == null ? Colors.white : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color:
              onPressed == null
                  ? const Color(0xFFDDE3EA)
                  : const Color(0xFFC9D5E1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF667085)),
          const SizedBox(width: 5),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF101828),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );

    return Tooltip(
      message: tooltip,
      child:
          onPressed == null
              ? content
              : Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onPressed,
                  child: content,
                ),
              ),
    );
  }

  Future<void> _openTableMetricDialog(
    _TableAggregateSummary summary,
    _TableMetricKind kind,
  ) async {
    final data = _tableMetricDialogData(summary, kind);
    await showDialog<void>(
      context: context,
      builder:
          (context) => Dialog(
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 620,
                maxHeight: MediaQuery.sizeOf(context).height * 0.72,
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMetricDialogHeader(data),
                    const SizedBox(height: 10),
                    Text(
                      data.meaning,
                      style: const TextStyle(
                        color: Color(0xFF475467),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child:
                          data.clients.isEmpty
                              ? EmptyStateCard(message: data.emptyMessage)
                              : ListView.separated(
                                itemCount: data.clients.length,
                                separatorBuilder:
                                    (_, _) => const SizedBox(height: 6),
                                itemBuilder:
                                    (context, index) => _buildMetricClientTile(
                                      data.clients[index],
                                    ),
                              ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  _TableMetricDialogData _tableMetricDialogData(
    _TableAggregateSummary summary,
    _TableMetricKind kind,
  ) {
    switch (kind) {
      case _TableMetricKind.synced:
        final clients =
            summary.clients
                .where((entry) => _tableStateHasSynced(entry.tableState))
                .map(
                  (entry) => _TableMetricClientInfo(
                    name: entry.agent.clientName,
                    subtitle:
                        'Last sync ${_formatTimestamp(_tableTimestampToken(entry.tableState))}',
                    detail:
                        'Rows ${entry.tableState.rowCount} - ${entry.tableState.status}',
                    active: entry.agent.isOnline,
                  ),
                )
                .toList()
              ..sort((left, right) => left.name.compareTo(right.name));
        return _TableMetricDialogData(
          title: 'Synced Clients',
          tableName: summary.displayTitle,
          icon: Icons.sync_rounded,
          countText: '${clients.length} / ${summary.clientCount}',
          meaning:
              'This number counts clients that already have sync data for this table. A client is counted when it has a last sync time, snapshot id, or snapshot timestamp.',
          emptyMessage: 'No client has synced this table yet.',
          clients: clients,
        );
      case _TableMetricKind.merged:
        final clients =
            summary.clients
                .where((entry) => _tableStateHasMerged(entry.tableState))
                .map((entry) {
                  final sources =
                      entry.tableState.mergedSnapshotSources.keys
                          .where((name) => name.trim().isNotEmpty)
                          .toList();
                  sources.sort();
                  return _TableMetricClientInfo(
                    name: entry.agent.clientName,
                    subtitle:
                        sources.isEmpty
                            ? 'Merged mode with synced table data'
                            : 'Merged from ${sources.join(', ')}',
                    detail:
                        'Mode ${entry.tableState.syncMode.toUpperCase()} - ${entry.tableState.status}',
                    active: entry.agent.isOnline,
                  );
                })
                .toList()
              ..sort((left, right) => left.name.compareTo(right.name));
        return _TableMetricDialogData(
          title: 'Merged Clients',
          tableName: summary.displayTitle,
          icon: Icons.merge_type_rounded,
          countText: '${clients.length}',
          meaning:
              'This number counts clients whose table data has merged master snapshot sources, or clients in merge mode that already synced this table.',
          emptyMessage: 'No client has merged data for this table yet.',
          clients: clients,
        );
      case _TableMetricKind.attempted:
        _ensureDerivedState(_state);
        final grouped = <String, List<AdminJob>>{};
        for (final job
            in _derivedJobsByTable[summary.table] ?? const <AdminJob>[]) {
          final name = job.clientName.trim();
          if (name.isEmpty) {
            continue;
          }
          grouped.putIfAbsent(name, () => <AdminJob>[]).add(job);
        }
        final clients =
            grouped.entries.map((entry) {
                final jobs =
                    entry.value..sort(
                      (left, right) => (right.completedAt ?? right.updatedAt)
                          .compareTo(left.completedAt ?? left.updatedAt),
                    );
                final latest = jobs.first;
                _TableClientEntry? agent;
                for (final client in summary.clients) {
                  if (client.agent.clientName == entry.key) {
                    agent = client;
                    break;
                  }
                }
                return _TableMetricClientInfo(
                  name: entry.key,
                  subtitle:
                      '${jobs.length} sync ${jobs.length == 1 ? 'attempt' : 'attempts'}',
                  detail:
                      'Last ${latest.direction.toUpperCase()} - ${latest.status.toUpperCase()} - ${_formatTimestamp(latest.completedAt ?? latest.updatedAt)}',
                  active: agent?.agent.isOnline ?? false,
                );
              }).toList()
              ..sort((left, right) => left.name.compareTo(right.name));
        return _TableMetricDialogData(
          title: 'Sync Attempts',
          tableName: summary.displayTitle,
          icon: Icons.history_rounded,
          countText: '${clients.length}',
          meaning:
              'This number counts unique clients that have at least one sync job recorded for this table. Multiple jobs from the same client count as one client here.',
          emptyMessage: 'No client has tried to sync this table yet.',
          clients: clients,
        );
    }
  }

  Widget _buildMetricDialogHeader(_TableMetricDialogData data) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFD9E2EC)),
            ),
            child: Icon(data.icon, size: 17, color: const Color(0xFF0F766E)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${data.title} (${data.countText})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.tableName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildMetricClientTile(_TableMetricClientInfo client) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color:
                  client.active
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF94A3B8),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  client.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  client.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF475467),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  client.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 11.5,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailCard() {
    final summary = _selectedTableSummary;
    if (summary == null) {
      return const SurfaceCard(
        title: 'Details',
        subtitle: '',
        child: EmptyStateCard(
          message:
              'No table is selected yet. Pick a table from the left to open its side detail card.',
        ),
      );
    }

    return SurfaceCard(
      title: summary.displayTitle,
      subtitle: '',
      expandChild: true,
      child: _buildMergedDetailBody(summary),
    );
  }

  Widget _buildMergedDetailBody(_TableAggregateSummary summary) {
    final tabIndex = _detailTabIndex.clamp(0, 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDetailTabBar(tabIndex),
        const SizedBox(height: 6),
        Expanded(
          child:
              tabIndex == 0
                  ? _buildClientDetailTab(summary)
                  : _buildAllHistoryTab(summary),
        ),
      ],
    );
  }

  Widget _buildDetailTabBar(int selectedIndex) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDetailTabButton(
            label: 'Client',
            selected: selectedIndex == 0,
            onTap: () => _selectDetailTab(0),
          ),
          _buildDetailTabButton(
            label: 'All History',
            selected: selectedIndex == 1,
            onTap: () => _selectDetailTab(1),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailTabButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: selected ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              color:
                  selected ? const Color(0xFF101828) : const Color(0xFF667085),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  void _selectDetailTab(int index) {
    if (_detailTabIndex == index) {
      return;
    }
    setState(() {
      _detailTabIndex = index;
    });
  }

  Widget _buildClientDetailTab(_TableAggregateSummary summary) {
    return _buildClientListPanel(summary);
  }

  Widget _buildClientListPanel(_TableAggregateSummary summary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Clients'),
        const SizedBox(height: 8),
        Expanded(child: _buildClientTableSide(summary)),
      ],
    );
  }

  Widget _buildAllHistoryTab(_TableAggregateSummary summary) {
    return _buildHistoryTableSide(summary, limit: false);
  }

  Widget _buildSelectedClientInfo(
    _TableClientEntry? selectedClient, {
    required String tableName,
    required bool busy,
    required int recentHistoryCount,
    required int totalHistoryCount,
    required VoidCallback onDownload,
    required VoidCallback onUpload,
    required VoidCallback? onPush,
    required VoidCallback? onPull,
    required VoidCallback onOpenHistory,
  }) {
    if (selectedClient == null) {
      return const EmptyStateCard(
        message: 'Select a client to view its table info and history.',
      );
    }

    final agent = selectedClient.agent;
    final tableState = selectedClient.tableState;
    final normalizedProgress = tableState.progress.clamp(0, 100);
    final progressColor = _statusColor(tableState.status);
    final progressLabel =
        tableState.inProgress
            ? 'Sync in progress'
            : tableState.enabled
            ? 'Sync ready'
            : 'Sync paused';
    final activityMessage =
        tableState.message.trim().isEmpty
            ? 'No sync note is available for this table yet.'
            : tableState.message.trim();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
        final stackIdentity = width < 760;
        final footerItems = <MapEntry<String, String>>[
          MapEntry('Role', _roleLabel(agent.isMaster)),
          MapEntry(
            'Flow',
            tableState.enabled
                ? (agent.isMaster ? 'Push source' : 'Pull target')
                : 'Disabled',
          ),
          MapEntry('Mode', tableState.syncMode.toUpperCase()),
          MapEntry('Direction', tableState.direction.toUpperCase()),
          MapEntry('Database', agent.database),
          MapEntry(
            'Last Sync',
            _formatTimestamp(_tableTimestampToken(tableState)),
          ),
          MapEntry('Rows', '${tableState.rowCount}'),
          MapEntry('Backup', _formatBytes(tableState.snapshotBytes)),
          MapEntry('History', '$recentHistoryCount / $totalHistoryCount'),
        ];
        final actions = <Widget>[
          _buildDetailActionButton(
            label: 'Download',
            icon: Icons.download_rounded,
            onPressed: busy ? null : onDownload,
          ),
          _buildDetailActionButton(
            label: 'Upload',
            icon: Icons.upload_file_rounded,
            onPressed: busy ? null : onUpload,
          ),
          _buildDetailActionButton(
            label: 'Push',
            icon: Icons.north_rounded,
            onPressed: onPush,
          ),
          _buildDetailActionButton(
            label: 'Pull',
            icon: Icons.south_rounded,
            onPressed: onPull,
          ),
          _buildDetailActionButton(
            label: 'History',
            icon: Icons.history_rounded,
            onPressed: onOpenHistory,
          ),
          _buildDetailActionButton(
            label: 'Details',
            icon: Icons.info_outline_rounded,
            onPressed:
                () => _openClientMetadataDialog(
                  title: agent.clientName,
                  subtitle: tableName,
                  items: footerItems,
                ),
          ),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stackIdentity)
              _buildDetailIdentityBlock(context, tableName, agent)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildDetailIdentityBlock(context, tableName, agent),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          progressLabel,
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '$normalizedProgress%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Color(0xFF475467),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ProgressStrip(
                    progress: normalizedProgress,
                    color: progressColor,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    activityMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 11.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: actions),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openClientMetadataDialog({
    required String title,
    required String subtitle,
    required List<MapEntry<String, String>> items,
  }) async {
    await showDialog<void>(
      context: context,
      builder:
          (context) => Dialog(
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: const Color(0xFFD9E2EC),
                              ),
                            ),
                            child: const Icon(
                              Icons.info_outline_rounded,
                              size: 17,
                              color: Color(0xFF0F766E),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF0F172A),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF667085),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildDetailMetadataFooter(items),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  Widget _buildClientDetailDialogHeader({
    required _TableAggregateSummary summary,
    required _TableClientEntry entry,
  }) {
    final tableState = entry.tableState;
    final statusColor = _statusColor(tableState.status);
    final lastSync = _formatTimestamp(_tableTimestampToken(tableState));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFD9E2EC)),
            ),
            child: const Icon(
              Icons.computer_rounded,
              size: 18,
              color: Color(0xFF2563EB),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.agent.clientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${tableState.status} - ${summary.displayTitle} - Last sync $lastSync',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF667085),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailMetadataFooter(List<MapEntry<String, String>> items) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFCFD),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth =
              constraints.maxWidth < 520
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 36) / 4;
          return Wrap(
            spacing: 12,
            runSpacing: 6,
            children: items
                .map((item) => _buildDetailMetadataText(item, width: itemWidth))
                .toList(growable: false),
          );
        },
      ),
    );
  }

  Widget _buildDetailMetadataText(
    MapEntry<String, String> item, {
    required double width,
  }) {
    return SizedBox(
      width: width,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${item.key}: ',
              style: const TextStyle(
                color: Color(0xFF667085),
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: item.value,
              style: const TextStyle(
                color: Color(0xFF101828),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, height: 1.25),
      ),
    );
  }

  Widget _buildDetailIdentityBlock(
    BuildContext context,
    String tableName,
    AdminAgent agent,
  ) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tableName,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF0F172A),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${agent.machineName} - ${agent.server}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
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

  Widget _buildClientTableSide(_TableAggregateSummary summary) {
    final clients = _filteredTableClients(summary.clients);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child:
              clients.isEmpty
                  ? EmptyStateCard(
                    message: 'No clients are exposing ${summary.table} yet.',
                  )
                  : ListView.separated(
                    itemCount: clients.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder:
                        (context, index) => _buildClientEntryTile(
                          summary: summary,
                          entry: clients[index],
                        ),
                  ),
        ),
      ],
    );
  }

  Widget _buildClientEntryTile({
    required _TableAggregateSummary summary,
    required _TableClientEntry entry,
  }) {
    final selected = entry.agent.clientName == _selectedClientName;
    final lastSync = _formatTimestamp(_tableTimestampToken(entry.tableState));

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openClientDetailDialog(summary: summary, entry: entry),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE6F4F1) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF85C7BC) : const Color(0xFFDDE3EA),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showSync = constraints.maxWidth >= 660;
            final showRoleLabel = constraints.maxWidth >= 430;
            final roleColumnWidth = showRoleLabel ? 86.0 : 28.0;
            final statusColumnWidth = 88.0;
            final syncColumnWidth = showSync ? 140.0 : 0.0;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    entry.agent.clientName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                SizedBox(
                  width: roleColumnWidth,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildRoleBadge(
                      entry.agent.isMaster,
                      compact: !showRoleLabel,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: statusColumnWidth,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: StatusBadge(
                      label: entry.tableState.status,
                      color: _statusColor(entry.tableState.status),
                    ),
                  ),
                ),
                if (showSync) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: syncColumnWidth,
                    child: Text(
                      lastSync,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFF62717C),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 2),
                Tooltip(
                  message: 'Open client details',
                  child: IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        () => _openClientDetailDialog(
                          summary: summary,
                          entry: entry,
                        ),
                    icon: const Icon(Icons.info_outline_rounded, size: 18),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHistoryTableSide(
    _TableAggregateSummary summary, {
    String? clientName,
    bool limit = true,
  }) {
    final jobs = _filteredHistoryJobs(
      table: summary.table,
      clientName: clientName,
      limit: limit,
    );
    final historyLabel = clientName ?? 'All clients';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            MetricPill(label: 'Client', value: historyLabel),
            MetricPill(label: 'Events', value: '${jobs.length}'),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child:
              jobs.isEmpty
                  ? EmptyStateCard(
                    message: 'No history is available yet for this table.',
                  )
                  : ListView.separated(
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) => _buildJobCard(jobs[index]),
                  ),
        ),
      ],
    );
  }

  Widget _buildSnapshotGrid(
    AdminSnapshotDetail snapshot,
    List<_ScoredSnapshotRow> filteredRows, {
    bool showMasterMatchColumn = false,
    Map<String, int>? rowMasterCounts,
  }) {
    const rowNumberWidth = 72.0;
    const masterCountWidth = 104.0;
    const cellWidth = 220.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth =
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
        final mainTableWidth = math.max(
          panelWidth,
          rowNumberWidth + (snapshot.columns.length * cellWidth),
        );
        final panelHeight =
            constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.sizeOf(context).height * 0.65;

        if (showMasterMatchColumn) {
          final stickyColumnController = ScrollController();
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              border: Border.all(color: const Color(0xFFDDE3EA)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: mainTableWidth,
                        height: panelHeight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _buildSnapshotHeaderCell('#', rowNumberWidth),
                                ...snapshot.columns.map(
                                  (column) => _buildSnapshotHeaderCell(
                                    column,
                                    cellWidth,
                                  ),
                                ),
                              ],
                            ),
                            Expanded(
                              child: NotificationListener<
                                ScrollUpdateNotification
                              >(
                                onNotification: (notification) {
                                  if (stickyColumnController.hasClients) {
                                    final targetOffset = notification
                                        .metrics
                                        .pixels
                                        .clamp(
                                          0.0,
                                          stickyColumnController
                                              .position
                                              .maxScrollExtent,
                                        );
                                    if ((stickyColumnController.offset -
                                                targetOffset)
                                            .abs() >
                                        0.5) {
                                      stickyColumnController.jumpTo(
                                        targetOffset,
                                      );
                                    }
                                  }
                                  return false;
                                },
                                child: ListView.builder(
                                  itemCount: filteredRows.length,
                                  itemBuilder: (context, index) {
                                    final match = filteredRows[index];
                                    return _buildSnapshotRow(
                                      snapshot: snapshot,
                                      columns: snapshot.columns,
                                      row: match.row,
                                      rowNumber: match.originalIndex + 1,
                                      rowNumberWidth: rowNumberWidth,
                                      masterCountWidth: masterCountWidth,
                                      cellWidth: cellWidth,
                                      alternate: index.isOdd,
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
                  Container(
                    width: masterCountWidth,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF5F3FF),
                      border: Border(
                        left: BorderSide(color: Color(0xFFD8CCFF)),
                      ),
                    ),
                    child: Column(
                      children: [
                        _buildSnapshotStickyHeaderCell(
                          'Masters',
                          masterCountWidth,
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: stickyColumnController,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: filteredRows.length,
                            itemBuilder: (context, index) {
                              final match = filteredRows[index];
                              final rowNumber = match.originalIndex + 1;
                              return _buildSnapshotStickyMasterCell(
                                snapshot: snapshot,
                                row: match.row,
                                rowNumber: rowNumber,
                                width: masterCountWidth,
                                alternate: index.isOdd,
                                value:
                                    rowMasterCounts?[_snapshotRowSignature(
                                      snapshot.columns,
                                      match.row,
                                    )],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

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
                width: mainTableWidth,
                height: panelHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildSnapshotHeaderCell('#', rowNumberWidth),
                        ...snapshot.columns.map(
                          (column) =>
                              _buildSnapshotHeaderCell(column, cellWidth),
                        ),
                      ],
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filteredRows.length,
                        itemBuilder: (context, index) {
                          final match = filteredRows[index];
                          return _buildSnapshotRow(
                            snapshot: snapshot,
                            columns: snapshot.columns,
                            row: match.row,
                            rowNumber: match.originalIndex + 1,
                            rowNumberWidth: rowNumberWidth,
                            masterCountWidth: masterCountWidth,
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

  Widget _buildSnapshotHeaderCell(String value, double width) {
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

  Widget _buildSnapshotStickyHeaderCell(String value, double width) {
    return Container(
      width: width,
      height: 45,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFFE9E3FF),
        border: Border(bottom: BorderSide(color: Color(0xFFD4C6FF))),
      ),
      child: Text(
        value,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: Color(0xFF4C1D95),
        ),
      ),
    );
  }

  Widget _buildSnapshotRow({
    required AdminSnapshotDetail snapshot,
    required List<String> columns,
    required Map<String, String?> row,
    required int rowNumber,
    required double rowNumberWidth,
    required double masterCountWidth,
    required double cellWidth,
    required bool alternate,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap:
            () => _openSnapshotRowDetailDialog(
              snapshot: snapshot,
              row: row,
              rowNumber: rowNumber,
            ),
        mouseCursor: SystemMouseCursors.click,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildSnapshotBodyCell(
              '$rowNumber',
              rowNumberWidth,
              alternate: alternate,
              alignCenter: true,
            ),
            ...columns.map(
              (column) => _buildSnapshotBodyCell(
                row[column] ?? 'NULL',
                cellWidth,
                alternate: alternate,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSnapshotStickyMasterCell({
    required AdminSnapshotDetail snapshot,
    required Map<String, String?> row,
    required int rowNumber,
    required double width,
    required bool alternate,
    required int? value,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap:
            () => _openSnapshotRowDetailDialog(
              snapshot: snapshot,
              row: row,
              rowNumber: rowNumber,
            ),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color:
                alternate ? const Color(0xFFF8F5FF) : const Color(0xFFF3EEFF),
            border: const Border(bottom: BorderSide(color: Color(0xFFE2D9FF))),
          ),
          child: Text(
            value == null ? '...' : '$value',
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF5B21B6),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSnapshotRowDetailDialog({
    required AdminSnapshotDetail snapshot,
    required Map<String, String?> row,
    required int rowNumber,
  }) async {
    final attemptsFuture = _loadMasterRowAttempts(
      sourceSnapshot: snapshot,
      row: row,
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 840,
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSnapshotRowDialogHeader(
                    snapshot: snapshot,
                    rowNumber: rowNumber,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Uploaded by master: ${snapshot.clientName}',
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildSnapshotRowValuePreview(snapshot.columns, row),
                  const SizedBox(height: 12),
                  Expanded(
                    child: FutureBuilder<List<_MasterRowAttempt>>(
                      future: attemptsFuture,
                      builder: (context, attemptState) {
                        if (attemptState.connectionState ==
                                ConnectionState.waiting &&
                            !attemptState.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (attemptState.hasError) {
                          return EmptyStateCard(
                            message: attemptState.error.toString(),
                          );
                        }
                        final attempts =
                            attemptState.data ?? const <_MasterRowAttempt>[];
                        if (attempts.isEmpty) {
                          return const EmptyStateCard(
                            message:
                                'No master snapshot contains this same row value yet.',
                          );
                        }
                        return _buildMasterRowAttemptList(attempts);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSnapshotRowDialogHeader({
    required AdminSnapshotDetail snapshot,
    required int rowNumber,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFD9E2EC)),
            ),
            child: const Icon(
              Icons.data_object_rounded,
              size: 17,
              color: Color(0xFF0F766E),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Row $rowNumber',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${snapshot.table} - ${_formatTimestamp(snapshot.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshotRowValuePreview(
    List<String> columns,
    Map<String, String?> row,
  ) {
    final visibleColumns = columns.take(8).toList(growable: false);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFCFD),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth =
              constraints.maxWidth < 620
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 18) / 2;
          return Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              ...visibleColumns.map(
                (column) => _buildRowValueText(
                  column,
                  row[column] ?? 'NULL',
                  width: itemWidth,
                ),
              ),
              if (columns.length > visibleColumns.length)
                SizedBox(
                  width: itemWidth,
                  child: Text(
                    '+${columns.length - visibleColumns.length} more columns',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRowValueText(
    String label,
    String value, {
    required double width,
  }) {
    return SizedBox(
      width: width,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: Color(0xFF667085),
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Color(0xFF101828),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, height: 1.25),
      ),
    );
  }

  Widget _buildMasterRowAttemptList(List<_MasterRowAttempt> attempts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Master Attempts'),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: attempts.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder:
                (context, index) => _buildMasterRowAttemptTile(attempts[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildMasterRowAttemptTile(_MasterRowAttempt attempt) {
    final usedByText =
        attempt.usedByClients.isEmpty
            ? 'No client has merged this master yet'
            : 'Used by ${attempt.usedByClients.join(', ')}';
    final statusText =
        attempt.isSelectedSource
            ? 'Current uploaded row value'
            : 'Same row value found in this master snapshot';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color:
            attempt.isSelectedSource ? const Color(0xFFEFF6FF) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color:
              attempt.isSelectedSource
                  ? const Color(0xFFBFDBFE)
                  : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color:
                  attempt.isSelectedSource
                      ? const Color(0xFF2563EB)
                      : const Color(0xFF94A3B8),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attempt.masterName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$statusText - $usedByText',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _formatTimestamp(attempt.snapshot.createdAt),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Color(0xFF475467),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Future<List<_MasterRowAttempt>> _loadMasterRowAttempts({
    required AdminSnapshotDetail sourceSnapshot,
    required Map<String, String?> row,
  }) async {
    final state = _state;
    final signature = _snapshotRowSignature(sourceSnapshot.columns, row);
    final masterNames =
        (state?.agents ?? const <AdminAgent>[])
            .where((agent) => agent.isMaster)
            .map((agent) => agent.clientName)
            .toSet();
    if (sourceSnapshot.clientName.trim().isNotEmpty) {
      masterNames.add(sourceSnapshot.clientName);
    }

    final candidateSummaries = (state?.snapshots ?? const <AdminSnapshot>[])
        .where(
          (snapshot) =>
              snapshot.table == sourceSnapshot.table &&
              masterNames.contains(snapshot.clientName),
        )
        .toList(growable: false);

    final loadedSnapshots = await Future.wait(
      candidateSummaries.map((summary) async {
        if (summary.id == sourceSnapshot.id) {
          return sourceSnapshot;
        }
        try {
          return await _api.fetchSnapshotById(summary.id);
        } catch (_) {
          return null;
        }
      }),
    );

    final attempts = <_MasterRowAttempt>[];
    var sourceAdded = false;
    for (final snapshot in loadedSnapshots.whereType<AdminSnapshotDetail>()) {
      final isSelectedSource = snapshot.id == sourceSnapshot.id;
      final hasMatchingRow = snapshot.rows.any(
        (candidateRow) =>
            _snapshotRowSignature(sourceSnapshot.columns, candidateRow) ==
            signature,
      );
      if (!isSelectedSource && !hasMatchingRow) {
        continue;
      }
      if (isSelectedSource) {
        sourceAdded = true;
      }
      attempts.add(
        _MasterRowAttempt(
          masterName: snapshot.clientName,
          snapshot: snapshot,
          isSelectedSource: isSelectedSource,
          usedByClients: _clientsUsingMasterSnapshot(snapshot),
        ),
      );
    }

    if (!sourceAdded) {
      attempts.add(
        _MasterRowAttempt(
          masterName: sourceSnapshot.clientName,
          snapshot: sourceSnapshot,
          isSelectedSource: true,
          usedByClients: _clientsUsingMasterSnapshot(sourceSnapshot),
        ),
      );
    }

    attempts.sort((left, right) {
      if (left.isSelectedSource != right.isSelectedSource) {
        return left.isSelectedSource ? -1 : 1;
      }
      return right.snapshot.createdAt.compareTo(left.snapshot.createdAt);
    });
    return attempts;
  }

  Future<List<AdminSnapshotDetail>> _loadLatestMasterSnapshotsForTable(
    String table,
  ) async {
    final state = _state;
    if (state == null) {
      return const [];
    }

    final masterNames =
        state.agents
            .where((agent) => agent.isMaster)
            .map((agent) => agent.clientName)
            .toSet();
    final summaries = state.snapshots
        .where(
          (snapshot) =>
              snapshot.table == table &&
              masterNames.contains(snapshot.clientName),
        )
        .toList(growable: false);
    final seenIds = <String>{};
    final loaded = await Future.wait(
      summaries.where((snapshot) => seenIds.add(snapshot.id)).map((
        snapshot,
      ) async {
        try {
          return await _api.fetchSnapshotById(snapshot.id);
        } catch (_) {
          return null;
        }
      }),
    );
    return loaded.whereType<AdminSnapshotDetail>().toList(growable: false);
  }

  Map<String, int> _masterRowCountsForSnapshot(
    AdminSnapshotDetail sourceSnapshot,
    List<AdminSnapshotDetail> masterSnapshots,
  ) {
    final snapshots = <AdminSnapshotDetail>[...masterSnapshots];
    if (_isMasterClientName(sourceSnapshot.clientName) &&
        !snapshots.any((snapshot) => snapshot.id == sourceSnapshot.id)) {
      snapshots.add(sourceSnapshot);
    }

    final counts = <String, int>{};
    for (final snapshot in snapshots) {
      if (snapshot.table != sourceSnapshot.table ||
          !_isMasterClientName(snapshot.clientName)) {
        continue;
      }
      final uniqueRowsInMaster = <String>{};
      for (final row in snapshot.rows) {
        uniqueRowsInMaster.add(
          _snapshotRowSignature(sourceSnapshot.columns, row),
        );
      }
      for (final signature in uniqueRowsInMaster) {
        counts[signature] = (counts[signature] ?? 0) + 1;
      }
    }
    return counts;
  }

  bool _isMasterClientName(String clientName) {
    final state = _state;
    if (state == null) {
      return false;
    }
    for (final agent in state.agents) {
      if (agent.clientName == clientName) {
        return agent.isMaster;
      }
    }
    return false;
  }

  List<String> _clientsUsingMasterSnapshot(AdminSnapshotDetail snapshot) {
    final state = _state;
    if (state == null) {
      return const [];
    }
    final clients = <String>{};
    for (final agent in state.agents) {
      AdminTableState? tableState;
      for (final candidate in agent.tables) {
        if (candidate.table == snapshot.table) {
          tableState = candidate;
          break;
        }
      }
      if (tableState == null) {
        continue;
      }
      if (agent.clientName == snapshot.clientName) {
        clients.add(agent.clientName);
        continue;
      }
      if (tableState.snapshotId == snapshot.id ||
          tableState.mergedSnapshotSources.containsKey(snapshot.clientName)) {
        clients.add(agent.clientName);
      }
    }
    return clients.toList()..sort();
  }

  String _snapshotRowSignature(List<String> columns, Map<String, String?> row) {
    return jsonEncode(
      columns
          .map((column) => <String, String?>{column: row[column]})
          .toList(growable: false),
    );
  }

  Widget _buildSnapshotBodyCell(
    String value,
    double width, {
    required bool alternate,
    bool alignCenter = false,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: alternate ? Colors.white : const Color(0xFFFAFBF9),
        border: const Border(bottom: BorderSide(color: Color(0xFFE4E8E3))),
      ),
      child: Text(
        value,
        textAlign: alignCenter ? TextAlign.center : TextAlign.start,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildDashboardContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSidebar = constraints.maxWidth >= 980;
        final content = _buildCurrentPageContent();
        if (!showSidebar) {
          return content;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 280, child: _buildNavigationPane()),
            const SizedBox(width: 12),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _buildCurrentPageContent() {
    final serverItem = _selectedServerInventoryItem;
    final clientAgent = _selectedPageClientAgent;
    if (clientAgent != null) {
      return _buildClientPage(clientAgent);
    }
    if (serverItem != null) {
      return _buildServerPage(serverItem);
    }
    return _buildOverviewPage();
  }

  Widget _buildOverviewPage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobileStack = constraints.maxWidth < 760;
        final useSideBySide = constraints.maxWidth >= 1180;
        if (mobileStack) {
          return ListView(
            children: [
              _buildOverviewIntroCard(),
              const SizedBox(height: 10),
              _buildServerListCard(),
              const SizedBox(height: 10),
              SizedBox(height: 460, child: _buildTableListCard()),
              const SizedBox(height: 10),
              SizedBox(height: 600, child: _buildDetailCard()),
            ],
          );
        }
        return Column(
          children: [
            _buildOverviewIntroCard(),
            const SizedBox(height: 10),
            _buildServerListCard(),
            const SizedBox(height: 10),
            Expanded(
              child:
                  useSideBySide
                      ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 7, child: _buildTableListCard()),
                          const SizedBox(width: 10),
                          Expanded(flex: 5, child: _buildDetailCard()),
                        ],
                      )
                      : Column(
                        children: [
                          Expanded(flex: 6, child: _buildTableListCard()),
                          const SizedBox(height: 10),
                          Expanded(flex: 7, child: _buildDetailCard()),
                        ],
                      ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildServerListCard() {
    final items = _serverInventoryItems;
    return SurfaceCard(
      title: 'Servers',
      subtitle: 'Open a server to enter its clients and tables.',
      child:
          items.isEmpty
              ? const EmptyStateCard(message: 'No servers are available yet.')
              : Column(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    _buildServerNavigationTile(
                      items[index],
                      closeAfterSelection: false,
                    ),
                    if (index != items.length - 1) const SizedBox(height: 8),
                  ],
                ],
              ),
    );
  }

  Widget _buildOverviewIntroCard() {
    return SurfaceCard(
      title: 'Overview',
      subtitle:
          'Use the left menu to open a server page, then drill into its tables and clients.',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          MetricPill(
            label: 'Servers',
            value: '${_serverInventoryItems.length}',
          ),
          MetricPill(label: 'Agents', value: '${_state?.agents.length ?? 0}'),
          MetricPill(label: 'Jobs', value: '${_jobs.length}'),
          MetricPill(
            label: 'Updated',
            value: _formatTimestamp(_state?.generatedAt ?? ''),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationPane({bool closeAfterSelection = false}) {
    final items = _serverInventoryItems;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Servers',
            style: TextStyle(
              color: Color(0xFF101828),
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Open a server to see its tables and clients.',
            style: TextStyle(
              color: Color(0xFF667085),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          _buildNavigationTile(
            icon: Icons.dashboard_customize_outlined,
            label: 'Overview',
            subtitle: 'Tables, sync status, and detail panels',
            selected:
                _selectedServerKey == null && _selectedPageClientName == null,
            onTap:
                () => _handleNavigationSelection(
                  _selectOverviewPage,
                  closeAfterSelection: closeAfterSelection,
                ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder:
                  (context, index) => _buildServerNavigationTile(
                    items[index],
                    closeAfterSelection: closeAfterSelection,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleNavigationSelection(
    VoidCallback onSelect, {
    required bool closeAfterSelection,
  }) {
    onSelect();
    if (closeAfterSelection && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Widget _buildNavigationTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    Color iconColor = const Color(0xFF0F766E),
    Widget? trailing,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE6F4F1) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  selected ? const Color(0xFF85C7BC) : const Color(0xFFDDE3EA),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: const Color(0xFFDDE3EA)),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF101828),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServerNavigationTile(
    _ServerInventoryItem item, {
    required bool closeAfterSelection,
  }) {
    final selected =
        _selectedServerKey == item.key &&
        (_selectedPageClientName == null ||
            item.clientNames.contains(_selectedPageClientName));
    return _buildNavigationTile(
      icon: Icons.dns_rounded,
      iconColor:
          item.available ? const Color(0xFF0F766E) : const Color(0xFFB42318),
      label: item.title,
      subtitle: '${item.connectedClients} clients',
      selected: selected,
      onTap:
          () => _handleNavigationSelection(
            () => _selectServerPage(item.key),
            closeAfterSelection: closeAfterSelection,
          ),
      trailing: StatusBadge(
        label: item.available ? 'Live' : 'Down',
        color:
            item.available ? const Color(0xFF0F766E) : const Color(0xFFB42318),
      ),
    );
  }

  Widget _buildServerPage(_ServerInventoryItem item) {
    final agents = List<AdminAgent>.from(item.agents)
      ..sort((left, right) => left.clientName.compareTo(right.clientName));
    final summaries = _serverTableSummaries(item);
    return ListView(
      children: [
        _buildServerInventoryTile(item),
        const SizedBox(height: 10),
        SurfaceCard(
          title: 'Tables',
          subtitle: 'Tables exposed by this server.',
          child:
              summaries.isEmpty
                  ? const EmptyStateCard(
                    message: 'No tables are exposed by this server yet.',
                  )
                  : Column(
                    children: [
                      for (
                        var index = 0;
                        index < summaries.length;
                        index++
                      ) ...[
                        _buildServerTableTile(summaries[index]),
                        if (index != summaries.length - 1)
                          const SizedBox(height: 8),
                      ],
                    ],
                  ),
        ),
        const SizedBox(height: 10),
        SurfaceCard(
          title: 'Clients',
          subtitle: 'Each client opens as its own page.',
          child:
              agents.isEmpty
                  ? const EmptyStateCard(
                    message: 'No clients are connected to this server yet.',
                  )
                  : Column(
                    children: [
                      for (var index = 0; index < agents.length; index++) ...[
                        _buildServerClientTile(item, agents[index]),
                        if (index != agents.length - 1)
                          const SizedBox(height: 8),
                      ],
                    ],
                  ),
        ),
      ],
    );
  }

  List<_TableAggregateSummary> _serverTableSummaries(
    _ServerInventoryItem item,
  ) {
    final serverClientNames =
        item.agents
            .map((agent) => agent.clientName)
            .where((clientName) => clientName.trim().isNotEmpty)
            .toSet();
    final summaries = _tableSummaries
        .where(
          (summary) => summary.clients.any(
            (entry) => serverClientNames.contains(entry.agent.clientName),
          ),
        )
        .toList(growable: false);
    summaries.sort(_compareSummariesByActiveSort);
    return summaries;
  }

  Widget _buildServerTableTile(_TableAggregateSummary summary) {
    final entry = summary.clients.first;
    final lastSync = _formatTimestamp(summary.lastSync);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: const Icon(
              Icons.table_rows_outlined,
              size: 18,
              color: Color(0xFF2563EB),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF101828),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${summary.clientCount} clients - Last sync $lastSync',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
          StatusBadge(
            label: summary.masterCount > 0 ? 'Live' : 'Idle',
            color:
                summary.masterCount > 0
                    ? const Color(0xFF0F766E)
                    : const Color(0xFF667085),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Open table details',
            onPressed:
                () => _openClientDetailDialog(summary: summary, entry: entry),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildServerClientTile(_ServerInventoryItem item, AdminAgent agent) {
    final statusColor =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: const Icon(
              Icons.computer_rounded,
              size: 18,
              color: Color(0xFF2563EB),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agent.clientName,
                  style: const TextStyle(
                    color: Color(0xFF101828),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${agent.database} - ${agent.tables.length} tables - ${item.serverName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _buildRoleBadge(agent.isMaster),
                    StatusBadge(
                      label: agent.isOnline ? 'Online' : 'Offline',
                      color: statusColor,
                    ),
                    MetricPill(
                      label: 'Server Link',
                      value: agent.serverConnected ? 'Connected' : 'Pending',
                    ),
                    MetricPill(
                      label: 'SQL',
                      value: agent.sqlConnected ? 'Connected' : 'Pending',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: () => _openClientPage(agent.clientName),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Open Client'),
          ),
        ],
      ),
    );
  }

  Widget _buildClientPage(AdminAgent agent) {
    final tables = List<AdminTableState>.from(agent.tables)
      ..sort((left, right) => left.table.compareTo(right.table));
    final jobs = List<AdminJob>.from(_jobs)..sort(_compareJobsByUpdatedAtDesc);
    final clientJobs = jobs
        .where((job) => job.clientName == agent.clientName)
        .take(_historyLimit)
        .toList(growable: false);

    return ListView(
      children: [
        _buildClientHeroCard(agent),
        const SizedBox(height: 10),
        SurfaceCard(
          title: 'Tables',
          subtitle:
              'Open a client table to inspect its sync state and history.',
          child:
              tables.isEmpty
                  ? const EmptyStateCard(
                    message: 'This client is not exposing any tables yet.',
                  )
                  : Column(
                    children: [
                      for (var index = 0; index < tables.length; index++) ...[
                        _buildClientTablePageTile(agent, tables[index]),
                        if (index != tables.length - 1)
                          const SizedBox(height: 8),
                      ],
                    ],
                  ),
        ),
        const SizedBox(height: 10),
        SurfaceCard(
          title: 'Recent History',
          subtitle: 'Latest sync jobs for this client.',
          child:
              clientJobs.isEmpty
                  ? const EmptyStateCard(
                    message:
                        'No sync jobs have been recorded for this client yet.',
                  )
                  : Column(
                    children: [
                      for (
                        var index = 0;
                        index < clientJobs.length;
                        index++
                      ) ...[
                        _buildClientJobTile(clientJobs[index]),
                        if (index != clientJobs.length - 1)
                          const SizedBox(height: 8),
                      ],
                    ],
                  ),
        ),
      ],
    );
  }

  Widget _buildClientHeroCard(AdminAgent agent) {
    final serverItem = _serverItemForClientName(agent.clientName);
    return SurfaceCard(
      title: agent.clientName,
      subtitle: 'Client page for ${serverItem?.title ?? 'server'}',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          MetricPill(label: 'Server', value: agent.server),
          MetricPill(label: 'Machine', value: agent.machineName),
          MetricPill(label: 'Database', value: agent.database),
          MetricPill(label: 'Tables', value: '${agent.tables.length}'),
          MetricPill(label: 'Role', value: _roleLabel(agent.isMaster)),
          MetricPill(label: 'Online', value: agent.isOnline ? 'Yes' : 'No'),
        ],
      ),
    );
  }

  Widget _buildClientTablePageTile(
    AdminAgent agent,
    AdminTableState tableState,
  ) {
    final summary =
        _derivedSummaryByTable[_tableKeyForAgent(agent, tableState)];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _displayTableName(tableState.table),
                  style: const TextStyle(
                    color: Color(0xFF101828),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${tableState.rowCount} rows - Last sync ${_formatTimestamp(_tableTimestampToken(tableState))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
          StatusBadge(
            label: tableState.status,
            color: _statusColor(tableState.status),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Open table details',
            onPressed:
                summary == null
                    ? null
                    : () => _openClientDetailDialog(
                      summary: summary,
                      entry: _TableClientEntry(
                        agent: agent,
                        tableState: tableState,
                      ),
                    ),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildClientJobTile(AdminJob job) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _displayTableName(job.table),
                  style: const TextStyle(
                    color: Color(0xFF101828),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${job.direction.toUpperCase()} - ${_formatTimestamp(job.updatedAt)}',
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
          StatusBadge(label: job.status, color: _statusColor(job.status)),
        ],
      ),
    );
  }

  String _displayTableName(String table) {
    final separatorIndex = table.indexOf(_TableAggregateSummary.separator);
    final value =
        separatorIndex < 0
            ? table
            : table.substring(
              separatorIndex + _TableAggregateSummary.separator.length,
            );
    return value.replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');
  }

  Widget _buildServerInventoryTile(_ServerInventoryItem item) {
    final statusColor =
        item.available ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final databases =
        item.databases.isEmpty ? 'None reported' : item.databases.join(', ');
    final clients =
        item.clientNames.isEmpty
            ? 'None reported'
            : item.clientNames.join(', ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: item.isLocal ? const Color(0xFFF8FFFC) : const Color(0xFFFCFCFD),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color:
              item.isLocal ? const Color(0xFFB7DDD7) : const Color(0xFFDDE3EA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFDDE3EA)),
                ),
                child: const Icon(
                  Icons.dns_rounded,
                  size: 19,
                  color: Color(0xFF0F766E),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF101828),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.roleLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(label: item.statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              MetricPill(label: 'Platform', value: item.platformLabel),
              MetricPill(label: 'Machine', value: item.machineName),
              MetricPill(label: 'Server', value: item.serverName),
              MetricPill(label: 'Clients', value: '${item.connectedClients}'),
              if (item.onlineClients > 0)
                MetricPill(label: 'Online', value: '${item.onlineClients}'),
              MetricPill(
                label: 'Server Link',
                value: '${item.serverConnectedClients}',
              ),
              if (item.sqlConnectedClients > 0)
                MetricPill(label: 'SQL', value: '${item.sqlConnectedClients}'),
              MetricPill(
                label: 'Scope',
                value: item.isLocal ? 'Local' : 'Live',
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildServerInfoLine('Databases', databases),
          const SizedBox(height: 4),
          _buildServerInfoLine('Clients', clients),
          const SizedBox(height: 4),
          _buildServerInfoLine(
            'Last Heartbeat',
            item.lastHeartbeat.isEmpty
                ? 'No heartbeat reported'
                : _formatTimestamp(item.lastHeartbeat),
          ),
        ],
      ),
    );
  }

  Widget _buildServerInfoLine(String label, String value) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
              color: Color(0xFF667085),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xFF101828),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildJobCard(AdminJob job, {VoidCallback? onOpenSnapshot}) {
    final canOpenSnapshot = (job.snapshotId?.trim().isNotEmpty ?? false);
    final eventTime = _formatTimestamp(job.completedAt ?? job.updatedAt);
    final message =
        job.message.isEmpty ? 'No job message recorded.' : job.message;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap:
            canOpenSnapshot
                ? (onOpenSnapshot ?? () => _openJobSnapshotDialog(job))
                : null,
        child: Ink(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0xFFE2D8CB)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stack = constraints.maxWidth < 620;
                final trailing = Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      job.clientName,
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '${job.progress}%',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '${job.rowCount} rows',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      _formatBytes(job.snapshotBytes),
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 11,
                      ),
                    ),
                    if (canOpenSnapshot)
                      const Icon(
                        Icons.table_rows_outlined,
                        size: 14,
                        color: Color(0xFF62717C),
                      ),
                  ],
                );

                if (stack) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          StatusBadge(
                            label: job.status,
                            color: _statusColor(job.status),
                          ),
                          Text(
                            job.direction.toUpperCase(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
                            ),
                          ),
                          Text(
                            eventTime,
                            style: const TextStyle(
                              color: Color(0xFF5F6B76),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.1, fontSize: 11.5),
                      ),
                      const SizedBox(height: 3),
                      trailing,
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    StatusBadge(
                      label: job.status,
                      color: _statusColor(job.status),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 84,
                      child: Text(
                        job.direction.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.1, fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 154,
                      child: Text(
                        eventTime,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Color(0xFF5F6B76),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    trailing,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinnedSummaryBar() {
    final summary = _selectedTableSummary;
    final selectedClient = _selectedClientEntry;
    final tableState = selectedClient?.tableState;
    final state = _state;
    final lastSync =
        tableState == null
            ? _formatTimestamp(summary?.lastSync ?? '')
            : _formatTimestamp(_tableTimestampToken(tableState));
    final backupBytes =
        tableState?.snapshotBytes ?? summary?.latestSnapshotBytes;
    final status = _connected ? 'Online' : 'Offline';
    final visibleTables = _tableSummariesForDatabase(_tableSummaries).length;
    final totalTables = _tableSummaries.length;
    final totalClients = state?.agents.length ?? 0;
    final totalJobs = _jobs.length;

    final footerItems = <Widget>[
      InfoLine(label: 'Status', value: status),
      InfoLine(
        label: 'Updated',
        value: state == null ? 'Waiting' : _formatTimestamp(state.generatedAt),
      ),
      InfoLine(label: 'Table', value: summary?.displayTable ?? 'None'),
      InfoLine(label: 'Database', value: _selectedDatabaseName ?? 'None'),
      InfoLine(label: 'Shown', value: '$visibleTables / $totalTables'),
      InfoLine(label: 'Clients', value: '${summary?.clientCount ?? 0}'),
      InfoLine(label: 'Master', value: '${summary?.masterCount ?? 0}'),
      InfoLine(label: 'Slave', value: '${summary?.slaveCount ?? 0}'),
      InfoLine(label: 'Client', value: _selectedClientName ?? 'All'),
      InfoLine(label: 'Agents', value: '$totalClients'),
      InfoLine(label: 'Jobs', value: '$totalJobs'),
      InfoLine(label: 'Last Sync', value: lastSync),
      InfoLine(
        label: 'Backup',
        value: backupBytes == null ? '--' : _formatBytes(backupBytes),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 720;

        return Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFDDE3EA))),
            color: Color(0xFFF6F7F9),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child:
                  stack
                      ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: footerItems,
                          ),
                          const SizedBox(height: 8),
                          _buildBackendStatusIndicator(),
                        ],
                      )
                      : Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: footerItems,
                            ),
                          ),
                          const SizedBox(width: 12),
                          _buildBackendStatusIndicator(),
                        ],
                      ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBackendStatusIndicator() {
    final color =
        _connected ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final label = _connected ? 'Online' : 'Offline';

    return Tooltip(
      message:
          _state == null
              ? 'Backend connection status.'
              : 'Last refresh ${_formatTimestamp(_state!.generatedAt)}',
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

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactAppBar = screenWidth < 760;
    final compactLayout = screenWidth < 980;
    final profileCompact = screenWidth < 560;
    final pagePadding =
        screenWidth < 480
            ? const EdgeInsets.all(8)
            : (screenWidth < 760
                ? const EdgeInsets.all(10)
                : const EdgeInsets.all(12));
    final title = _currentPageTitle();
    final profileLabel =
        widget.authenticatedUser.name.trim().isEmpty
            ? widget.authenticatedUser.username
            : widget.authenticatedUser.name;

    return Scaffold(
      drawer:
          compactLayout
              ? Drawer(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: _buildNavigationPane(closeAfterSelection: true),
                  ),
                ),
              )
              : null,
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 12,
        title: Text(
          compactAppBar ? 'SQL Sync' : title,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        actions: [
          Container(
            height: 36,
            margin: EdgeInsets.only(right: compactAppBar ? 4 : 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Refresh now',
                  onPressed: () => unawaited(_refreshState()),
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
                Container(width: 1, height: 20, color: const Color(0xFFE4E7EC)),
                PopupMenuButton<_ProfileMenuAction>(
                  tooltip: 'Profile',
                  position: PopupMenuPosition.under,
                  offset: const Offset(0, 8),
                  onSelected: (value) {
                    switch (value) {
                      case _ProfileMenuAction.settings:
                        unawaited(_openSettingsDialog());
                        break;
                      case _ProfileMenuAction.users:
                        unawaited(_openUserManagementDialog());
                        break;
                      case _ProfileMenuAction.about:
                        unawaited(_openAboutDialog());
                        break;
                      case _ProfileMenuAction.signOut:
                        widget.onLogout();
                        break;
                    }
                  },
                  itemBuilder:
                      (context) => [
                        const PopupMenuItem<_ProfileMenuAction>(
                          value: _ProfileMenuAction.settings,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.settings_outlined),
                            title: Text('Settings'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        if (widget.authenticatedUser.canManageUsers)
                          const PopupMenuItem<_ProfileMenuAction>(
                            value: _ProfileMenuAction.users,
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.manage_accounts_outlined),
                              title: Text('Users'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        const PopupMenuItem<_ProfileMenuAction>(
                          value: _ProfileMenuAction.about,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.info_outline),
                            title: Text('About'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<_ProfileMenuAction>(
                          value: _ProfileMenuAction.signOut,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.logout_rounded),
                            title: Text('Sign out'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: profileCompact ? 7 : 8,
                      right: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircleAvatar(
                          radius: 12,
                          backgroundColor: Color(0xFFE6F4F1),
                          child: Icon(
                            Icons.person_outline,
                            size: 14,
                            color: Color(0xFF0F766E),
                          ),
                        ),
                        if (!profileCompact) ...[
                          const SizedBox(width: 7),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: Text(
                              profileLabel,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF101828),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: Color(0xFF667085),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Padding(
        padding: pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0xFFFEF3F2),
                  border: Border.all(color: const Color(0xFFF7C9C4)),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFB42318)),
                ),
              ),
            Expanded(
              child:
                  _loading && state == null
                      ? const Center(child: CircularProgressIndicator())
                      : _buildDashboardContent(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildPinnedSummaryBar(),
    );
  }

  String _currentPageTitle() {
    final clientAgent = _selectedPageClientAgent;
    if (clientAgent != null) {
      return 'SQL Sync - ${clientAgent.clientName}';
    }
    final serverItem = _selectedServerInventoryItem;
    if (serverItem != null) {
      return 'SQL Sync - ${serverItem.title}';
    }
    if (_selectedTableName == null) {
      return 'SQL Sync';
    }
    return 'SQL Sync - ${_selectedTableSummary?.displayTitle ?? _selectedTableName}';
  }
}

class _TableAggregateSummary {
  const _TableAggregateSummary({
    required this.table,
    required this.lastSync,
    required this.clientCount,
    required this.masterCount,
    required this.slaveCount,
    required this.latestRowCount,
    required this.latestSnapshotBytes,
    required this.sourceClientName,
    required this.clients,
  });

  final String table;
  final String lastSync;
  final int clientCount;
  final int masterCount;
  final int slaveCount;
  final int latestRowCount;
  final int latestSnapshotBytes;
  final String sourceClientName;
  final List<_TableClientEntry> clients;

  static const String separator = '::';

  String get database {
    final separatorIndex = table.indexOf(separator);
    return separatorIndex < 0 ? '' : table.substring(0, separatorIndex);
  }

  String get displayTable {
    final separatorIndex = table.indexOf(separator);
    final localTable =
        separatorIndex < 0
            ? table
            : table.substring(separatorIndex + separator.length);
    return localTable.replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');
  }

  String get displayTitle => displayTable;
}

class _TableClientEntry {
  const _TableClientEntry({required this.agent, required this.tableState});

  final AdminAgent agent;
  final AdminTableState tableState;
}

class _TableSnapshotSource {
  const _TableSnapshotSource({
    required this.clientName,
    required this.table,
    required this.createdAt,
    required this.rowCount,
    required this.snapshotBytes,
  });

  final String clientName;
  final String table;
  final String createdAt;
  final int rowCount;
  final int snapshotBytes;
}

class _ServerInventoryItem {
  const _ServerInventoryItem({
    required this.key,
    required this.title,
    required this.serverName,
    required this.machineName,
    required this.platformLabel,
    required this.roleLabel,
    required this.statusLabel,
    required this.available,
    required this.isLocal,
    required this.connectedClients,
    this.onlineClients = 0,
    this.serverConnectedClients = 0,
    this.sqlConnectedClients = 0,
    this.databases = const <String>[],
    this.clientNames = const <String>[],
    this.lastHeartbeat = '',
    this.agents = const <AdminAgent>[],
  });

  final String key;
  final String title;
  final String serverName;
  final String machineName;
  final String platformLabel;
  final String roleLabel;
  final String statusLabel;
  final bool available;
  final bool isLocal;
  final int connectedClients;
  final int onlineClients;
  final int serverConnectedClients;
  final int sqlConnectedClients;
  final List<String> databases;
  final List<String> clientNames;
  final String lastHeartbeat;
  final List<AdminAgent> agents;
}

class _ScoredTableSummary {
  const _ScoredTableSummary({required this.summary, required this.score});

  final _TableAggregateSummary summary;
  final double score;
}

enum _TableMetricKind { synced, merged, attempted }

class _TableMetricDialogData {
  const _TableMetricDialogData({
    required this.title,
    required this.tableName,
    required this.icon,
    required this.countText,
    required this.meaning,
    required this.emptyMessage,
    required this.clients,
  });

  final String title;
  final String tableName;
  final IconData icon;
  final String countText;
  final String meaning;
  final String emptyMessage;
  final List<_TableMetricClientInfo> clients;
}

class _TableMetricClientInfo {
  const _TableMetricClientInfo({
    required this.name,
    required this.subtitle,
    required this.detail,
    required this.active,
  });

  final String name;
  final String subtitle;
  final String detail;
  final bool active;
}

class _ScoredSnapshotRow {
  const _ScoredSnapshotRow({
    required this.originalIndex,
    required this.row,
    required this.score,
  });

  final int originalIndex;
  final Map<String, String?> row;
  final double score;
}

class _MasterRowAttempt {
  const _MasterRowAttempt({
    required this.masterName,
    required this.snapshot,
    required this.isSelectedSource,
    required this.usedByClients,
  });

  final String masterName;
  final AdminSnapshotDetail snapshot;
  final bool isSelectedSource;
  final List<String> usedByClients;
}
