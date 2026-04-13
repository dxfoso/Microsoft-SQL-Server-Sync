import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'browser_bridge.dart';
import 'dashboard_widgets.dart';
import 'live_sync_api.dart';
import 'models.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({
    super.key,
    required this.authenticatedEmail,
    required this.onLogout,
  });

  final String authenticatedEmail;
  final VoidCallback onLogout;

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage>
    with SingleTickerProviderStateMixin {
  final LiveSyncApiClient _api = LiveSyncApiClient();
  final TextEditingController _syncSearchController = TextEditingController();
  final TextEditingController _dataSearchController = TextEditingController();
  Timer? _refreshTimer;
  late final TabController _tabController;

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
  final Set<String> _busyBackupKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_handleTabChange);
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
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _syncSearchController.removeListener(_handleSearchChange);
    _dataSearchController.removeListener(_handleSearchChange);
    _syncSearchController.dispose();
    _dataSearchController.dispose();
    _api.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (!mounted || _tabController.indexIsChanging) {
      return;
    }
    setState(() {});
  }

  void _handleSearchChange() {
    if (!mounted) {
      return;
    }
    setState(() {});
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

      final nextClientName = _resolveSelectedClient(nextState);
      final nextTableName = _resolveSelectedTable(nextState, nextClientName);

      setState(() {
        _state = nextState;
        _selectedClientName = nextClientName;
        _selectedTableName = nextTableName;
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

  String? _resolveSelectedClient(AdminLiveState state) {
    if (state.agents.isEmpty) {
      return null;
    }
    if (_selectedClientName != null &&
        state.agents.any((agent) => agent.clientName == _selectedClientName)) {
      return _selectedClientName;
    }
    return state.agents.first.clientName;
  }

  String? _resolveSelectedTable(AdminLiveState state, String? clientName) {
    final agent = _agentByName(state, clientName);
    if (agent == null || agent.tables.isEmpty) {
      return null;
    }
    if (_selectedTableName != null &&
        agent.tables.any((table) => table.table == _selectedTableName)) {
      return _selectedTableName;
    }
    final preferredTable = agent.selectedTable;
    if (preferredTable != null &&
        agent.tables.any((table) => table.table == preferredTable)) {
      return preferredTable;
    }
    return agent.tables.first.table;
  }

  AdminAgent? _agentByName(AdminLiveState? state, String? clientName) {
    if (state == null || clientName == null) {
      return null;
    }
    for (final agent in state.agents) {
      if (agent.clientName == clientName) {
        return agent;
      }
    }
    return null;
  }

  AdminAgent? get _selectedAgent => _agentByName(_state, _selectedClientName);

  List<AdminTableState> get _selectedTables =>
      _selectedAgent?.tables ?? const <AdminTableState>[];

  AdminTableState? get _selectedTableState {
    final tableName = _selectedTableName;
    if (tableName == null) {
      return null;
    }
    for (final table in _selectedTables) {
      if (table.table == tableName) {
        return table;
      }
    }
    return null;
  }

  List<AdminJob> get _jobs => _state?.jobs ?? const <AdminJob>[];

  Future<void> _loadSelectedSnapshot({bool force = false}) async {
    final agent = _selectedAgent;
    final tableName = _selectedTableName;
    final tableState = _selectedTableState;

    if (agent == null || tableName == null) {
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

    final nextKey = '${agent.clientName}::$tableName';
    final snapshotCreatedAt = tableState?.snapshotCreatedAt?.trim() ?? '';
    final nextVersion =
        snapshotCreatedAt.isNotEmpty
            ? snapshotCreatedAt
            : tableState?.lastSync.trim() ?? '';

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
        clientName: agent.clientName,
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
                ? 'No snapshot uploaded yet for $tableName. Trigger a Push from Sync Status after the agent loads the table.'
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
    if (clientName == null ||
        clientName == _selectedClientName ||
        _state == null) {
      return;
    }
    final nextTable = _resolveSelectedTable(_state!, clientName);
    setState(() {
      _selectedClientName = clientName;
      _selectedTableName = nextTable;
      _snapshot = null;
      _snapshotError = null;
    });
    unawaited(_loadSelectedSnapshot(force: true));
  }

  void _selectTable(String? tableName) {
    if (tableName == null || tableName == _selectedTableName) {
      return;
    }
    setState(() {
      _selectedTableName = tableName;
      _snapshot = null;
      _snapshotError = null;
    });
    unawaited(_loadSelectedSnapshot(force: true));
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

  List<AdminTableState> _filteredTables(List<AdminTableState> tables) {
    final query = _syncSearchController.text.trim();
    if (query.isEmpty) {
      return tables;
    }

    final matches = tables
      .map((table) {
        final score = _bestMatchScore(
          query,
          [
            table.table,
            table.status,
            table.message,
            table.direction,
            _formatTimestamp(table.lastSync),
          ].join(' '),
        );
        return _ScoredTableMatch(table: table, score: score);
      })
      .where((match) => match.score > 0)
      .toList(growable: false)..sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) {
        return byScore;
      }
      return left.table.table.compareTo(right.table.table);
    });

    return matches.map((match) => match.table).toList(growable: false);
  }

  List<_ScoredSnapshotRow> _filteredSnapshotRows(AdminSnapshotDetail snapshot) {
    final query = _dataSearchController.text.trim();
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
            score: query.isEmpty ? 1 : _bestMatchScore(query, rowText),
          );
        })
        .where((match) => match.score > 0)
        .toList(growable: false);

    if (query.isEmpty) {
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

  List<AdminJob> get _selectedTableJobs {
    final agent = _selectedAgent;
    final table = _selectedTableName;
    if (agent == null || table == null) {
      return const <AdminJob>[];
    }
    return _jobs
        .where(
          (job) => job.clientName == agent.clientName && job.table == table,
        )
        .take(12)
        .toList(growable: false);
  }

  AdminTableState? _tableStateForAgent(AdminAgent agent, String tableName) {
    for (final table in agent.tables) {
      if (table.table == tableName) {
        return table;
      }
    }
    return null;
  }

  List<AdminAgent> _agentsForTable(String? tableName) {
    if (_state == null || tableName == null) {
      return const <AdminAgent>[];
    }
    return _state!.agents
        .where((agent) => _tableStateForAgent(agent, tableName) != null)
        .toList(growable: false);
  }

  List<AdminJob> _tableJobsForClient(String clientName, String tableName) {
    return _jobs
        .where((job) => job.clientName == clientName && job.table == tableName)
        .take(8)
        .toList(growable: false);
  }

  void _focusClientTable(String clientName, String tableName) {
    if (_state == null) {
      return;
    }
    final agent = _agentByName(_state, clientName);
    if (agent == null || _tableStateForAgent(agent, tableName) == null) {
      return;
    }
    setState(() {
      _selectedClientName = clientName;
      _selectedTableName = tableName;
      _snapshot = null;
      _snapshotError = null;
    });
    unawaited(_loadSelectedSnapshot(force: true));
  }

  Widget _buildSelectionHeader() {
    final agent = _selectedAgent;
    final tables = _selectedTables;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 320,
            child: DropdownButtonFormField<String>(
              value: _selectedClientName,
              isExpanded: true,
              decoration: _selectionDecoration('Agent'),
              items: (_state?.agents ?? const <AdminAgent>[])
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.clientName,
                      child: Text(
                        item.clientName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged:
                  (_state?.agents ?? const <AdminAgent>[]).isEmpty
                      ? null
                      : _selectClient,
            ),
          ),
          SizedBox(
            width: 320,
            child: DropdownButtonFormField<String>(
              value: _selectedTableName,
              isExpanded: true,
              decoration: _selectionDecoration('Table'),
              items: tables
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.table,
                      child: Text(item.table, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(growable: false),
              onChanged: tables.isEmpty ? null : _selectTable,
            ),
          ),
          if (agent != null) ...[
            _buildRoleBadge(agent.isMaster),
            MetricPill(label: 'Machine', value: agent.machineName),
            MetricPill(
              label: 'Database',
              value: agent.database.isEmpty ? 'Not selected' : agent.database,
            ),
            MetricPill(
              label: 'Heartbeat',
              value: _formatTimestamp(agent.lastHeartbeat),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _selectionDecoration(String label) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      filled: true,
      fillColor: const Color(0xFFF6F7F5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFD9DDD8)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFD9DDD8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF7C8A7A)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
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

  Widget _buildTableDataTab() {
    final agent = _selectedAgent;
    if (agent == null) {
      return SurfaceCard(
        title: 'Table Data',
        subtitle:
            'Select an agent first. Table data comes from the latest uploaded snapshot for the selected table.',
        child: const EmptyStateCard(
          message:
              'No agents have registered yet. Open the Windows agent and let it connect before browsing table data here.',
        ),
      );
    }

    final tableState = _selectedTableState;
    final snapshot = _snapshot;
    final filteredRows =
        snapshot == null
            ? const <_ScoredSnapshotRow>[]
            : _filteredSnapshotRows(snapshot);

    return SurfaceCard(
      title: 'Table Data',
      subtitle:
          'Browse the latest uploaded snapshot for ${_selectedTableName ?? 'the selected table'}. Search ranks the best matching rows first.',
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(
            controller: _dataSearchController,
            label: 'Search Rows',
            hint:
                'Search across all visible columns for the best matching row.',
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              MetricPill(label: 'Agent', value: agent.clientName),
              MetricPill(label: 'Role', value: _roleLabel(agent.isMaster)),
              MetricPill(
                label: 'Rows',
                value:
                    snapshot == null
                        ? '${tableState?.rowCount ?? 0}'
                        : '${filteredRows.length} / ${snapshot.rowCount}',
              ),
              MetricPill(
                label: 'Last Sync',
                value: _formatTimestamp(tableState?.lastSync ?? ''),
              ),
              MetricPill(
                label: 'Snapshot',
                value:
                    snapshot == null
                        ? 'Not available'
                        : _formatTimestamp(snapshot.createdAt),
              ),
              MetricPill(
                label: 'Backup Size',
                value: _formatBytes(
                  snapshot?.snapshotBytes ?? tableState?.snapshotBytes ?? 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
      ),
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

  Widget _buildSyncStatusTab() {
    final agent = _selectedAgent;
    if (agent == null) {
      return SurfaceCard(
        title: 'Sync Status',
        subtitle:
            'Select an agent to inspect table sync progress and trigger uploads or downloads.',
        child: const EmptyStateCard(
          message:
              'No agents are available yet. Start the Windows agent first so the control plane has a machine to inspect.',
        ),
      );
    }

    final filteredTables = _filteredTables(_selectedTables);

    return SurfaceCard(
      title: 'Sync Status',
      subtitle:
          'This mirrors the Windows agent workflow: table sync state at the top, recent activity for the selected table below it.',
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(
            controller: _syncSearchController,
            label: 'Search Tables',
            hint:
                'Search table names, statuses, messages, and last sync times.',
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              MetricPill(label: 'Agent', value: agent.clientName),
              MetricPill(label: 'Role', value: _roleLabel(agent.isMaster)),
              MetricPill(
                label: 'SQL',
                value: agent.sqlConnected ? 'Ready' : 'Offline',
              ),
              MetricPill(
                label: 'Server',
                value: agent.server.isEmpty ? 'Not set' : agent.server,
              ),
              MetricPill(
                label: 'Tables',
                value: _selectedTables.length.toString(),
              ),
              MetricPill(
                label: 'Backup Size',
                value: _formatBytes(_selectedTableState?.snapshotBytes ?? 0),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                if (filteredTables.isEmpty)
                  EmptyStateCard(
                    message:
                        _syncSearchController.text.trim().isEmpty
                            ? 'No tables are loaded on this agent yet.'
                            : 'No tables matched your search.',
                  )
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      showCheckboxColumn: false,
                      headingRowColor: const WidgetStatePropertyAll(
                        Color(0xFFE7ECE6),
                      ),
                      columns: const [
                        DataColumn(label: Text('Sync')),
                        DataColumn(label: Text('Role')),
                        DataColumn(label: Text('Table')),
                        DataColumn(label: Text('Status')),
                        DataColumn(label: Text('Progress')),
                        DataColumn(label: Text('Rows')),
                        DataColumn(label: Text('Last Sync')),
                        DataColumn(label: Text('Backup')),
                        DataColumn(label: Text('Message')),
                        DataColumn(label: Text('Download')),
                        DataColumn(label: Text('Upload')),
                        DataColumn(label: Text('Sync')),
                      ],
                      rows: filteredTables
                          .map(
                            (table) => DataRow(
                              selected: table.table == _selectedTableName,
                              onSelectChanged: (_) => _selectTable(table.table),
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
                                DataCell(
                                  _buildRoleBadge(
                                    agent.isMaster,
                                    compact: true,
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
                                    width: 150,
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        ProgressStrip(
                                          progress: table.progress,
                                          color: _statusColor(table.status),
                                        ),
                                        const SizedBox(height: 6),
                                        Text('${table.progress}%'),
                                      ],
                                    ),
                                  ),
                                ),
                                DataCell(Text(table.rowCount.toString())),
                                DataCell(
                                  Text(_formatTimestamp(table.lastSync)),
                                ),
                                DataCell(
                                  Text(_formatBytes(table.snapshotBytes)),
                                ),
                                DataCell(
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 340,
                                    ),
                                    child: Text(
                                      table.message.isEmpty
                                          ? 'No sync message yet.'
                                          : table.message,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(
                                  IconButton(
                                    tooltip: 'Download backup file',
                                    onPressed:
                                        _isBackupBusy(
                                              agent.clientName,
                                              table.table,
                                            )
                                            ? null
                                            : () => _downloadSnapshotFile(
                                              clientName: agent.clientName,
                                              table: table.table,
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
                                              agent.clientName,
                                              table.table,
                                            )
                                            ? null
                                            : () => _uploadSnapshotFile(
                                              clientName: agent.clientName,
                                              table: table.table,
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
                                            table.enabled
                                                ? () => _triggerJob(
                                                  clientName: agent.clientName,
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
                                                  clientName: agent.clientName,
                                                  table: table.table,
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
                _buildTableClientOverview(),
                const SizedBox(height: 18),
                Text(
                  '${_selectedTableName ?? 'Selected table'} activity for ${_selectedAgent?.clientName ?? 'the selected client'}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                if (_selectedTableJobs.isEmpty)
                  const EmptyStateCard(
                    message:
                        'No sync jobs have been recorded yet for the selected table.',
                  )
                else
                  ..._selectedTableJobs.map(_buildJobCard),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJobCard(AdminJob job) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2D8CB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusBadge(label: job.status, color: _statusColor(job.status)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${job.direction.toUpperCase()} - ${job.table}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 6),
                ProgressStrip(
                  progress: job.progress,
                  color: _statusColor(job.status),
                ),
                const SizedBox(height: 8),
                Text(
                  job.message.isEmpty
                      ? 'No job message recorded.'
                      : job.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.35),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    Text(
                      '${job.progress}%',
                      style: const TextStyle(
                        color: Color(0xFF5F6B76),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${job.rowCount} rows',
                      style: const TextStyle(color: Color(0xFF5F6B76)),
                    ),
                    Text(
                      _formatBytes(job.snapshotBytes),
                      style: const TextStyle(color: Color(0xFF5F6B76)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTimestamp(job.updatedAt),
                style: const TextStyle(color: Color(0xFF5F6B76)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTableClientOverview() {
    final tableName = _selectedTableName;
    final agents = _agentsForTable(tableName);
    if (tableName == null) {
      return const EmptyStateCard(
        message: 'Select a table to compare that table across every client.',
      );
    }
    if (agents.isEmpty) {
      return EmptyStateCard(message: 'No clients are exposing $tableName yet.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$tableName across clients',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Text(
          'Click a client card to switch the history view below to that client and see whether it is running as master or slave.',
          style: const TextStyle(color: Color(0xFF58656B), height: 1.4),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: agents.map(_buildClientTableCard).toList(growable: false),
        ),
      ],
    );
  }

  Widget _buildClientTableCard(AdminAgent agent) {
    final tableName = _selectedTableName!;
    final tableState = _tableStateForAgent(agent, tableName)!;
    final selected = agent.clientName == _selectedClientName;
    final recentJobs = _tableJobsForClient(agent.clientName, tableName);
    final latestJob = recentJobs.isEmpty ? null : recentJobs.first;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _focusClientTable(agent.clientName, tableName),
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? const Color(0xFF1E6674) : const Color(0xFFD9DDD8),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    agent.clientName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _buildRoleBadge(agent.isMaster, compact: false),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                StatusBadge(
                  label: tableState.status,
                  color: _statusColor(tableState.status),
                ),
                MetricPill(
                  label: 'Last Sync',
                  value: _formatTimestamp(tableState.lastSync),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ProgressStrip(
              progress: tableState.progress,
              color: _statusColor(tableState.status),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                Text(
                  '${tableState.progress}%',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${tableState.rowCount} rows',
                  style: const TextStyle(color: Color(0xFF5F6B76)),
                ),
                Text(
                  _formatBytes(tableState.snapshotBytes),
                  style: const TextStyle(color: Color(0xFF5F6B76)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              tableState.message.isEmpty
                  ? 'No sync message yet.'
                  : tableState.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(height: 1.35),
            ),
            const SizedBox(height: 10),
            Text(
              latestJob == null
                  ? 'No recent history yet.'
                  : 'Latest: ${latestJob.direction.toUpperCase()} ${_formatTimestamp(latestJob.updatedAt)}',
              style: const TextStyle(
                color: Color(0xFF58656B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedSummaryBar() {
    final agent = _selectedAgent;
    final tableState = _selectedTableState;
    final footerItems =
        _tabController.index == 0
            ? <Widget>[
              InfoLine(label: 'Agent', value: agent?.clientName ?? 'None'),
              InfoLine(
                label: 'Role',
                value: agent == null ? 'None' : _roleLabel(agent.isMaster),
              ),
              InfoLine(label: 'Table', value: _selectedTableName ?? 'None'),
              InfoLine(
                label: 'Rows',
                value:
                    _snapshot == null
                        ? '${tableState?.rowCount ?? 0}'
                        : '${_filteredSnapshotRows(_snapshot!).length}/${_snapshot!.rowCount}',
              ),
              InfoLine(
                label: 'Last Sync',
                value: _formatTimestamp(tableState?.lastSync ?? ''),
              ),
              InfoLine(
                label: 'Backup',
                value: _formatBytes(tableState?.snapshotBytes ?? 0),
              ),
            ]
            : <Widget>[
              InfoLine(label: 'Agent', value: agent?.clientName ?? 'None'),
              InfoLine(
                label: 'Role',
                value: agent == null ? 'None' : _roleLabel(agent.isMaster),
              ),
              InfoLine(
                label: 'Tables',
                value: _selectedTables.length.toString(),
              ),
              InfoLine(label: 'Selected', value: _selectedTableName ?? 'None'),
              InfoLine(
                label: 'Progress',
                value: tableState == null ? '0%' : '${tableState.progress}%',
              ),
              InfoLine(label: 'Status', value: tableState?.status ?? 'Idle'),
              InfoLine(
                label: 'Last Sync',
                value: _formatTimestamp(tableState?.lastSync ?? ''),
              ),
              InfoLine(
                label: 'Backup',
                value: _formatBytes(tableState?.snapshotBytes ?? 0),
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
              ? 'Control plane connection status.'
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
        _selectedClientName == null
            ? 'SQL Sync Control Plane'
            : 'SQL Sync Control Plane - $_selectedClientName';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.table_rows), text: 'Table Data'),
            Tab(icon: Icon(Icons.sync), text: 'Sync Status'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout_rounded),
          ),
          IconButton(
            tooltip: 'Refresh now',
            onPressed: () => unawaited(_refreshState()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSelectionHeader(),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFFFFEEEE),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child:
                  _loading && state == null
                      ? const Center(child: CircularProgressIndicator())
                      : TabBarView(
                        controller: _tabController,
                        children: [_buildTableDataTab(), _buildSyncStatusTab()],
                      ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildPinnedSummaryBar(),
    );
  }
}

class _ScoredTableMatch {
  const _ScoredTableMatch({required this.table, required this.score});

  final AdminTableState table;
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
