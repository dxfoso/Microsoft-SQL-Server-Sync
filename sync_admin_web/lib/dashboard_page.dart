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
      final action = direction == 'download' ? 'Pull' : 'Push';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$action queued for $table on $clientName.')));
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

  List<AdminJob> get _jobs => _state?.jobs ?? const [];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1180;
        final contentWidth = isWide ? 1360.0 : 920.0;
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
                                child: _buildAgentsSection(state),
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
      title: 'Live sync',
      subtitle:
          'Only live machine state is shown here. Each enabled table is being synced from a frozen snapshot, not a mutable live query.',
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
                                '${job.clientName} - ${job.table}',
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
                            '${job.progress}% - ${job.rowCount} rows - ${job.message}',
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
}
