import 'dart:async';

// Legacy compact-layout helpers remain available for future detail navigation.
// ignore_for_file: unused_element

import 'package:flutter/material.dart';

import 'browser_bridge.dart';
import 'live_sync_api.dart';
import 'models.dart';

enum _ClientSortField { name, status, database, tables, lastSync, heartbeat }

enum _ClientDetailView { logs, tables }

enum _ClientScreen { list, detail, sync, table }

bool _messageContainsReportedRowCount(String message) => RegExp(
  r'\b\d[\d,]*\s+(?:(?:changed|missing|new)\s+)?rows?\b',
  caseSensitive: false,
).hasMatch(message);

class _SyncLogOperation {
  _SyncLogOperation({
    required this.key,
    required this.jobs,
    required this.clientName,
  });

  final String key;
  final List<AdminJob> jobs;
  final String clientName;
  int? changedRowsOverride;

  AdminJob? get upload => _jobFor('upload');
  AdminJob? get download => _jobFor('download');

  AdminJob? _jobFor(String direction) {
    for (final job in jobs) {
      if (job.direction.toLowerCase() == direction) return job;
    }
    return null;
  }

  AdminJob get representative => download ?? upload ?? jobs.first;

  int? get uploadedRows => _localRows(upload);
  int? get downloadedRows => _localRows(download);
  int? get changedRows => downloadedRows ?? uploadedRows;

  String get status {
    final failed = jobs.any(
      (job) =>
          job.status.toLowerCase() == 'failed' ||
          job.error?.trim().isNotEmpty == true,
    );
    if (failed) return 'Failed';
    final active = jobs.firstWhere(
      (job) => job.isActive,
      orElse: () => representative,
    );
    return active.status;
  }

  String get phase {
    if (jobs.any(
      (job) =>
          job.status.toLowerCase() == 'failed' ||
          job.error?.trim().isNotEmpty == true,
    )) {
      return 'Failed';
    }
    final downloadStatus = download?.status.toLowerCase() ?? '';
    if (downloadStatus == 'downloading' || downloadStatus == 'applying') {
      return 'Download';
    }
    final uploadStatus = upload?.status.toLowerCase() ?? '';
    if (uploadStatus == 'queued' ||
        uploadStatus == 'running' ||
        uploadStatus == 'snapshotting' ||
        uploadStatus == 'uploading') {
      return 'Upload';
    }
    if (downloadStatus == 'waiting') return 'Waiting';
    if (uploadStatus == 'completed' &&
        (downloadStatus == 'completed' || download == null)) {
      return 'Completed';
    }
    return status;
  }

  int get progress {
    if (jobs.isEmpty) return 0;
    return jobs
        .map((job) => job.progress)
        .reduce((left, right) => left < right ? left : right);
  }

  String get message {
    for (final job in [download, upload]) {
      if (job?.error?.trim().isNotEmpty == true) return job!.error!;
    }
    final messages = jobs
        .map((job) => job.message.trim())
        .where(
          (message) =>
              message.isNotEmpty && !_messageContainsReportedRowCount(message),
        )
        .toList(growable: false);
    if (messages.isNotEmpty) return messages.join(' / ');
    return status.toLowerCase() == 'completed'
        ? 'Sync completed.'
        : 'No additional message.';
  }

  int? _reportedRows(AdminJob? job) {
    if (job == null) return null;
    if (changedRowsOverride != null) return changedRowsOverride;
    return job.changedRowCount ?? job.rowCount;
  }

  int? _localRows(AdminJob? job) {
    if (job == null) return null;
    if (job.clientName != clientName) return 0;
    return _reportedRows(job);
  }
}

class _SyncLogBatch {
  _SyncLogBatch({
    required this.key,
    required this.operations,
    required this.clientName,
  });

  final String key;
  final List<_SyncLogOperation> operations;
  final String clientName;

  _SyncLogOperation get representative => operations.first;

  int? _sum(int? Function(_SyncLogOperation operation) valueFor) {
    final values = operations
        .map(valueFor)
        .whereType<int>()
        .toList(growable: false);
    if (values.isEmpty) return null;
    return values.fold<int>(0, (sum, value) => sum + value);
  }

  int? get changedRows => _sum((operation) => operation.changedRows);
  int? get uploadedRows => _sum((operation) => operation.uploadedRows);
  int? get downloadedRows => _sum((operation) => operation.downloadedRows);

  String get status {
    final failed = operations.any((operation) => operation.status == 'Failed');
    if (failed) return 'Failed';
    final active = operations.firstWhere(
      (operation) => operation.status.toLowerCase() != 'completed',
      orElse: () => representative,
    );
    return active.status;
  }

  int get progress {
    if (operations.isEmpty) return 0;
    return operations
        .map((operation) => operation.progress)
        .reduce((left, right) => left < right ? left : right);
  }

  String get message {
    final messages = operations
        .map((operation) => operation.message)
        .where((message) => message.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    return messages.isEmpty ? 'No message reported.' : messages.join(' / ');
  }
}

class ClientsPage extends StatefulWidget {
  const ClientsPage({
    super.key,
    required this.authenticatedUser,
    required this.authToken,
    required this.onLogout,
  });

  final AuthenticatedUser authenticatedUser;
  final String authToken;
  final VoidCallback onLogout;

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  static const _refreshInterval = Duration(seconds: 15);

  final LiveSyncApiClient _api = LiveSyncApiClient();
  final TextEditingController _filterController = TextEditingController();
  final TextEditingController _logFilterController = TextEditingController();
  Timer? _refreshTimer;
  AdminLiveState? _state;
  String? _selectedClientName;
  String? _error;
  bool _loading = true;
  bool _refreshing = false;
  bool _bulkSyncBusy = false;
  bool _bulkMinimizeBusy = false;
  bool _bulkUpdateBusy = false;
  bool _bulkLogsBusy = false;
  String _filter = '';
  String _logFilter = '';
  String _logDirection = 'all';
  String _logStatus = 'all';
  _ClientSortField _sortField = _ClientSortField.name;
  bool _sortAscending = true;
  _ClientDetailView _detailView = _ClientDetailView.logs;
  _ClientScreen _screen = _ClientScreen.list;
  String? _selectedTable;
  String? _selectedSyncKey;

  @override
  void initState() {
    super.initState();
    _restoreRouteFromUrl();
    _api.setAuthToken(widget.authToken);
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => _refresh(silent: true),
    );
    unawaited(_refresh());
  }

  void _restoreRouteFromUrl() {
    final segments = Uri.base.pathSegments;
    if (segments.isEmpty || segments.first != 'clients') {
      return;
    }
    if (segments.length >= 2 && segments[1].trim().isNotEmpty) {
      _selectedClientName = Uri.decodeComponent(segments[1]);
      _screen = _ClientScreen.detail;
    }
    if (segments.length >= 4 && segments[2] == 'tables') {
      _selectedTable = Uri.decodeComponent(segments[3]);
      _screen = _ClientScreen.table;
    }
    if (segments.length >= 4 && segments[2] == 'sync') {
      _selectedSyncKey = Uri.decodeComponent(segments[3]);
      _screen = _ClientScreen.sync;
    }
  }

  void _replaceRoute() {
    final client = _selectedClientName;
    final table = _selectedTable;
    final sync = _selectedSyncKey;
    final path = switch (_screen) {
      _ClientScreen.list => '/clients',
      _ClientScreen.detail => '/clients/${Uri.encodeComponent(client ?? '')}',
      _ClientScreen.sync =>
        '/clients/${Uri.encodeComponent(client ?? '')}/sync/${Uri.encodeComponent(sync ?? '')}',
      _ClientScreen.table =>
        '/clients/${Uri.encodeComponent(client ?? '')}/tables/${Uri.encodeComponent(table ?? '')}',
    };
    replaceBrowserUrl(Uri.base.replace(path: path, query: '').toString());
  }

  @override
  void didUpdateWidget(covariant ClientsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authToken != widget.authToken) {
      _api.setAuthToken(widget.authToken);
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _filterController.dispose();
    _logFilterController.dispose();
    _api.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final nextState = await _api.fetchLiveState();
      if (!mounted) {
        return;
      }
      final availableNames =
          nextState.agents.map((agent) => agent.clientName).toSet();
      final selected = _selectedClientName;
      setState(() {
        _state = nextState;
        _selectedClientName =
            selected != null && availableNames.contains(selected)
                ? selected
                : null;
        if (_selectedClientName == null) {
          _screen = _ClientScreen.list;
          _selectedTable = null;
          _selectedSyncKey = null;
          _replaceRoute();
        }
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final text = error.toString().toLowerCase();
      if (text.contains('unauthorized') ||
          text.contains('forbidden') ||
          text.contains('session')) {
        widget.onLogout();
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    } finally {
      _refreshing = false;
    }
  }

  AdminAgent? get _selectedAgent {
    final name = _selectedClientName;
    if (name == null) {
      return null;
    }
    for (final agent in _state?.agents ?? const <AdminAgent>[]) {
      if (agent.clientName == name) {
        return agent;
      }
    }
    return null;
  }

  AdminTableState? get _selectedTableState {
    final tableName = _selectedTable;
    if (tableName == null) return null;
    for (final table in _selectedAgent?.tables ?? const <AdminTableState>[]) {
      if (table.table == tableName) return table;
    }
    return null;
  }

  List<AdminJob> _jobsFor(AdminAgent agent) {
    return (_state?.jobs ?? const <AdminJob>[])
      .where(
        (job) =>
            job.clientName == agent.clientName ||
            job.subscriberClientName == agent.clientName,
      )
      .toList(growable: false)..sort(
      (left, right) =>
          _timestamp(right.updatedAt).compareTo(_timestamp(left.updatedAt)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child:
          _loading && _state == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    _buildMessage(_error!, error: true),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      children: [
                        if (_screen == _ClientScreen.list) _buildClientList(),
                        if (_screen == _ClientScreen.detail) _buildDetail(),
                        if (_screen == _ClientScreen.sync)
                          _buildSyncDetailPage(),
                        if (_screen == _ClientScreen.table)
                          _buildTableDetailPage(),
                      ],
                    ),
                  ),
                ],
              ),
    );
  }

  Widget _buildHeader() {
    final clients = _state?.agents ?? const <AdminAgent>[];
    final online = clients.where((client) => client.isOnline).length;
    final agent = _selectedAgent;
    if (_screen != _ClientScreen.list && agent != null) {
      if (_screen == _ClientScreen.detail) {
        return _buildClientDetailToolbar(agent);
      }
      final table = _selectedTableState;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip:
                _screen == _ClientScreen.table || _screen == _ClientScreen.sync
                    ? 'Back to client'
                    : 'Back to clients',
            onPressed:
                () => setState(() {
                  if (_screen == _ClientScreen.table ||
                      _screen == _ClientScreen.sync) {
                    _screen = _ClientScreen.detail;
                    _selectedTable = null;
                    _selectedSyncKey = null;
                  } else {
                    _screen = _ClientScreen.list;
                    _selectedTable = null;
                    _selectedSyncKey = null;
                  }
                  _replaceRoute();
                }),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _screen == _ClientScreen.table
                  ? _displayTable(table?.table ?? _selectedTable ?? '')
                  : _screen == _ClientScreen.sync
                  ? 'Sync details'
                  : agent.clientName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Clients',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$online online of ${clients.length} registered clients. Select a client to inspect its sync log.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF667085),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _refreshing ? null : () => _refresh(),
          icon:
              _refreshing
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.refresh_rounded, size: 17),
          label: const Text('Refresh clients'),
        ),
      ],
    );
  }

  Widget _buildClientDetailToolbar(AdminAgent agent) {
    final jobs = _jobsFor(agent);
    final activeSyncs = _activeSyncCount(agent, jobs);
    final statusColor =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final machine =
        agent.machineName.isEmpty ? 'Machine not reported' : agent.machineName;
    final database =
        agent.database.isEmpty ? 'Database not reported' : agent.database;
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Back to clients',
              onPressed:
                  () => setState(() {
                    _screen = _ClientScreen.list;
                    _selectedTable = null;
                    _selectedSyncKey = null;
                    _replaceRoute();
                  }),
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
            ),
            const SizedBox(width: 2),
            Text(
              agent.clientName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            _statusChip(agent.isOnline ? 'Online' : 'Offline', statusColor),
            const SizedBox(width: 10),
            Text(
              '$machine · $database',
              style: const TextStyle(color: Color(0xFF667085), fontSize: 12),
            ),
            const SizedBox(width: 12),
            _toolbarMetric(
              Icons.table_view_outlined,
              '${agent.tables.length} tables',
            ),
            _toolbarMetric(
              Icons.arrow_upward_rounded,
              '${_changedRowsLabel(jobs, direction: 'upload')} uploaded',
              color: const Color(0xFF2563EB),
            ),
            _toolbarMetric(
              Icons.arrow_downward_rounded,
              '${_changedRowsLabel(jobs, direction: 'download')} downloaded',
              color: const Color(0xFFB54708),
            ),
            _toolbarMetric(Icons.sync_rounded, '$activeSyncs active'),
            const SizedBox(width: 10),
            _buildDetailNavigation(),
          ],
        ),
      ),
    );
  }

  Widget _toolbarMetric(IconData icon, String label, {Color? color}) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Row(
      children: [
        Icon(icon, size: 14, color: color ?? const Color(0xFF667085)),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color ?? const Color(0xFF475467),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  Widget _buildDetailNavigation() {
    return SegmentedButton<_ClientDetailView>(
      segments: const [
        ButtonSegment(
          value: _ClientDetailView.logs,
          icon: Icon(Icons.receipt_long_outlined),
          label: Text('Sync logs'),
        ),
        ButtonSegment(
          value: _ClientDetailView.tables,
          icon: Icon(Icons.table_view_outlined),
          label: Text('Tables'),
        ),
      ],
      selected: {_detailView},
      onSelectionChanged: (selection) {
        setState(() => _detailView = selection.first);
      },
    );
  }

  Widget _buildClientList() {
    final clients = _filteredClients();
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'All clients',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                '${clients.length} shown',
                style: const TextStyle(color: Color(0xFF667085), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.authenticatedUser.canManageUsers) ...[
            _buildBulkActions(),
            const SizedBox(height: 10),
          ],
          _buildClientFilters(),
          const SizedBox(height: 10),
          if (clients.isEmpty)
            _buildEmpty(
              _filter.isEmpty
                  ? 'No clients have reported to the control plane yet.'
                  : 'No clients match this filter.',
            )
          else
            LayoutBuilder(
              builder:
                  (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: constraints.maxWidth,
                      ),
                      child: DataTable(
                        columnSpacing: 22,
                        headingRowHeight: 42,
                        dataRowMinHeight: 62,
                        dataRowMaxHeight: 72,
                        columns: const [
                          DataColumn(label: Text('Client')),
                          DataColumn(label: Text('Status')),
                          DataColumn(label: Text('Database')),
                          DataColumn(label: Text('Tables')),
                          DataColumn(label: Text('Last synced')),
                          DataColumn(label: Text('Last heartbeat')),
                          DataColumn(label: Text('Actions')),
                        ],
                        rows: clients.map(_buildClientDataRow).toList(),
                      ),
                    ),
                  ),
            ),
        ],
      ),
    );
  }

  Widget _buildClientFilters() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 680;
        final search = TextField(
          controller: _filterController,
          onChanged: (value) => setState(() => _filter = value.trim()),
          decoration: const InputDecoration(
            labelText: 'Filter clients',
            hintText: 'Name, machine, database, or status',
            prefixIcon: Icon(Icons.search_rounded),
            isDense: true,
          ),
        );
        final sort = _buildSortMenu();
        if (stack) {
          return Column(
            children: [
              search,
              const SizedBox(height: 8),
              Row(
                children: [Expanded(child: sort), _buildSortDirectionButton()],
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: search),
            const SizedBox(width: 8),
            SizedBox(width: 190, child: sort),
            _buildSortDirectionButton(),
          ],
        );
      },
    );
  }

  Widget _buildBulkActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed:
              _bulkSyncBusy
                  ? null
                  : () => unawaited(_triggerSyncAllEnabledNow()),
          icon: _actionIcon(busy: _bulkSyncBusy, icon: Icons.sync_rounded),
          label: const Text('Sync All'),
        ),
        FilledButton.tonalIcon(
          onPressed:
              _bulkMinimizeBusy
                  ? null
                  : () => unawaited(_requestAllAgentWindowMinimize()),
          icon: _actionIcon(
            busy: _bulkMinimizeBusy,
            icon: Icons.minimize_rounded,
          ),
          label: const Text('Minimize All'),
        ),
        FilledButton.tonalIcon(
          onPressed:
              _bulkUpdateBusy
                  ? null
                  : () => unawaited(_requestAllAgentClientUpdates()),
          icon: _actionIcon(
            busy: _bulkUpdateBusy,
            icon: Icons.system_update_alt_rounded,
          ),
          label: const Text('Update All'),
        ),
        FilledButton.tonalIcon(
          onPressed:
              _bulkLogsBusy
                  ? null
                  : () => unawaited(_requestAllAgentDiagnostics()),
          icon: _actionIcon(
            busy: _bulkLogsBusy,
            icon: Icons.receipt_long_rounded,
          ),
          label: const Text('Request All Logs'),
        ),
      ],
    );
  }

  Widget _actionIcon({required bool busy, required IconData icon}) {
    if (!busy) return Icon(icon, size: 17);
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }

  Widget _buildSortMenu() {
    return DropdownButtonFormField<_ClientSortField>(
      initialValue: _sortField,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(labelText: 'Sort by'),
      items: const [
        DropdownMenuItem(
          value: _ClientSortField.name,
          child: Text('Client name'),
        ),
        DropdownMenuItem(value: _ClientSortField.status, child: Text('Status')),
        DropdownMenuItem(
          value: _ClientSortField.database,
          child: Text('Database'),
        ),
        DropdownMenuItem(
          value: _ClientSortField.tables,
          child: Text('Table count'),
        ),
        DropdownMenuItem(
          value: _ClientSortField.lastSync,
          child: Text('Last synced'),
        ),
        DropdownMenuItem(
          value: _ClientSortField.heartbeat,
          child: Text('Last heartbeat'),
        ),
      ],
      onChanged: (value) {
        if (value != null) setState(() => _sortField = value);
      },
    );
  }

  Widget _buildSortDirectionButton() {
    return IconButton(
      tooltip: _sortAscending ? 'Ascending' : 'Descending',
      onPressed: () => setState(() => _sortAscending = !_sortAscending),
      icon: Icon(
        _sortAscending
            ? Icons.arrow_upward_rounded
            : Icons.arrow_downward_rounded,
      ),
    );
  }

  List<AdminAgent> _filteredClients() {
    final query = _filter.toLowerCase();
    final clients =
        (_state?.agents ?? const <AdminAgent>[]).where((agent) {
          if (query.isEmpty) return true;
          final searchable =
              [
                agent.clientName,
                agent.machineName,
                agent.database,
                agent.server,
                agent.isOnline ? 'online' : 'offline',
              ].join(' ').toLowerCase();
          return searchable.contains(query);
        }).toList();
    clients.sort((left, right) {
      int comparison;
      switch (_sortField) {
        case _ClientSortField.name:
          comparison = left.clientName.toLowerCase().compareTo(
            right.clientName.toLowerCase(),
          );
        case _ClientSortField.status:
          comparison = (left.isOnline ? 0 : 1).compareTo(
            right.isOnline ? 0 : 1,
          );
        case _ClientSortField.database:
          comparison = left.database.toLowerCase().compareTo(
            right.database.toLowerCase(),
          );
        case _ClientSortField.tables:
          comparison = left.tables.length.compareTo(right.tables.length);
        case _ClientSortField.lastSync:
          comparison = _timestamp(
            _latestClientSync(left),
          ).compareTo(_timestamp(_latestClientSync(right)));
        case _ClientSortField.heartbeat:
          comparison = _timestamp(
            left.lastHeartbeat,
          ).compareTo(_timestamp(right.lastHeartbeat));
      }
      return _sortAscending ? comparison : -comparison;
    });
    return clients;
  }

  DataRow _buildClientDataRow(AdminAgent agent) {
    final selected = agent.clientName == _selectedClientName;
    final jobs = _jobsFor(agent);
    final activityStatus = _clientActivityStatus(agent, jobs);
    return DataRow(
      selected: selected,
      cells: [
        DataCell(
          SizedBox(
            width: 210,
            child: Text(
              agent.clientName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        DataCell(
          _statusChip(activityStatus, _clientActivityColor(activityStatus)),
        ),
        DataCell(
          Text(
            agent.database.trim().isEmpty ? 'Not reported' : agent.database,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DataCell(Text('${agent.tables.length}')),
        DataCell(Text(_formatTimestamp(_latestClientSync(agent)))),
        DataCell(Text(_formatTimestamp(agent.lastHeartbeat))),
        DataCell(
          TextButton.icon(
            onPressed:
                () => setState(() {
                  _selectedClientName = agent.clientName;
                  _detailView = _ClientDetailView.logs;
                  _screen = _ClientScreen.detail;
                  _selectedTable = null;
                  _replaceRoute();
                }),
            icon: const Icon(Icons.visibility_outlined, size: 16),
            label: const Text('View'),
          ),
        ),
      ],
    );
  }

  String _clientActivityStatus(AdminAgent agent, List<AdminJob> jobs) {
    if (!agent.isOnline) return 'Offline';
    if (agent.clientUpdate.pending) return 'Updating';
    if (!agent.serverConnected) return 'Server offline';
    if (!agent.sqlConnected) return 'SQL offline';

    final currentStatuses =
        jobs
            .where(
              (job) => job.isActive || job.status.toLowerCase() == 'waiting',
            )
            .map((job) => job.status.toLowerCase())
            .toSet();
    for (final phase in const [
      'applying',
      'downloading',
      'uploading',
      'snapshotting',
      'running',
      'waiting',
      'queued',
    ]) {
      if (!currentStatuses.contains(phase)) continue;
      return switch (phase) {
        'applying' => 'Applying',
        'downloading' => 'Downloading',
        'uploading' || 'snapshotting' => 'Uploading',
        'running' => 'Syncing',
        'waiting' => 'Waiting',
        'queued' => 'Queued',
        _ => 'Syncing',
      };
    }
    return 'Ready';
  }

  Color _clientActivityColor(String status) {
    switch (status.toLowerCase()) {
      case 'ready':
        return const Color(0xFF0F766E);
      case 'uploading':
      case 'updating':
      case 'syncing':
        return const Color(0xFF2563EB);
      case 'downloading':
      case 'applying':
        return const Color(0xFFB54708);
      case 'waiting':
      case 'queued':
        return const Color(0xFF7A5D00);
      case 'offline':
      case 'server offline':
      case 'sql offline':
        return const Color(0xFFB42318);
      default:
        return const Color(0xFF475467);
    }
  }

  Widget _buildClientListItem(AdminAgent agent) {
    final selected = agent.clientName == _selectedClientName;
    final color =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final database =
        agent.database.trim().isEmpty
            ? 'Database not reported'
            : agent.database.trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _selectedClientName = agent.clientName),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE6F4F1) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  selected ? const Color(0xFF85C7BC) : const Color(0xFFDDE3EA),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.computer_rounded, color: color, size: 20),
              const SizedBox(width: 9),
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
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        _statusChip(
                          agent.isOnline ? 'Online' : 'Offline',
                          color,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$database · ${agent.tables.length} tables',
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Heartbeat ${_formatTimestamp(agent.lastHeartbeat)}',
                      style: const TextStyle(
                        color: Color(0xFF98A2B3),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailWithBack() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _selectedClientName = null),
          icon: const Icon(Icons.arrow_back_rounded, size: 17),
          label: const Text('All clients'),
        ),
        const SizedBox(height: 4),
        Expanded(child: _buildDetail()),
      ],
    );
  }

  Widget _buildDetail() {
    final agent = _selectedAgent;
    if (agent == null) {
      return _panel(
        child: _buildEmpty('Select a client to inspect its sync activity.'),
      );
    }
    final jobs = _jobsFor(agent);
    return _panel(
      child:
          _detailView == _ClientDetailView.logs
              ? _buildJobLog(jobs)
              : _buildDataViewer(agent),
    );
  }

  int _activeSyncCount(AdminAgent agent, List<AdminJob> jobs) {
    final operations = _groupSyncLogOperations(
      jobs,
      clientName: agent.clientName,
    );
    final batches = _groupSyncLogBatches(
      operations,
      clientName: agent.clientName,
    );
    return batches
        .where(
          (batch) =>
              batch.status.toLowerCase() != 'completed' &&
              batch.status.toLowerCase() != 'failed',
        )
        .length;
  }

  Widget _buildTableDetailPage() {
    final agent = _selectedAgent;
    final table = _selectedTableState;
    if (agent == null || table == null) {
      return _panel(child: _buildEmpty('Table detail is no longer available.'));
    }
    final jobs = _jobsFor(
      agent,
    ).where((job) => job.table == table.table).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _displayTable(table.table),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${agent.clientName} · ${agent.database.isEmpty ? 'Database not reported' : agent.database}',
                style: const TextStyle(color: Color(0xFF667085)),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _metric('Changed rows', _changedRowsLabel(jobs)),
                  _metric('Status', table.status),
                  _metric('Last sync', _formatTimestamp(table.lastSync)),
                ],
              ),
              const SizedBox(height: 12),
              _buildMessage(
                'The control plane does not store row-level table payloads. Use the Windows client for row-level verification.',
                error: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _panel(child: _buildJobLog(jobs)),
      ],
    );
  }

  int? _changedRows(List<AdminJob> jobs, {String? direction}) {
    final normalizedDirection = (direction ?? '').toLowerCase();
    final reported = jobs
        .where((job) {
          if (job.changedRowCount == null) return false;
          return direction == null ||
              job.direction.toLowerCase() == normalizedDirection;
        })
        .toList(growable: false);
    if (reported.isEmpty) return null;
    return reported.fold<int>(0, (sum, job) => sum + job.changedRowCount!);
  }

  String _changedRowsLabel(List<AdminJob> jobs, {String? direction}) {
    final value = _changedRows(jobs, direction: direction);
    return value == null ? 'Not reported' : _number(value);
  }

  int _transferRows(List<AdminJob> jobs, String direction) {
    return _changedRows(jobs, direction: direction) ?? 0;
  }

  Widget _buildDataViewer(AdminAgent agent) {
    final tables = List<AdminTableState>.from(agent.tables)
      ..sort((left, right) => left.table.compareTo(right.table));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Table & data viewer',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Table metadata and row counts reported by this client.',
          style: TextStyle(color: Color(0xFF667085), fontSize: 12),
        ),
        const SizedBox(height: 10),
        if (tables.isEmpty)
          _buildEmpty('No table state has been reported.')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Table')),
                DataColumn(label: Text('Changed rows')),
                DataColumn(label: Text('Uploaded')),
                DataColumn(label: Text('Downloaded')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Last sync')),
                DataColumn(label: Text('Data')),
              ],
              rows:
                  tables
                      .map(
                        (table) => DataRow(
                          cells: [
                            DataCell(Text(_displayTable(table.table))),
                            DataCell(
                              Text(
                                _changedRowsLabel(
                                  _jobsFor(agent)
                                      .where((job) => job.table == table.table)
                                      .toList(growable: false),
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _changedRowsLabel(
                                  _jobsFor(agent)
                                      .where((job) => job.table == table.table)
                                      .toList(growable: false),
                                  direction: 'upload',
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _changedRowsLabel(
                                  _jobsFor(agent)
                                      .where((job) => job.table == table.table)
                                      .toList(growable: false),
                                  direction: 'download',
                                ),
                              ),
                            ),
                            DataCell(
                              _statusChip(
                                table.status,
                                _statusColor(table.status),
                              ),
                            ),
                            DataCell(Text(_formatTimestamp(table.lastSync))),
                            DataCell(
                              TextButton.icon(
                                onPressed:
                                    () => setState(() {
                                      _selectedTable = table.table;
                                      _screen = _ClientScreen.table;
                                      _replaceRoute();
                                    }),
                                icon: const Icon(Icons.open_in_new, size: 15),
                                label: const Text('Open'),
                              ),
                            ),
                          ],
                        ),
                      )
                      .toList(),
            ),
          ),
        const SizedBox(height: 10),
        _buildMessage(
          'The control plane does not store row-level table payloads. Use the Windows client for row-level verification.',
          error: false,
        ),
      ],
    );
  }

  Widget _buildTableLog(AdminAgent agent) {
    final tables = List<AdminTableState>.from(agent.tables)
      ..sort((left, right) => left.table.compareTo(right.table));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Table activity',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Current row count and last reported sync state for this client.',
          style: TextStyle(color: Color(0xFF667085), fontSize: 12),
        ),
        const SizedBox(height: 10),
        if (tables.isEmpty)
          _buildEmpty('No table state has been reported.')
        else ...[
          for (var index = 0; index < tables.length; index++) ...[
            _buildTableRow(tables[index]),
            if (index != tables.length - 1) const Divider(height: 14),
          ],
        ],
      ],
    );
  }

  Widget _buildTableRow(AdminTableState table) {
    final displayStatus = _displayTableStatus(table);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _displayTable(table.table),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                table.message.isEmpty ? 'No message reported.' : table.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF667085), fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${_number(table.rowCount)} rows',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 3),
            _statusChip(displayStatus, _statusColor(displayStatus)),
            const SizedBox(height: 3),
            Text(
              _formatTimestamp(table.lastSync),
              style: const TextStyle(color: Color(0xFF98A2B3), fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  String _displayTableStatus(AdminTableState table) {
    final agent = _selectedAgent;
    if (agent == null) {
      return table.status;
    }
    final jobs = _jobsFor(
      agent,
    ).where((job) => job.table == table.table).toList(growable: false);
    final active = jobs.where((job) => job.isActive).toList(growable: false);
    if (active.isNotEmpty) {
      return active.first.status;
    }
    final latestCompleted = jobs.where(
      (job) => job.status.toLowerCase() == 'completed',
    );
    if (latestCompleted.isNotEmpty) {
      return 'Completed';
    }
    final stale = table.status.toLowerCase();
    if (stale == 'applying' ||
        stale == 'running' ||
        stale == 'uploading' ||
        stale == 'downloading' ||
        stale == 'failed' ||
        stale == 'error') {
      return table.lastSync.trim().isNotEmpty ? 'Completed' : 'Waiting';
    }
    return table.status;
  }

  Widget _buildJobLog(List<AdminJob> jobs) {
    final operations = _groupSyncLogOperations(
      jobs,
      clientName: _selectedClientName ?? '',
    );
    final batches = _groupSyncLogBatches(
      operations,
      clientName: _selectedClientName ?? '',
    );
    final visibleBatches = batches
        .where((batch) {
          final query = _logFilter.toLowerCase();
          final matchesQuery =
              query.isEmpty ||
              '${batch.operations.map((operation) => operation.representative.table).join(' ')} upload download ${batch.status} ${batch.message}'
                  .toLowerCase()
                  .contains(query);
          final matchesDirection =
              _logDirection == 'all' ||
              (_logDirection == 'upload' &&
                  batch.operations.any(
                    (operation) => operation.upload != null,
                  )) ||
              (_logDirection == 'download' &&
                  batch.operations.any(
                    (operation) => operation.download != null,
                  ));
          final matchesStatus =
              _logStatus == 'all' || batch.status.toLowerCase() == _logStatus;
          return matchesQuery && matchesDirection && matchesStatus;
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sync log',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'One row represents one sync. Open it to inspect each table difference.',
          style: TextStyle(color: Color(0xFF667085), fontSize: 12),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 720;
            final search = TextField(
              controller: _logFilterController,
              onChanged: (value) => setState(() => _logFilter = value.trim()),
              decoration: const InputDecoration(
                labelText: 'Filter log',
                hintText: 'Table, direction, status, or message',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            );
            final direction = _buildLogFilter(
              label: 'Direction',
              value: _logDirection,
              values: const {
                'all': 'All directions',
                'upload': 'Upload',
                'download': 'Download',
              },
              onChanged: (value) => setState(() => _logDirection = value),
            );
            final statuses = <String, String>{'all': 'All statuses'};
            for (final job in jobs) {
              final status = job.status.toLowerCase();
              if (status.isNotEmpty) statuses[status] = job.status;
            }
            final status = _buildLogFilter(
              label: 'Status',
              value: _logStatus,
              values: statuses,
              onChanged: (value) => setState(() => _logStatus = value),
            );
            if (stack) {
              return Column(
                children: [
                  search,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: direction),
                      const SizedBox(width: 8),
                      Expanded(child: status),
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 8),
                SizedBox(width: 160, child: direction),
                const SizedBox(width: 8),
                SizedBox(width: 160, child: status),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        if (visibleBatches.isEmpty)
          _buildEmpty(
            batches.isEmpty
                ? 'No sync jobs are visible for this client.'
                : 'No logs match the current filters.',
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 20,
              columns: const [
                DataColumn(label: Text('Updated')),
                DataColumn(label: Text('Operation')),
                DataColumn(label: Text('Tables')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Progress')),
                DataColumn(label: Text('Changed rows')),
                DataColumn(label: Text('Uploaded new')),
                DataColumn(label: Text('Downloaded new')),
                DataColumn(label: Text('Message')),
              ],
              rows: visibleBatches
                  .map(_buildSyncDataRow)
                  .toList(growable: false),
            ),
          ),
      ],
    );
  }

  DataRow _buildSyncDataRow(_SyncLogBatch batch) {
    final uploadColor = const Color(0xFF2563EB);
    final downloadColor = const Color(0xFFB54708);
    return DataRow(
      onSelectChanged: (_) {
        setState(() {
          _selectedSyncKey = batch.key;
          _screen = _ClientScreen.sync;
          _replaceRoute();
        });
      },
      cells: [
        DataCell(
          Text(_formatTimestamp(batch.representative.representative.updatedAt)),
        ),
        DataCell(
          Row(
            children: [
              Icon(
                Icons.sync_rounded,
                size: 16,
                color: Colors.blueGrey.shade700,
              ),
              const SizedBox(width: 5),
              const Text('Sync', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(width: 5),
              const Icon(Icons.chevron_right_rounded, size: 17),
            ],
          ),
        ),
        DataCell(Text('${batch.operations.length}')),
        DataCell(_statusChip(batch.status, _statusColor(batch.status))),
        DataCell(Text('${batch.progress}%')),
        DataCell(
          Text(
            batch.changedRows == null
                ? 'Not reported'
                : '+${_number(batch.changedRows!)}',
            style: const TextStyle(
              color: Color(0xFFB54708),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        DataCell(
          Text(
            batch.uploadedRows == null
                ? 'Not reported'
                : '+${_number(batch.uploadedRows!)}',
            style: TextStyle(color: uploadColor, fontWeight: FontWeight.w800),
          ),
        ),
        DataCell(
          Text(
            batch.downloadedRows == null
                ? 'Not reported'
                : '+${_number(batch.downloadedRows!)}',
            style: TextStyle(color: downloadColor, fontWeight: FontWeight.w800),
          ),
        ),
        DataCell(
          SizedBox(
            width: 260,
            child: Text(
              batch.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncDetailPage() {
    final agent = _selectedAgent;
    if (agent == null) {
      return _panel(child: _buildEmpty('Client is no longer available.'));
    }
    final operations = _groupSyncLogOperations(
      _jobsFor(agent),
      clientName: agent.clientName,
    );
    final batches = _groupSyncLogBatches(
      operations,
      clientName: agent.clientName,
    );
    _SyncLogBatch? batch;
    for (final candidate in batches) {
      if (candidate.key == _selectedSyncKey) {
        batch = candidate;
        break;
      }
    }
    if (batch == null) {
      return _panel(
        child: _buildEmpty('Sync operation is no longer available.'),
      );
    }
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sync detail · ${_formatTimestamp(batch.representative.representative.updatedAt)}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            '${batch.operations.length} tables · totals show only changed rows',
            style: const TextStyle(color: Color(0xFF667085), fontSize: 12),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 20,
              columns: const [
                DataColumn(label: Text('Table')),
                DataColumn(label: Text('Phase')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Changed')),
                DataColumn(label: Text('Uploaded new')),
                DataColumn(label: Text('Downloaded new')),
                DataColumn(label: Text('Message')),
              ],
              rows: batch.operations
                  .map(_buildLogDataRow)
                  .toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }

  List<_SyncLogOperation> _groupSyncLogOperations(
    List<AdminJob> jobs, {
    required String clientName,
  }) {
    final grouped = <String, List<AdminJob>>{};
    for (final job in jobs) {
      final batch = job.batchId.trim();
      final snapshot = job.snapshotId?.trim() ?? '';
      final timestamp =
          job.createdAt.length >= 19
              ? job.createdAt.substring(0, 19)
              : job.createdAt;
      final key =
          batch.isNotEmpty
              ? 'batch:$batch|${job.table}'
              : snapshot.isNotEmpty
              ? 'snapshot:$snapshot'
              : '${job.table}|${job.sourceClientName}|${job.subscriberClientName}|$timestamp';
      grouped.putIfAbsent(key, () => <AdminJob>[]).add(job);
    }
    final operations = grouped.entries
        .map(
          (entry) => _SyncLogOperation(
            key: entry.key,
            jobs: entry.value,
            clientName: clientName,
          ),
        )
        .toList(growable: false);
    operations.sort(
      (left, right) => _timestamp(
        right.representative.updatedAt,
      ).compareTo(_timestamp(left.representative.updatedAt)),
    );
    for (var index = 0; index < operations.length; index++) {
      final current = operations[index];
      final currentRows = current.representative.rowCount;
      if (currentRows <= 0) {
        current.changedRowsOverride = 0;
        continue;
      }
      final previous = operations
          .skip(index + 1)
          .firstWhere(
            (candidate) =>
                candidate.representative.table ==
                    current.representative.table &&
                candidate.representative.rowCount > 0,
            orElse:
                () => _SyncLogOperation(
                  key: '',
                  jobs: const [],
                  clientName: clientName,
                ),
          );
      if (previous.jobs.isNotEmpty &&
          currentRows >= previous.representative.rowCount) {
        current.changedRowsOverride =
            currentRows - previous.representative.rowCount;
      }
    }
    return operations;
  }

  List<_SyncLogBatch> _groupSyncLogBatches(
    List<_SyncLogOperation> operations, {
    required String clientName,
  }) {
    final grouped = <String, List<_SyncLogOperation>>{};
    for (final operation in operations) {
      final representative = operation.representative;
      final timestamp =
          representative.createdAt.length >= 16
              ? representative.createdAt.substring(0, 16)
              : representative.createdAt;
      final key =
          '${representative.sourceClientName}|'
          '${representative.subscriberClientName}|$timestamp';
      grouped.putIfAbsent(key, () => <_SyncLogOperation>[]).add(operation);
    }
    final batches = grouped.entries
        .map(
          (entry) => _SyncLogBatch(
            key: entry.key,
            operations: entry.value,
            clientName: clientName,
          ),
        )
        .toList(growable: false);
    batches.sort(
      (left, right) => _timestamp(
        right.representative.representative.updatedAt,
      ).compareTo(_timestamp(left.representative.representative.updatedAt)),
    );
    return batches;
  }

  Widget _buildLogFilter({
    required String label,
    required String value,
    required Map<String, String> values,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: values.containsKey(value) ? value : 'all',
      isExpanded: true,
      isDense: true,
      decoration: InputDecoration(labelText: label),
      items: values.entries
          .map(
            (entry) =>
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          )
          .toList(growable: false),
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }

  DataRow _buildLogDataRow(_SyncLogOperation operation) {
    final changed = operation.changedRows;
    final uploadColor = const Color(0xFF2563EB);
    final downloadColor = const Color(0xFFB54708);
    return DataRow(
      cells: [
        DataCell(Text(_formatTimestamp(operation.representative.updatedAt))),
        DataCell(
          Row(
            children: [
              if (operation.upload != null)
                Icon(Icons.arrow_upward_rounded, size: 16, color: uploadColor),
              if (operation.download != null)
                Icon(
                  Icons.arrow_downward_rounded,
                  size: 16,
                  color: downloadColor,
                ),
              const SizedBox(width: 5),
              const Text('Sync', style: TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
        DataCell(Text(_displayTable(operation.representative.table))),
        DataCell(_statusChip(operation.phase, _phaseColor(operation.phase))),
        DataCell(_statusChip(operation.status, _statusColor(operation.status))),
        DataCell(Text('${operation.progress}%')),
        DataCell(
          Text(
            changed == null ? 'Not reported' : '+${_number(changed)}',
            style: const TextStyle(
              color: Color(0xFFB54708),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        DataCell(
          Text(
            operation.uploadedRows == null
                ? 'Not reported'
                : '+${_number(operation.uploadedRows!)}',
            style: const TextStyle(
              color: Color(0xFF2563EB),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        DataCell(
          Text(
            operation.downloadedRows == null
                ? 'Not reported'
                : '+${_number(operation.downloadedRows!)}',
            style: const TextStyle(
              color: Color(0xFFB54708),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: 260,
            child: Text(
              operation.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Color _phaseColor(String phase) {
    switch (phase.toLowerCase()) {
      case 'upload':
        return const Color(0xFF2563EB);
      case 'download':
        return const Color(0xFFB54708);
      case 'waiting':
        return const Color(0xFF667085);
      case 'failed':
        return const Color(0xFFB42318);
      case 'completed':
        return const Color(0xFF15803D);
      default:
        return const Color(0xFF667085);
    }
  }

  Widget _buildJobRow(AdminJob job) {
    final failed =
        job.error?.trim().isNotEmpty == true ||
        job.status.toLowerCase() == 'failed';
    final isUpload = job.direction.toLowerCase() == 'upload';
    final deltaColor =
        isUpload ? const Color(0xFF2563EB) : const Color(0xFFB54708);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          job.direction.toLowerCase() == 'upload'
              ? Icons.arrow_upward_rounded
              : Icons.arrow_downward_rounded,
          size: 17,
          color: deltaColor,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_displayTable(job.table)} · ${job.direction}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                job.error?.trim().isNotEmpty == true
                    ? job.error!
                    : (job.message.isEmpty
                        ? 'No message reported.'
                        : job.message),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      failed
                          ? const Color(0xFFB42318)
                          : const Color(0xFF667085),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _statusChip(job.status, _statusColor(job.status)),
            const SizedBox(height: 3),
            _deltaChip(job.changedRowCount, deltaColor),
            const SizedBox(height: 3),
            Text('${job.progress}%', style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 3),
            Text(
              _formatTimestamp(job.updatedAt),
              style: const TextStyle(color: Color(0xFF98A2B3), fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  Widget _deltaChip(int? changedRows, Color color) {
    final label =
        changedRows == null
            ? 'Additional rows not reported'
            : '+${_number(changedRows)} rows';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _panel({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFDDE3EA)),
    ),
    child: child,
  );

  Widget _buildMessage(String message, {required bool error}) => _panel(
    child: Text(
      message,
      style: TextStyle(
        color: error ? const Color(0xFFB42318) : const Color(0xFF667085),
      ),
    ),
  );

  Widget _buildEmpty(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFF667085)),
      ),
    ),
  );

  Widget _statusChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
    ),
  );

  Widget _metric(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0xFFDDE3EA)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF667085), fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    ),
  );

  Color _statusColor(String status) {
    final value = status.toLowerCase();
    if (value == 'completed' || value == 'complete' || value == 'idle') {
      return const Color(0xFF0F766E);
    }
    if (value == 'failed' || value == 'cancelled' || value == 'offline') {
      return const Color(0xFFB42318);
    }
    if (value == 'queued' || value == 'waiting' || value == 'paused') {
      return const Color(0xFFB54708);
    }
    return const Color(0xFF475467);
  }

  String _displayTable(String table) {
    final separator = table.indexOf('::');
    final value = separator < 0 ? table : table.substring(separator + 2);
    return value.replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');
  }

  String _formatTimestamp(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value.trim().isEmpty ? 'Not reported' : value;
    String two(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} ${two(parsed.hour)}:${two(parsed.minute)}';
  }

  DateTime _timestamp(String value) =>
      DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);

  String _latestClientSync(AdminAgent agent) {
    var latest = '';
    var latestTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
    for (final table in agent.tables) {
      final value = table.lastSync.trim();
      final timestamp = _timestamp(value);
      if (value.isNotEmpty && timestamp.isAfter(latestTimestamp)) {
        latest = value;
        latestTimestamp = timestamp;
      }
    }
    return latest;
  }

  Future<void> _triggerSyncAllEnabledNow() async {
    if (_bulkSyncBusy) return;
    setState(() => _bulkSyncBusy = true);
    try {
      final result = await _api.triggerSyncAllEnabledNow();
      if (!mounted) return;
      final details = <String>[
        'Queued ${result.queuedJobCount} jobs across ${result.queuedClientCount} clients.',
      ];
      if (result.skippedOfflineClients.isNotEmpty) {
        details.add('Offline: ${result.skippedOfflineClients.join(', ')}.');
      }
      if (result.skippedBusyTables.isNotEmpty) {
        details.add('Busy tables skipped: ${result.skippedBusyTables.length}.');
      }
      _showActionMessage(details.join(' '));
      await _refresh(silent: true);
    } catch (error) {
      if (mounted) _showActionError(error);
    } finally {
      if (mounted) setState(() => _bulkSyncBusy = false);
    }
  }

  Future<void> _requestAllAgentWindowMinimize() async {
    if (_bulkMinimizeBusy) return;
    setState(() => _bulkMinimizeBusy = true);
    try {
      final result = await _api.requestAllAgentWindowActions();
      if (!mounted) return;
      _showActionMessage(
        'Minimize requested for ${result.requestedClientCount} online client(s).',
      );
      await _refresh(silent: true);
    } catch (error) {
      if (mounted) _showActionError(error);
    } finally {
      if (mounted) setState(() => _bulkMinimizeBusy = false);
    }
  }

  Future<void> _requestAllAgentClientUpdates() async {
    if (_bulkUpdateBusy) return;
    setState(() => _bulkUpdateBusy = true);
    try {
      final result = await _api.requestAllAgentClientUpdates();
      if (!mounted) return;
      _showActionMessage(
        'Update requested for ${result.requestedClientCount} online client(s).',
      );
      await _refresh(silent: true);
    } catch (error) {
      if (mounted) _showActionError(error);
    } finally {
      if (mounted) setState(() => _bulkUpdateBusy = false);
    }
  }

  Future<void> _requestAllAgentDiagnostics() async {
    if (_bulkLogsBusy) return;
    setState(() => _bulkLogsBusy = true);
    try {
      final clientNames = (_state?.agents ?? const <AdminAgent>[])
          .where((agent) => agent.isOnline)
          .map((agent) => agent.clientName.trim())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList(growable: false);
      var requestedCount = 0;
      var requestId = '';
      for (var index = 0; index < clientNames.length; index += 5) {
        final result = await _api.requestAgentDiagnosticsBatch(
          clientNames: clientNames.skip(index).take(5).toList(growable: false),
          requestId: requestId,
        );
        if (requestId.isEmpty) requestId = result.requestId;
        requestedCount += result.requestedClientCount;
      }
      if (!mounted) return;
      _showActionMessage(
        requestedCount == 0
            ? 'No online clients were available for log collection.'
            : 'Requested logs from $requestedCount online client(s).',
      );
      await _refresh(silent: true);
    } catch (error) {
      if (mounted) _showActionError(error);
    } finally {
      if (mounted) setState(() => _bulkLogsBusy = false);
    }
  }

  void _showActionMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showActionError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: SelectableText(error.toString())));
  }

  int _rowCount(AdminAgent agent) =>
      agent.tables.fold<int>(0, (sum, table) => sum + table.rowCount);

  String _number(int value) => value.toString().replaceAllMapped(
    RegExp(r'(?<!^)(?=(\d{3})+$)'),
    (_) => ',',
  );
}
