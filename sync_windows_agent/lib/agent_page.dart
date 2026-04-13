import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'agent_widgets.dart';
import 'live_sync_api.dart';
import 'sync_state.dart';

class AgentDashboardPage extends StatefulWidget {
  const AgentDashboardPage({
    super.key,
    this.autoLoadOnStart = true,
    required this.clientName,
    required this.onClientNameChanged,
    required this.initialSyncState,
    required this.onSyncStateChanged,
  });

  final bool autoLoadOnStart;
  final String clientName;
  final ValueChanged<String> onClientNameChanged;
  final SyncClientState initialSyncState;
  final ValueChanged<SyncClientState> onSyncStateChanged;

  @override
  State<AgentDashboardPage> createState() => _AgentDashboardPageState();
}

class _AgentDashboardPageState extends State<AgentDashboardPage>
    with SingleTickerProviderStateMixin {
  static const int _rowsPerPage = 25;
  static const Duration _syncPollInterval = Duration(seconds: 15);
  static const Duration _autoUploadInterval = Duration(minutes: 1);

  final TextEditingController _serverController = TextEditingController(
    text: 'localhost',
  );
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ScrollController _tableScrollController = ScrollController();
  final AgentControlPlaneClient _controlPlaneClient = AgentControlPlaneClient();
  late SyncClientState _syncState;
  late final TabController _tabController;
  Timer? _connectionCheckTimer;
  Timer? _syncPollTimer;

  final bool _useWindowsAuth = true;
  bool _rowsLoading = false;
  bool _hasMoreRows = false;
  String? _errorMessage;
  int? _sortColumnIndex;
  bool _sortAscending = true;
  String? _selectedSyncTable;
  int _totalTableRows = 0;
  bool _serverConnected = false;
  bool _checkingServerConnection = false;
  DateTime? _lastServerCheck;
  bool _syncLoopBusy = false;
  List<RemoteSyncJob> _activeJobs = const [];
  final Set<String> _processingJobIds = <String>{};
  final Set<String> _busyFileTables = <String>{};

  List<String> _databases = const [];
  String? _selectedDatabase;
  List<String> _tables = const [];
  String? _selectedTable;
  List<String> _tableColumns = const [];
  List<List<String>> _tableRows = const [];
  int _rowOffset = 0;

  @override
  void initState() {
    super.initState();
    _syncState = widget.initialSyncState;
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_onTabChanged);
    _tableScrollController.addListener(_onTableScroll);
    _connectionCheckTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_checkServerConnection()),
    );
    _syncPollTimer = Timer.periodic(
      _syncPollInterval,
      (_) => unawaited(_syncWithControlPlane()),
    );
    if (widget.autoLoadOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_refreshConnection(loadTables: true));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_checkServerConnection());
        unawaited(_syncWithControlPlane());
      }
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _connectionCheckTimer?.cancel();
    _syncPollTimer?.cancel();
    _controlPlaneClient.dispose();
    _serverController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _tableScrollController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted || _tabController.indexIsChanging) {
      return;
    }
    setState(() {});
  }

  Future<void> _checkServerConnection() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _checkingServerConnection = true;
    });

    final online = await _controlPlaneClient.checkHealth();

    if (!mounted) {
      return;
    }

    setState(() {
      _serverConnected = online;
      _checkingServerConnection = false;
      _lastServerCheck = DateTime.now();
    });
  }

  void _updateSyncTableState(String table, SyncTableState state) {
    final tables = Map<String, SyncTableState>.from(_syncState.tables);
    tables[table] = state;
    final nextState = _syncState.copyWith(tables: tables);
    setState(() {
      _syncState = nextState;
    });
    widget.onSyncStateChanged(nextState);
  }

  void _replaceSyncState(SyncClientState nextState) {
    setState(() {
      _syncState = nextState;
    });
    widget.onSyncStateChanged(nextState);
  }

  List<SyncHistoryEntry> _appendHistory(
    List<SyncHistoryEntry> current,
    SyncHistoryEntry entry,
  ) {
    final next = List<SyncHistoryEntry>.from(current)..insert(0, entry);
    if (next.length > 20) {
      next.removeRange(20, next.length);
    }
    return next;
  }

  void _updateSyncEnabledTable(String table, bool enabled) {
    final current = _syncState.tables[table] ?? _defaultSyncTableState(table);
    final now = DateTime.now().toIso8601String();
    final nextStatus = enabled ? 'Queued' : 'Paused';
    final nextHistory = _appendHistory(
      current.history,
      SyncHistoryEntry(
        timestamp: now,
        table: table,
        status: nextStatus,
        success: enabled,
        message:
            enabled
                ? 'Remote sync enabled for ${widget.clientName}.'
                : 'Remote sync paused for ${widget.clientName}.',
        direction: current.direction,
        rowCount: current.rowCount,
        progress: enabled ? 0 : current.progress,
        snapshotId: current.snapshotId,
        snapshotBytes: current.snapshotBytes,
      ),
    );
    _updateSyncTableState(
      table,
      current.copyWith(
        enabled: enabled,
        status: nextStatus,
        lastSync: enabled ? current.lastSync : now,
        progress: enabled ? 0 : current.progress,
        message:
            enabled
                ? 'Waiting for the next live snapshot upload.'
                : 'Sync disabled.',
        history: nextHistory,
      ),
    );
    if (enabled) {
      unawaited(_queueEnabledUploads(forceTables: {table}));
    }
  }

  SyncTableState _defaultSyncTableState(String table) {
    return SyncTableState(
      enabled: false,
      status: 'Paused',
      lastSync: '',
      progress: 0,
      direction: 'upload',
      rowCount: 0,
      snapshotId: null,
      snapshotCreatedAt: null,
      snapshotBytes: 0,
      message: 'Remote sync disabled.',
      history: const [],
    );
  }

  void _ensureSyncTablesLoaded(Iterable<String> tableNames) {
    final nextTables = Map<String, SyncTableState>.from(_syncState.tables);
    var changed = false;
    for (final table in tableNames) {
      if (!nextTables.containsKey(table)) {
        nextTables[table] = _defaultSyncTableState(table);
        changed = true;
      }
    }
    if (changed) {
      _replaceSyncState(_syncState.copyWith(tables: nextTables));
    }
  }

  @override
  void didUpdateWidget(covariant AgentDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clientName != widget.clientName) {
      _syncState = widget.initialSyncState;
      unawaited(_syncWithControlPlane());
    }
  }

  String? _selectedSyncTableName(List<String> tableNames) {
    if (_selectedSyncTable != null && tableNames.contains(_selectedSyncTable)) {
      return _selectedSyncTable;
    }
    return tableNames.isNotEmpty ? tableNames.first : null;
  }

  Future<void> _onTableScroll() async {
    if (!_tableScrollController.hasClients ||
        _rowsLoading ||
        !_hasMoreRows ||
        _selectedDatabase == null ||
        _selectedTable == null) {
      return;
    }
    final position = _tableScrollController.position.pixels;
    final max = _tableScrollController.position.maxScrollExtent;
    if (max <= 0 || position < max - 200) {
      return;
    }
    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: _selectedTable!,
      reset: false,
      orderByColumn:
          _sortColumnIndex != null && _sortColumnIndex! < _tableColumns.length
              ? _tableColumns[_sortColumnIndex!]
              : null,
      orderAscending: _sortAscending,
    );
  }

  Future<void> _refreshConnection({bool loadTables = true}) async {
    await _loadDatabases(profile: _activeProfile(), loadTables: loadTables);
  }

  Future<void> _loadDatabases({
    required _SqlConnectionProfile profile,
    bool loadTables = true,
    bool preserveSelection = true,
  }) async {
    final previousDatabase = _selectedDatabase;

    setState(() {
      _errorMessage = null;
      _selectedDatabase = preserveSelection ? _selectedDatabase : null;
      _tables = const [];
      _selectedTable = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _totalTableRows = 0;
    });

    final result = await _queryDatabases(profile: profile);
    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _errorMessage = result.errorText;
        _databases = const [];
        _selectedDatabase = null;
      });
      return;
    }

    var selectedDatabase = _selectedDatabase;
    if (!preserveSelection ||
        selectedDatabase == null ||
        !result.values.contains(selectedDatabase)) {
      selectedDatabase = _preferredDatabase(result.values);
    }

    setState(() {
      _databases = result.values;
      _selectedDatabase = selectedDatabase;
      if (selectedDatabase != previousDatabase) {
        _selectedTable = null;
      }
      _sortColumnIndex = null;
    });

    if (loadTables && selectedDatabase != null) {
      await _loadTables(
        profile: profile,
        database: selectedDatabase,
        autoLoadRows: true,
      );
    }
  }

  void _selectDatabase(String? database) {
    if (database == null || database == _selectedDatabase) {
      return;
    }

    setState(() {
      _selectedDatabase = database;
      _selectedTable = null;
      _tables = const [];
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _sortColumnIndex = null;
      _totalTableRows = 0;
    });

    unawaited(
      _loadTables(
        profile: _activeProfile(),
        database: database,
        autoLoadRows: true,
      ),
    );
  }

  Future<void> _loadTables({
    required _SqlConnectionProfile profile,
    required String database,
    bool autoLoadRows = false,
  }) async {
    setState(() {
      _errorMessage = null;
      _tables = const [];
      _selectedTable = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _sortColumnIndex = null;
      _totalTableRows = 0;
    });

    final result = await _queryTables(profile: profile, database: database);
    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _errorMessage = result.errorText;
      });
      return;
    }

    String? selectedTable = _selectedTable;
    if (selectedTable != null && !result.values.contains(selectedTable)) {
      selectedTable = null;
    }
    if (selectedTable == null && result.values.isNotEmpty) {
      selectedTable = result.values.first;
    }

    setState(() {
      _tables = result.values;
      _selectedTable = selectedTable;
    });
    _ensureSyncTablesLoaded(result.values);

    if (autoLoadRows && selectedTable != null) {
      await _loadTableRows(
        profile: profile,
        database: database,
        table: selectedTable,
        reset: true,
        orderByColumn: null,
        orderAscending: true,
      );
    }
    unawaited(_syncWithControlPlane());
  }

  String? _preferredDatabase(List<String> databases) {
    if (databases.contains('velvet')) {
      return 'velvet';
    }
    return databases.isNotEmpty ? databases.first : null;
  }

  void _selectTable(String? table) {
    if (table == null || _selectedDatabase == null) {
      return;
    }

    setState(() {
      _selectedTable = table;
      _errorMessage = null;
      _sortColumnIndex = null;
      _tableColumns = const [];
      _tableRows = const [];
      _hasMoreRows = false;
      _rowOffset = 0;
      _totalTableRows = 0;
    });

    unawaited(
      _loadTableRows(
        profile: _activeProfile(),
        database: _selectedDatabase!,
        table: table,
        reset: true,
        orderByColumn: null,
        orderAscending: true,
      ),
    );
  }

  Future<void> _loadTableRows({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required bool reset,
    required String? orderByColumn,
    required bool orderAscending,
  }) async {
    if (reset) {
      _rowOffset = 0;
      _hasMoreRows = true;
    } else if (!_hasMoreRows) {
      return;
    }

    if (_rowsLoading) {
      return;
    }

    setState(() {
      _rowsLoading = true;
      _errorMessage = null;
      if (reset) {
        _tableColumns = const [];
        _tableRows = const [];
      }
    });

    final result = await _queryTableRows(
      profile: profile,
      database: database,
      table: table,
      offset: _rowOffset,
      pageSize: _rowsPerPage,
      orderByColumn: orderByColumn,
      orderAscending: orderAscending,
    );

    if (!mounted) {
      return;
    }

    if (!result.success) {
      setState(() {
        _rowsLoading = false;
        _errorMessage = result.errorText;
        _hasMoreRows = false;
      });
      return;
    }

    final nextOffset = _rowOffset + result.rows.length;
    setState(() {
      _rowsLoading = false;
      _tableColumns = result.columns;
      _tableRows =
          reset
              ? List<List<String>>.from(result.rows)
              : <List<String>>[..._tableRows, ...result.rows];
      _rowOffset = nextOffset;
      _hasMoreRows = result.hasMoreRows;
      _totalTableRows = result.totalRows;
    });
  }

  Future<void> _reloadCurrentTableRows() async {
    if (_selectedDatabase == null || _selectedTable == null) {
      return;
    }

    final sortColumn =
        _sortColumnIndex != null && _sortColumnIndex! < _tableColumns.length
            ? _tableColumns[_sortColumnIndex!]
            : null;

    await _loadTableRows(
      profile: _activeProfile(),
      database: _selectedDatabase!,
      table: _selectedTable!,
      reset: true,
      orderByColumn: sortColumn,
      orderAscending: _sortAscending,
    );
  }

  Map<String, SyncTableState> _heartbeatTablesPayload() {
    if (_tables.isEmpty) {
      return _syncState.tables;
    }

    return Map<String, SyncTableState>.fromEntries(
      _tables.map(
        (table) => MapEntry(
          table,
          _syncState.tables[table] ?? _defaultSyncTableState(table),
        ),
      ),
    );
  }

  String _displayStatus(String status) {
    if (status.isEmpty) {
      return 'Idle';
    }
    final normalized = status.replaceAll('_', ' ').trim();
    return normalized.isEmpty
        ? 'Idle'
        : normalized[0].toUpperCase() + normalized.substring(1);
  }

  bool _isTableDueForUpload(SyncTableState state) {
    if (!state.enabled) {
      return false;
    }
    if (state.lastSync.trim().isEmpty) {
      return true;
    }
    final parsed = DateTime.tryParse(state.lastSync);
    if (parsed == null) {
      return true;
    }
    return DateTime.now().difference(parsed).abs() >= _autoUploadInterval;
  }

  void _applyRemoteJobState(
    RemoteSyncJob job, {
    bool appendHistory = false,
    bool success = true,
    String? overrideMessage,
  }) {
    setState(() {
      final nextJobs = <String, RemoteSyncJob>{
        for (final item in _activeJobs)
          if (item.id != job.id) item.id: item,
      };
      if (job.isActive) {
        nextJobs[job.id] = job;
      }
      _activeJobs = nextJobs.values.toList(growable: false);
    });

    final current =
        _syncState.tables[job.table] ?? _defaultSyncTableState(job.table);
    final timestamp = job.completedAt ?? job.snapshotCreatedAt ?? job.updatedAt;
    final nextStatus = _displayStatus(job.status);
    final nextMessage = overrideMessage ?? job.error ?? job.message;
    final nextState = current.copyWith(
      enabled: current.enabled,
      status: nextStatus,
      lastSync: timestamp.trim().isEmpty ? current.lastSync : timestamp,
      progress: job.progress,
      direction: job.direction,
      rowCount: job.rowCount,
      snapshotId: job.snapshotId,
      snapshotCreatedAt: job.snapshotCreatedAt ?? current.snapshotCreatedAt,
      snapshotBytes:
          job.snapshotBytes > 0 ? job.snapshotBytes : current.snapshotBytes,
      message: nextMessage,
      history:
          appendHistory
              ? _appendHistory(
                current.history,
                SyncHistoryEntry(
                  timestamp: timestamp,
                  table: job.table,
                  status: nextStatus,
                  success: success,
                  message: nextMessage,
                  direction: job.direction,
                  rowCount: job.rowCount,
                  progress: job.progress,
                  snapshotId: job.snapshotId,
                  snapshotBytes: job.snapshotBytes,
                ),
              )
              : current.history,
    );
    _updateSyncTableState(job.table, nextState);
  }

  bool _isFileBusy(String table) => _busyFileTables.contains(table);

  void _setFileBusy(String table, bool busy) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (busy) {
        _busyFileTables.add(table);
      } else {
        _busyFileTables.remove(table);
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

  _SnapshotFileDocument _createSnapshotFileDocument({
    required String clientName,
    required String table,
    required String createdAt,
    required int rowCount,
    required List<String> columns,
    required List<Map<String, String?>> rows,
    String? id,
    String checksum = '',
    String? sourceJobId,
  }) {
    return _SnapshotFileDocument(
      id: id ?? '${clientName}_${table}_${createdAt.hashCode}',
      clientName: clientName,
      table: table,
      createdAt: createdAt,
      rowCount: rowCount,
      checksum: checksum,
      snapshotBytes: 0,
      columns: columns,
      rows: rows,
      sourceJobId: sourceJobId,
    );
  }

  String _encodeSnapshotFileDocument(_SnapshotFileDocument document) {
    var snapshotBytes = 0;
    var encoded = jsonEncode(
      document.copyWith(snapshotBytes: snapshotBytes).toJson(),
    );

    for (var index = 0; index < 3; index += 1) {
      final nextBytes = utf8.encode(encoded).length;
      if (nextBytes == snapshotBytes) {
        snapshotBytes = nextBytes;
        break;
      }
      snapshotBytes = nextBytes;
      encoded = jsonEncode(
        document.copyWith(snapshotBytes: snapshotBytes).toJson(),
      );
    }

    return encoded;
  }

  String _backupFileName(String table, String createdAt) {
    String sanitize(String value) {
      final normalized = value
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
          .replaceAll(RegExp(r'-+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      return normalized.isEmpty ? 'snapshot' : normalized;
    }

    return '${sanitize(widget.clientName)}-${sanitize(table)}-${sanitize(createdAt)}.json';
  }

  Future<void> _exportTableBackup(String table) async {
    if (_selectedDatabase == null || _isFileBusy(table)) {
      return;
    }

    _setFileBusy(table, true);
    try {
      final snapshot = await _createTableSnapshot(
        profile: _activeProfile(),
        database: _selectedDatabase!,
        table: table,
      );
      if (!snapshot.success) {
        throw Exception(snapshot.errorText);
      }

      final document = _createSnapshotFileDocument(
        clientName: widget.clientName,
        table: table,
        createdAt: snapshot.snapshotCreatedAt,
        rowCount: snapshot.totalRows,
        columns: snapshot.columns,
        rows: snapshot.rows,
      );
      final content = _encodeSnapshotFileDocument(document);
      final bytes = utf8.encode(content).length;

      final location = await getSaveLocation(
        suggestedName: _backupFileName(table, snapshot.snapshotCreatedAt),
        acceptedTypeGroups: <XTypeGroup>[
          const XTypeGroup(label: 'JSON backup', extensions: <String>['json']),
        ],
      );
      if (location == null) {
        return;
      }

      await File(location.path).writeAsString(content);

      final current = _syncState.tables[table] ?? _defaultSyncTableState(table);
      final history = _appendHistory(
        current.history,
        SyncHistoryEntry(
          timestamp: DateTime.now().toIso8601String(),
          table: table,
          status: 'Backup saved',
          success: true,
          message: 'Saved a backup file with ${snapshot.totalRows} rows.',
          direction: 'file',
          rowCount: snapshot.totalRows,
          progress: current.progress,
          snapshotId: current.snapshotId,
          snapshotBytes: bytes,
        ),
      );
      _updateSyncTableState(
        table,
        current.copyWith(
          rowCount: snapshot.totalRows,
          snapshotCreatedAt: snapshot.snapshotCreatedAt,
          snapshotBytes: bytes,
          message: 'Backup file saved for $table.',
          history: history,
        ),
      );

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved backup file for $table.')));
    } catch (error) {
      final current = _syncState.tables[table] ?? _defaultSyncTableState(table);
      _updateSyncTableState(
        table,
        current.copyWith(
          status: 'Failed',
          message: error.toString(),
          history: _appendHistory(
            current.history,
            SyncHistoryEntry(
              timestamp: DateTime.now().toIso8601String(),
              table: table,
              status: 'Backup save failed',
              success: false,
              message: error.toString(),
              direction: 'file',
              rowCount: current.rowCount,
              progress: current.progress,
              snapshotId: current.snapshotId,
              snapshotBytes: current.snapshotBytes,
            ),
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      _setFileBusy(table, false);
    }
  }

  Future<void> _importTableBackup(String table) async {
    if (_selectedDatabase == null || _isFileBusy(table)) {
      return;
    }

    _setFileBusy(table, true);
    try {
      final pickedFile = await openFile(
        acceptedTypeGroups: <XTypeGroup>[
          const XTypeGroup(label: 'JSON backup', extensions: <String>['json']),
        ],
      );
      if (pickedFile == null) {
        return;
      }

      final content = await pickedFile.readAsString();
      final bytes = utf8.encode(content).length;
      final document = _SnapshotFileDocument.fromJson(
        Map<String, dynamic>.from(jsonDecode(content) as Map),
      );

      final snapshot = RemoteSnapshot(
        id: document.id,
        clientName: widget.clientName,
        table: table,
        createdAt: document.createdAt,
        rowCount: document.rowCount,
        checksum: document.checksum,
        snapshotBytes: bytes,
        columns: document.columns,
        rows: document.rows,
        sourceJobId: document.sourceJobId,
      );

      await _applySnapshotToTable(
        profile: _activeProfile(),
        database: _selectedDatabase!,
        table: table,
        snapshot: snapshot,
      );

      final current = _syncState.tables[table] ?? _defaultSyncTableState(table);
      final history = _appendHistory(
        current.history,
        SyncHistoryEntry(
          timestamp: DateTime.now().toIso8601String(),
          table: table,
          status: 'Backup applied',
          success: true,
          message: 'Applied a backup file with ${document.rowCount} rows.',
          direction: 'file',
          rowCount: document.rowCount,
          progress: current.progress,
          snapshotId: document.id,
          snapshotBytes: bytes,
        ),
      );
      _updateSyncTableState(
        table,
        current.copyWith(
          rowCount: document.rowCount,
          snapshotId: document.id,
          snapshotCreatedAt: document.createdAt,
          snapshotBytes: bytes,
          message: 'Backup file applied to $table.',
          history: history,
        ),
      );

      if (_selectedTable == table) {
        await _reloadCurrentTableRows();
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Applied backup file to $table.')));
    } catch (error) {
      final current = _syncState.tables[table] ?? _defaultSyncTableState(table);
      _updateSyncTableState(
        table,
        current.copyWith(
          status: 'Failed',
          message: error.toString(),
          history: _appendHistory(
            current.history,
            SyncHistoryEntry(
              timestamp: DateTime.now().toIso8601String(),
              table: table,
              status: 'Backup apply failed',
              success: false,
              message: error.toString(),
              direction: 'file',
              rowCount: current.rowCount,
              progress: current.progress,
              snapshotId: current.snapshotId,
              snapshotBytes: current.snapshotBytes,
            ),
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      _setFileBusy(table, false);
    }
  }

  Future<void> _queueEnabledUploads({Set<String>? forceTables}) async {
    if (_tables.isEmpty || _selectedDatabase == null) {
      return;
    }

    final activeTables = _activeJobs.map((job) => job.table).toSet();
    final dueTables = _tables
        .where((table) {
          final state =
              _syncState.tables[table] ?? _defaultSyncTableState(table);
          if (!state.enabled || activeTables.contains(table)) {
            return false;
          }
          return forceTables?.contains(table) ?? _isTableDueForUpload(state);
        })
        .toList(growable: false);

    if (dueTables.isEmpty) {
      return;
    }

    final queuedJobs = await _controlPlaneClient.createJobs(
      clientName: widget.clientName,
      tables: dueTables,
      direction: 'upload',
    );

    if (!mounted) {
      return;
    }

    setState(() {
      final merged = <String, RemoteSyncJob>{
        for (final job in _activeJobs) job.id: job,
        for (final job in queuedJobs) job.id: job,
      };
      _activeJobs = merged.values.toList(growable: false);
    });

    for (final job in queuedJobs) {
      _applyRemoteJobState(job);
    }
  }

  Future<void> _syncWithControlPlane() async {
    if (!mounted || _syncLoopBusy) {
      return;
    }

    _syncLoopBusy = true;
    try {
      final jobs = await _controlPlaneClient.heartbeat(
        clientName: widget.clientName,
        machineName: Platform.localHostname,
        server: _serverController.text.trim(),
        database: _selectedDatabase ?? '',
        serverConnected: _serverConnected,
        sqlConnected: _selectedDatabase != null,
        selectedTable: _selectedTable,
        tables: _heartbeatTablesPayload(),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _serverConnected = true;
        _checkingServerConnection = false;
        _lastServerCheck = DateTime.now();
        _activeJobs = jobs;
      });

      for (final job in jobs) {
        _applyRemoteJobState(job);
      }

      await _queueEnabledUploads();
      await _processPendingJobs();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _serverConnected = false;
        _checkingServerConnection = false;
        _lastServerCheck = DateTime.now();
        _errorMessage = error.toString();
      });
    } finally {
      _syncLoopBusy = false;
    }
  }

  Future<void> _processPendingJobs() async {
    final pendingJobs = _activeJobs
        .where((job) => job.isActive)
        .toList(growable: false);

    for (final job in pendingJobs) {
      if (_processingJobIds.contains(job.id)) {
        continue;
      }
      _processingJobIds.add(job.id);
      try {
        if (job.direction == 'download') {
          await _processDownloadJob(job);
        } else {
          await _processUploadJob(job);
        }
      } finally {
        _processingJobIds.remove(job.id);
      }
    }
  }

  Future<void> _processUploadJob(RemoteSyncJob job) async {
    try {
      var activeJob = await _controlPlaneClient.startJob(
        job.id,
        status: 'snapshotting',
        progress: 10,
        message: 'Creating a local snapshot before upload.',
      );
      _applyRemoteJobState(activeJob);

      final snapshot = await _createTableSnapshot(
        profile: _activeProfile(),
        database: _selectedDatabase ?? '',
        table: job.table,
      );

      if (!snapshot.success) {
        throw Exception(snapshot.errorText);
      }

      final backupFile = _createSnapshotFileDocument(
        clientName: widget.clientName,
        table: job.table,
        createdAt: snapshot.snapshotCreatedAt,
        rowCount: snapshot.totalRows,
        columns: snapshot.columns,
        rows: snapshot.rows,
      );
      final backupContent = _encodeSnapshotFileDocument(backupFile);
      final backupBytes = utf8.encode(backupContent).length;

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'uploading',
        progress: 70,
        message: 'Uploading snapshot to the control plane.',
        rowCount: snapshot.totalRows,
        direction: 'upload',
      );
      _applyRemoteJobState(activeJob);

      final uploadResult = await _controlPlaneClient.uploadSnapshot(
        job.id,
        clientName: widget.clientName,
        table: job.table,
        columns: snapshot.columns,
        rows: snapshot.rows,
        rowCount: snapshot.totalRows,
        snapshotCreatedAt: snapshot.snapshotCreatedAt,
        snapshotBytes: backupBytes,
      );

      _applyRemoteJobState(
        uploadResult.job,
        appendHistory: true,
        success: true,
      );
    } catch (error) {
      await _controlPlaneClient.failJob(
        job.id,
        error.toString(),
        progress: 100,
      );
      final failedJob = RemoteSyncJob(
        id: job.id,
        clientName: job.clientName,
        sourceClientName: job.sourceClientName,
        table: job.table,
        direction: job.direction,
        status: 'failed',
        progress: 100,
        rowCount: job.rowCount,
        createdAt: job.createdAt,
        updatedAt: DateTime.now().toIso8601String(),
        startedAt: job.startedAt,
        completedAt: DateTime.now().toIso8601String(),
        snapshotId: job.snapshotId,
        snapshotCreatedAt: job.snapshotCreatedAt,
        snapshotBytes: job.snapshotBytes,
        message: error.toString(),
        error: error.toString(),
      );
      _applyRemoteJobState(
        failedJob,
        appendHistory: true,
        success: false,
        overrideMessage: error.toString(),
      );
    }
  }

  Future<void> _processDownloadJob(RemoteSyncJob job) async {
    try {
      var activeJob = await _controlPlaneClient.startJob(
        job.id,
        status: 'snapshotting',
        progress: 10,
        message: 'Creating a local snapshot before download apply.',
      );
      _applyRemoteJobState(activeJob);

      final localSnapshot = await _createTableSnapshot(
        profile: _activeProfile(),
        database: _selectedDatabase ?? '',
        table: job.table,
      );
      if (!localSnapshot.success) {
        throw Exception(localSnapshot.errorText);
      }

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'downloading',
        progress: 40,
        message: 'Downloading the latest remote snapshot.',
        rowCount: localSnapshot.totalRows,
        direction: 'download',
      );
      _applyRemoteJobState(activeJob);

      final snapshot = await _controlPlaneClient.downloadSnapshot(job.id);

      activeJob = await _controlPlaneClient.updateJobProgress(
        job.id,
        status: 'applying',
        progress: 75,
        message: 'Applying the remote snapshot to local SQL Server.',
        rowCount: snapshot.rowCount,
        direction: 'download',
      );
      _applyRemoteJobState(activeJob);

      await _applySnapshotToTable(
        profile: _activeProfile(),
        database: _selectedDatabase ?? '',
        table: job.table,
        snapshot: snapshot,
      );

      activeJob = await _controlPlaneClient.completeJob(
        job.id,
        status: 'completed',
        progress: 100,
        message:
            'Applied snapshot ${snapshot.id} with ${snapshot.rowCount} rows to local SQL Server.',
        rowCount: snapshot.rowCount,
        snapshotId: snapshot.id,
        snapshotCreatedAt: snapshot.createdAt,
        snapshotBytes: snapshot.snapshotBytes,
      );

      _applyRemoteJobState(
        activeJob,
        appendHistory: true,
        success: true,
        overrideMessage:
            'Applied remote snapshot ${snapshot.id} with ${snapshot.rowCount} rows. Local pre-apply snapshot captured ${localSnapshot.totalRows} rows.',
      );
    } catch (error) {
      await _controlPlaneClient.failJob(
        job.id,
        error.toString(),
        progress: 100,
      );
      final failedJob = RemoteSyncJob(
        id: job.id,
        clientName: job.clientName,
        sourceClientName: job.sourceClientName,
        table: job.table,
        direction: job.direction,
        status: 'failed',
        progress: 100,
        rowCount: job.rowCount,
        createdAt: job.createdAt,
        updatedAt: DateTime.now().toIso8601String(),
        startedAt: job.startedAt,
        completedAt: DateTime.now().toIso8601String(),
        snapshotId: job.snapshotId,
        snapshotCreatedAt: job.snapshotCreatedAt,
        snapshotBytes: job.snapshotBytes,
        message: error.toString(),
        error: error.toString(),
      );
      _applyRemoteJobState(
        failedJob,
        appendHistory: true,
        success: false,
        overrideMessage: error.toString(),
      );
    }
  }

  Future<void> _applySnapshotToTable({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required RemoteSnapshot snapshot,
  }) async {
    if (database.isEmpty) {
      throw Exception(
        'Select a database before applying a downloaded snapshot.',
      );
    }

    final tableParts = _splitQualifiedName(table);
    final schemaResult = await _queryTableColumnSchemas(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!schemaResult.success) {
      throw Exception(schemaResult.errorText);
    }

    final schemas = schemaResult.values;
    if (schemas.isEmpty) {
      throw Exception('No column metadata was found for $table.');
    }

    final schemasByName = {for (final schema in schemas) schema.name: schema};
    final missingColumns =
        snapshot.columns
            .where((column) => !schemasByName.containsKey(column))
            .toList();
    if (missingColumns.isNotEmpty) {
      throw Exception(
        'Downloaded snapshot columns do not exist locally: ${missingColumns.join(', ')}',
      );
    }

    final hasIdentity = snapshot.columns.any(
      (column) => schemasByName[column]?.isIdentity ?? false,
    );
    final qualifiedTable = _quoteQualifiedIdentifier(table);
    final columnList = snapshot.columns.map(_quoteIdentifier).join(', ');
    final statements = <String>[
      'SET NOCOUNT ON;',
      'BEGIN TRY',
      'BEGIN TRAN;',
      'DELETE FROM $qualifiedTable;',
      if (hasIdentity) 'SET IDENTITY_INSERT $qualifiedTable ON;',
    ];

    const rowsPerBatch = 100;
    for (var index = 0; index < snapshot.rows.length; index += rowsPerBatch) {
      final chunk = snapshot.rows.skip(index).take(rowsPerBatch);
      final values = chunk
          .map(
            (row) =>
                '(${snapshot.columns.map((column) => _sqlLiteral(row[column])).join(', ')})',
          )
          .join(', ');
      if (values.isNotEmpty) {
        statements.add(
          'INSERT INTO $qualifiedTable ($columnList) VALUES $values;',
        );
      }
    }

    if (hasIdentity) {
      statements.add('SET IDENTITY_INSERT $qualifiedTable OFF;');
    }
    statements.add('COMMIT TRAN;');
    statements.add('END TRY');
    statements.add('BEGIN CATCH');
    statements.add('IF @@TRANCOUNT > 0 ROLLBACK TRAN;');
    statements.add('THROW;');
    statements.add('END CATCH;');

    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: statements.join(' '),
    );

    if (processResult == null) {
      throw Exception(
        'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      throw Exception(_sqlCmdFailed('download apply', processResult));
    }
  }

  Future<_TableSnapshotResult> _createTableSnapshot({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
  }) async {
    if (database.isEmpty || table.isEmpty) {
      return const _TableSnapshotResult(
        success: false,
        columns: [],
        rows: [],
        totalRows: 0,
        snapshotCreatedAt: '',
        errorText: 'Load a database and table before syncing.',
      );
    }

    final tableParts = _splitQualifiedName(table);
    final schemaResult = await _queryTableColumnSchemas(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!schemaResult.success || schemaResult.values.isEmpty) {
      return _TableSnapshotResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        snapshotCreatedAt: '',
        errorText:
            schemaResult.errorText ?? 'No columns were returned for $table.',
      );
    }
    final columns = schemaResult.values
        .map((schema) => schema.name)
        .toList(growable: false);

    final rowCountResult = await _queryTableRowCount(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!rowCountResult.success) {
      return _TableSnapshotResult(
        success: false,
        columns: columns,
        rows: const [],
        totalRows: 0,
        snapshotCreatedAt: '',
        errorText: rowCountResult.errorText,
      );
    }

    final orderByColumn = _quoteIdentifier(columns.first);
    final rows = <Map<String, String?>>[];
    const pageSize = 200;
    for (var offset = 0; offset < rowCountResult.value; offset += pageSize) {
      final pageResult = await _querySnapshotPage(
        profile: profile,
        database: database,
        table: table,
        columns: columns,
        orderByColumn: orderByColumn,
        offset: offset,
        pageSize: pageSize,
      );
      if (!pageResult.success) {
        return _TableSnapshotResult(
          success: false,
          columns: columns,
          rows: const [],
          totalRows: rowCountResult.value,
          snapshotCreatedAt: '',
          errorText: pageResult.errorText,
        );
      }
      rows.addAll(pageResult.rows);
    }

    return _TableSnapshotResult(
      success: true,
      columns: columns,
      rows: rows,
      totalRows: rowCountResult.value,
      snapshotCreatedAt: DateTime.now().toIso8601String(),
      errorText: null,
    );
  }

  Future<_StringQueryResult> _queryDatabases({
    required _SqlConnectionProfile profile,
  }) async {
    if (profile.server.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: 'Enter a SQL Server instance name.',
      );
    }

    final sql = 'SET NOCOUNT ON; SELECT name FROM sys.databases ORDER BY name;';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: 'master',
      query: sql,
    );
    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('database discovery', processResult),
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    if (values.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'No databases returned. Verify server access and permissions.',
      );
    }

    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_StringQueryResult> _queryTables({
    required _SqlConnectionProfile profile,
    required String database,
  }) async {
    if (database.isEmpty) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: 'Select a database first.',
      );
    }

    final query = '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
SELECT SCHEMA_NAME(schema_id) + '.' + name AS table_name
FROM sys.tables
ORDER BY table_name;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('table discovery', processResult),
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_TableRowsResult> _queryTableRows({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required int offset,
    required int pageSize,
    required String? orderByColumn,
    required bool orderAscending,
  }) async {
    if (database.isEmpty || table.isEmpty) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        hasMoreRows: false,
        errorText: 'Select database and table before loading rows.',
      );
    }

    final fetchSize = pageSize + 1;
    final tableParts = _splitQualifiedName(table);
    final columnsResult = await _queryTableColumns(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!columnsResult.success) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        hasMoreRows: false,
        errorText: columnsResult.errorText,
      );
    }

    final rowCountResult = await _queryTableRowCount(
      profile: profile,
      database: database,
      schema: tableParts.schema,
      table: tableParts.table,
    );
    if (!rowCountResult.success) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: 0,
        hasMoreRows: false,
        errorText: rowCountResult.errorText,
      );
    }

    final orderClause =
        orderByColumn == null || orderByColumn.isEmpty
            ? _quoteIdentifier(
              columnsResult.values.isNotEmpty
                  ? columnsResult.values.first
                  : '1',
            )
            : _quoteIdentifier(orderByColumn);
    final direction = orderAscending ? 'ASC' : 'DESC';

    final query = '''
SET NOCOUNT ON;
SELECT * FROM ${_quoteQualifiedIdentifier(table)}
ORDER BY $orderClause $direction
OFFSET $offset ROWS FETCH NEXT $fetchSize ROWS ONLY;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _TableRowsResult(
        success: false,
        columns: const [],
        rows: const [],
        totalRows: rowCountResult.value,
        hasMoreRows: false,
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _TableRowsResult(
        success: false,
        columns: columnsResult.values,
        rows: const [],
        totalRows: rowCountResult.value,
        hasMoreRows: false,
        errorText: _sqlCmdFailed('row fetch', processResult),
      );
    }

    return _parseTableOutput(
      output: processResult.stdout.toString(),
      columns: columnsResult.values,
      totalRows: rowCountResult.value,
      fetchSize: fetchSize,
    );
  }

  Future<_StringQueryResult> _queryTableColumns({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
SELECT COLUMN_NAME
FROM ${_quoteIdentifier(database)}.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = '${_escapeSqlLiteral(schema)}'
  AND TABLE_NAME = '${_escapeSqlLiteral(table)}'
ORDER BY ORDINAL_POSITION;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _StringQueryResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('column discovery', processResult),
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    return _StringQueryResult(success: true, values: values, errorText: null);
  }

  Future<_ColumnSchemaResult> _queryTableColumnSchemas({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
SELECT c.name, TYPE_NAME(c.user_type_id), c.is_nullable, c.is_identity
FROM ${_quoteIdentifier(database)}.sys.columns AS c
INNER JOIN ${_quoteIdentifier(database)}.sys.tables AS t ON t.object_id = c.object_id
INNER JOIN ${_quoteIdentifier(database)}.sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = '${_escapeSqlLiteral(schema)}'
  AND t.name = '${_escapeSqlLiteral(table)}'
ORDER BY c.column_id;
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return const _ColumnSchemaResult(
        success: false,
        values: [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _ColumnSchemaResult(
        success: false,
        values: const [],
        errorText: _sqlCmdFailed('column schema discovery', processResult),
      );
    }

    final values = <_TableColumnSchema>[];
    final lines = processResult.stdout.toString().split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      final parts = _splitRowValues(trimmedLine);
      if (parts.length < 4) {
        continue;
      }
      values.add(
        _TableColumnSchema(
          name: parts[0],
          sqlType: parts[1],
          isNullable: parts[2] == '1' || parts[2].toLowerCase() == 'true',
          isIdentity: parts[3] == '1' || parts[3].toLowerCase() == 'true',
        ),
      );
    }

    return _ColumnSchemaResult(success: true, values: values, errorText: null);
  }

  Future<_IntQueryResult> _queryTableRowCount({
    required _SqlConnectionProfile profile,
    required String database,
    required String schema,
    required String table,
  }) async {
    final query = '''
SET NOCOUNT ON;
SELECT COUNT_BIG(1) AS row_count
FROM ${_quoteIdentifier(database)}.${_quoteIdentifier(schema)}.${_quoteIdentifier(table)};
''';
    final processResult = await _runSqlCmd(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return const _IntQueryResult(
        success: false,
        value: 0,
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _IntQueryResult(
        success: false,
        value: 0,
        errorText: _sqlCmdFailed('row count lookup', processResult),
      );
    }

    final values = _parseSingleColumnOutput(processResult.stdout.toString());
    final parsed = values.isNotEmpty ? int.tryParse(values.first) : null;
    if (parsed == null) {
      return const _IntQueryResult(
        success: false,
        value: 0,
        errorText: 'Unable to read table row count from SQL Server.',
      );
    }

    return _IntQueryResult(success: true, value: parsed, errorText: null);
  }

  Future<_SnapshotPageResult> _querySnapshotPage({
    required _SqlConnectionProfile profile,
    required String database,
    required String table,
    required List<String> columns,
    required String orderByColumn,
    required int offset,
    required int pageSize,
  }) async {
    final query = '''
SET NOCOUNT ON;
WITH page_source AS (
  SELECT * FROM ${_quoteQualifiedIdentifier(table)}
  ORDER BY $orderByColumn ASC
  OFFSET $offset ROWS FETCH NEXT $pageSize ROWS ONLY
)
SELECT (
  SELECT * FROM page_source FOR JSON PATH, INCLUDE_NULL_VALUES
) AS snapshot_json;
''';
    final processResult = await _runSqlCmdJson(
      profile: profile,
      database: database,
      query: query,
    );

    if (processResult == null) {
      return const _SnapshotPageResult(
        success: false,
        rows: [],
        errorText:
            'sqlcmd is not available. Install SQL Server Command Line Utilities.',
      );
    }
    if (processResult.exitCode != 0) {
      return _SnapshotPageResult(
        success: false,
        rows: const [],
        errorText: _sqlCmdFailed('snapshot page fetch', processResult),
      );
    }

    final jsonText = _parseJsonScalarOutput(processResult.stdout.toString());
    if (jsonText.isEmpty || jsonText == 'null') {
      return const _SnapshotPageResult(
        success: true,
        rows: [],
        errorText: null,
      );
    }

    final decoded = jsonDecode(jsonText);
    if (decoded is! List) {
      return const _SnapshotPageResult(
        success: false,
        rows: [],
        errorText: 'Snapshot page did not return a JSON array.',
      );
    }

    final rows = decoded
        .map(
          (row) => _normalizeSnapshotRowMap(
            Map<String, dynamic>.from(row as Map),
            columns,
          ),
        )
        .toList(growable: false);
    return _SnapshotPageResult(success: true, rows: rows, errorText: null);
  }

  String _formatSqlError(ProcessResult processResult) {
    final details = <String>[];
    final stdout = processResult.stdout.toString().trim();
    final stderr = processResult.stderr.toString().trim();
    if (stdout.isNotEmpty) {
      details.add('stdout: $stdout');
    }
    if (stderr.isNotEmpty) {
      details.add('stderr: $stderr');
    }
    return details.isEmpty ? 'No output returned.' : details.join('\n');
  }

  String _sqlCmdFailed(String phase, ProcessResult processResult) {
    return 'sqlcmd failed during $phase (exit ${processResult.exitCode}): '
        '${_formatSqlError(processResult)}';
  }

  Future<ProcessResult?> _runSqlCmd({
    required _SqlConnectionProfile profile,
    String? database,
    required String query,
  }) async {
    final normalizedQuery = query
        .trim()
        .replaceAll('\r\n', ' ')
        .replaceAll('\n', ' ');
    final arguments = <String>[
      '-S',
      profile.server,
      if (database != null && database.isNotEmpty) ...['-d', database],
      '-b',
      '-h',
      '-1',
      '-W',
      '-w',
      '32767',
      '-s',
      '|',
      '-Q',
      normalizedQuery,
    ];

    if (profile.useWindowsAuth) {
      arguments.insert(0, '-E');
    } else {
      if (profile.user.isEmpty || profile.password.isEmpty) {
        return null;
      }
      arguments.insertAll(0, ['-U', profile.user, '-P', profile.password]);
    }

    try {
      return await Process.run(
        'sqlcmd',
        arguments,
        runInShell: false,
        stdoutEncoding: SystemEncoding(),
        stderrEncoding: SystemEncoding(),
      );
    } on ProcessException {
      return null;
    }
  }

  Future<ProcessResult?> _runSqlCmdJson({
    required _SqlConnectionProfile profile,
    String? database,
    required String query,
  }) async {
    final normalizedQuery = query
        .trim()
        .replaceAll('\r\n', ' ')
        .replaceAll('\n', ' ');
    final arguments = <String>[
      '-S',
      profile.server,
      if (database != null && database.isNotEmpty) ...['-d', database],
      '-b',
      '-w',
      '65535',
      '-y',
      '0',
      '-Q',
      normalizedQuery,
    ];

    if (profile.useWindowsAuth) {
      arguments.insert(0, '-E');
    } else {
      if (profile.user.isEmpty || profile.password.isEmpty) {
        return null;
      }
      arguments.insertAll(0, ['-U', profile.user, '-P', profile.password]);
    }

    try {
      return await Process.run(
        'sqlcmd',
        arguments,
        runInShell: false,
        stdoutEncoding: SystemEncoding(),
        stderrEncoding: SystemEncoding(),
      );
    } on ProcessException {
      return null;
    }
  }

  String _quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

  String _escapeSqlLiteral(String value) => value.replaceAll("'", "''");

  String _sqlLiteral(String? value) {
    if (value == null) {
      return 'NULL';
    }
    return "N'${_escapeSqlLiteral(value)}'";
  }

  _QualifiedTableName _splitQualifiedName(String qualifiedName) {
    final parts = qualifiedName.split('.');
    if (parts.length >= 2) {
      return _QualifiedTableName(schema: parts.first, table: parts.last);
    }
    return _QualifiedTableName(schema: 'dbo', table: qualifiedName);
  }

  String _quoteQualifiedIdentifier(String qualifiedName) =>
      qualifiedName.split('.').map(_quoteIdentifier).join('.');

  List<String> _splitRowValues(String line) =>
      line.split('|').map((value) => value.trim()).toList();

  bool _isSkippableOutputLine(String line) {
    if (line.isEmpty) return true;
    final normalized = line.toLowerCase();
    return line.startsWith('---') ||
        line.startsWith('(') ||
        normalized.contains('changed database context') ||
        normalized.contains('row') && normalized.contains('affected') ||
        normalized.contains('command') && normalized.contains('completed');
  }

  String _parseJsonScalarOutput(String output) {
    final buffer = StringBuffer();
    final lines = output.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      buffer.write(trimmedLine);
    }
    return buffer.toString().trim();
  }

  Map<String, String?> _normalizeSnapshotRowMap(
    Map<String, dynamic> row,
    List<String> columns,
  ) {
    return Map<String, String?>.fromEntries(
      columns.map(
        (column) => MapEntry(column, _normalizeSnapshotValue(row[column])),
      ),
    );
  }

  String? _normalizeSnapshotValue(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value ? '1' : '0';
    }
    return value.toString();
  }

  List<String> _parseSingleColumnOutput(String output) {
    final values = <String>[];
    final lines = output.split(RegExp(r'\r?\n'));

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }
      final split = _splitRowValues(trimmedLine);
      if (split.isNotEmpty) {
        values.add(split.first);
      }
    }

    return values;
  }

  _TableRowsResult _parseTableOutput({
    required String output,
    required List<String> columns,
    required int totalRows,
    required int fetchSize,
  }) {
    final lines = output.split(RegExp(r'\r?\n'));
    final rows = <List<String>>[];

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (_isSkippableOutputLine(trimmedLine)) {
        continue;
      }

      final split = _splitRowValues(trimmedLine);
      if (split.length == columns.length) {
        rows.add(split);
      } else {
        final padded = List<String>.from(split);
        while (padded.length < columns.length) {
          padded.add('');
        }
        rows.add(padded.take(columns.length).toList());
      }
    }

    var hasMoreRows = false;
    if (rows.length > fetchSize - 1) {
      rows.removeRange(fetchSize - 1, rows.length);
      hasMoreRows = true;
    }

    return _TableRowsResult(
      success: true,
      columns: columns,
      rows: rows,
      totalRows: totalRows,
      hasMoreRows: hasMoreRows,
      errorText: null,
    );
  }

  _SqlConnectionProfile _activeProfile() => _SqlConnectionProfile(
    server: _serverController.text.trim(),
    useWindowsAuth: _useWindowsAuth,
    user: _userController.text.trim(),
    password: _passwordController.text,
  );

  Future<void> _openSettingsDialog() async {
    final clientNameController = TextEditingController(text: widget.clientName);
    final serverController = TextEditingController(
      text: _serverController.text,
    );

    _SqlConnectionProfile readDialogProfile() => _SqlConnectionProfile(
      server: serverController.text.trim(),
      useWindowsAuth: _useWindowsAuth,
      user: _userController.text.trim(),
      password: _passwordController.text,
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: const Text('Settings'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: clientNameController,
                        decoration: _compactInputDecoration('Client Name'),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _InfoLine(
                            label: 'Auth',
                            value: _useWindowsAuth ? 'Windows' : 'SQL',
                          ),
                          _InfoLine(
                            label: 'Server',
                            value:
                                serverController.text.trim().isEmpty
                                    ? 'Not set'
                                    : serverController.text.trim(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final dialogProfile = readDialogProfile();
                    final clientName =
                        clientNameController.text.trim().isEmpty
                            ? 'Local Agent'
                            : clientNameController.text.trim();

                    setState(() {
                      _serverController.text = dialogProfile.server;
                      _databases = const [];
                      _selectedDatabase = null;
                      _tables = const [];
                      _selectedTable = null;
                      _tableColumns = const [];
                      _tableRows = const [];
                      _hasMoreRows = false;
                      _rowOffset = 0;
                      _errorMessage = null;
                    });
                    Navigator.of(context).pop();
                    widget.onClientNameChanged(clientName);

                    await _loadDatabases(
                      profile: dialogProfile,
                      loadTables: true,
                      preserveSelection: false,
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    clientNameController.dispose();
    serverController.dispose();
  }

  Widget _buildTablePanel() {
    if (_databases.isEmpty && _selectedDatabase == null) {
      return Center(
        child: Text(
          'Open the settings dialog to read database metadata.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child:
              _selectedTable == null
                  ? Center(
                    child: Text(
                      _tables.isEmpty
                          ? 'Load tables from the selected database.'
                          : 'Select a table to view data.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  )
                  : _buildSpreadsheetTable(),
        ),
      ],
    );
  }

  Widget _buildSyncPanel() {
    final syncRows = _tables
        .map((table) {
          final state =
              _syncState.tables[table] ?? _defaultSyncTableState(table);
          return (table: table, state: state);
        })
        .toList(growable: false);

    if (syncRows.isEmpty) {
      return AgentSectionShell(
        title: 'Sync',
        subtitle:
            'Load a database on the Table tab first. The live sync page only shows real SQL tables from the selected database.',
        child: const Text(
          'No live tables are available yet. Open the Table tab, choose a database, and let the agent read the table list.',
        ),
      );
    }

    final selectedTableName = _selectedSyncTableName(
      syncRows.map((row) => row.table).toList(growable: false),
    );
    final selectedRow = syncRows.firstWhere(
      (row) => row.table == selectedTableName,
      orElse: () => syncRows.first,
    );
    final historyEntries = List<SyncHistoryEntry>.from(
      selectedRow.state.history,
    )..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return AgentSectionShell(
      title: 'Sync',
      subtitle:
          'Live sync status, backup size, and table file actions for ${widget.clientName}. Every enabled table is snapshotted locally before any upload or download step.',
      scrollChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(const Color(0xFFE7ECE6)),
              dataRowMinHeight: 48,
              dataRowMaxHeight: 56,
              columns: const [
                DataColumn(label: Text('Sync')),
                DataColumn(label: Text('Table')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Progress')),
                DataColumn(label: Text('Rows')),
                DataColumn(label: Text('Last Sync')),
                DataColumn(label: Text('Backup')),
                DataColumn(label: Text('File')),
                DataColumn(label: Text('Message')),
              ],
              rows:
                  syncRows
                      .map(
                        (row) => DataRow(
                          selected: row.table == selectedTableName,
                          onSelectChanged: (_) {
                            setState(() {
                              _selectedSyncTable = row.table;
                            });
                          },
                          cells: [
                            DataCell(
                              Checkbox(
                                value: row.state.enabled,
                                onChanged: (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  _updateSyncEnabledTable(row.table, value);
                                },
                              ),
                            ),
                            DataCell(Text(row.table)),
                            DataCell(
                              AgentStatusPill(
                                label: row.state.status,
                                color:
                                    row.state.status == 'Paused'
                                        ? const Color(0xFF718096)
                                        : row.state.status == 'Failed'
                                        ? const Color(0xFFC53030)
                                        : row.state.status == 'Queued' ||
                                            row.state.status ==
                                                'Snapshotting' ||
                                            row.state.status == 'Uploading' ||
                                            row.state.status == 'Downloading' ||
                                            row.state.status == 'Applying'
                                        ? const Color(0xFFD69E2E)
                                        : const Color(0xFF2F855A),
                              ),
                            ),
                            DataCell(
                              SizedBox(
                                width: 132,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    LinearProgressIndicator(
                                      value:
                                          row.state.progress.clamp(0, 100) /
                                          100,
                                      minHeight: 6,
                                      backgroundColor: const Color(0xFFE7ECE6),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        row.state.status == 'Failed'
                                            ? const Color(0xFFC53030)
                                            : row.state.status == 'Paused'
                                            ? const Color(0xFF718096)
                                            : const Color(0xFF2F855A),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text('${row.state.progress}%'),
                                  ],
                                ),
                              ),
                            ),
                            DataCell(Text(row.state.rowCount.toString())),
                            DataCell(
                              Text(_formatTimestamp(row.state.lastSync)),
                            ),
                            DataCell(
                              Text(_formatBytes(row.state.snapshotBytes)),
                            ),
                            DataCell(
                              Wrap(
                                spacing: 4,
                                children: [
                                  IconButton(
                                    tooltip: 'Download backup file',
                                    onPressed:
                                        _selectedDatabase == null ||
                                                _isFileBusy(row.table)
                                            ? null
                                            : () =>
                                                _exportTableBackup(row.table),
                                    icon: const Icon(Icons.download_rounded),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  IconButton(
                                    tooltip: 'Upload backup file',
                                    onPressed:
                                        _selectedDatabase == null ||
                                                _isFileBusy(row.table)
                                            ? null
                                            : () =>
                                                _importTableBackup(row.table),
                                    icon: const Icon(Icons.upload_file_rounded),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ),
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 220,
                                ),
                                child: Text(
                                  row.state.message.isEmpty
                                      ? 'No sync message yet.'
                                      : row.state.message,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                      .toList(),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '$selectedTableName history',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          if (historyEntries.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE2D8CB)),
              ),
              child: const Text('No sync history recorded for this table.'),
            )
          else
            ...historyEntries.map(
              (entry) => Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2D8CB)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AgentStatusPill(
                      label: entry.success ? 'Success' : 'Failed',
                      color:
                          entry.success
                              ? const Color(0xFF2F855A)
                              : const Color(0xFFC53030),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.status,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 10,
                            runSpacing: 6,
                            children: [
                              Text(
                                '${entry.rowCount} rows',
                                style: const TextStyle(
                                  color: Color(0xFF5F6B76),
                                ),
                              ),
                              Text(
                                _formatBytes(entry.snapshotBytes),
                                style: const TextStyle(
                                  color: Color(0xFF5F6B76),
                                ),
                              ),
                              Text(
                                '${entry.progress}%',
                                style: const TextStyle(
                                  color: Color(0xFF5F6B76),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _formatTimestamp(entry.timestamp),
                      style: const TextStyle(color: Color(0xFF5F6B76)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: DropdownButtonFormField<String>(
                value: _selectedDatabase,
                isDense: true,
                isExpanded: true,
                iconSize: 18,
                borderRadius: BorderRadius.circular(12),
                items:
                    _databases
                        .map(
                          (database) => DropdownMenuItem(
                            value: database,
                            child: Text(
                              database,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        )
                        .toList(),
                onChanged: _databases.isEmpty ? null : _selectDatabase,
                decoration: _compactInputDecoration('Database'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            fit: FlexFit.loose,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: DropdownButtonFormField<String>(
                value: _selectedTable,
                isDense: true,
                isExpanded: true,
                iconSize: 18,
                borderRadius: BorderRadius.circular(12),
                items:
                    _tables
                        .map(
                          (table) => DropdownMenuItem(
                            value: table,
                            child: Text(
                              table,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        )
                        .toList(),
                selectedItemBuilder:
                    (context) =>
                        _tables
                            .map(
                              (table) => Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(
                                  table,
                                  maxLines: 1,
                                  minLines: 1,
                                  scrollPhysics: const BouncingScrollPhysics(),
                                ),
                              ),
                            )
                            .toList(),
                onChanged: _tables.isEmpty ? null : _selectTable,
                decoration: _compactInputDecoration('Table'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        _buildSelectionHeader(),
        const SizedBox(height: 12),
        if (_errorMessage != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFFFFEEEE),
            ),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _buildTablePanel(),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_errorMessage != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFFFFEEEE),
            ),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _buildSyncPanel(),
          ),
        ),
      ],
    );
  }

  InputDecoration _compactInputDecoration(String label) {
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
  }

  Widget _buildTableCell(String value, double cellWidth, {required bool alt}) {
    return Container(
      width: cellWidth,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: alt ? Colors.white : const Color(0xFFFAFBF9),
        border: const Border(bottom: BorderSide(color: Color(0xFFE4E8E3))),
      ),
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildTableRow(List<String> row, double cellWidth, int index) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 64,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: index.isOdd ? Colors.white : const Color(0xFFFAFBF9),
            border: const Border(bottom: BorderSide(color: Color(0xFFE4E8E3))),
          ),
          child: Text(
            '${index + 1}',
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        ...List.generate(_tableColumns.length, (columnIndex) {
          final value = columnIndex < row.length ? row[columnIndex] : '';
          return _buildTableCell(value, cellWidth, alt: index.isOdd);
        }),
      ],
    );
  }

  Widget _buildPinnedSummaryBar() {
    final syncRows = _tables
        .map((table) {
          final state =
              _syncState.tables[table] ?? _defaultSyncTableState(table);
          return (table: table, state: state);
        })
        .toList(growable: false);

    final selectedSyncTableName = _selectedSyncTableName(
      syncRows.map((row) => row.table).toList(growable: false),
    );
    final selectedSyncRow =
        syncRows.isEmpty
            ? null
            : syncRows.firstWhere(
              (row) => row.table == selectedSyncTableName,
              orElse: () => syncRows.first,
            );
    final activeSyncCount =
        syncRows
            .where(
              (row) =>
                  row.state.status == 'Queued' ||
                  row.state.status == 'Snapshotting' ||
                  row.state.status == 'Uploading' ||
                  row.state.status == 'Downloading' ||
                  row.state.status == 'Applying',
            )
            .length;

    final footerItems =
        _tabController.index == 1
            ? <Widget>[
              _InfoLine(label: 'Client', value: widget.clientName),
              _InfoLine(label: 'Tables', value: syncRows.length.toString()),
              _InfoLine(
                label: 'Selected',
                value: selectedSyncRow?.table ?? 'None',
              ),
              _InfoLine(label: 'Active', value: activeSyncCount.toString()),
              _InfoLine(
                label: 'Progress',
                value:
                    selectedSyncRow == null
                        ? '0%'
                        : '${selectedSyncRow.state.progress}%',
              ),
              _InfoLine(
                label: 'Status',
                value: selectedSyncRow?.state.status ?? 'Idle',
              ),
              _InfoLine(
                label: 'Backup',
                value:
                    selectedSyncRow == null
                        ? '--'
                        : _formatBytes(selectedSyncRow.state.snapshotBytes),
              ),
            ]
            : <Widget>[
              _InfoLine(label: 'Database', value: _selectedDatabase ?? 'None'),
              _InfoLine(label: 'Table', value: _selectedTable ?? 'None'),
              _InfoLine(label: 'Rows', value: _totalTableRows.toString()),
              _InfoLine(
                label: 'Backup',
                value:
                    _selectedTable == null
                        ? '--'
                        : _formatBytes(
                          (_syncState.tables[_selectedTable!]?.snapshotBytes ??
                              0),
                        ),
              ),
              _InfoLine(
                label: 'Loaded',
                value:
                    _selectedTable == null
                        ? 'No table selected'
                        : (_rowsLoading ? 'Loading' : 'Ready'),
              ),
            ];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFC9D2C7))),
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
            _buildServerStatusIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildServerStatusIndicator() {
    final color =
        _checkingServerConnection
            ? const Color(0xFFD69E2E)
            : _serverConnected
            ? const Color(0xFF2F855A)
            : const Color(0xFFC53030);
    final label =
        _checkingServerConnection
            ? 'Checking'
            : _serverConnected
            ? 'Online'
            : 'Offline';
    final tooltip =
        _lastServerCheck == null
            ? 'Checks the control plane health every minute.'
            : 'Last checked at ${_lastServerCheck!.toLocal()}';

    return Tooltip(
      message: tooltip,
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

  Widget _buildSpreadsheetTable() {
    if (_tableColumns.isEmpty) {
      return Center(
        child:
            _rowsLoading
                ? const CircularProgressIndicator()
                : Text(
                  'No columns returned for $_selectedTable.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
      );
    }

    final cellWidth = 180.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9F6),
              border: Border.all(color: const Color(0xFFD9DDD8)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final panelWidth =
                    constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(context).width;
                final columnWidth = math.max(
                  panelWidth,
                  64 + (_tableColumns.length * cellWidth),
                );
                final panelHeight =
                    constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : MediaQuery.sizeOf(context).height * 0.7;

                return ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: columnWidth,
                      height: panelHeight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: 64,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 12,
                                ),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFE3E8E1),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Color(0xFFBFC9BE),
                                    ),
                                  ),
                                ),
                                child: const Text(
                                  '#',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              ..._tableColumns.asMap().entries.map((entry) {
                                final isSortedColumn =
                                    _sortColumnIndex == entry.key;
                                final icon =
                                    isSortedColumn
                                        ? (_sortAscending
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward)
                                        : Icons.unfold_more;

                                return InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () {
                                    final ascending =
                                        isSortedColumn ? !_sortAscending : true;
                                    setState(() {
                                      _sortColumnIndex = entry.key;
                                      _sortAscending = ascending;
                                    });
                                    unawaited(_reloadCurrentTableRows());
                                  },
                                  child: Container(
                                    width: cellWidth,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFE3E8E1),
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Color(0xFFBFC9BE),
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            entry.value,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          icon,
                                          size: 16,
                                          color: Colors.black54,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                          Expanded(
                            child:
                                _tableRows.isEmpty && !_rowsLoading
                                    ? Center(
                                      child: Text(
                                        '0 rows found in $_selectedTable.',
                                        style:
                                            Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                      ),
                                    )
                                    : Scrollbar(
                                      controller: _tableScrollController,
                                      thumbVisibility: true,
                                      child: ListView.builder(
                                        controller: _tableScrollController,
                                        itemCount:
                                            _tableRows.length +
                                            (_rowsLoading ? 1 : 0),
                                        itemBuilder: (context, index) {
                                          if (index >= _tableRows.length) {
                                            return const Padding(
                                              padding: EdgeInsets.symmetric(
                                                vertical: 16,
                                              ),
                                              child: Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                            );
                                          }
                                          return _buildTableRow(
                                            _tableRows[index],
                                            cellWidth,
                                            index,
                                          );
                                        },
                                      ),
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.clientName == 'Local Agent'
              ? 'SQL Sync Agent'
              : '${widget.clientName} - SQL Sync Agent',
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.table_rows), text: 'Table'),
            Tab(icon: Icon(Icons.sync), text: 'Sync'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.more_vert),
            style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _openSettingsDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TabBarView(
          controller: _tabController,
          children: [_buildTableTab(), _buildSyncTab()],
        ),
      ),
      bottomNavigationBar: _buildPinnedSummaryBar(),
    );
  }
}

class _SqlConnectionProfile {
  const _SqlConnectionProfile({
    required this.server,
    required this.useWindowsAuth,
    required this.user,
    required this.password,
  });

  final String server;
  final bool useWindowsAuth;
  final String user;
  final String password;
}

class _StringQueryResult {
  const _StringQueryResult({
    required this.success,
    required this.values,
    required this.errorText,
  });

  final bool success;
  final List<String> values;
  final String? errorText;
}

class _ColumnSchemaResult {
  const _ColumnSchemaResult({
    required this.success,
    required this.values,
    required this.errorText,
  });

  final bool success;
  final List<_TableColumnSchema> values;
  final String? errorText;
}

class _QualifiedTableName {
  const _QualifiedTableName({required this.schema, required this.table});

  final String schema;
  final String table;
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
              color: Color(0xFF5E6C73),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xFF18212B),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotFileDocument {
  const _SnapshotFileDocument({
    required this.id,
    required this.clientName,
    required this.table,
    required this.createdAt,
    required this.rowCount,
    required this.checksum,
    required this.snapshotBytes,
    required this.columns,
    required this.rows,
    required this.sourceJobId,
  });

  final String id;
  final String clientName;
  final String table;
  final String createdAt;
  final int rowCount;
  final String checksum;
  final int snapshotBytes;
  final List<String> columns;
  final List<Map<String, String?>> rows;
  final String? sourceJobId;

  factory _SnapshotFileDocument.fromJson(Map<String, dynamic> json) {
    final columns = (json['columns'] as List<dynamic>? ?? const [])
        .map((item) => item.toString())
        .toList(growable: false);
    final rawRows = json['rows'] as List<dynamic>? ?? const [];
    return _SnapshotFileDocument(
      id: json['id'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      table: json['table'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      rowCount: (json['rowCount'] as num? ?? rawRows.length).round(),
      checksum: json['checksum'] as String? ?? '',
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      columns: columns,
      rows: rawRows
          .map(
            (row) => Map<String, String?>.fromEntries(
              columns.map((column) {
                final value =
                    row is Map && row.containsKey(column) ? row[column] : null;
                return MapEntry(column, value?.toString());
              }),
            ),
          )
          .toList(growable: false),
      sourceJobId: json['sourceJobId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'formatVersion': 1,
    'id': id,
    'clientName': clientName,
    'table': table,
    'createdAt': createdAt,
    'rowCount': rowCount,
    'checksum': checksum,
    'snapshotBytes': snapshotBytes,
    'columns': columns,
    'rows': rows,
    'sourceJobId': sourceJobId,
  };

  _SnapshotFileDocument copyWith({int? snapshotBytes}) {
    return _SnapshotFileDocument(
      id: id,
      clientName: clientName,
      table: table,
      createdAt: createdAt,
      rowCount: rowCount,
      checksum: checksum,
      snapshotBytes: snapshotBytes ?? this.snapshotBytes,
      columns: columns,
      rows: rows,
      sourceJobId: sourceJobId,
    );
  }
}

class _TableRowsResult {
  const _TableRowsResult({
    required this.success,
    required this.columns,
    required this.rows,
    required this.totalRows,
    required this.hasMoreRows,
    required this.errorText,
  });

  final bool success;
  final List<String> columns;
  final List<List<String>> rows;
  final int totalRows;
  final bool hasMoreRows;
  final String? errorText;
}

class _TableSnapshotResult {
  const _TableSnapshotResult({
    required this.success,
    required this.columns,
    required this.rows,
    required this.totalRows,
    required this.snapshotCreatedAt,
    required this.errorText,
  });

  final bool success;
  final List<String> columns;
  final List<Map<String, String?>> rows;
  final int totalRows;
  final String snapshotCreatedAt;
  final String? errorText;
}

class _SnapshotPageResult {
  const _SnapshotPageResult({
    required this.success,
    required this.rows,
    required this.errorText,
  });

  final bool success;
  final List<Map<String, String?>> rows;
  final String? errorText;
}

class _TableColumnSchema {
  const _TableColumnSchema({
    required this.name,
    required this.sqlType,
    required this.isNullable,
    required this.isIdentity,
  });

  final String name;
  final String sqlType;
  final bool isNullable;
  final bool isIdentity;
}

class _IntQueryResult {
  const _IntQueryResult({
    required this.success,
    required this.value,
    required this.errorText,
  });

  final bool success;
  final int value;
  final String? errorText;
}
