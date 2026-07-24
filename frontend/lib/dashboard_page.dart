import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'browser_bridge.dart';
import 'client_sync_progress.dart';
import 'database_selection.dart';
import 'dashboard_widgets.dart';
import 'live_sync_api.dart';
import 'models.dart';

const String _historyLimitStorageKey = 'sync_admin_web.history_limit';
const int _defaultHistoryLimit = 5;
const int _maxHistoryLimit = 100;
const int _defaultAutoSyncIntervalMinutes = 15;
const int _minAutoSyncIntervalMinutes = 1;
const int _maxAutoSyncIntervalMinutes = 1440;
const Duration _dashboardRefreshInterval = Duration(seconds: 15);
const Duration _dashboardReconnectDelay = Duration(minutes: 1);
const int _bulkDiagnosticsBatchSize = 5;
const String _requestAllLogsAction = 'requestAllClientLogs';
const String _waitForLogsQueryKey = 'waitForLogs';
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
  bool _refreshInFlight = false;

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
  Map<String, List<AdminJob>> _derivedJobsByTable =
      const <String, List<AdminJob>>{};
  Map<String, List<AdminJob>> _derivedJobsByTableClient =
      const <String, List<AdminJob>>{};
  List<AuthenticatedUser> _visibleUsers = const <AuthenticatedUser>[];
  bool _loading = true;
  bool _loadingUsers = false;
  bool _connected = false;
  String? _error;
  String? _userListError;
  final Set<String> _deletingClientUserIds = <String>{};
  String? _selectedClientName;
  String? _selectedTableName;
  String? _selectedDatabaseName;
  String? _selectedServerKey;
  String? _selectedPageClientName;
  bool _sortLastSyncAscending = false;
  int _detailTabIndex = 0;
  int _historyLimit = _defaultHistoryLimit;
  final Set<String> _busyTablePolicyKeys = <String>{};
  final Set<String> _requestingDiagnosticsClientNames = <String>{};
  final Set<String> _requestingClientUpdateClientNames = <String>{};
  bool _bulkSyncBusy = false;
  bool _bulkDiagnosticsBusy = false;
  bool _bulkClientUpdateBusy = false;
  bool _bulkWindowMinimizeBusy = false;
  bool _serverResetBusy = false;
  AdminServerResetResult? _lastServerResetResult;
  bool _handledLaunchAction = false;
  String? _bulkDiagnosticsRequestId;
  String? _bulkDiagnosticsRequestedAt;
  List<String> _bulkDiagnosticsRequestedClientNames = const <String>[];
  List<String> _bulkDiagnosticsCompletedClientNames = const <String>[];
  List<String> _bulkDiagnosticsPendingClientNames = const <String>[];
  bool _bulkDiagnosticsWaitingForUploads = false;
  bool get _showBulkActionsInLegacyDashboard => false;
  @override
  void initState() {
    super.initState();
    _api.setAuthToken(widget.authToken);
    _historyLimit = _readStoredHistoryLimit();
    _selectedDatabaseName = _readStoredDatabaseSelection();
    _syncSearchController.addListener(_handleSearchChange);
    _startRefreshPolling();
    if (widget.authenticatedUser.canManageUsers) {
      unawaited(_refreshVisibleUsers());
    }
    unawaited(_refreshState());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_handleLaunchActionUrl());
    });
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

  String? _readStoredDatabaseSelection() {
    final stored =
        readBrowserStorage(
          databaseSelectionStorageKey(widget.authenticatedUser),
        )?.trim();
    return stored == null || stored.isEmpty ? null : stored;
  }

  void _persistDatabaseSelection(String? databaseName) {
    final key = databaseSelectionStorageKey(widget.authenticatedUser);
    final normalized = databaseName?.trim() ?? '';
    if (normalized.isEmpty) {
      removeBrowserStorage(key);
      return;
    }
    writeBrowserStorage(key, normalized);
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
    if (_refreshInFlight) {
      return;
    }
    _refreshInFlight = true;
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
      if (nextDatabaseName != _selectedDatabaseName) {
        _persistDatabaseSelection(nextDatabaseName);
      }
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
      _updateBulkDiagnosticsProgress(nextState);
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
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<void> _refreshVisibleUsers({bool silent = false}) async {
    if (!widget.authenticatedUser.canManageUsers) {
      return;
    }
    if (!silent && mounted) {
      setState(() {
        _loadingUsers = true;
        _userListError = null;
      });
    }

    try {
      final users = await _api.listUsers();
      if (!mounted) {
        return;
      }
      setState(() {
        _visibleUsers = users;
        _loadingUsers = false;
        _userListError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingUsers = false;
        _userListError = error.toString();
      });
    }
  }

  Future<void> _confirmAndDeleteClientUser(AuthenticatedUser user) async {
    if (!_canDeleteClientUser(user)) {
      return;
    }
    if (_deletingClientUserIds.contains(user.id)) {
      return;
    }

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete Client ${user.name}?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              'This removes the client account, revokes its sessions, and removes its live client entry. Sync history is kept.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB42318),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete Client'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _deletingClientUserIds.add(user.id);
      _userListError = null;
    });

    try {
      await _api.deleteUser(userId: user.id);
      await _refreshVisibleUsers(silent: true);
      if (!mounted) {
        return;
      }
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Deleted client ${user.name}.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _userListError = error.toString();
      });
      scaffoldMessenger.showSnackBar(
        SnackBar(content: SelectableText(error.toString())),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deletingClientUserIds.remove(user.id);
        });
      }
    }
  }

  bool _canDeleteClientUser(AuthenticatedUser user) {
    if (!user.isClient) {
      return false;
    }
    if (widget.authenticatedUser.isAdmin) {
      return true;
    }
    if (!widget.authenticatedUser.isOwner) {
      return false;
    }
    return user.ownerUserId == widget.authenticatedUser.id;
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
          latestRowCount: latestClient.tableState.rowCount,
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

    final databaseTableSets = <String, Set<String>>{};
    for (final summary in summaries) {
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
              (databaseName == null ||
                  databaseName.isEmpty ||
                  summary.database == databaseName),
        )
        .toList(growable: false);
  }

  String? _resolveSelectedDatabase(AdminLiveState state) {
    final databases = _databaseNamesFromState(state);
    return resolveDatabaseSelection(
      preferred: _selectedDatabaseName,
      available: databases,
    );
  }

  String? _resolveSelectedTable(AdminLiveState state, {String? databaseName}) {
    final summaries = _tableSummariesFromState(state)
        .where(
          (summary) =>
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
      _detailTabIndex = 0;
    });
    _persistDatabaseSelection(databaseName);
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
    final byTimestamp = _compareTimestamps(
      _tableTimestampToken(right.tableState),
      _tableTimestampToken(left.tableState),
    );
    if (byTimestamp != 0) {
      return byTimestamp;
    }
    return left.agent.clientName.compareTo(right.agent.clientName);
  }

  String _tableTimestampToken(AdminTableState tableState) =>
      tableState.lastSync.trim();

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
      _detailTabIndex = 0;
    });
  }

  Future<void> _openTableFromSummary(_TableAggregateSummary summary) async {
    _selectTable(summary.table);
    await _openTableDataDialog(summary);
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
    final firstAgent = agents.isEmpty ? null : agents.first;
    final agentHistoryController = TextEditingController(
      text: (firstAgent?.historyLimit ?? _defaultHistoryLimit).toString(),
    );
    final autoSyncIntervalController = TextEditingController(
      text:
          (firstAgent?.autoSyncIntervalMinutes ??
                  _defaultAutoSyncIntervalMinutes)
              .toString(),
    );
    var saving = false;
    String? webHistoryError;
    String? agentHistoryError;
    String? autoSyncIntervalError;
    String? saveError;

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
                        Text(
                          'Applies to all ${agents.length} client${agents.length == 1 ? '' : 's'}.',
                          style: const TextStyle(
                            color: Color(0xFF667085),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
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
                            if (agents.isNotEmpty) {
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
                              if (agents.isNotEmpty &&
                                  nextAgentHistoryLimit != null &&
                                  nextAutoSyncInterval != null) {
                                await _api.updateAllAgentSyncSettings(
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
      if (mounted) {
        setState(() {
          _visibleUsers = users;
          _userListError = null;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
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
    String? deletingUserId;
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
                  errorText = 'Select a server user for the client account.';
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
                  if (mounted) {
                    setState(() {
                      _visibleUsers = dialogUsers;
                    });
                  }
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
                final message = error.toString();
                if (message.toLowerCase().contains('already exists')) {
                  try {
                    final refreshedUsers = await _api.listUsers();
                    if (mounted) {
                      setState(() {
                        _visibleUsers = refreshedUsers;
                        _userListError = null;
                      });
                    }
                    setDialogState(() {
                      dialogUsers = List<AuthenticatedUser>.from(
                        refreshedUsers,
                      );
                      submitting = false;
                      errorText =
                          'That account already exists. The visible account list was refreshed.';
                    });
                    return;
                  } catch (_) {}
                }
                setDialogState(() {
                  submitting = false;
                  errorText = message;
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

            Future<void> openDeleteClientDialog(AuthenticatedUser user) async {
              if (!_canDeleteClientUser(user)) {
                return;
              }

              final scaffoldMessenger = ScaffoldMessenger.of(this.context);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text('Delete Client ${user.name}?'),
                    content: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Text(
                        'This removes the client account, revokes its sessions, and removes its live client entry. Sync history is kept.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(height: 1.45),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB42318),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Delete Client'),
                      ),
                    ],
                  );
                },
              );

              if (confirmed != true) {
                return;
              }

              setDialogState(() {
                deletingUserId = user.id;
                errorText = null;
              });

              try {
                await _api.deleteUser(userId: user.id);
                final refreshedUsers = await _api.listUsers();
                if (!mounted) {
                  return;
                }
                setState(() {
                  _visibleUsers = refreshedUsers;
                  _userListError = null;
                });
                setDialogState(() {
                  dialogUsers = List<AuthenticatedUser>.from(refreshedUsers);
                  deletingUserId = null;
                });
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text('Deleted client ${user.name}.')),
                );
              } catch (error) {
                if (!mounted) {
                  return;
                }
                setDialogState(() {
                  deletingUserId = null;
                  errorText = error.toString();
                });
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
                            ? 'Admins can create server users or client accounts. Server users can create client accounts in their own namespace.'
                            : 'Server users can create client accounts in their own namespace.',
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
                              initialValue: selectedRole,
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
                                initialValue: selectedOwnerUserId,
                                decoration: const InputDecoration(
                                  labelText: 'Server User',
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
                        'Visible Accounts',
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
                                    final deleting = deletingUserId == user.id;
                                    final roleColor =
                                        user.isAdmin
                                            ? const Color(0xFF143842)
                                            : user.isOwner
                                            ? const Color(0xFF2B6F73)
                                            : const Color(0xFFD8A23A);
                                    final identity = Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          user.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        if (user.email.trim().isNotEmpty)
                                          Text(
                                            user.email,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xFF8A949A),
                                              fontSize: 12,
                                            ),
                                          ),
                                      ],
                                    );
                                    final accountMeta = Text(
                                      user.isClient
                                          ? 'Server user: $serverLabel'
                                          : 'Web account',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        color: Color(0xFF58656B),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    );
                                    final trailing = Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      alignment: WrapAlignment.end,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        StatusBadge(
                                          label: user.role.toUpperCase(),
                                          color: roleColor,
                                        ),
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 190,
                                          ),
                                          child: accountMeta,
                                        ),
                                        if (widget.authenticatedUser.isAdmin)
                                          OutlinedButton(
                                            onPressed:
                                                deleting
                                                    ? null
                                                    : () => unawaited(
                                                      openResetPasswordDialog(
                                                        user,
                                                      ),
                                                    ),
                                            child: const Text('Reset Password'),
                                          ),
                                        if (_canDeleteClientUser(user))
                                          OutlinedButton.icon(
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: const Color(
                                                0xFFB42318,
                                              ),
                                              side: const BorderSide(
                                                color: Color(0xFFFDA29B),
                                              ),
                                            ),
                                            onPressed:
                                                deleting
                                                    ? null
                                                    : () => unawaited(
                                                      openDeleteClientDialog(
                                                        user,
                                                      ),
                                                    ),
                                            icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 16,
                                            ),
                                            label: Text(
                                              deleting
                                                  ? 'Deleting...'
                                                  : 'Delete',
                                            ),
                                          ),
                                      ],
                                    );
                                    return Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFFDDE3EA),
                                        ),
                                      ),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final stack =
                                              constraints.maxWidth < 700;
                                          if (stack) {
                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                identity,
                                                const SizedBox(height: 10),
                                                trailing,
                                              ],
                                            );
                                          }
                                          return Row(
                                            children: [
                                              Expanded(child: identity),
                                              const SizedBox(width: 12),
                                              Flexible(
                                                child: Align(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: trailing,
                                                ),
                                              ),
                                            ],
                                          );
                                        },
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
    await showDialog<void>(
      context: context,
      builder: (context) {
        final canGoBackToDetails = backLabel?.trim().isNotEmpty ?? false;
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 860,
              maxHeight: MediaQuery.sizeOf(context).height * 0.84,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (canGoBackToDetails) ...[
                        IconButton(
                          tooltip: backLabel!.trim(),
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          '$clientName History',
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
                        jobs.isEmpty
                            ? const EmptyStateCard(
                              message:
                                  'No sync jobs have been recorded yet for this client or table.',
                            )
                            : ListView.separated(
                              itemCount: jobs.length,
                              separatorBuilder:
                                  (_, _) => const SizedBox(height: 6),
                              itemBuilder:
                                  (context, index) =>
                                      _buildJobCard(jobs[index]),
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
    await showDialog<void>(
      context: context,
      builder: (context) {
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
                    recentHistoryCount: recentJobs.length,
                    totalHistoryCount: jobs.length,
                    onSync:
                        entry.tableState.enabled
                            ? () => _triggerJob(
                              clientName: entry.agent.clientName,
                              table: summary.table,
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
                  Expanded(child: _buildRecentHistoryPanel(recentJobs)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openTableDataDialog(_TableAggregateSummary summary) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 860,
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          summary.displayTitle,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
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
                  const SizedBox(height: 14),
                  _buildTableDialogClientStatus(summary),
                  const SizedBox(height: 12),
                  const EmptyStateCard(
                    message:
                        'The control plane no longer stores row-level table payloads. Use sync job history and the Windows client for table-level verification.',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTableDialogClientStatus(_TableAggregateSummary summary) {
    final clients = List<_TableClientEntry>.from(summary.clients)
      ..sort(_compareClientEntries);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Client Sync Status',
                  style: TextStyle(
                    color: Color(0xFF101828),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              MetricPill(label: 'Clients', value: '${clients.length}'),
            ],
          ),
          const SizedBox(height: 8),
          if (clients.isEmpty)
            const Text(
              'No clients expose this table yet.',
              style: TextStyle(
                color: Color(0xFF667085),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in clients) _buildClientSyncStatusChip(entry),
              ],
            ),
        ],
      ),
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

  Future<void> _triggerJob({
    required String clientName,
    required String table,
  }) async {
    try {
      await _api.triggerJob(clientName: clientName, table: table);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Merge sync queued for $table on $clientName.')),
      );
      await _refreshState(silent: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    }
  }

  Future<void> _triggerSyncAllEnabledNow() async {
    if (_bulkSyncBusy) {
      return;
    }
    setState(() {
      _bulkSyncBusy = true;
    });
    try {
      final result = await _api.triggerSyncAllEnabledNow();
      if (!mounted) {
        return;
      }
      final details = <String>[
        'Queued ${result.queuedJobCount} jobs across ${result.queuedClientCount} clients.',
      ];
      if (result.skippedOfflineClients.isNotEmpty) {
        details.add('Offline: ${result.skippedOfflineClients.join(', ')}');
      }
      if (result.skippedBusyTables.isNotEmpty) {
        details.add('Busy tables skipped: ${result.skippedBusyTables.length}');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(details.join(' '))));
      await _refreshState(silent: true);
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
          _bulkSyncBusy = false;
        });
      }
    }
  }

  Future<void> _confirmAndResetServerSavedData() async {
    if (!widget.authenticatedUser.isAdmin || _serverResetBusy) {
      return;
    }

    final confirmationController = TextEditingController();
    var confirmed = false;
    try {
      final shouldReset = await showDialog<bool>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final matches =
                  confirmationController.text.trim().toUpperCase() == 'RESET';
              return AlertDialog(
                title: const Text('Reset Server Sync Data?'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This immediately cancels active sync operations, then permanently deletes all saved sync jobs, transfer data, and cached client diagnostics on the server. Client machines keep their local SQL data.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(height: 1.45),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Type RESET to confirm.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFB42318),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: confirmationController,
                        autofocus: true,
                        onChanged: (_) => setDialogState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'RESET',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB42318),
                      foregroundColor: Colors.white,
                    ),
                    onPressed:
                        matches ? () => Navigator.of(context).pop(true) : null,
                    child: const Text('Reset Server Data'),
                  ),
                ],
              );
            },
          );
        },
      );
      confirmed = shouldReset == true;
    } finally {
      confirmationController.dispose();
    }

    if (!confirmed) {
      return;
    }

    setState(() {
      _serverResetBusy = true;
      _lastServerResetResult = null;
    });

    try {
      final result = await _api.resetServerSavedData();
      if (!mounted) {
        return;
      }
      setState(() => _lastServerResetResult = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Server data cleaned. Cancelled ${result.cancelledJobCount} active sync operation(s), deleted ${result.deletedRecordCount} saved records, reset ${result.agentResetCount} agents, and paused automatic sync. Live client connectivity was preserved.',
          ),
        ),
      );
      await _refreshState(silent: true);
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
          _serverResetBusy = false;
        });
      }
    }
  }

  String _requestAllLogsActionUrl() {
    final current = Uri.base;
    final nextQuery = Map<String, String>.from(current.queryParameters);
    nextQuery['action'] = _requestAllLogsAction;
    nextQuery[_waitForLogsQueryKey] = '1';
    return current.replace(queryParameters: nextQuery).toString();
  }

  void _clearLaunchActionUrl() {
    final current = Uri.base;
    if (!current.queryParameters.containsKey('action')) {
      return;
    }
    final nextQuery =
        Map<String, String>.from(current.queryParameters)
          ..remove('action')
          ..remove(_waitForLogsQueryKey);
    final nextUrl =
        current
            .replace(queryParameters: nextQuery.isEmpty ? null : nextQuery)
            .toString();
    replaceBrowserUrl(nextUrl);
  }

  Future<void> _handleLaunchActionUrl() async {
    if (_handledLaunchAction || !widget.authenticatedUser.canManageUsers) {
      return;
    }
    _handledLaunchAction = true;
    final action = Uri.base.queryParameters['action']?.trim() ?? '';
    if (action != _requestAllLogsAction) {
      return;
    }
    final shouldWaitForUploads =
        Uri.base.queryParameters[_waitForLogsQueryKey] == '1';
    _clearLaunchActionUrl();
    await _requestAllAgentDiagnostics(
      fromActionUrl: true,
      waitForUploads: shouldWaitForUploads,
    );
  }

  void _openBulkDiagnosticsTab() {
    openBrowserTab(_requestAllLogsActionUrl());
  }

  void _updateBulkDiagnosticsProgress(AdminLiveState state) {
    final requestId = _bulkDiagnosticsRequestId?.trim() ?? '';
    if (requestId.isEmpty || _bulkDiagnosticsRequestedClientNames.isEmpty) {
      return;
    }

    final pending = <String>[];
    final completed = <String>[];
    for (final clientName in _bulkDiagnosticsRequestedClientNames) {
      final normalized = clientName.trim();
      AdminAgent? agent;
      for (final item in state.agents) {
        if (item.clientName == normalized) {
          agent = item;
          break;
        }
      }
      final diagnostics = agent?.diagnostics;
      final uploadedForRequest =
          diagnostics != null &&
          (diagnostics.lastRequestId?.trim() ?? '') == requestId &&
          (diagnostics.uploadedAt?.trim().isNotEmpty ?? false);
      if (uploadedForRequest) {
        completed.add(normalized);
      } else {
        pending.add(normalized);
      }
    }

    if (!mounted) {
      _bulkDiagnosticsCompletedClientNames = List<String>.unmodifiable(
        completed,
      );
      _bulkDiagnosticsPendingClientNames = List<String>.unmodifiable(pending);
      _bulkDiagnosticsWaitingForUploads = pending.isNotEmpty;
      return;
    }

    setState(() {
      _bulkDiagnosticsCompletedClientNames = List<String>.unmodifiable(
        completed,
      );
      _bulkDiagnosticsPendingClientNames = List<String>.unmodifiable(pending);
      _bulkDiagnosticsWaitingForUploads = pending.isNotEmpty;
    });
  }

  Future<void> _requestAllAgentDiagnostics({
    bool fromActionUrl = false,
    bool waitForUploads = false,
  }) async {
    if (_bulkDiagnosticsBusy) {
      return;
    }
    setState(() {
      _bulkDiagnosticsBusy = true;
    });
    try {
      final visibleOnlineClientNames = (_state?.agents ?? const <AdminAgent>[])
          .where((agent) => agent.isOnline)
          .map((agent) => agent.clientName.trim())
          .where((name) => name.isNotEmpty)
          .toList(growable: false);
      final uniqueClientNames = <String>[];
      for (final clientName in visibleOnlineClientNames) {
        if (!uniqueClientNames.contains(clientName)) {
          uniqueClientNames.add(clientName);
        }
      }

      AdminBulkDiagnosticsRequestResult? firstResult;
      final requestedNames = <String>[];
      var sharedRequestId = '';
      if (uniqueClientNames.isEmpty && _state == null) {
        firstResult = await _api.requestAllAgentDiagnostics();
        sharedRequestId = firstResult.requestId.trim();
        for (final clientName in firstResult.requestedClientNames) {
          final normalized = clientName.trim();
          if (normalized.isNotEmpty && !requestedNames.contains(normalized)) {
            requestedNames.add(normalized);
          }
        }
      } else {
        for (
          var index = 0;
          index < uniqueClientNames.length;
          index += _bulkDiagnosticsBatchSize
        ) {
          final batch = uniqueClientNames
              .skip(index)
              .take(_bulkDiagnosticsBatchSize)
              .toList(growable: false);
          final result = await _api.requestAgentDiagnosticsBatch(
            clientNames: batch,
            requestId: sharedRequestId,
          );
          firstResult ??= result;
          if (sharedRequestId.isEmpty) {
            sharedRequestId = result.requestId.trim();
          }
          for (final clientName in result.requestedClientNames) {
            final normalized = clientName.trim();
            if (normalized.isNotEmpty && !requestedNames.contains(normalized)) {
              requestedNames.add(normalized);
            }
          }
        }
      }
      final result =
          firstResult ??
          const AdminBulkDiagnosticsRequestResult(
            requestId: '',
            requestedAt: '',
            requestedByUserId: null,
            requestedClientCount: 0,
            requestedClientNames: <String>[],
          );
      if (!mounted) {
        return;
      }
      final requestedNamesView = List<String>.unmodifiable(requestedNames);
      setState(() {
        _bulkDiagnosticsRequestId =
            sharedRequestId.isEmpty ? null : sharedRequestId;
        _bulkDiagnosticsRequestedAt =
            result.requestedAt.trim().isEmpty
                ? null
                : result.requestedAt.trim();
        _bulkDiagnosticsRequestedClientNames = requestedNamesView;
        _bulkDiagnosticsCompletedClientNames = const <String>[];
        _bulkDiagnosticsPendingClientNames = requestedNamesView;
        _bulkDiagnosticsWaitingForUploads =
            waitForUploads && requestedNamesView.isNotEmpty;
      });
      final suffix =
          requestedNamesView.isEmpty
              ? 'No visible clients were available.'
              : requestedNamesView.length <= 5
              ? ' Clients: ${requestedNamesView.join(', ')}.'
              : ' Clients: ${requestedNamesView.take(5).join(', ')} and ${requestedNamesView.length - 5} more.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            fromActionUrl
                ? waitForUploads
                    ? 'Requested logs from ${requestedNamesView.length} clients in batches of $_bulkDiagnosticsBatchSize in this tab. Waiting for uploads now.$suffix'
                    : 'Requested logs from ${requestedNamesView.length} clients from the action URL in batches of $_bulkDiagnosticsBatchSize.$suffix'
                : 'Requested logs from ${requestedNamesView.length} clients in batches of $_bulkDiagnosticsBatchSize.$suffix',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      await _refreshState(silent: true);
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
          _bulkDiagnosticsBusy = false;
        });
      }
    }
  }

  Widget _buildBulkDiagnosticsWaitCard() {
    final requestId = _bulkDiagnosticsRequestId;
    if (requestId == null || _bulkDiagnosticsRequestedClientNames.isEmpty) {
      return const SizedBox.shrink();
    }

    final waiting = _bulkDiagnosticsWaitingForUploads;
    final completedCount = _bulkDiagnosticsCompletedClientNames.length;
    final totalCount = _bulkDiagnosticsRequestedClientNames.length;
    final pendingNames = _bulkDiagnosticsPendingClientNames;
    final completedNames = _bulkDiagnosticsCompletedClientNames;
    final accentColor =
        waiting ? const Color(0xFF2563EB) : const Color(0xFF15803D);
    final backgroundColor =
        waiting ? const Color(0xFFEFF6FF) : const Color(0xFFECFDF3);
    final borderColor =
        waiting ? const Color(0xFFD7E4FF) : const Color(0xFFABEFC6);
    final label =
        waiting
            ? 'Waiting for $completedCount of $totalCount client logs'
            : 'All $totalCount client logs uploaded';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                waiting ? Icons.hourglass_top_rounded : Icons.task_alt_rounded,
                size: 18,
                color: accentColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Request ${requestId.length > 12 ? requestId.substring(0, 12) : requestId} • Started ${_formatTimestamp(_bulkDiagnosticsRequestedAt ?? '')}',
            style: const TextStyle(
              color: Color(0xFF667085),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (pendingNames.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Pending: ${pendingNames.join(', ')}',
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
          if (completedNames.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Uploaded: ${completedNames.join(', ')}',
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _requestAgentDiagnostics(AdminAgent agent) async {
    if (_requestingDiagnosticsClientNames.contains(agent.clientName)) {
      return;
    }
    setState(() {
      _requestingDiagnosticsClientNames.add(agent.clientName);
    });
    try {
      await _api.requestAgentDiagnostics(clientName: agent.clientName);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Diagnostics requested from ${agent.clientName}. The Windows agent will upload on its next heartbeat.',
          ),
        ),
      );
      await _refreshState(silent: true);
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
          _requestingDiagnosticsClientNames.remove(agent.clientName);
        });
      }
    }
  }

  Future<void> _requestAgentClientUpdate(AdminAgent agent) async {
    if (_requestingClientUpdateClientNames.contains(agent.clientName)) {
      return;
    }
    setState(() {
      _requestingClientUpdateClientNames.add(agent.clientName);
    });
    try {
      await _api.requestAgentClientUpdate(clientName: agent.clientName);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Client update requested from ${agent.clientName}. The Windows agent will install the latest live version on its next heartbeat.',
          ),
        ),
      );
      await _refreshState(silent: true);
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
          _requestingClientUpdateClientNames.remove(agent.clientName);
        });
      }
    }
  }

  Future<void> _requestAllAgentClientUpdates() async {
    if (_bulkClientUpdateBusy) {
      return;
    }
    setState(() {
      _bulkClientUpdateBusy = true;
    });
    try {
      final result = await _api.requestAllAgentClientUpdates();
      if (!mounted) {
        return;
      }
      final names = result.requestedClientNames;
      final detail =
          names.isEmpty
              ? 'No online clients were available.'
              : names.length <= 5
              ? ' Clients: ${names.join(', ')}.'
              : ' Clients: ${names.take(5).join(', ')} and ${names.length - 5} more.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Client update requested for ${result.requestedClientCount} online client(s).$detail',
          ),
        ),
      );
      await _refreshState(silent: true);
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
          _bulkClientUpdateBusy = false;
        });
      }
    }
  }

  Future<void> _requestAllAgentWindowMinimize() async {
    if (_bulkWindowMinimizeBusy) {
      return;
    }
    setState(() {
      _bulkWindowMinimizeBusy = true;
    });
    try {
      final result = await _api.requestAllAgentWindowActions(
        action: 'minimize',
      );
      if (!mounted) {
        return;
      }
      final names = result.requestedClientNames;
      final detail =
          names.isEmpty
              ? 'No online clients were available.'
              : names.length <= 5
              ? ' Clients: ${names.join(', ')}.'
              : ' Clients: ${names.take(5).join(', ')} and ${names.length - 5} more.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Minimize requested for ${result.requestedClientCount} online client(s).$detail',
          ),
        ),
      );
      await _refreshState(silent: true);
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
          _bulkWindowMinimizeBusy = false;
        });
      }
    }
  }

  Future<void> _openDiagnosticsDialog(AdminAgent agent) async {
    try {
      final diagnostics = await _api.fetchAgentDiagnostics(
        clientName: agent.clientName,
      );
      if (!mounted) {
        return;
      }
      final payload = diagnostics.payload?.trim() ?? '';
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('Diagnostics: ${agent.clientName}'),
            content: SizedBox(
              width: 760,
              height: 560,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status ${diagnostics.status} • Requested ${_formatTimestamp(diagnostics.requestedAt ?? '')} • Uploaded ${_formatTimestamp(diagnostics.uploadedAt ?? '')}',
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (diagnostics.summary.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SelectableText(diagnostics.summary),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFDDE3EA)),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          payload.isEmpty
                              ? 'No uploaded diagnostic payload is available yet.'
                              : payload,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    }
  }

  String _tablePolicyBusyKey(String clientName, String table) =>
      '$clientName::$table';

  bool _isTablePolicyBusy(String clientName, String table) =>
      _busyTablePolicyKeys.contains(_tablePolicyBusyKey(clientName, table));

  void _setTablePolicyBusy(String clientName, String table, bool busy) {
    final key = _tablePolicyBusyKey(clientName, table);
    if (!mounted) {
      return;
    }
    setState(() {
      if (busy) {
        _busyTablePolicyKeys.add(key);
      } else {
        _busyTablePolicyKeys.remove(key);
      }
    });
  }

  Future<void> _updateTableSyncPolicy({
    required AdminAgent agent,
    required AdminTableState tableState,
    required bool enabled,
  }) async {
    final tableKey = _tableKeyForAgent(agent, tableState);
    if (tableKey.trim().isEmpty) {
      return;
    }
    _setTablePolicyBusy(agent.clientName, tableState.table, true);
    try {
      await _api.updateTableSyncPolicy(
        clientName: agent.clientName,
        table: tableKey,
        enabled: enabled,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${enabled ? 'Enabled' : 'Disabled'} shared sync for ${_displayTableName(tableState.table)}.',
          ),
        ),
      );
      await _refreshState(silent: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
    } finally {
      _setTablePolicyBusy(agent.clientName, tableState.table, false);
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
    return '$day.$month.$year  $hour:$minute:$second  $zoneLabel';
  }

  String _formatCompactTimestamp(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return raw.isEmpty ? 'Never' : raw;
    }
    final local = parsed.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    const monthNames = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = monthNames[local.month - 1];
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    if (local.year == DateTime.now().year) {
      return '$day $month $hour:$minute';
    }
    return '$day $month ${local.year} $hour:$minute';
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

  Color _roleColor() => const Color(0xFF0F766E);

  IconData _roleIcon() => Icons.sync_rounded;

  String _roleLabel() => 'Participant';

  String _syncFlowDisplay() => 'SNAPSHOT';

  String _syncDirectionDisplay() => 'SYNC';

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
        return Icons.dns_rounded;
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
        return 'Server User';
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
        return 'Owns one sync namespace and its client accounts.';
      case 'admin':
        return 'Full control plane access.';
      case 'client':
      default:
        return 'Uploads local rows and receives rows from other clients.';
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

  Widget _buildUserRoleDropdownOption(String role, {bool selected = false}) {
    return _buildIconDropdownOption(
      icon: _userRoleIcon(role),
      label: _userRoleLabel(role),
      description: _userRoleDescription(role),
      color: _userRoleColor(role),
      selected: selected,
    );
  }

  Widget _buildRoleBadge({bool compact = false}) {
    final color = _roleColor();
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
          Icon(_roleIcon(), size: compact ? 14 : 16, color: color),
          const SizedBox(width: 5),
          Text(
            _roleLabel(),
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
              ...summary.clients.map((entry) {
                return [
                  entry.agent.clientName,
                  entry.agent.machineName,
                  _roleLabel(),
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
    return status == 'completed' ||
        status == 'running' ||
        status == 'applying' ||
        tableState.lastSync.trim().isNotEmpty;
  }

  bool _tableStateHasMerged(AdminTableState tableState) =>
      _tableStateHasSynced(tableState);

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
      initialValue: selectedValue,
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
      title: widget.authenticatedUser.isOwner ? 'Server Tables' : 'Tables',
      subtitle:
          widget.authenticatedUser.isOwner
              ? 'Choose a database, then open a table to inspect rows and client sync status.'
              : 'Select a database, then open a table to see every client uploading rows and receiving copies from the server.',
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
                              ? 'No tables are available yet.'
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
      onTap: () => unawaited(_openTableFromSummary(summary)),
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
            final stack = constraints.maxWidth < 720;
            final clientStatuses = _buildTableClientStatusStrip(summary);
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
                              if (clientStatuses != null) ...[
                                const SizedBox(height: 7),
                                clientStatuses,
                              ],
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
                                    if (clientStatuses != null) ...[
                                      const SizedBox(height: 7),
                                      clientStatuses,
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: metrics,
                                ),
                              ),
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

  Widget? _buildTableClientStatusStrip(
    _TableAggregateSummary summary, {
    int maxVisible = 4,
  }) {
    if (summary.clients.isEmpty) {
      return null;
    }
    final clients = List<_TableClientEntry>.from(summary.clients)
      ..sort(_compareClientEntries);
    final visibleClients = clients.take(maxVisible).toList(growable: false);
    final hiddenCount = clients.length - visibleClients.length;
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final entry in visibleClients) _buildClientSyncStatusChip(entry),
        if (hiddenCount > 0) _buildMutedCountChip('+$hiddenCount clients'),
      ],
    );
  }

  Widget _buildClientSyncStatusChip(_TableClientEntry entry) {
    final color = _statusColor(entry.tableState.status);
    final updated = _formatTimestamp(_tableTimestampToken(entry.tableState));
    final message =
        '${entry.agent.clientName}: ${entry.tableState.status}'
        '${updated.isEmpty || updated == 'Never' ? '' : ' - $updated'}';
    return Tooltip(
      message: message,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 190, minHeight: 24),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                '${entry.agent.clientName} ${entry.tableState.status}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMutedCountChip(String label) {
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF667085),
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
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
          onPressed: () => unawaited(_openTableFromSummary(summary)),
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
              'This number counts clients that already have sync activity for this table.',
          emptyMessage: 'No client has synced this table yet.',
          clients: clients,
        );
      case _TableMetricKind.merged:
        final clients =
            summary.clients
                .where((entry) => _tableStateHasMerged(entry.tableState))
                .map((entry) {
                  return _TableMetricClientInfo(
                    name: entry.agent.clientName,
                    subtitle: 'Sync participant',
                    detail:
                        '${_syncFlowDisplay()} - ${entry.tableState.status}',
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
              'This number counts clients whose table data is configured for sync, or clients that already synced this table.',
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
                      'Last ${_syncDirectionDisplay()} - ${latest.status.toUpperCase()} - ${_formatTimestamp(latest.completedAt ?? latest.updatedAt)}',
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final fillWidth = constraints.maxWidth < 220;
        Widget tab({
          required String label,
          required bool selected,
          required VoidCallback onTap,
        }) {
          final button = _buildDetailTabButton(
            label: label,
            selected: selected,
            onTap: onTap,
          );
          return fillWidth ? Expanded(child: button) : button;
        }

        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: fillWidth ? double.infinity : null,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: Row(
              mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
              children: [
                tab(
                  label: 'Client',
                  selected: selectedIndex == 0,
                  onTap: () => _selectDetailTab(0),
                ),
                tab(
                  label: 'All History',
                  selected: selectedIndex == 1,
                  onTap: () => _selectDetailTab(1),
                ),
              ],
            ),
          ),
        );
      },
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
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
    required int recentHistoryCount,
    required int totalHistoryCount,
    required VoidCallback? onSync,
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
          MapEntry('Role', _roleLabel()),
          MapEntry(
            'Flow',
            tableState.enabled ? 'Merge participant' : 'Disabled',
          ),
          const MapEntry('Mode', 'SNAPSHOT'),
          const MapEntry('Direction', 'SYNC'),
          MapEntry('Database', agent.database),
          MapEntry(
            'Last Sync',
            _formatTimestamp(_tableTimestampToken(tableState)),
          ),
          MapEntry('Rows', '${tableState.rowCount}'),
          MapEntry('History', '$recentHistoryCount / $totalHistoryCount'),
        ];
        final actions = <Widget>[
          _buildDetailActionButton(
            label: 'Sync',
            icon: Icons.sync_rounded,
            onPressed: onSync,
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
            final compact = constraints.maxWidth < 560;
            final showSync = constraints.maxWidth >= 760;
            final showRoleLabel = constraints.maxWidth >= 520;
            final roleColumnWidth = showRoleLabel ? 112.0 : 28.0;
            final statusColumnWidth = 96.0;
            final syncColumnWidth = showSync ? 140.0 : 0.0;
            final detailsButton = Tooltip(
              message: 'Open client details',
              child: IconButton(
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed:
                    () =>
                        _openClientDetailDialog(summary: summary, entry: entry),
                icon: const Icon(Icons.info_outline_rounded, size: 18),
              ),
            );

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                      detailsButton,
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _buildRoleBadge(compact: true),
                      StatusBadge(
                        label: entry.tableState.status,
                        color: _statusColor(entry.tableState.status),
                      ),
                    ],
                  ),
                ],
              );
            }

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
                    child: _buildRoleBadge(compact: !showRoleLabel),
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
                detailsButton,
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final metricWidth = math.max(
          96.0,
          math.min(220.0, constraints.maxWidth),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: metricWidth),
                  child: MetricPill(label: 'Client', value: historyLabel),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: metricWidth),
                  child: MetricPill(label: 'Events', value: '${jobs.length}'),
                ),
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
                        itemBuilder:
                            (context, index) => _buildJobCard(jobs[index]),
                      ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDashboardContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.authenticatedUser.isAdmin) {
          return _buildAdminUsersPage();
        }
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
    if (widget.authenticatedUser.isAdmin) {
      return _buildAdminUsersPage();
    }
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

  Widget _buildAdminUsersPage() {
    final users = List<AuthenticatedUser>.from(_visibleUsers)
      ..sort((left, right) => left.name.compareTo(right.name));
    final admins = users.where((user) => user.isAdmin).toList(growable: false);
    final serverUsers = users
        .where((user) => user.isOwner)
        .toList(growable: false);
    final clientsByOwner = <String, List<AuthenticatedUser>>{};
    final unassignedClients = <AuthenticatedUser>[];
    for (final user in users.where((user) => user.isClient)) {
      final ownerId = user.ownerUserId?.trim();
      if (ownerId == null || ownerId.isEmpty) {
        unassignedClients.add(user);
        continue;
      }
      clientsByOwner
          .putIfAbsent(ownerId, () => <AuthenticatedUser>[])
          .add(user);
    }
    for (final clients in clientsByOwner.values) {
      clients.sort((left, right) => left.name.compareTo(right.name));
    }

    return ListView(
      children: [
        SurfaceCard(
          title: 'Users',
          subtitle:
              'Admins manage server users and assign clients under the correct server user.',
          headerTrailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed:
                    _loadingUsers
                        ? null
                        : () => unawaited(_refreshVisibleUsers()),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Refresh'),
              ),
              FilledButton.icon(
                onPressed: () => unawaited(_openUserManagementDialog()),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                label: const Text('Create User'),
              ),
            ],
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MetricPill(label: 'Admins', value: '${admins.length}'),
              MetricPill(label: 'Server Users', value: '${serverUsers.length}'),
              MetricPill(
                label: 'Clients',
                value: '${users.where((user) => user.isClient).length}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_userListError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: EmptyStateCard(message: _userListError!),
          ),
        SurfaceCard(
          title: 'Server Users',
          subtitle:
              'Each server user owns the client accounts shown beneath it.',
          child:
              _loadingUsers && users.isEmpty
                  ? const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  )
                  : serverUsers.isEmpty && unassignedClients.isEmpty
                  ? const EmptyStateCard(
                    message:
                        'No server users are available yet. Create a server user, then add clients under that account.',
                  )
                  : Column(
                    children: [
                      for (
                        var index = 0;
                        index < serverUsers.length;
                        index++
                      ) ...[
                        _buildServerUserAccountGroup(
                          serverUsers[index],
                          clientsByOwner[serverUsers[index].id] ??
                              const <AuthenticatedUser>[],
                        ),
                        if (index != serverUsers.length - 1)
                          const SizedBox(height: 8),
                      ],
                      if (unassignedClients.isNotEmpty) ...[
                        if (serverUsers.isNotEmpty) const SizedBox(height: 8),
                        _buildServerUserAccountGroup(null, unassignedClients),
                      ],
                    ],
                  ),
        ),
        if (admins.isNotEmpty) ...[
          const SizedBox(height: 10),
          SurfaceCard(
            title: 'Admins',
            subtitle: 'Full control plane accounts.',
            child: Column(
              children: [
                for (var index = 0; index < admins.length; index++) ...[
                  _buildAccountTile(admins[index], compact: true),
                  if (index != admins.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildServerUserAccountGroup(
    AuthenticatedUser? serverUser,
    List<AuthenticatedUser> clients,
  ) {
    final title = serverUser == null ? 'Unassigned Clients' : serverUser.name;
    final subtitle =
        serverUser == null
            ? 'Clients without a server user assignment.'
            : _accountSubtitle(serverUser);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildAccountTitleBlock(
                  title: title,
                  subtitle: subtitle,
                  icon: Icons.dns_rounded,
                  color: const Color(0xFF2563EB),
                ),
              ),
              StatusBadge(
                label:
                    serverUser == null
                        ? '${clients.length} clients'
                        : 'Server User',
                color: const Color(0xFF2563EB),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (clients.isEmpty)
            const EmptyStateCard(
              message: 'No clients are assigned to this server user yet.',
            )
          else
            Column(
              children: [
                for (var index = 0; index < clients.length; index++) ...[
                  _buildAccountTile(clients[index], compact: true),
                  if (index != clients.length - 1) const SizedBox(height: 6),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildAccountTile(AuthenticatedUser user, {bool compact = false}) {
    final deleting = _deletingClientUserIds.contains(user.id);
    final trailing = Wrap(
      spacing: 8,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusBadge(
          label: _userRoleLabel(user.role),
          color: _userRoleColor(user.role),
        ),
        if (_canDeleteClientUser(user))
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB42318),
              side: const BorderSide(color: Color(0xFFFDA29B)),
            ),
            onPressed:
                deleting
                    ? null
                    : () => unawaited(_confirmAndDeleteClientUser(user)),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: Text(deleting ? 'Deleting...' : 'Delete'),
          ),
      ],
    );
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final titleBlock = _buildAccountTitleBlock(
            title: user.name,
            subtitle: _accountSubtitle(user),
            icon: _userRoleIcon(user.role),
            color: _userRoleColor(user.role),
          );
          final stack = constraints.maxWidth < 520;
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [titleBlock, const SizedBox(height: 10), trailing],
            );
          }
          return Row(
            children: [
              Expanded(child: titleBlock),
              const SizedBox(width: 10),
              Flexible(
                child: Align(alignment: Alignment.centerRight, child: trailing),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAccountTitleBlock({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.18)),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.trim().isEmpty ? 'Unnamed account' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF101828),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
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
      ],
    );
  }

  String _accountSubtitle(AuthenticatedUser user) {
    final parts = <String>[
      if (user.email.trim().isNotEmpty) user.email.trim(),
      if (user.isClient)
        'Server user: ${user.ownerName ?? user.ownerUsername ?? user.ownerEmail ?? 'Unassigned'}',
      if (user.createdAt.trim().isNotEmpty)
        'Created ${_formatTimestamp(user.createdAt)}',
    ];
    return parts.isEmpty ? _userRoleDescription(user.role) : parts.join(' - ');
  }

  Widget _buildOverviewPage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ownerView = widget.authenticatedUser.isOwner;
        final mobileStack = constraints.maxWidth < 760;
        final useSideBySide = constraints.maxWidth >= 1180;
        if (mobileStack) {
          return ListView(
            children: [
              _buildOverviewIntroCard(),
              if (!ownerView) ...[
                const SizedBox(height: 10),
                _buildServerListCard(),
              ],
              const SizedBox(height: 10),
              SizedBox(
                height: ownerView ? 560 : 460,
                child: _buildTableListCard(),
              ),
              const SizedBox(height: 10),
              SizedBox(height: 600, child: _buildDetailCard()),
            ],
          );
        }
        return Column(
          children: [
            _buildOverviewIntroCard(),
            if (!ownerView) ...[
              const SizedBox(height: 10),
              _buildServerListCard(),
            ],
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
    if (widget.authenticatedUser.isOwner) {
      return _buildOwnerClientListCard();
    }

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

  Widget _buildOwnerClientListCard() {
    final agents = _clientNavigationAgents();
    return SurfaceCard(
      title: 'Clients',
      subtitle: 'Open a client to inspect its tables and sync history.',
      child:
          agents.isEmpty
              ? const EmptyStateCard(
                message: 'No clients are connected to this server user yet.',
              )
              : Column(
                children: [
                  for (var index = 0; index < agents.length; index++) ...[
                    _buildClientNavigationTile(
                      agents[index],
                      closeAfterSelection: false,
                    ),
                    if (index != agents.length - 1) const SizedBox(height: 6),
                  ],
                ],
              ),
    );
  }

  Widget _buildOverviewIntroCard() {
    final ownerView = widget.authenticatedUser.isOwner;
    final visibleTables = _tableSummariesForDatabase(_tableSummaries).length;
    final totalTables = _tableSummaries.length;
    return SurfaceCard(
      title: ownerView ? 'Server Tables' : 'Overview',
      subtitle:
          ownerView
              ? 'Select a database, open a table, and review every client sync state.'
              : 'Use the left menu to open a server page, then drill into its tables and clients.',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (ownerView) ...[
            MetricPill(
              label: 'Databases',
              value: '${_databaseNamesFromState(_state).length}',
            ),
            MetricPill(label: 'Tables', value: '$visibleTables / $totalTables'),
            MetricPill(
              label: 'Clients',
              value: '${_clientNavigationAgents().length}',
            ),
          ] else
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

  List<AdminAgent> _clientNavigationAgents() {
    final agentsByName = <String, AdminAgent>{};
    for (final agent in _state?.agents ?? const <AdminAgent>[]) {
      final clientName = agent.clientName.trim();
      if (clientName.isEmpty || agentsByName.containsKey(clientName)) {
        continue;
      }
      agentsByName[clientName] = agent;
    }
    final agents = agentsByName.values.toList(growable: false)
      ..sort((left, right) => left.clientName.compareTo(right.clientName));
    return agents;
  }

  _ClientSyncProgress _syncProgressForClient(AdminAgent agent) {
    final summary = computeClientSyncProgressSummary(agent: agent, jobs: _jobs);
    return _ClientSyncProgress(
      progress: summary.progress,
      label: summary.label,
      color: _clientSyncProgressColor(summary.label),
      detail: summary.detail,
    );
  }

  Color _clientSyncProgressColor(String label) {
    switch (label) {
      case 'Failed':
        return const Color(0xFFB42318);
      case 'Complete':
        return const Color(0xFF0F766E);
      case 'Syncing':
        return const Color(0xFF2563EB);
      case 'No sync jobs':
        return const Color(0xFF667085);
      case 'Partial':
      case 'Waiting':
      default:
        return const Color(0xFFB54708);
    }
  }

  _ClientSyncDelta? _latestSuccessfulRowDeltaForClient(AdminAgent agent) {
    final jobs = _jobs
      .where(
        (job) =>
            job.clientName == agent.clientName &&
            job.status.toLowerCase() == 'completed',
      )
      .toList(growable: false)..sort(_compareJobsByUpdatedAtDesc);
    if (jobs.isEmpty) {
      return null;
    }
    final latest = jobs.first;
    return _ClientSyncDelta(
      rowsAdded: latest.rowCount.clamp(0, 1000000000).toInt(),
      table: _displayTableName(latest.table),
      completedAt: latest.completedAt ?? latest.updatedAt,
    );
  }

  String _newerTimestamp(String left, String right) {
    if (left.trim().isEmpty) {
      return right;
    }
    if (right.trim().isEmpty) {
      return left;
    }
    final leftParsed = DateTime.tryParse(left);
    final rightParsed = DateTime.tryParse(right);
    if (leftParsed == null || rightParsed == null) {
      return left.compareTo(right) >= 0 ? left : right;
    }
    return leftParsed.isAfter(rightParsed) ? left : right;
  }

  String _latestSyncTimestampForClient(AdminAgent agent) {
    var latest = '';
    for (final job in _jobs) {
      if (job.clientName != agent.clientName ||
          job.status.toLowerCase() != 'completed') {
        continue;
      }
      latest = _newerTimestamp(latest, job.completedAt ?? job.updatedAt);
    }
    for (final tableState in agent.tables) {
      latest = _newerTimestamp(latest, tableState.lastSync);
    }
    return latest;
  }

  String _formatCompactCount(int value) {
    final raw = value.toString();
    final buffer = StringBuffer();
    for (var index = 0; index < raw.length; index++) {
      final remaining = raw.length - index;
      buffer.write(raw[index]);
      if (remaining > 1 && remaining % 3 == 1) {
        buffer.write(',');
      }
    }
    return buffer.toString();
  }

  String _simpleClientVersion(AdminAgent agent) {
    final version = _clientVersionSource(agent);
    if (version.isEmpty) {
      return '-';
    }
    final buildMatch = RegExp(r'\+(\d+)$').firstMatch(version);
    if (buildMatch != null) {
      return buildMatch.group(1)!;
    }
    final numberMatches = RegExp(r'\d+').allMatches(version).toList();
    if (numberMatches.isEmpty) {
      return version.length <= 8 ? version : version.substring(0, 8);
    }
    return numberMatches.last.group(0)!;
  }

  String _clientVersionSource(AdminAgent agent) {
    final heartbeatVersion = agent.clientVersion.trim();
    if (heartbeatVersion.isNotEmpty) {
      return heartbeatVersion;
    }
    final payload = agent.diagnostics.payload?.trim();
    if (payload == null || payload.isEmpty) {
      return '';
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['app'] is Map) {
        final app = Map<String, dynamic>.from(decoded['app'] as Map);
        return (app['version'] as String? ?? '').trim();
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  Widget _buildClientSyncProgressBar(AdminAgent agent) {
    final progress = _syncProgressForClient(agent);
    final delta = _latestSuccessfulRowDeltaForClient(agent);
    final lastSync = _latestSyncTimestampForClient(agent);
    final lastSyncLabel = _formatCompactTimestamp(lastSync);
    return Tooltip(
      message: '${progress.detail}\nLast sync: ${_formatTimestamp(lastSync)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.progress / 100,
                    minHeight: 7,
                    backgroundColor: const Color(0xFFE6EAF0),
                    valueColor: AlwaysStoppedAnimation<Color>(progress.color),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${progress.progress}%',
                style: TextStyle(
                  color: progress.color,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Last sync $lastSyncLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF475467),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                progress.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: progress.color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (delta != null)
                Tooltip(
                  message:
                      'Last successful sync: ${delta.table} at ${_formatTimestamp(delta.completedAt)}',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE7F8EF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFB7E4C7)),
                    ),
                    child: Text(
                      '+${_formatCompactCount(delta.rowsAdded)} rows',
                      style: const TextStyle(
                        color: Color(0xFF087443),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationPane({bool closeAfterSelection = false}) {
    if (widget.authenticatedUser.isOwner) {
      return _buildClientNavigationPane(
        closeAfterSelection: closeAfterSelection,
      );
    }

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

  Widget _buildClientNavigationPane({required bool closeAfterSelection}) {
    final agents = _clientNavigationAgents();
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
            'Clients',
            style: TextStyle(
              color: Color(0xFF101828),
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Open all tables or inspect one client.',
            style: TextStyle(
              color: Color(0xFF667085),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          _buildNavigationTile(
            icon: Icons.table_chart_outlined,
            label: 'All Tables',
            subtitle:
                '${_databaseNamesFromState(_state).length} databases - ${_tableSummaries.length} tables',
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
            child:
                agents.isEmpty
                    ? const EmptyStateCard(
                      message:
                          'No clients are connected to this server user yet.',
                    )
                    : ListView.separated(
                      itemCount: agents.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder:
                          (context, index) => _buildClientNavigationTile(
                            agents[index],
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

  Widget _buildClientNavigationTile(
    AdminAgent agent, {
    required bool closeAfterSelection,
  }) {
    final selected = _selectedPageClientName == agent.clientName;
    final statusColor =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final database =
        agent.database.trim().isEmpty ? 'No database' : agent.database.trim();
    final version = _simpleClientVersion(agent);
    final versionLabel = version == '-' ? 'version unknown' : 'v$version';
    final lastSync = _formatCompactTimestamp(
      _latestSyncTimestampForClient(agent),
    );
    final subtitle =
        '$database - ${agent.tables.length} tables - $versionLabel - Sync $lastSync';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap:
            () => _handleNavigationSelection(
              () => _openClientPage(agent.clientName),
              closeAfterSelection: closeAfterSelection,
            ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE6F4F1) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  selected ? const Color(0xFF85C7BC) : const Color(0xFFDDE3EA),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFFDDE3EA)),
                ),
                child: Icon(
                  Icons.computer_rounded,
                  size: 16,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            agent.clientName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF101828),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        StatusBadge(
                          label: agent.isOnline ? 'Online' : 'Offline',
                          color: statusColor,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _buildClientSyncProgressBar(agent),
                  ],
                ),
              ),
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
    return ListView(
      children: [
        _buildServerInventoryTile(item),
        const SizedBox(height: 10),
        SizedBox(height: 520, child: _buildTableListCard()),
        const SizedBox(height: 10),
        SizedBox(height: 640, child: _buildDetailCard()),
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
                          const SizedBox(height: 6),
                      ],
                    ],
                  ),
        ),
      ],
    );
  }

  Widget _buildServerClientTile(_ServerInventoryItem item, AdminAgent agent) {
    final statusColor =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final database =
        agent.database.trim().isEmpty ? 'No database' : agent.database.trim();
    final lastSync = _formatCompactTimestamp(
      _latestSyncTimestampForClient(agent),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: Icon(Icons.computer_rounded, size: 16, color: statusColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        agent.clientName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF101828),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    StatusBadge(
                      label: agent.isOnline ? 'Online' : 'Offline',
                      color: statusColor,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$database - ${agent.tables.length} tables - ${item.serverName} - Sync $lastSync',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                _buildClientSyncProgressBar(agent),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _buildRoleBadge(),
                    MetricPill(
                      label: 'Version',
                      value: _simpleClientVersion(agent),
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
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => _openClientPage(agent.clientName),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Open'),
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
    final diagnostics = agent.diagnostics;
    final clientUpdate = agent.clientUpdate;
    final requestingDiagnostics = _requestingDiagnosticsClientNames.contains(
      agent.clientName,
    );
    final requestingClientUpdate = _requestingClientUpdateClientNames.contains(
      agent.clientName,
    );
    return SurfaceCard(
      title: agent.clientName,
      subtitle: 'Client page for ${serverItem?.title ?? 'server'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MetricPill(label: 'Server', value: agent.server),
              MetricPill(label: 'Machine', value: agent.machineName),
              MetricPill(label: 'Database', value: agent.database),
              MetricPill(label: 'Tables', value: '${agent.tables.length}'),
              MetricPill(label: 'Version', value: _simpleClientVersion(agent)),
              MetricPill(label: 'Role', value: _roleLabel()),
              MetricPill(label: 'Online', value: agent.isOnline ? 'Yes' : 'No'),
              MetricPill(label: 'Diagnostics', value: diagnostics.status),
              MetricPill(label: 'Update', value: clientUpdate.status),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed:
                    requestingDiagnostics
                        ? null
                        : () => unawaited(_requestAgentDiagnostics(agent)),
                icon:
                    requestingDiagnostics
                        ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(
                          Icons.health_and_safety_outlined,
                          size: 16,
                        ),
                label: Text(
                  diagnostics.pending
                      ? 'Diagnostics Requested'
                      : 'Request Diagnostics',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed:
                    requestingClientUpdate
                        ? null
                        : () => unawaited(_requestAgentClientUpdate(agent)),
                icon:
                    requestingClientUpdate
                        ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.system_update_alt_rounded, size: 16),
                label: Text(
                  clientUpdate.pending ? 'Update Requested' : 'Update Client',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed:
                    diagnostics.hasReport
                        ? () => unawaited(_openDiagnosticsDialog(agent))
                        : null,
                icon: const Icon(Icons.description_outlined, size: 16),
                label: const Text('View Diagnostics'),
              ),
            ],
          ),
          if (clientUpdate.pending ||
              clientUpdate.message.trim().isNotEmpty ||
              (clientUpdate.acknowledgedAt?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDDE3EA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clientUpdate.pending
                        ? 'Client update request pending'
                        : 'Latest client update status',
                    style: const TextStyle(
                      color: Color(0xFF101828),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Status ${clientUpdate.status} • Requested ${_formatTimestamp(clientUpdate.requestedAt ?? '')} • Acknowledged ${_formatTimestamp(clientUpdate.acknowledgedAt ?? '')}',
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (clientUpdate.message.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(clientUpdate.message),
                  ],
                ],
              ),
            ),
          ],
          if (diagnostics.pending ||
              diagnostics.summary.trim().isNotEmpty ||
              (diagnostics.uploadedAt?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDDE3EA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    diagnostics.pending
                        ? 'Diagnostics request pending'
                        : 'Latest diagnostics',
                    style: const TextStyle(
                      color: Color(0xFF101828),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    diagnostics.summary.trim().isEmpty
                        ? 'Requested ${_formatTimestamp(diagnostics.requestedAt ?? '')}'
                        : diagnostics.summary,
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (diagnostics.uploadedAt?.trim().isNotEmpty ?? false) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Uploaded ${_formatTimestamp(diagnostics.uploadedAt ?? '')}',
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
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
    final policyBusy = _isTablePolicyBusy(agent.clientName, tableState.table);
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
                  textDirection: directionForDisplayText(
                    _displayTableName(tableState.table),
                  ),
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
          Tooltip(
            message:
                tableState.enabled
                    ? 'Disable sync for this table on all clients'
                    : 'Enable sync for this table on all clients',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: tableState.enabled,
                  onChanged:
                      policyBusy
                          ? null
                          : (value) => unawaited(
                            _updateTableSyncPolicy(
                              agent: agent,
                              tableState: tableState,
                              enabled: value,
                            ),
                          ),
                ),
                if (policyBusy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
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
                  '${_syncDirectionDisplay()} - ${_formatTimestamp(job.updatedAt)}',
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

  String _compactServerMeta(_ServerInventoryItem item) {
    final values = <String>[];

    void addValue(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || trimmed == 'Not reported') {
        return;
      }
      if (!values.contains(trimmed)) {
        values.add(trimmed);
      }
    }

    addValue(item.roleLabel);
    addValue(item.platformLabel);
    addValue(item.machineName);
    if (item.serverName != item.title) {
      addValue(item.serverName);
    }
    addValue(item.isLocal ? 'Local' : 'Live');
    return values.isEmpty ? 'Server' : values.join(' - ');
  }

  Widget _buildServerInventoryTile(_ServerInventoryItem item) {
    final statusColor =
        item.available ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final compactMeta = _compactServerMeta(item);
    final databases =
        item.databases.isEmpty ? 'None reported' : item.databases.join(', ');
    final clients =
        item.clientNames.isEmpty
            ? 'None reported'
            : item.clientNames.join(', ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: item.isLocal ? const Color(0xFFF8FFFC) : const Color(0xFFFCFCFD),
        borderRadius: BorderRadius.circular(8),
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
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFDDE3EA)),
                ),
                child: const Icon(
                  Icons.dns_rounded,
                  size: 17,
                  color: Color(0xFF0F766E),
                ),
              ),
              const SizedBox(width: 8),
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
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      compactMeta,
                      maxLines: 1,
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
              const SizedBox(width: 8),
              StatusBadge(label: item.statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              MetricPill(label: 'Clients', value: '${item.connectedClients}'),
              MetricPill(label: 'DBs', value: '${item.databases.length}'),
              if (item.onlineClients > 0)
                MetricPill(label: 'Online', value: '${item.onlineClients}'),
              if (item.serverConnectedClients > 0)
                MetricPill(
                  label: 'Link',
                  value: '${item.serverConnectedClients}',
                ),
              if (item.sqlConnectedClients > 0)
                MetricPill(label: 'SQL', value: '${item.sqlConnectedClients}'),
            ],
          ),
          const SizedBox(height: 8),
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
    final eventTime = _formatTimestamp(job.completedAt ?? job.updatedAt);
    final message =
        job.message.isEmpty ? 'No job message recorded.' : job.message;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onOpenSnapshot,
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
                final stack = constraints.maxWidth < 840;
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
                            _syncDirectionDisplay(),
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
                        _syncDirectionDisplay(),
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
                      width: 128,
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
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: trailing,
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
      InfoLine(label: 'Sources', value: '${summary?.clientCount ?? 0}'),
      InfoLine(label: 'Participants', value: '${summary?.clientCount ?? 0}'),
      InfoLine(label: 'Client', value: _selectedClientName ?? 'All'),
      InfoLine(label: 'Agents', value: '$totalClients'),
      InfoLine(label: 'Jobs', value: '$totalJobs'),
      InfoLine(label: 'Last Sync', value: lastSync),
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
          compactLayout && !widget.authenticatedUser.isAdmin
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
          if (widget.authenticatedUser.isAdmin)
            Padding(
              padding: EdgeInsets.only(right: compactAppBar ? 6 : 8),
              child:
                  compactAppBar
                      ? IconButton(
                        tooltip: 'Reset saved sync data on the server',
                        onPressed:
                            _serverResetBusy
                                ? null
                                : () => unawaited(
                                  _confirmAndResetServerSavedData(),
                                ),
                        icon:
                            _serverResetBusy
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.delete_sweep_rounded),
                      )
                      : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB42318),
                          side: const BorderSide(color: Color(0xFFF4C7C3)),
                        ),
                        onPressed:
                            _serverResetBusy
                                ? null
                                : () => unawaited(
                                  _confirmAndResetServerSavedData(),
                                ),
                        icon:
                            _serverResetBusy
                                ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(
                                  Icons.delete_sweep_rounded,
                                  size: 16,
                                ),
                        label: Text(
                          _serverResetBusy
                              ? 'Cleaning Server Data…'
                              : 'Reset Server Data',
                        ),
                      ),
            ),
          if (widget.authenticatedUser.isAdmin &&
              !_serverResetBusy &&
              _lastServerResetResult?.cleaned == true &&
              !compactAppBar)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: 'Server data cleaned; automatic sync is paused',
                child: Chip(
                  avatar: const Icon(
                    Icons.check_circle_outline_rounded,
                    size: 16,
                    color: Color(0xFF067647),
                  ),
                  label: const Text('Cleaned'),
                  labelStyle: const TextStyle(
                    color: Color(0xFF067647),
                    fontWeight: FontWeight.w700,
                  ),
                  backgroundColor: const Color(0xFFECFDF3),
                  side: const BorderSide(color: Color(0xFFABEFC6)),
                ),
              ),
            ),
          if (_showBulkActionsInLegacyDashboard &&
              widget.authenticatedUser.canManageUsers)
            Padding(
              padding: EdgeInsets.only(right: compactAppBar ? 6 : 8),
              child:
                  compactAppBar
                      ? IconButton(
                        tooltip: 'Minimize all online Windows clients',
                        onPressed:
                            _bulkWindowMinimizeBusy
                                ? null
                                : () =>
                                    unawaited(_requestAllAgentWindowMinimize()),
                        icon:
                            _bulkWindowMinimizeBusy
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.minimize_rounded),
                      )
                      : FilledButton.tonalIcon(
                        onPressed:
                            _bulkWindowMinimizeBusy
                                ? null
                                : () =>
                                    unawaited(_requestAllAgentWindowMinimize()),
                        icon:
                            _bulkWindowMinimizeBusy
                                ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.minimize_rounded, size: 16),
                        label: const Text('Minimize All Clients'),
                      ),
            ),
          if (_showBulkActionsInLegacyDashboard &&
              widget.authenticatedUser.canManageUsers)
            Padding(
              padding: EdgeInsets.only(right: compactAppBar ? 6 : 8),
              child:
                  compactAppBar
                      ? IconButton(
                        tooltip:
                            'Request latest client update on all online clients',
                        onPressed:
                            _bulkClientUpdateBusy
                                ? null
                                : () =>
                                    unawaited(_requestAllAgentClientUpdates()),
                        icon:
                            _bulkClientUpdateBusy
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.system_update_alt_rounded),
                      )
                      : FilledButton.tonalIcon(
                        onPressed:
                            _bulkClientUpdateBusy
                                ? null
                                : () =>
                                    unawaited(_requestAllAgentClientUpdates()),
                        icon:
                            _bulkClientUpdateBusy
                                ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(
                                  Icons.system_update_alt_rounded,
                                  size: 16,
                                ),
                        label: const Text('Update All Clients'),
                      ),
            ),
          if (_showBulkActionsInLegacyDashboard &&
              widget.authenticatedUser.canManageUsers)
            Padding(
              padding: EdgeInsets.only(right: compactAppBar ? 6 : 8),
              child:
                  compactAppBar
                      ? IconButton(
                        tooltip:
                            'Request logs from all visible Windows clients',
                        onPressed:
                            _bulkDiagnosticsBusy
                                ? null
                                : _openBulkDiagnosticsTab,
                        icon:
                            _bulkDiagnosticsBusy
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.receipt_long_rounded),
                      )
                      : FilledButton.tonalIcon(
                        onPressed:
                            _bulkDiagnosticsBusy
                                ? null
                                : _openBulkDiagnosticsTab,
                        icon:
                            _bulkDiagnosticsBusy
                                ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(
                                  Icons.receipt_long_rounded,
                                  size: 16,
                                ),
                        label: const Text('Request All Logs'),
                      ),
            ),
          if (_showBulkActionsInLegacyDashboard &&
              widget.authenticatedUser.canManageUsers)
            Padding(
              padding: EdgeInsets.only(right: compactAppBar ? 6 : 8),
              child:
                  compactAppBar
                      ? IconButton(
                        tooltip: 'Sync all enabled tables now',
                        onPressed:
                            _bulkSyncBusy
                                ? null
                                : () => unawaited(_triggerSyncAllEnabledNow()),
                        icon:
                            _bulkSyncBusy
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.sync_rounded),
                      )
                      : FilledButton.tonalIcon(
                        onPressed:
                            _bulkSyncBusy
                                ? null
                                : () => unawaited(_triggerSyncAllEnabledNow()),
                        icon:
                            _bulkSyncBusy
                                ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.sync_rounded, size: 16),
                        label: const Text('Sync All Now'),
                      ),
            ),
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
                              title: Text('User Management'),
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
              SelectionArea(
                child: Container(
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
              ),
            if (state?.syncGate.blocked == true)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0xFFFFF6ED),
                  border: Border.all(color: const Color(0xFFF7B27A)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.pause_circle_filled,
                      color: Color(0xFFB54708),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'All sync is stopped: ${state!.syncGate.issueCount} ${state.syncGate.issueCount == 1 ? 'table needs' : 'tables need'} a user decision. Open Clients and resolve every table marked Needs input before manual or automatic sync can start.',
                        style: const TextStyle(
                          color: Color(0xFF7A2E0E),
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_bulkDiagnosticsRequestId != null &&
                _bulkDiagnosticsRequestedClientNames.isNotEmpty)
              _buildBulkDiagnosticsWaitCard(),
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
    if (widget.authenticatedUser.isAdmin) {
      return 'SQL Sync - Users';
    }
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
    required this.latestRowCount,
    required this.sourceClientName,
    required this.clients,
  });

  final String table;
  final String lastSync;
  final int clientCount;
  final int latestRowCount;
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

class _ClientSyncProgress {
  const _ClientSyncProgress({
    required this.progress,
    required this.label,
    required this.color,
    required this.detail,
  });

  final int progress;
  final String label;
  final Color color;
  final String detail;
}

class _ClientSyncDelta {
  const _ClientSyncDelta({
    required this.rowsAdded,
    required this.table,
    required this.completedAt,
  });

  final int rowsAdded;
  final String table;
  final String completedAt;
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
