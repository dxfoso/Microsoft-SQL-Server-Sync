import 'package:flutter/material.dart';

import 'dashboard_widgets.dart';
import 'models.dart';
import 'sample_data.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final TextEditingController _planController = TextEditingController(
    text: 'finance-master-sync',
  );

  late final List<SyncRun> _history = List<SyncRun>.from(recentRuns);

  String _selectedSourceId = 'finance-hq';
  final Set<String> _selectedSinkIds = {'warehouse-01', 'branch-07'};
  final Set<String> _selectedTables = {
    'dbo.Customers',
    'dbo.Orders',
    'dbo.Inventory',
  };
  int _syncEveryMinutes = 5;
  bool _allowDeletes = false;
  bool _trackSchemaDrift = true;

  int get _onlineMachines =>
      machines.where((machine) => machine.isOnline).length;

  @override
  void dispose() {
    _planController.dispose();
    super.dispose();
  }

  void _savePlan() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Saved ${_planController.text} with ${_selectedTables.length} tables '
          'from ${_machineClientName(_selectedSourceId)} to ${_selectedSinkIds.length} sink machines.',
        ),
      ),
    );
  }

  void _runNow() {
    final sinks = _selectedSinkIds.map(_machineClientName).join(', ');
    setState(() {
      _history.insert(
        0,
        SyncRun(
          title: '${_machineClientName(_selectedSourceId)} -> $sinks',
          startedAt: 'now',
          outcome: SyncOutcome.success,
          message:
              '${_selectedTables.length} selected tables queued for immediate execution.',
        ),
      );
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Manual sync dispatched to the selected Windows agents.'),
      ),
    );
  }

  String _machineName(String id) {
    return machines.firstWhere((machine) => machine.id == id).name;
  }

  String _machineClientName(String id) {
    return machines.firstWhere((machine) => machine.id == id).clientName;
  }

  String _compactRows(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1120;
        final contentWidth = isWide ? 1320.0 : 760.0;

        return Scaffold(
          body: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0xFFF6F7F3)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: contentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HeroBanner(
                        onlineMachines: _onlineMachines,
                        totalMachines: machines.length,
                        selectedTables: _selectedTables.length,
                        syncEveryMinutes: _syncEveryMinutes,
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          MetricCard(
                            title: 'Online Agents',
                            value: '$_onlineMachines/${machines.length}',
                            detail:
                                'Windows agents currently reachable from the domain.',
                          ),
                          MetricCard(
                            title: 'Source Machine',
                            value: _machineName(_selectedSourceId),
                            detail:
                                'Primary machine used to read the source rows.',
                          ),
                          MetricCard(
                            title: 'Selected Sinks',
                            value: _selectedSinkIds.length.toString(),
                            detail:
                                'Targets that will receive the sync batches.',
                          ),
                          MetricCard(
                            title: 'Synced Clients',
                            value: machines.length.toString(),
                            detail:
                                'Client names reported from the Windows agents.',
                          ),
                          MetricCard(
                            title: 'Current Cadence',
                            value: 'Every $_syncEveryMinutes min',
                            detail:
                                'Recommended for near-real-time operational copies.',
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (isWide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 7,
                              child: Column(
                                children: [
                                  _buildPlanBuilder(),
                                  const SizedBox(height: 20),
                                  _buildRecentRuns(),
                                ],
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              flex: 5,
                              child: Column(
                                children: [
                                  _buildSyncedClients(),
                                  const SizedBox(height: 20),
                                  _buildMachineTopology(),
                                  const SizedBox(height: 20),
                                  _buildTableCatalog(),
                                  const SizedBox(height: 20),
                                  _buildArchitectureNote(),
                                ],
                              ),
                            ),
                          ],
                        )
                      else
                        Column(
                          children: [
                            _buildPlanBuilder(),
                            const SizedBox(height: 20),
                            _buildSyncedClients(),
                            const SizedBox(height: 20),
                            _buildMachineTopology(),
                            const SizedBox(height: 20),
                            _buildTableCatalog(),
                            const SizedBox(height: 20),
                            _buildRecentRuns(),
                            const SizedBox(height: 20),
                            _buildArchitectureNote(),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlanBuilder() {
    return SectionShell(
      title: 'Sync Plan Builder',
      subtitle:
          'Choose one source PC, multiple sink PCs, and the SQL tables to sync every five minutes.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _planController,
            decoration: const InputDecoration(
              labelText: 'Plan Name',
              hintText: 'finance-master-sync',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _selectedSourceId,
            decoration: const InputDecoration(labelText: 'Source PC'),
            items:
                machines
                    .where((machine) => machine.isOnline)
                    .map(
                      (machine) => DropdownMenuItem<String>(
                        value: machine.id,
                        child: Text('${machine.name} | ${machine.office}'),
                      ),
                    )
                    .toList(),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _selectedSourceId = value;
                _selectedSinkIds.remove(value);
              });
            },
          ),
          const SizedBox(height: 20),
          Text('Sink PCs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...machines
              .where((machine) => machine.id != _selectedSourceId)
              .map(
                (machine) => CheckboxListTile(
                  value: _selectedSinkIds.contains(machine.id),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(machine.name),
                  subtitle: Text('${machine.office} | ${machine.sqlInstance}'),
                  secondary: StatusPill(
                    label: machine.isOnline ? 'Online' : 'Offline',
                    color:
                        machine.isOnline
                            ? const Color(0xFF2F855A)
                            : const Color(0xFF9B2C2C),
                  ),
                  onChanged: (selected) {
                    setState(() {
                      if (selected ?? false) {
                        _selectedSinkIds.add(machine.id);
                      } else {
                        _selectedSinkIds.remove(machine.id);
                      }
                    });
                  },
                ),
              ),
          const SizedBox(height: 12),
          Text('Tables', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children:
                tables
                    .map(
                      (table) => FilterChip(
                        label: Text(table.name),
                        selected: _selectedTables.contains(table.name),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _selectedTables.add(table.name);
                            } else {
                              _selectedTables.remove(table.name);
                            }
                          });
                        },
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<int>(
            value: _syncEveryMinutes,
            decoration: const InputDecoration(labelText: 'Schedule'),
            items: const [
              DropdownMenuItem(value: 5, child: Text('Every 5 minutes')),
              DropdownMenuItem(value: 15, child: Text('Every 15 minutes')),
              DropdownMenuItem(value: 30, child: Text('Every 30 minutes')),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _syncEveryMinutes = value);
              }
            },
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Track schema drift'),
            subtitle: const Text(
              'Warn when column shape changes before next sync.',
            ),
            value: _trackSchemaDrift,
            onChanged: (value) => setState(() => _trackSchemaDrift = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow delete propagation'),
            subtitle: const Text(
              'Disable unless the sink databases should mirror deletes.',
            ),
            value: _allowDeletes,
            onChanged: (value) => setState(() => _allowDeletes = value),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF14324A),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Execution Preview',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${_machineName(_selectedSourceId)} will publish ${_selectedTables.length} table streams '
                  'to ${_selectedSinkIds.length} sink machines every $_syncEveryMinutes minutes.',
                  style: const TextStyle(color: Colors.white70, height: 1.4),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: _savePlan,
                      child: const Text('Save Plan'),
                    ),
                    OutlinedButton(
                      onPressed: _runNow,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      child: const Text('Run Sync Now'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncedClients() {
    return SectionShell(
      title: 'Synced Clients',
      subtitle:
          'These are the client names the Windows agents expose back to the control plane.',
      child: Column(
        children:
            machines
                .map(
                  (machine) => Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9F6F2),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFD7C6B3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        StatusPill(
                          label: machine.isOnline ? 'Online' : 'Offline',
                          color:
                              machine.isOnline
                                  ? const Color(0xFF2F855A)
                                  : const Color(0xFF9B2C2C),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                machine.clientName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text('${machine.name} | ${machine.office}'),
                              const SizedBox(height: 4),
                              Text(
                                'SQL: ${machine.sqlInstance}',
                                style: const TextStyle(
                                  color: Color(0xFF5F6B76),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
      ),
    );
  }

  Widget _buildMachineTopology() {
    return SectionShell(
      title: 'Machine Topology',
      subtitle:
          'These Windows agents connect to the central domain and expose local SQL Server sync capability.',
      child: Column(
        children:
            machines
                .map(
                  (machine) => Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9F6F2),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFD7C6B3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                machine.clientName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            StatusPill(
                              label: machine.isOnline ? 'Online' : 'Offline',
                              color:
                                  machine.isOnline
                                      ? const Color(0xFF2F855A)
                                      : const Color(0xFF9B2C2C),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('${machine.name} | ${machine.office}'),
                        const SizedBox(height: 8),
                        Text(
                          'SQL instance: ${machine.sqlInstance}',
                          style: const TextStyle(color: Color(0xFF5F6B76)),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Last heartbeat: ${machine.lastHeartbeat}',
                          style: const TextStyle(color: Color(0xFF5F6B76)),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children:
                              machine.tags
                                  .map(
                                    (tag) => Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(tag),
                                    ),
                                  )
                                  .toList(),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
      ),
    );
  }

  Widget _buildTableCatalog() {
    return SectionShell(
      title: 'Table Catalog',
      subtitle:
          'Each table should have a stable primary key and a reliable change marker.',
      child: Column(
        children:
            tables
                .map(
                  (table) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(table.name),
                    subtitle: Text(
                      'PK: ${table.primaryKey} | Change marker: ${table.changeColumn}',
                    ),
                    trailing: Text(
                      _compactRows(table.estimatedRows),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                )
                .toList(),
      ),
    );
  }

  Widget _buildRecentRuns() {
    return SectionShell(
      title: 'Recent Runs',
      subtitle:
          'A quick operator view of the last sync executions and retry situations.',
      child: Column(
        children:
            _history
                .map(
                  (run) => Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE2D8CB)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutcomeDot(outcome: run.outcome),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                run.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(run.message),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          run.startedAt,
                          style: const TextStyle(color: Color(0xFF5F6B76)),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
      ),
    );
  }

  Widget _buildArchitectureNote() {
    return const SectionShell(
      title: 'Architecture Note',
      subtitle:
          'The web app is the control plane. The browser never talks directly to SQL Server running on a user PC.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Install the Windows agent on each machine that hosts Microsoft SQL Server. '
            'That agent stores the local SQL credentials, registers with your central domain, '
            'and performs the sync job every five minutes.',
          ),
          SizedBox(height: 12),
          Text(
            'For production, add a backend API that stores sync plans, authenticates agents, '
            'queues jobs, tracks history, and optionally pushes commands over WebSocket or SignalR.',
          ),
        ],
      ),
    );
  }
}
