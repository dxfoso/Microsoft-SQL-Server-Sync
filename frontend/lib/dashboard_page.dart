import 'dart:async';

import 'package:flutter/material.dart';

import 'dashboard_widgets.dart';
import 'live_sync_api.dart';
import 'models.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final LiveSyncApiClient _api = LiveSyncApiClient();
  Timer? _refreshTimer;

  AdminLiveState? _state;
  bool _loading = true;
  bool _connected = false;
  String? _error;
  String? _selectedSnapshotId;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshState());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshState(silent: true)),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  Future<void> _refreshState({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
      });
    }

    try {
      final state = await _api.fetchLiveState();
      if (!mounted) {
        return;
      }
      setState(() {
        _state = state;
        _connected = true;
        _loading = false;
        _error = null;
        final snapshots = state.snapshots;
        if (snapshots.isNotEmpty &&
            !snapshots.any((snapshot) => snapshot.id == _selectedSnapshotId)) {
          _selectedSnapshotId = snapshots.first.id;
        }
      });
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${direction == 'download' ? 'Pull' : 'Push'} queued for $table on $clientName.')),
      );
      await _refreshState(silent: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  String _formatTimestamp(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return raw.isEmpty ? 'Never' : raw;
    }
    final local = parsed.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
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

  int get _onlineAgents =>
      _state?.agents.where((agent) => agent.isOnline).length ?? 0;

  int get _enabledTables =>
      _state?.agents.fold<int>(
            0,
            (count, agent) =>
                count + agent.tables.where((table) => table.enabled).length,
          ) ??
      0;

  List<AdminJob> get _jobs => _state?.jobs ?? const [];

  List<AdminSnapshot> get _snapshots => _state?.snapshots ?? const [];

  AdminSnapshot? get _selectedSnapshot {
    if (_snapshots.isEmpty) {
      return null;
    }
    return _snapshots.firstWhere(
      (snapshot) => snapshot.id == _selectedSnapshotId,
      orElse: () => _snapshots.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1180;
        final contentWidth = isWide ? 1360.0 : 860.0;
        final state = _state;

        return Scaffold(
          body: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0xFFF6F7F3)),
            child: Align(
              alignment: Alignment.topCenter,
              child: RefreshIndicator(
                onRefresh: _refreshState,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: contentWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DashboardHeader(
                          isConnected: _connected,
                          lastUpdated: _formatTimestamp(
                            state?.generatedAt ?? '',
                          ),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            SummaryCard(
                              title: 'Online agents',
                              value:
                                  '$_onlineAgents/${state?.agents.length ?? 0}',
                              detail:
                                  'Windows agents with a recent heartbeat in the control plane.',
                            ),
                            SummaryCard(
                              title: 'Active sync jobs',
                              value:
                                  _jobs.where((job) => job.isActive).length.toString(),
                              detail:
                                  'Snapshot uploads or downloads still running right now.',
                            ),
                            SummaryCard(
                              title: 'Enabled tables',
                              value: _enabledTables.toString(),
                              detail:
                                  'Tables currently marked to sync with the remote control plane.',
                            ),
                            SummaryCard(
                              title: 'Latest snapshot',
                              value:
                                  _selectedSnapshot == null
                                      ? 'None'
                                      : _formatTimestamp(
                                        _selectedSnapshot!.createdAt,
                                      ),
                              detail:
                                  'Most recent table snapshot visible to the admin web app.',
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        if (_error != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF1F1),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: const Color(0xFFF2C5C5)),
                            ),
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Color(0xFFC53030)),
                            ),
                          ),
                        if (_loading && state == null)
                          const Padding(
                            padding: EdgeInsets.only(top: 80),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (isWide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 7,
                                child: Column(
                                  children: [
                                    _buildAgentsSection(state),
                                    const SizedBox(height: 18),
                                    _buildSnapshotsSection(),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 18),
                              Expanded(
                                flex: 5,
                                child: _buildJobsSection(),
                              ),
                            ],
                          )
                        else
                          Column(
                            children: [
                              _buildAgentsSection(state),
                              const SizedBox(height: 18),
                              _buildJobsSection(),
                              const SizedBox(height: 18),
                              _buildSnapshotsSection(),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAgentsSection(AdminLiveState? state) {
    final agents = state?.agents ?? const <AdminAgent>[];

    return SurfaceCard(
      title: 'Live agent sync',
      subtitle:
          'Only live machine state is shown here. Table rows, sync status, and progress all come from the backend heartbeat stream.',
      child: agents.isEmpty
          ? const Text('No agents have registered with the control plane yet.')
          : Column(
              children: agents
                  .map(
                    (agent) => Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FBF7),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE1E7DE)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                agent.clientName,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              StatusBadge(
                                label: agent.isOnline ? 'Online' : 'Offline',
                                color:
                                    agent.isOnline
                                        ? const Color(0xFF2F855A)
                                        : const Color(0xFFC53030),
                              ),
                              StatusBadge(
                                label:
                                    agent.sqlConnected ? 'SQL ready' : 'SQL down',
                                color:
                                    agent.sqlConnected
                                        ? const Color(0xFF1F5561)
                                        : const Color(0xFFD69E2E),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Server ${agent.server.isEmpty ? 'not set' : agent.server} | Database ${agent.database.isEmpty ? 'not selected' : agent.database} | Last heartbeat ${_formatTimestamp(agent.lastHeartbeat)}',
                            style: const TextStyle(color: Color(0xFF5E6C73)),
                          ),
                          const SizedBox(height: 14),
                          if (agent.tables.isEmpty)
                            const Text(
                              'No tables are loaded on this agent yet. Open the Table tab in the agent and load a database.',
                            )
                          else
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                headingRowColor: const WidgetStatePropertyAll(
                                  Color(0xFFE7ECE6),
                                ),
                                columns: const [
                                  DataColumn(label: Text('Sync')),
                                  DataColumn(label: Text('Table')),
                                  DataColumn(label: Text('Status')),
                                  DataColumn(label: Text('Progress')),
                                  DataColumn(label: Text('Rows')),
                                  DataColumn(label: Text('Last sync')),
                                  DataColumn(label: Text('Action')),
                                ],
                                rows: agent.tables
                                    .map(
                                      (table) => DataRow(
                                        cells: [
                                          DataCell(
                                            Icon(
                                              table.enabled
                                                  ? Icons.check_circle
                                                  : Icons.pause_circle,
                                              color:
                                                  table.enabled
                                                      ? const Color(0xFF2F855A)
                                                      : const Color(0xFF718096),
                                              size: 18,
                                            ),
                                          ),
                                          DataCell(Text(table.table)),
                                          DataCell(
                                            StatusBadge(
                                              label: table.status,
                                              color: _statusColor(table.status),
                                            ),
                                          ),
                                          DataCell(
                                            SizedBox(
                                              width: 140,
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  ProgressStrip(
                                                    progress: table.progress,
                                                    color: _statusColor(
                                                      table.status,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text('${table.progress}%'),
                                                ],
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Text(table.rowCount.toString()),
                                          ),
                                          DataCell(
                                            Text(_formatTimestamp(table.lastSync)),
                                          ),
                                          DataCell(
                                            Wrap(
                                              spacing: 8,
                                              children: [
                                                TextButton(
                                                  onPressed:
                                                      table.enabled
                                                          ? () => _triggerJob(
                                                            clientName:
                                                                agent.clientName,
                                                            table: table.table,
                                                            direction: 'upload',
                                                          )
                                                          : null,
                                                  child: const Text('Push'),
                                                ),
                                                TextButton(
                                                  onPressed:
                                                      table.enabled
                                                          ? () => _triggerJob(
                                                            clientName:
                                                                agent.clientName,
                                                            table: table.table,
                                                            direction:
                                                                'download',
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
                        ],
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }

  Widget _buildJobsSection() {
    return SurfaceCard(
      title: 'Sync progress',
      subtitle:
          'This feed shows queued, running, completed, and failed jobs exactly as the backend sees them.',
      child: _jobs.isEmpty
          ? const Text('No sync jobs have been recorded yet.')
          : Column(
              children: _jobs
                  .map(
                    (job) => Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FBF7),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFE1E7DE)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '${job.clientName} · ${job.table}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              StatusBadge(
                                label: job.status,
                                color: _statusColor(job.status),
                              ),
                              Text(
                                job.direction.toUpperCase(),
                                style: const TextStyle(
                                  color: Color(0xFF5E6C73),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ProgressStrip(
                            progress: job.progress,
                            color: _statusColor(job.status),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${job.progress}% · ${job.rowCount} rows · ${job.message}',
                            style: const TextStyle(height: 1.4),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Updated ${_formatTimestamp(job.updatedAt)}',
                            style: const TextStyle(color: Color(0xFF5E6C73)),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }

  Widget _buildSnapshotsSection() {
    final selectedSnapshot = _selectedSnapshot;

    return SurfaceCard(
      title: 'Latest snapshots',
      subtitle:
          'Each upload is a frozen snapshot. The web app previews the exact rows already stored by the backend, not sample data.',
      child: _snapshots.isEmpty
          ? const Text('No uploaded snapshots are available yet.')
          : LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 920;
                final list = _buildSnapshotList();
                final preview = _buildSnapshotPreview(selectedSnapshot);

                if (!isWide) {
                  return Column(
                    children: [
                      list,
                      const SizedBox(height: 16),
                      preview,
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 320, child: list),
                    const SizedBox(width: 18),
                    Expanded(child: preview),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildSnapshotList() {
    return Column(
      children: _snapshots
          .map(
            (snapshot) => InkWell(
              onTap: () {
                setState(() {
                  _selectedSnapshotId = snapshot.id;
                });
              },
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color:
                      snapshot.id == _selectedSnapshotId
                          ? const Color(0xFFEAF4F2)
                          : const Color(0xFFF9FBF7),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color:
                        snapshot.id == _selectedSnapshotId
                            ? const Color(0xFF7EB0A3)
                            : const Color(0xFFE1E7DE),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snapshot.table,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(snapshot.clientName),
                    const SizedBox(height: 6),
                    Text(
                      '${snapshot.rowCount} rows · ${_formatTimestamp(snapshot.createdAt)}',
                      style: const TextStyle(color: Color(0xFF5E6C73)),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildSnapshotPreview(AdminSnapshot? snapshot) {
    if (snapshot == null) {
      return const Text('Select a snapshot to preview the captured rows.');
    }

    if (snapshot.columns.isEmpty) {
      return const Text('The selected snapshot does not contain column metadata.');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FBF7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE1E7DE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${snapshot.clientName} · ${snapshot.table}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Snapshot created ${_formatTimestamp(snapshot.createdAt)} · ${snapshot.rowCount} rows',
            style: const TextStyle(color: Color(0xFF5E6C73)),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: const WidgetStatePropertyAll(Color(0xFFE7ECE6)),
              columns: snapshot.columns
                  .map((column) => DataColumn(label: Text(column)))
                  .toList(growable: false),
              rows: snapshot.previewRows
                  .map(
                    (row) => DataRow(
                      cells: List.generate(snapshot.columns.length, (index) {
                        final value = index < row.length ? row[index] : '';
                        return DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text(
                              value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      }),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }
}
