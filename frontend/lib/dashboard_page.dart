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
  final TextEditingController _dataSearchController = TextEditingController();
  Timer? _refreshTimer;

  AdminLiveState? _state;
  AdminSnapshotDetail? _snapshot;
  bool _loading = true;
  bool _connected = false;
  // ignore: unused_field
  bool _snapshotLoading = false;
  String? _error;
  String? _snapshotError;
  String? _selectedClientName;
  String? _selectedTableName;
  String? _selectedDatabaseName;
  String? _snapshotKey;
  String? _snapshotVersionToken;
  int _snapshotRequestToken = 0;
  int _historyLimit = _defaultHistoryLimit;
  final Set<String> _busyBackupKeys = <String>{};
  @override
  void initState() {
    super.initState();
    _api.setAuthToken(widget.authToken);
    _historyLimit = _readStoredHistoryLimit();
    _syncSearchController.addListener(_handleSearchChange);
    _dataSearchController.addListener(_handleSearchChange);
    unawaited(_refreshState());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshState(silent: true)),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _syncSearchController.removeListener(_handleSearchChange);
    _dataSearchController.removeListener(_handleSearchChange);
    _syncSearchController.dispose();
    _dataSearchController.dispose();
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

      final nextDatabaseName = _resolveSelectedDatabase(nextState);
      final nextTableName = _resolveSelectedTable(
        nextState,
        databaseName: nextDatabaseName,
      );
      final nextClientName = _resolveSelectedClientForTable(
        nextState,
        nextTableName,
      );

      setState(() {
        _state = nextState;
        _selectedDatabaseName = nextDatabaseName;
        _selectedTableName = nextTableName;
        _selectedClientName = nextClientName;
        _connected = true;
        _loading = false;
        _error = null;
      });

      unawaited(_loadSelectedSnapshot());
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
    }
  }

  List<AdminJob> get _jobs => _state?.jobs ?? const <AdminJob>[];

  List<_TableAggregateSummary> get _tableSummaries =>
      _tableSummariesFromState(_state);

  _TableAggregateSummary? get _selectedTableSummary {
    final tableName = _selectedTableName;
    if (tableName == null) {
      return null;
    }
    for (final summary in _tableSummaries) {
      if (summary.table == tableName) {
        return summary;
      }
    }
    return null;
  }

  List<_TableClientEntry> get _selectedTableClients =>
      _clientsForTableFromState(_state, _selectedTableName);

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

  _TableSnapshotSource? get _selectedSnapshotSource =>
      _snapshotSourceForTable(_state, _selectedTableName);

  List<String> _databaseNamesFromState(AdminLiveState? state) {
    if (state == null) {
      return const <String>[];
    }

    final databaseNames = _tableSummariesFromState(state)
      .map((summary) => summary.database.trim())
      .where((database) => database.isNotEmpty)
      .toSet()
      .toList(growable: false)..sort();
    return databaseNames;
  }

  List<_TableAggregateSummary> _tableSummariesForDatabase(
    List<_TableAggregateSummary> summaries,
  ) {
    final databaseName = _selectedDatabaseName?.trim();
    if (databaseName == null || databaseName.isEmpty) {
      return summaries;
    }
    return summaries
        .where((summary) => summary.database == databaseName)
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
              databaseName == null ||
              databaseName.isEmpty ||
              summary.database == databaseName,
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
      _snapshot = null;
      _snapshotError = null;
      _snapshotKey = null;
      _snapshotVersionToken = null;
    });
    unawaited(_loadSelectedSnapshot(force: true));
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
    if (state == null) {
      return const <_TableAggregateSummary>[];
    }

    final buckets = <String, List<_TableClientEntry>>{};
    for (final agent in state.agents) {
      for (final tableState in agent.tables) {
        if (!_hasSyncedTableState(tableState)) {
          continue;
        }
        final tableKey = _tableKeyForAgent(agent, tableState);
        final entries = buckets.putIfAbsent(
          tableKey,
          () => <_TableClientEntry>[],
        );
        entries.add(_TableClientEntry(agent: agent, tableState: tableState));
      }
    }

    final summaries = buckets.entries
      .map((entry) {
        final clients = List<_TableClientEntry>.from(entry.value)
          ..sort(_compareClientEntries);
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
        return _TableAggregateSummary(
          table: entry.key,
          lastSync: _tableTimestampToken(latestClient.tableState),
          clientCount: clients.length,
          masterCount: clients.where((item) => item.agent.isMaster).length,
          slaveCount: clients.where((item) => !item.agent.isMaster).length,
          latestRowCount: latestClient.tableState.rowCount,
          latestSnapshotBytes: latestClient.tableState.snapshotBytes,
          sourceClientName: latestClient.agent.clientName,
          clients: clients,
        );
      })
      .toList(growable: false)..sort((left, right) {
      final byTimestamp = _compareTimestamps(right.lastSync, left.lastSync);
      if (byTimestamp != 0) {
        return byTimestamp;
      }
      return left.table.compareTo(right.table);
    });

    return summaries;
  }

  String _tableKeyForAgent(AdminAgent agent, AdminTableState tableState) {
    final table = tableState.table.trim();
    if (table.isEmpty || table.contains(_TableAggregateSummary.separator)) {
      return table;
    }
    final database = agent.database.trim();
    return database.isEmpty
        ? table
        : '$database${_TableAggregateSummary.separator}$table';
  }

  List<_TableClientEntry> _clientsForTableFromState(
    AdminLiveState? state,
    String? tableName,
  ) {
    if (state == null || tableName == null) {
      return const <_TableClientEntry>[];
    }

    final entries = <_TableClientEntry>[];
    for (final agent in state.agents) {
      final tableState = _tableStateForAgent(agent, tableName);
      if (tableState != null && _hasSyncedTableState(tableState)) {
        entries.add(_TableClientEntry(agent: agent, tableState: tableState));
      }
    }
    entries.sort(_compareClientEntries);
    return entries;
  }

  AdminTableState? _tableStateForAgent(AdminAgent agent, String tableName) {
    for (final table in agent.tables) {
      if (_tableKeyForAgent(agent, table) == tableName) {
        return table;
      }
    }
    return null;
  }

  bool _hasSyncedTableState(AdminTableState tableState) {
    return tableState.lastSync.trim().isNotEmpty ||
        (tableState.snapshotId?.trim().isNotEmpty ?? false) ||
        (tableState.snapshotCreatedAt?.trim().isNotEmpty ?? false) ||
        tableState.snapshotBytes > 0;
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
    if (state == null || tableName == null) {
      return null;
    }

    final snapshots = state.snapshots
      .where((snapshot) => snapshot.table == tableName)
      .toList(growable: false)..sort(
      (left, right) => _compareTimestamps(right.createdAt, left.createdAt),
    );

    if (snapshots.isNotEmpty) {
      final snapshot = snapshots.first;
      return _TableSnapshotSource(
        clientName: snapshot.clientName,
        table: snapshot.table,
        createdAt: snapshot.createdAt,
        rowCount: snapshot.rowCount,
        snapshotBytes: snapshot.snapshotBytes,
      );
    }

    final clients = _clientsForTableFromState(state, tableName);
    if (clients.isEmpty) {
      return null;
    }

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

    if (latestEntry == null) {
      return null;
    }

    return _TableSnapshotSource(
      clientName: latestEntry.agent.clientName,
      table: tableName,
      createdAt: _tableTimestampToken(latestEntry.tableState),
      rowCount: latestEntry.tableState.rowCount,
      snapshotBytes: latestEntry.tableState.snapshotBytes,
    );
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

  int _timestampSortValue(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      return parsed.toUtc().microsecondsSinceEpoch;
    }
    return raw.trim().isEmpty ? -1 : 0;
  }

  Future<void> _loadSelectedSnapshot({bool force = false}) async {
    final tableName = _selectedTableName;
    final source = _selectedSnapshotSource;

    if (tableName == null || source == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = null;
        _snapshotLoading = false;
        _snapshotError = null;
        _snapshotKey = null;
        _snapshotVersionToken = null;
      });
      return;
    }

    final nextKey = '${source.clientName}::$tableName';
    final nextVersion = source.createdAt.trim();

    if (!force &&
        nextKey == _snapshotKey &&
        nextVersion == _snapshotVersionToken &&
        (_snapshot != null || _snapshotError != null)) {
      return;
    }

    final requestToken = ++_snapshotRequestToken;
    if (mounted) {
      setState(() {
        _snapshotLoading = true;
        _snapshotError = null;
        _snapshotKey = nextKey;
        _snapshotVersionToken = nextVersion;
        _snapshot = null;
      });
    }

    try {
      final snapshot = await _api.fetchLatestSnapshot(
        clientName: source.clientName,
        table: tableName,
      );
      if (!mounted || requestToken != _snapshotRequestToken) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _snapshotLoading = false;
        _snapshotError =
            snapshot == null
                ? 'No snapshot is available yet for $tableName.'
                : null;
      });
    } catch (error) {
      if (!mounted || requestToken != _snapshotRequestToken) {
        return;
      }
      setState(() {
        _snapshotLoading = false;
        _snapshot = null;
        _snapshotError = error.toString();
      });
    }
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
      _snapshotError = null;
    });
    unawaited(_loadSelectedSnapshot(force: true));
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
                          ),
                          items: agents
                              .map(
                                (agent) => DropdownMenuItem<String>(
                                  value: agent.clientName,
                                  child: Text(agent.clientName),
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
                        SwitchListTile(
                          value: isMaster,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Master'),
                          subtitle: Text(
                            isMaster
                                ? 'Uploads snapshots to the website.'
                                : 'Downloads the latest master snapshots.',
                          ),
                          onChanged: (value) {
                            setDialogState(() {
                              isMaster = value;
                            });
                          },
                        ),
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
                  errorText = 'Select an owner for the client account.';
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
                            ? 'Admin can create owner or client accounts. Owners can create client accounts only.'
                            : 'Owner accounts can create client accounts for the Windows app.',
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
                            width: 180,
                            child: DropdownButtonFormField<String>(
                              value: selectedRole,
                              decoration: const InputDecoration(
                                labelText: 'Role',
                              ),
                              items: [
                                if (widget.authenticatedUser.isAdmin)
                                  const DropdownMenuItem(
                                    value: 'owner',
                                    child: Text('Owner'),
                                  ),
                                const DropdownMenuItem(
                                  value: 'client',
                                  child: Text('Client'),
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
                                  labelText: 'Owner',
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
                                    final ownerLabel =
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
                                                  ? 'Owner: $ownerLabel'
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
                            if (showingData) ...[
                              IconButton(
                                tooltip: 'Back to history',
                                onPressed: () {
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

    await showDialog<void>(
      context: context,
      builder: (context) {
        final busy = _isBackupBusy(entry.agent.clientName, summary.table);

        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 940,
              maxHeight: MediaQuery.sizeOf(context).height * 0.84,
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
                          entry.agent.clientName,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildRoleBadge(entry.agent.isMaster),
                      const SizedBox(width: 8),
                      StatusBadge(
                        label: entry.tableState.status,
                        color: _statusColor(entry.tableState.status),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildSelectedClientInfo(entry),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            busy
                                ? null
                                : () => _downloadSnapshotFile(
                                  clientName: entry.agent.clientName,
                                  table: summary.table,
                                ),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('Download'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            busy
                                ? null
                                : () => _uploadSnapshotFile(
                                  clientName: entry.agent.clientName,
                                  table: summary.table,
                                ),
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: const Text('Upload'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed:
                            entry.tableState.enabled
                                ? () => _triggerJob(
                                  clientName: entry.agent.clientName,
                                  table: summary.table,
                                  direction: 'upload',
                                )
                                : null,
                        icon: const Icon(Icons.north_rounded, size: 16),
                        label: const Text('Push'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed:
                            entry.tableState.enabled
                                ? () => _triggerJob(
                                  clientName: entry.agent.clientName,
                                  table: summary.table,
                                  direction: 'download',
                                )
                                : null,
                        icon: const Icon(Icons.south_rounded, size: 16),
                        label: const Text('Pull'),
                      ),
                      TextButton.icon(
                        onPressed:
                            () => _openHistoryDialog(
                              clientName: entry.agent.clientName,
                              table: summary.table,
                            ),
                        icon: const Icon(Icons.history_rounded, size: 16),
                        label: const Text('Full History'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _buildSectionLabel('Recent History'),
                      const SizedBox(width: 8),
                      Text(
                        '${recentJobs.length} of ${jobs.length}',
                        style: const TextStyle(
                          color: Color(0xFF62717C),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
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
                              separatorBuilder:
                                  (_, _) => const SizedBox(height: 6),
                              itemBuilder:
                                  (context, index) =>
                                      _buildJobCard(recentJobs[index]),
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
        await _loadSelectedSnapshot(force: true);
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

  Widget _buildRoleBadge(bool isMaster, {bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 4),
      decoration: BoxDecoration(
        color: _roleColor(isMaster).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_roleIcon(isMaster), size: 16, color: _roleColor(isMaster)),
          if (!compact) ...[
            const SizedBox(width: 5),
            Text(
              _roleLabel(isMaster),
              style: TextStyle(
                color: _roleColor(isMaster),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
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
      return summaries;
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
      .toList(growable: false)..sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) {
        return byScore;
      }
      return left.summary.table.compareTo(right.summary.table);
    });

    return matches.map((match) => match.summary).toList(growable: false);
  }

  List<_TableClientEntry> _filteredTableClients(
    List<_TableClientEntry> entries,
  ) {
    final query = _dataSearchController.text.trim();
    if (query.isEmpty) {
      return entries;
    }

    final matches = entries
      .map((entry) {
        final score = _bestMatchScore(
          query,
          [
            entry.agent.clientName,
            entry.agent.machineName,
            _roleLabel(entry.agent.isMaster),
            entry.tableState.status,
            entry.tableState.message,
            _formatTimestamp(entry.tableState.lastSync),
            '${entry.tableState.rowCount}',
            _formatBytes(entry.tableState.snapshotBytes),
          ].join(' '),
        );
        return _ScoredTableClient(entry: entry, score: score);
      })
      .where((match) => match.score > 0)
      .toList(growable: false)..sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) {
        return byScore;
      }
      return _compareClientEntries(left.entry, right.entry);
    });

    return matches.map((match) => match.entry).toList(growable: false);
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
    return _jobs
        .where((job) => job.clientName == clientName && job.table == table)
        .take(_historyLimit)
        .toList(growable: false);
  }

  List<AdminJob> _filteredHistoryJobs({
    required String table,
    String? clientName,
    bool limit = true,
  }) {
    final query = _dataSearchController.text.trim();
    final matches = _jobs
        .where((job) => job.table == table)
        .where((job) => clientName == null || job.clientName == clientName)
        .map((job) {
          final score =
              query.isEmpty
                  ? 1.0
                  : _bestMatchScore(
                    query,
                    [
                      job.clientName,
                      job.table,
                      job.status,
                      job.direction,
                      job.message,
                      job.updatedAt,
                      job.completedAt ?? '',
                    ].join(' '),
                  );
          return (job: job, score: score);
        })
        .where((item) => item.score > 0)
        .toList(growable: false);

    matches.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) {
        return byScore;
      }
      return _compareTimestamps(right.job.updatedAt, left.job.updatedAt);
    });

    final jobs = matches.map((item) => item.job);
    return (limit ? jobs.take(_historyLimit) : jobs).toList(growable: false);
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
              child: Text(database, overflow: TextOverflow.ellipsis),
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
              if (stack) {
                return Column(
                  children: [database, const SizedBox(height: 10), search],
                );
              }
              return Row(
                children: [
                  SizedBox(width: 260, child: database),
                  const SizedBox(width: 10),
                  Expanded(child: search),
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

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectTable(summary.table),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
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

            return stack
                ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.displayTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Last sync ${_formatTimestamp(summary.lastSync)}',
                      style: const TextStyle(
                        color: Color(0xFF62717C),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                )
                : Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary.displayTitle,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Last sync ${_formatTimestamp(summary.lastSync)}',
                            style: const TextStyle(
                              color: Color(0xFF667085),
                              fontSize: 12.5,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(
            controller: _dataSearchController,
            label: 'Search Clients / History',
            hint:
                'Search client names, roles, statuses, directions, messages, and sync time.',
          ),
          const SizedBox(height: 10),
          Expanded(child: _buildMergedDetailBody(summary)),
        ],
      ),
    );
  }

  Widget _buildMergedDetailBody(_TableAggregateSummary summary) {
    return DefaultTabController(
      key: ValueKey(summary.table),
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [Tab(text: 'Client'), Tab(text: 'All History')],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              children: [
                _buildClientDetailTab(summary),
                _buildAllHistoryTab(summary),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _buildSelectedClientInfo(_TableClientEntry? selectedClient) {
    if (selectedClient == null) {
      return const EmptyStateCard(
        message: 'Select a client to view its table info and history.',
      );
    }

    final agent = selectedClient.agent;
    final tableState = selectedClient.tableState;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          MetricPill(label: 'Client', value: agent.clientName),
          MetricPill(label: 'Role', value: _roleLabel(agent.isMaster)),
          MetricPill(
            label: 'Status',
            value: agent.isOnline ? 'Online' : 'Offline',
          ),
          MetricPill(
            label: 'SQL',
            value: agent.sqlConnected ? 'Connected' : 'Disconnected',
          ),
          MetricPill(label: 'Machine', value: agent.machineName),
          MetricPill(label: 'Server', value: agent.server),
          MetricPill(label: 'Database', value: agent.database),
          MetricPill(
            label: 'Last Sync',
            value: _formatTimestamp(_tableTimestampToken(tableState)),
          ),
          MetricPill(label: 'Rows', value: '${tableState.rowCount}'),
          MetricPill(
            label: 'Backup',
            value: _formatBytes(tableState.snapshotBytes),
          ),
        ],
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
                    message:
                        _dataSearchController.text.trim().isEmpty
                            ? 'No clients are exposing ${summary.table} yet.'
                            : 'No clients matched your search.',
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
      onTap: () => _selectClient(entry.agent.clientName),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE6F4F1) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF85C7BC) : const Color(0xFFDDE3EA),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showSync = constraints.maxWidth >= 640;

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
                const SizedBox(width: 8),
                _buildRoleBadge(entry.agent.isMaster, compact: true),
                const SizedBox(width: 6),
                StatusBadge(
                  label: entry.tableState.status,
                  color: _statusColor(entry.tableState.status),
                ),
                if (showSync) ...[
                  const SizedBox(width: 10),
                  Expanded(
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
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Open client details',
                  child: IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
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
          spacing: 8,
          runSpacing: 8,
          children: [
            MetricPill(label: 'Client', value: historyLabel),
            MetricPill(label: 'Events', value: '${jobs.length}'),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child:
              jobs.isEmpty
                  ? EmptyStateCard(
                    message:
                        _dataSearchController.text.trim().isEmpty
                            ? 'No history is available yet for this table.'
                            : 'No history entries matched your search.',
                  )
                  : ListView.separated(
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) => _buildJobCard(jobs[index]),
                  ),
        ),
      ],
    );
  }

  Widget _buildSnapshotGrid(
    AdminSnapshotDetail snapshot,
    List<_ScoredSnapshotRow> filteredRows,
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

  Widget _buildSnapshotRow({
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
        final mobileStack = constraints.maxWidth < 760;
        final useSideBySide = constraints.maxWidth >= 1180;
        if (mobileStack) {
          return ListView(
            children: [
              SizedBox(height: 460, child: _buildTableListCard()),
              const SizedBox(height: 10),
              SizedBox(height: 600, child: _buildDetailCard()),
            ],
          );
        }
        if (useSideBySide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: _buildTableListCard()),
              const SizedBox(width: 10),
              Expanded(flex: 5, child: _buildDetailCard()),
            ],
          );
        }

        return Column(
          children: [
            Expanded(flex: 6, child: _buildTableListCard()),
            const SizedBox(height: 10),
            Expanded(flex: 7, child: _buildDetailCard()),
          ],
        );
      },
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
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE2D8CB)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stack = constraints.maxWidth < 620;
                final trailing = Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      job.clientName,
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                    Text(
                      '${job.progress}%',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                    Text(
                      '${job.rowCount} rows',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 11.5,
                      ),
                    ),
                    Text(
                      _formatBytes(job.snapshotBytes),
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 11.5,
                      ),
                    ),
                    if (canOpenSnapshot)
                      const Icon(
                        Icons.table_rows_outlined,
                        size: 15,
                        color: Color(0xFF62717C),
                      ),
                  ],
                );

                if (stack) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
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
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            eventTime,
                            style: const TextStyle(
                              color: Color(0xFF5F6B76),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.15, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
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
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.15, fontSize: 12),
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
                          fontSize: 11.5,
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
    final profileCompact = screenWidth < 560;
    final pagePadding =
        screenWidth < 480
            ? const EdgeInsets.all(8)
            : (screenWidth < 760
                ? const EdgeInsets.all(10)
                : const EdgeInsets.all(12));
    final title =
        _selectedTableName == null
            ? 'SQL Sync'
            : 'SQL Sync - ${_selectedTableSummary?.displayTitle ?? _selectedTableName}';
    final profileLabel =
        widget.authenticatedUser.name.trim().isEmpty
            ? widget.authenticatedUser.username
            : widget.authenticatedUser.name;

    return Scaffold(
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
    return separatorIndex < 0
        ? table
        : table.substring(separatorIndex + separator.length);
  }

  String get displayTitle =>
      database.isEmpty ? displayTable : '$displayTable - $database';
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

class _ScoredTableSummary {
  const _ScoredTableSummary({required this.summary, required this.score});

  final _TableAggregateSummary summary;
  final double score;
}

class _ScoredTableClient {
  const _ScoredTableClient({required this.entry, required this.score});

  final _TableClientEntry entry;
  final double score;
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
