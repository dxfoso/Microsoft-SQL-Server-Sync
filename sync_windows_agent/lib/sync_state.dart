import 'dart:convert';
import 'dart:io';

class SyncHistoryEntry {
  const SyncHistoryEntry({
    required this.timestamp,
    required this.table,
    required this.status,
    required this.success,
    required this.message,
    this.direction = 'upload',
    this.rowCount = 0,
    this.progress = 0,
    this.snapshotId,
    this.snapshotBytes = 0,
  });

  final String timestamp;
  final String table;
  final String status;
  final bool success;
  final String message;
  final String direction;
  final int rowCount;
  final int progress;
  final String? snapshotId;
  final int snapshotBytes;

  factory SyncHistoryEntry.fromJson(Map<String, dynamic> json) {
    return SyncHistoryEntry(
      timestamp: json['timestamp'] as String? ?? '',
      table: json['table'] as String? ?? '',
      status: json['status'] as String? ?? '',
      success: json['success'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      direction: json['direction'] as String? ?? 'upload',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      progress: (json['progress'] as num? ?? 0).round(),
      snapshotId: json['snapshotId'] as String?,
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'table': table,
    'status': status,
    'success': success,
    'message': message,
    'direction': direction,
    'rowCount': rowCount,
    'progress': progress,
    'snapshotId': snapshotId,
    'snapshotBytes': snapshotBytes,
  };
}

class SyncTableState {
  const SyncTableState({
    required this.enabled,
    required this.status,
    required this.lastSync,
    required this.progress,
    required this.direction,
    required this.rowCount,
    required this.snapshotId,
    required this.snapshotCreatedAt,
    required this.snapshotBytes,
    required this.message,
    required this.history,
  });

  final bool enabled;
  final String status;
  final String lastSync;
  final int progress;
  final String direction;
  final int rowCount;
  final String? snapshotId;
  final String? snapshotCreatedAt;
  final int snapshotBytes;
  final String message;
  final List<SyncHistoryEntry> history;

  factory SyncTableState.fromJson(Map<String, dynamic> json) {
    final history = (json['history'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              SyncHistoryEntry.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
    return SyncTableState(
      enabled: json['enabled'] as bool? ?? false,
      status: json['status'] as String? ?? 'Paused',
      lastSync: json['lastSync'] as String? ?? '--',
      progress: (json['progress'] as num? ?? 0).round(),
      direction: json['direction'] as String? ?? 'upload',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      snapshotId: json['snapshotId'] as String?,
      snapshotCreatedAt: json['snapshotCreatedAt'] as String?,
      snapshotBytes: (json['snapshotBytes'] as num? ?? 0).round(),
      message: json['message'] as String? ?? '',
      history: history,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'status': status,
    'lastSync': lastSync,
    'progress': progress,
    'direction': direction,
    'rowCount': rowCount,
    'snapshotId': snapshotId,
    'snapshotCreatedAt': snapshotCreatedAt,
    'snapshotBytes': snapshotBytes,
    'message': message,
    'history': history.map((entry) => entry.toJson()).toList(growable: false),
  };

  SyncTableState copyWith({
    bool? enabled,
    String? status,
    String? lastSync,
    int? progress,
    String? direction,
    int? rowCount,
    String? snapshotId,
    String? snapshotCreatedAt,
    int? snapshotBytes,
    String? message,
    List<SyncHistoryEntry>? history,
  }) {
    return SyncTableState(
      enabled: enabled ?? this.enabled,
      status: status ?? this.status,
      lastSync: lastSync ?? this.lastSync,
      progress: progress ?? this.progress,
      direction: direction ?? this.direction,
      rowCount: rowCount ?? this.rowCount,
      snapshotId: snapshotId ?? this.snapshotId,
      snapshotCreatedAt: snapshotCreatedAt ?? this.snapshotCreatedAt,
      snapshotBytes: snapshotBytes ?? this.snapshotBytes,
      message: message ?? this.message,
      history: history ?? this.history,
    );
  }
}

class SyncClientState {
  const SyncClientState({required this.tables});

  final Map<String, SyncTableState> tables;

  factory SyncClientState.fromJson(Map<String, dynamic> json) {
    final tablesJson = Map<String, dynamic>.from(
      json['tables'] as Map? ?? const {},
    );
    return SyncClientState(
      tables: tablesJson.map(
        (key, value) => MapEntry(
          key,
          SyncTableState.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'tables': tables.map((key, value) => MapEntry(key, value.toJson())),
  };

  SyncClientState copyWith({Map<String, SyncTableState>? tables}) {
    return SyncClientState(tables: tables ?? this.tables);
  }
}

class SyncAppStateStore {
  const SyncAppStateStore({
    required this.lastClientName,
    required this.clients,
  });

  final String lastClientName;
  final Map<String, SyncClientState> clients;

  static Directory _stateDirectory() {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.current.path;
    return Directory('$base${Platform.pathSeparator}Microsoft-SQL-Server-Sync');
  }

  static File _stateFile() {
    return File(
      '${_stateDirectory().path}${Platform.pathSeparator}sync_windows_agent_state.json',
    );
  }

  static Future<SyncAppStateStore> load() async {
    final file = _stateFile();
    if (!await file.exists()) {
      return const SyncAppStateStore(
        lastClientName: 'Local Agent',
        clients: {},
      );
    }

    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const SyncAppStateStore(
          lastClientName: 'Local Agent',
          clients: {},
        );
      }

      final json = Map<String, dynamic>.from(decoded);
      final clientsJson = Map<String, dynamic>.from(
        json['clients'] as Map? ?? const {},
      );
      return SyncAppStateStore(
        lastClientName: json['lastClientName'] as String? ?? 'Local Agent',
        clients: clientsJson.map(
          (key, value) => MapEntry(
            key,
            SyncClientState.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
      );
    } catch (_) {
      return const SyncAppStateStore(
        lastClientName: 'Local Agent',
        clients: {},
      );
    }
  }

  static SyncAppStateStore loadSync() {
    final file = _stateFile();
    if (!file.existsSync()) {
      return const SyncAppStateStore(
        lastClientName: 'Local Agent',
        clients: {},
      );
    }

    try {
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const SyncAppStateStore(
          lastClientName: 'Local Agent',
          clients: {},
        );
      }

      final json = Map<String, dynamic>.from(decoded);
      final clientsJson = Map<String, dynamic>.from(
        json['clients'] as Map? ?? const {},
      );
      return SyncAppStateStore(
        lastClientName: json['lastClientName'] as String? ?? 'Local Agent',
        clients: clientsJson.map(
          (key, value) => MapEntry(
            key,
            SyncClientState.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
      );
    } catch (_) {
      return const SyncAppStateStore(
        lastClientName: 'Local Agent',
        clients: {},
      );
    }
  }

  Future<void> save() async {
    final dir = _stateDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = _stateFile();
    final payload = jsonEncode({
      'lastClientName': lastClientName,
      'clients': clients.map((key, value) => MapEntry(key, value.toJson())),
    });
    await file.writeAsString(payload);
  }
}
