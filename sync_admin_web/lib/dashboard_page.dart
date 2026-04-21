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
  bool _snapshotLoading = false;
  String? _error;
  String? _snapshotError;
  String? _selectedClientName;
  String? _selectedTableName;
  String? _snapshotKey;
  String? _snapshotVersionToken;
  int _snapshotRequestToken = 0;
  int _historyLimit = _defaultHistoryLimit;
  final Set<String> _busyBackupKeys = <String>{};
  _TableDetailMode _detailMode = _TableDetailMode.clients;

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

      final nextTableName = _resolveSelectedTable(nextState);
      final nextClientName = _resolveSelectedClientForTable(
        nextState,
        nextTableName,
      );

      setState(() {
        _state = nextState;
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

      setState(() {
        _connected = false;
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

  String? _resolveSelectedTable(AdminLiveState state) {
    final summaries = _tableSummariesFromState(state);
    if (summaries.isEmpty) {
      return null;
    }
    if (_selectedTableName != null &&
        summaries.any((summary) => summary.table == _selectedTableName)) {
      return _selectedTableName;
    }
    return summaries.first.table;
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
        final entries = buckets.putIfAbsent(
          tableState.table,
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
      if (tableState != null) {
        entries.add(_TableClientEntry(agent: agent, tableState: tableState));
      }
    }
    entries.sort(_compareClientEntries);
    return entries;
  }

  AdminTableState? _tableStateForAgent(AdminAgent agent, String tableName) {
    for (final table in agent.tables) {
      if (table.table == tableName) {
        return table;
      }
    }
    return null;
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

  void _selectDetailMode(_TableDetailMode mode) {
    if (mode == _detailMode) {
      return;
    }
    _dataSearchController.clear();
    setState(() {
      _detailMode = mode;
    });
  }

  Future<void> _openSettingsDialog() async {
    final controller = TextEditingController(text: _historyLimit.toString());
    String? errorText;

    final nextLimit = await showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Settings'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Keep Last History Items',
                        hintText: '5',
                        helperText:
                            'Choose how many recent history items to keep visible in the history dialog.',
                        errorText: errorText,
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
                  onPressed: () {
                    final parsed = int.tryParse(controller.text.trim());
                    if (parsed == null ||
                        parsed < 1 ||
                        parsed > _maxHistoryLimit) {
                      setDialogState(() {
                        errorText =
                            'Enter a number between 1 and $_maxHistoryLimit.';
                      });
                      return;
                    }
                    Navigator.of(context).pop(parsed);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    if (!mounted || nextLimit == null || nextLimit == _historyLimit) {
      return;
    }

    writeBrowserStorage(_historyLimitStorageKey, nextLimit.toString());
    setState(() {
      _historyLimit = nextLimit;
    });
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
                            color: Color(0xFFC53030),
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
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: const Color(0xFFD9DDD8),
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

    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 860,
              maxHeight: MediaQuery.sizeOf(context).height * 0.8,
            ),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$clientName History',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child:
                        jobs.isEmpty
                            ? const EmptyStateCard(
                              message:
                                  'No sync jobs have been recorded yet for this client or table.',
                            )
                            : ListView.builder(
                              itemCount: jobs.length,
                              itemBuilder: (context, index) {
                                return _buildJobCard(jobs[index]);
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
                insetPadding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 1180,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(22),
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
        return const Color(0xFF2F855A);
      case 'failed':
        return const Color(0xFFC53030);
      case 'paused':
        return const Color(0xFF718096);
      default:
        return const Color(0xFFD69E2E);
    }
  }

  Color _roleColor(bool isMaster) =>
      isMaster ? const Color(0xFF2563EB) : const Color(0xFF2F855A);

  IconData _roleIcon(bool isMaster) =>
      isMaster ? Icons.upload_rounded : Icons.download_done_rounded;

  String _roleLabel(bool isMaster) => isMaster ? 'Master' : 'Slave';

  Widget _buildRoleBadge(bool isMaster, {bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 6),
      decoration: BoxDecoration(
        color: _roleColor(isMaster).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_roleIcon(isMaster), size: 16, color: _roleColor(isMaster)),
          if (!compact) ...[
            const SizedBox(width: 6),
            Text(
              _roleLabel(isMaster),
              style: TextStyle(
                color: _roleColor(isMaster),
                fontWeight: FontWeight.w700,
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

  List<_ScoredSnapshotRow> _filteredSnapshotRows(AdminSnapshotDetail snapshot) {
    return _filteredSnapshotRowsForQuery(
      snapshot,
      _dataSearchController.text.trim(),
    );
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

  Widget _buildActionIconButton({
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

  Widget _buildDetailModeTab({
    required _TableDetailMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = _detailMode == mode;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _selectDetailMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border:
                selected
                    ? Border.all(color: const Color(0xFFD9DDD8))
                    : Border.all(color: Colors.transparent),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color:
                    selected
                        ? const Color(0xFF18212B)
                        : const Color(0xFF58656B),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color:
                        selected
                            ? const Color(0xFF18212B)
                            : const Color(0xFF58656B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailModeTabs() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F3EE),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD9DDD8)),
      ),
      child: Row(
        children: [
          _buildDetailModeTab(
            mode: _TableDetailMode.clients,
            icon: Icons.people_alt_outlined,
            label: 'Client Table',
          ),
          const SizedBox(width: 4),
          _buildDetailModeTab(
            mode: _TableDetailMode.data,
            icon: Icons.table_rows_outlined,
            label: 'Data Table',
          ),
        ],
      ),
    );
  }

  Widget _buildTableListCard() {
    final summaries = _filteredTableSummaries(_tableSummaries);
    final totalTables = _tableSummaries.length;
    final totalClients = _state?.agents.length ?? 0;
    final masterClients =
        _state?.agents.where((agent) => agent.isMaster).length ?? 0;
    final slaveClients =
        _state?.agents.where((agent) => !agent.isMaster).length ?? 0;

    return SurfaceCard(
      title: 'Tables',
      subtitle: '',
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(
            controller: _syncSearchController,
            label: 'Search Tables',
            hint:
                'Search table names, connected clients, role counts, and sync dates.',
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              MetricPill(label: 'Tables', value: totalTables.toString()),
              MetricPill(label: 'Clients', value: totalClients.toString()),
              MetricPill(label: 'Masters', value: masterClients.toString()),
              MetricPill(label: 'Slaves', value: slaveClients.toString()),
              MetricPill(
                label: 'Selected',
                value: _selectedTableName ?? 'None',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child:
                summaries.isEmpty
                    ? EmptyStateCard(
                      message:
                          _syncSearchController.text.trim().isEmpty
                              ? 'No synced tables are available yet.'
                              : 'No tables matched your search.',
                    )
                    : ListView(
                      children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            showCheckboxColumn: false,
                            headingRowColor: const WidgetStatePropertyAll(
                              Color(0xFFE7ECE6),
                            ),
                            columns: const [
                              DataColumn(label: Text('Table')),
                              DataColumn(label: Text('Last Sync')),
                              DataColumn(label: Text('Clients')),
                              DataColumn(label: Text('Masters')),
                              DataColumn(label: Text('Slaves')),
                            ],
                            rows: summaries
                                .map(
                                  (summary) => DataRow(
                                    selected:
                                        summary.table == _selectedTableName,
                                    onSelectChanged:
                                        (_) => _selectTable(summary.table),
                                    cells: [
                                      DataCell(Text(summary.table)),
                                      DataCell(
                                        Text(
                                          _formatTimestamp(summary.lastSync),
                                        ),
                                      ),
                                      DataCell(
                                        Text(summary.clientCount.toString()),
                                      ),
                                      DataCell(
                                        Text(summary.masterCount.toString()),
                                      ),
                                      DataCell(
                                        Text(summary.slaveCount.toString()),
                                      ),
                                    ],
                                  ),
                                )
                                .toList(growable: false),
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
      title: summary.table,
      subtitle: '',
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDetailModeTabs(),
          const SizedBox(height: 14),
          _buildSearchField(
            controller: _dataSearchController,
            label:
                _detailMode == _TableDetailMode.clients
                    ? 'Search Clients'
                    : 'Search Rows',
            hint:
                _detailMode == _TableDetailMode.clients
                    ? 'Search client names, roles, statuses, and sync dates.'
                    : 'Search across all visible columns for the best matching row.',
          ),
          const SizedBox(height: 14),
          Expanded(
            child:
                _detailMode == _TableDetailMode.clients
                    ? _buildClientTableSide(summary)
                    : _buildDataTableSide(summary),
          ),
        ],
      ),
    );
  }

  Widget _buildClientTableSide(_TableAggregateSummary summary) {
    final clients = _filteredTableClients(summary.clients);
    final selectedClient = _selectedClientEntry;

    return ListView(
      children: [
        if (clients.isEmpty)
          EmptyStateCard(
            message:
                _dataSearchController.text.trim().isEmpty
                    ? 'No clients are exposing ${summary.table} yet.'
                    : 'No clients matched your search.',
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              showCheckboxColumn: false,
              headingRowColor: const WidgetStatePropertyAll(Color(0xFFE7ECE6)),
              columns: const [
                DataColumn(label: Text('Client')),
                DataColumn(label: Text('Type')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Last Sync')),
                DataColumn(label: Text('Rows')),
                DataColumn(label: Text('Backup')),
                DataColumn(label: Text('Download')),
                DataColumn(label: Text('Upload')),
                DataColumn(label: Text('Sync')),
              ],
              rows: clients
                  .map(
                    (entry) => DataRow(
                      selected: entry.agent.clientName == _selectedClientName,
                      onSelectChanged:
                          (_) => _selectClient(entry.agent.clientName),
                      cells: [
                        DataCell(Text(entry.agent.clientName)),
                        DataCell(_buildRoleBadge(entry.agent.isMaster)),
                        DataCell(
                          StatusBadge(
                            label: entry.tableState.status,
                            color: _statusColor(entry.tableState.status),
                          ),
                        ),
                        DataCell(
                          Text(_formatTimestamp(entry.tableState.lastSync)),
                        ),
                        DataCell(Text(entry.tableState.rowCount.toString())),
                        DataCell(
                          Text(_formatBytes(entry.tableState.snapshotBytes)),
                        ),
                        DataCell(
                          IconButton(
                            tooltip: 'Download backup file',
                            onPressed:
                                _isBackupBusy(
                                      entry.agent.clientName,
                                      summary.table,
                                    )
                                    ? null
                                    : () => _downloadSnapshotFile(
                                      clientName: entry.agent.clientName,
                                      table: summary.table,
                                    ),
                            icon: const Icon(Icons.download_rounded),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        DataCell(
                          IconButton(
                            tooltip: 'Upload backup file',
                            onPressed:
                                _isBackupBusy(
                                      entry.agent.clientName,
                                      summary.table,
                                    )
                                    ? null
                                    : () => _uploadSnapshotFile(
                                      clientName: entry.agent.clientName,
                                      table: summary.table,
                                    ),
                            icon: const Icon(Icons.upload_file_rounded),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        DataCell(
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed:
                                    entry.tableState.enabled
                                        ? () => _triggerJob(
                                          clientName: entry.agent.clientName,
                                          table: summary.table,
                                          direction: 'upload',
                                        )
                                        : null,
                                child: const Text('Push'),
                              ),
                              TextButton(
                                onPressed:
                                    entry.tableState.enabled
                                        ? () => _triggerJob(
                                          clientName: entry.agent.clientName,
                                          table: summary.table,
                                          direction: 'download',
                                        )
                                        : null,
                                child: const Text('Pull'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            MetricPill(
              label: 'Selected Client',
              value: selectedClient?.agent.clientName ?? 'None',
            ),
            MetricPill(
              label: 'Type',
              value:
                  selectedClient == null
                      ? 'None'
                      : _roleLabel(selectedClient.agent.isMaster),
            ),
            MetricPill(
              label: 'Last Sync',
              value: _formatTimestamp(
                selectedClient?.tableState.lastSync ?? '',
              ),
            ),
            MetricPill(label: 'History Limit', value: '$_historyLimit'),
          ],
        ),
        const SizedBox(height: 18),
        if (selectedClient == null)
          EmptyStateCard(
            message: 'Select a client row to view or open history.',
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: _buildActionIconButton(
              tooltip: 'Open history',
              onPressed:
                  () => _openHistoryDialog(
                    clientName: selectedClient.agent.clientName,
                    table: summary.table,
                  ),
              icon: Icons.history_rounded,
            ),
          ),
      ],
    );
  }

  Widget _buildDataTableSide(_TableAggregateSummary summary) {
    final snapshot = _snapshot;
    final source = _selectedSnapshotSource;
    final filteredRows =
        snapshot == null
            ? const <_ScoredSnapshotRow>[]
            : _filteredSnapshotRows(snapshot);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            MetricPill(
              label: 'Source Client',
              value: source?.clientName ?? 'Not available',
            ),
            MetricPill(
              label: 'Last Sync',
              value: _formatTimestamp(source?.createdAt ?? summary.lastSync),
            ),
            MetricPill(
              label: 'Rows',
              value:
                  snapshot == null
                      ? '${summary.latestRowCount}'
                      : '${filteredRows.length} / ${snapshot.rowCount}',
            ),
            MetricPill(
              label: 'Backup Size',
              value: _formatBytes(
                snapshot?.snapshotBytes ??
                    source?.snapshotBytes ??
                    summary.latestSnapshotBytes,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (source != null)
          Align(
            alignment: Alignment.centerLeft,
            child: _buildActionIconButton(
              tooltip: 'Download latest backup',
              onPressed:
                  _isBackupBusy(source.clientName, summary.table)
                      ? null
                      : () => _downloadSnapshotFile(
                        clientName: source.clientName,
                        table: summary.table,
                      ),
              icon: Icons.download_rounded,
            ),
          ),
        if (_snapshotLoading)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        Expanded(
          child: _buildSnapshotBody(
            snapshot: snapshot,
            filteredRows: filteredRows,
          ),
        ),
      ],
    );
  }

  Widget _buildSnapshotBody({
    required AdminSnapshotDetail? snapshot,
    required List<_ScoredSnapshotRow> filteredRows,
  }) {
    if (_snapshotLoading && snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (snapshot == null) {
      return EmptyStateCard(
        message:
            _snapshotError ??
            'No snapshot is available yet for the selected table.',
      );
    }

    if (filteredRows.isEmpty) {
      return EmptyStateCard(
        message:
            _dataSearchController.text.trim().isEmpty
                ? 'This snapshot has no rows.'
                : 'No rows matched your search. Try a broader term or clear the search box.',
      );
    }

    return _buildSnapshotGrid(snapshot, filteredRows);
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
            color: const Color(0xFFF7F9F6),
            border: Border.all(color: const Color(0xFFD9DDD8)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
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
        final useSideBySide = constraints.maxWidth >= 1180;
        if (useSideBySide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: _buildTableListCard()),
              const SizedBox(width: 16),
              Expanded(flex: 5, child: _buildDetailCard()),
            ],
          );
        }

        return Column(
          children: [
            Expanded(flex: 6, child: _buildTableListCard()),
            const SizedBox(height: 16),
            Expanded(flex: 7, child: _buildDetailCard()),
          ],
        );
      },
    );
  }

  Widget _buildJobCard(AdminJob job) {
    final canOpenSnapshot = (job.snapshotId?.trim().isNotEmpty ?? false);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2D8CB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusBadge(label: job.status, color: _statusColor(job.status)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        job.direction.toUpperCase(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      _formatTimestamp(job.updatedAt),
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  job.message.isEmpty
                      ? 'No job message recorded.'
                      : job.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.2, fontSize: 12.5),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      '${job.progress}%',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      '${job.rowCount} rows',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      _formatBytes(job.snapshotBytes),
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildActionIconButton(
            tooltip: 'Open history data',
            onPressed:
                canOpenSnapshot ? () => _openJobSnapshotDialog(job) : null,
            icon: Icons.table_rows_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedSummaryBar() {
    final summary = _selectedTableSummary;

    final footerItems = <Widget>[
      InfoLine(label: 'Table', value: summary?.table ?? 'None'),
      InfoLine(label: 'Clients', value: '${summary?.clientCount ?? 0}'),
      InfoLine(label: 'Masters', value: '${summary?.masterCount ?? 0}'),
      InfoLine(label: 'Slaves', value: '${summary?.slaveCount ?? 0}'),
      InfoLine(
        label: 'Panel',
        value:
            _detailMode == _TableDetailMode.clients
                ? 'Client Table'
                : 'Data Table',
      ),
    ];

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFC9D2C7))),
        color: Color(0xFFF6F7F3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
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
            _buildBackendStatusIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildBackendStatusIndicator() {
    final color =
        _connected ? const Color(0xFF2F855A) : const Color(0xFFC53030);
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
    final title =
        _selectedTableName == null
            ? 'SQL Sync'
            : 'SQL Sync - $_selectedTableName';
    final profileLabel =
        widget.authenticatedUser.name.trim().isEmpty
            ? widget.authenticatedUser.username
            : widget.authenticatedUser.name;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Refresh now',
            onPressed: () => unawaited(_refreshState()),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<_ProfileMenuAction>(
            tooltip: 'Profile',
            position: PopupMenuPosition.under,
            offset: const Offset(0, 10),
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6F1),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFDDE6DA)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: const Color(0xFFE8F0EC),
                    child: const Icon(
                      Icons.person_outline,
                      size: 16,
                      color: Color(0xFF17313A),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    profileLabel,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF17313A),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: Color(0xFF58656B),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: const Color(0xFFFFEEEE),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
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

enum _TableDetailMode { clients, data }

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
