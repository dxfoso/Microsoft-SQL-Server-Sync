import 'dart:async';

// Legacy compact-layout helpers remain available for future detail navigation.
// ignore_for_file: unused_element

import 'package:flutter/material.dart';

import 'live_sync_api.dart';
import 'models.dart';

enum _ClientSortField { name, status, database, tables, rows, heartbeat }

enum _ClientDetailView { logs, tables }

class ClientsPage extends StatefulWidget {
  const ClientsPage({
    super.key,
    required this.authToken,
    required this.onLogout,
  });

  final String authToken;
  final VoidCallback onLogout;

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  static const _refreshInterval = Duration(seconds: 15);

  final LiveSyncApiClient _api = LiveSyncApiClient();
  final TextEditingController _filterController = TextEditingController();
  Timer? _refreshTimer;
  AdminLiveState? _state;
  String? _selectedClientName;
  String? _error;
  bool _loading = true;
  bool _refreshing = false;
  String _filter = '';
  _ClientSortField _sortField = _ClientSortField.name;
  bool _sortAscending = true;
  _ClientDetailView _detailView = _ClientDetailView.logs;

  @override
  void initState() {
    super.initState();
    _api.setAuthToken(widget.authToken);
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => _refresh(silent: true),
    );
    unawaited(_refresh());
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
                        _buildClientList(),
                        if (_selectedAgent != null) ...[
                          const SizedBox(height: 12),
                          _buildDetail(),
                        ],
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
                          DataColumn(label: Text('Rows')),
                          DataColumn(label: Text('Rows uploaded')),
                          DataColumn(label: Text('Rows downloaded')),
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
          value: _ClientSortField.rows,
          child: Text('Row count'),
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
        case _ClientSortField.rows:
          comparison = _rowCount(left).compareTo(_rowCount(right));
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
    final color =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    final jobs = _jobsFor(agent);
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
        DataCell(_statusChip(agent.isOnline ? 'Online' : 'Offline', color)),
        DataCell(
          Text(
            agent.database.trim().isEmpty ? 'Not reported' : agent.database,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DataCell(Text('${agent.tables.length}')),
        DataCell(Text(_number(_rowCount(agent)))),
        DataCell(Text(_number(_transferRows(jobs, 'upload')))),
        DataCell(Text(_number(_transferRows(jobs, 'download')))),
        DataCell(Text(_formatTimestamp(agent.lastHeartbeat))),
        DataCell(
          TextButton.icon(
            onPressed:
                () => setState(() {
                  _selectedClientName = agent.clientName;
                  _detailView = _ClientDetailView.logs;
                }),
            icon: const Icon(Icons.visibility_outlined, size: 16),
            label: const Text('View'),
          ),
        ),
      ],
    );
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
    final completedRows = jobs
        .where((job) => job.status.toLowerCase() == 'completed')
        .fold<int>(0, (sum, job) => sum + job.rowCount);
    final activeJobs = jobs.where((job) => job.isActive).length;
    final currentRows = agent.tables.fold<int>(
      0,
      (sum, table) => sum + table.rowCount,
    );
    return Column(
      children: [
        _buildDetailToolbar(agent),
        const SizedBox(height: 10),
        _panel(
          child: _buildClientSummary(
            agent,
            currentRows,
            completedRows,
            activeJobs,
          ),
        ),
        const SizedBox(height: 12),
        _panel(
          child:
              _detailView == _ClientDetailView.logs
                  ? _buildJobLog(jobs)
                  : _buildDataViewer(agent),
        ),
      ],
    );
  }

  int _transferRows(List<AdminJob> jobs, String direction) {
    final normalizedDirection = direction.toLowerCase();
    return jobs
        .where((job) => job.direction.toLowerCase() == normalizedDirection)
        .fold<int>(0, (sum, job) => sum + job.rowCount);
  }

  Widget _buildDetailToolbar(AdminAgent agent) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Client view · ${agent.clientName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
        SegmentedButton<_ClientDetailView>(
          segments: const [
            ButtonSegment(
              value: _ClientDetailView.logs,
              icon: Icon(Icons.receipt_long_outlined),
              label: Text('Logs'),
            ),
            ButtonSegment(
              value: _ClientDetailView.tables,
              icon: Icon(Icons.table_view_outlined),
              label: Text('Table & data viewer'),
            ),
          ],
          selected: {_detailView},
          onSelectionChanged: (selection) {
            setState(() => _detailView = selection.first);
          },
        ),
      ],
    );
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
                DataColumn(label: Text('Rows')),
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
                            DataCell(Text(_number(table.rowCount))),
                            DataCell(
                              _statusChip(
                                table.status,
                                _statusColor(table.status),
                              ),
                            ),
                            DataCell(Text(_formatTimestamp(table.lastSync))),
                            const DataCell(Text('Row data not reported')),
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

  Widget _buildClientSummary(
    AdminAgent agent,
    int currentRows,
    int completedRows,
    int activeJobs,
  ) {
    final color =
        agent.isOnline ? const Color(0xFF0F766E) : const Color(0xFFB42318);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.monitor_heart_rounded, color: color, size: 24),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                agent.clientName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            _statusChip(agent.isOnline ? 'Online' : 'Offline', color),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '${agent.machineName.isEmpty ? 'Machine not reported' : agent.machineName} · ${agent.database.isEmpty ? 'Database not reported' : agent.database}',
          style: const TextStyle(color: Color(0xFF667085)),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _metric('Tables', '${agent.tables.length}'),
            _metric('Current rows', _number(currentRows)),
            _metric('Rows synced', _number(completedRows)),
            _metric('Active jobs', '$activeJobs'),
            _metric('New / changed', 'Not reported'),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Last heartbeat ${_formatTimestamp(agent.lastHeartbeat)} · SQL ${agent.sqlConnected ? 'connected' : 'not connected'} · Client ${agent.clientVersion.isEmpty ? 'unknown' : agent.clientVersion}',
          style: const TextStyle(color: Color(0xFF667085), fontSize: 12),
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
            _statusChip(table.status, _statusColor(table.status)),
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

  Widget _buildJobLog(List<AdminJob> jobs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sync log',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Each job reports direction, status, progress, and rows transferred.',
          style: TextStyle(color: Color(0xFF667085), fontSize: 12),
        ),
        const SizedBox(height: 10),
        if (jobs.isEmpty)
          _buildEmpty('No sync jobs are visible for this client.')
        else ...[
          for (var index = 0; index < jobs.length; index++) ...[
            _buildJobRow(jobs[index]),
            if (index != jobs.length - 1) const Divider(height: 14),
          ],
        ],
      ],
    );
  }

  Widget _buildJobRow(AdminJob job) {
    final failed =
        job.error?.trim().isNotEmpty == true ||
        job.status.toLowerCase() == 'failed';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          job.direction.toLowerCase() == 'upload'
              ? Icons.arrow_upward_rounded
              : Icons.arrow_downward_rounded,
          size: 17,
          color: const Color(0xFF667085),
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
            Text(
              '${job.progress}% · ${_number(job.rowCount)} rows',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
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
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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

  int _rowCount(AdminAgent agent) =>
      agent.tables.fold<int>(0, (sum, table) => sum + table.rowCount);

  String _number(int value) => value.toString().replaceAllMapped(
    RegExp(r'(?<!^)(?=(\d{3})+$)'),
    (_) => ',',
  );
}
