import 'dart:convert';
import 'dart:io';

const int kDefaultHistoryLimit = 5;
const int kMaxHistoryLimit = 100;
const int kDefaultAutoSyncIntervalMinutes = 15;
const int kMinAutoSyncIntervalMinutes = 1;
const int kMaxAutoSyncIntervalMinutes = 1440;
const Object _syncTableStateUnset = Object();

class SyncHistoryEntry {
  const SyncHistoryEntry({
    required this.timestamp,
    required this.table,
    required this.status,
    required this.success,
    required this.message,
    this.rowCount = 0,
    this.progress = 0,
  });

  final String timestamp;
  final String table;
  final String status;
  final bool success;
  final String message;
  final int rowCount;
  final int progress;

  factory SyncHistoryEntry.fromJson(Map<String, dynamic> json) {
    return SyncHistoryEntry(
      timestamp: json['timestamp'] as String? ?? '',
      table: json['table'] as String? ?? '',
      status: json['status'] as String? ?? '',
      success: json['success'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      progress: (json['progress'] as num? ?? 0).round(),
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'table': table,
    'status': status,
    'success': success,
    'message': message,
    'rowCount': rowCount,
    'progress': progress,
  };
}

class SyncTableState {
  const SyncTableState({
    required this.enabled,
    required this.autoRequired,
    required this.status,
    required this.lastSync,
    required this.progress,
    required this.rowCount,
    required this.savedRowCount,
    required this.tableChecksum,
    required this.message,
    required this.history,
  });

  final bool enabled;
  final bool autoRequired;
  final String status;
  final String lastSync;
  final int progress;
  final int rowCount;
  final int? savedRowCount;
  final String tableChecksum;
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
      autoRequired: json['autoRequired'] as bool? ?? false,
      status: json['status'] as String? ?? 'Paused',
      lastSync: json['lastSync'] as String? ?? '--',
      progress: (json['progress'] as num? ?? 0).round(),
      rowCount: (json['rowCount'] as num? ?? 0).round(),
      savedRowCount: (json['savedRowCount'] as num?)?.round(),
      tableChecksum: json['tableChecksum'] as String? ?? '',
      message: json['message'] as String? ?? '',
      history: history,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'autoRequired': autoRequired,
    'status': status,
    'lastSync': lastSync,
    'progress': progress,
    'rowCount': rowCount,
    'savedRowCount': savedRowCount,
    'tableChecksum': tableChecksum,
    'message': message,
    'history': history.map((entry) => entry.toJson()).toList(growable: false),
  };

  SyncTableState copyWith({
    bool? enabled,
    bool? autoRequired,
    String? status,
    String? lastSync,
    int? progress,
    int? rowCount,
    Object? savedRowCount = _syncTableStateUnset,
    String? tableChecksum,
    String? message,
    List<SyncHistoryEntry>? history,
  }) {
    return SyncTableState(
      enabled: enabled ?? this.enabled,
      autoRequired: autoRequired ?? this.autoRequired,
      status: status ?? this.status,
      lastSync: lastSync ?? this.lastSync,
      progress: progress ?? this.progress,
      rowCount: rowCount ?? this.rowCount,
      savedRowCount:
          identical(savedRowCount, _syncTableStateUnset)
              ? this.savedRowCount
              : savedRowCount as int?,
      tableChecksum: tableChecksum ?? this.tableChecksum,
      message: message ?? this.message,
      history: history ?? this.history,
    );
  }
}

class SyncClientState {
  const SyncClientState({
    required this.tables,
    this.historyLimit = kDefaultHistoryLimit,
    this.autoSyncIntervalMinutes = kDefaultAutoSyncIntervalMinutes,
  });

  final Map<String, SyncTableState> tables;
  final int historyLimit;
  final int autoSyncIntervalMinutes;

  factory SyncClientState.fromJson(Map<String, dynamic> json) {
    final tablesJson = Map<String, dynamic>.from(
      json['tables'] as Map? ?? const {},
    );
    return SyncClientState(
      historyLimit:
          (json['historyLimit'] as num? ?? kDefaultHistoryLimit)
              .round()
              .clamp(1, kMaxHistoryLimit)
              .toInt(),
      autoSyncIntervalMinutes:
          (json['autoSyncIntervalMinutes'] as num? ??
                  kDefaultAutoSyncIntervalMinutes)
              .round()
              .clamp(kMinAutoSyncIntervalMinutes, kMaxAutoSyncIntervalMinutes)
              .toInt(),
      tables: tablesJson.map(
        (key, value) => MapEntry(
          key,
          SyncTableState.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'historyLimit': historyLimit,
    'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
    'tables': tables.map((key, value) => MapEntry(key, value.toJson())),
  };

  SyncClientState copyWith({
    Map<String, SyncTableState>? tables,
    int? historyLimit,
    int? autoSyncIntervalMinutes,
  }) {
    return SyncClientState(
      historyLimit: historyLimit ?? this.historyLimit,
      autoSyncIntervalMinutes:
          autoSyncIntervalMinutes ?? this.autoSyncIntervalMinutes,
      tables: tables ?? this.tables,
    );
  }
}

class SyncAppStateStore {
  const SyncAppStateStore({
    required this.lastClientName,
    required this.clients,
    required this.server,
    required this.hasOpenedOnce,
    this.startMinimized = false,
    this.startOnStartup = false,
    this.authToken,
    this.accountUsername,
    this.accountEmail,
    this.accountName,
    this.rememberedLoginName,
    this.rememberedLoginPassword,
    this.lastAutoUpdateTarget,
    this.lastAutoUpdateAttemptedAt,
  });

  static const SyncAppStateStore _defaultStore = SyncAppStateStore(
    lastClientName: 'Local Agent',
    clients: {},
    server: 'localhost',
    hasOpenedOnce: false,
    startMinimized: false,
    startOnStartup: false,
    authToken: null,
    accountUsername: null,
    accountEmail: null,
    accountName: null,
    rememberedLoginName: null,
    rememberedLoginPassword: null,
    lastAutoUpdateTarget: null,
    lastAutoUpdateAttemptedAt: null,
  );

  final String lastClientName;
  final Map<String, SyncClientState> clients;
  final String server;
  final bool hasOpenedOnce;
  final bool startMinimized;
  final bool startOnStartup;
  final String? authToken;
  final String? accountUsername;
  final String? accountEmail;
  final String? accountName;
  final String? rememberedLoginName;
  final String? rememberedLoginPassword;
  final String? lastAutoUpdateTarget;
  final String? lastAutoUpdateAttemptedAt;

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
    try {
      final file = _stateFile();
      if (!await file.exists()) {
        return _defaultStore;
      }

      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _defaultStore;
      }

      final json = Map<String, dynamic>.from(decoded);
      final clientsJson = Map<String, dynamic>.from(
        json['clients'] as Map? ?? const {},
      );
      return SyncAppStateStore(
        lastClientName: json['lastClientName'] as String? ?? 'Local Agent',
        hasOpenedOnce: json['hasOpenedOnce'] as bool? ?? false,
        startMinimized: json['startMinimized'] as bool? ?? false,
        startOnStartup: json['startOnStartup'] as bool? ?? false,
        server: json['server'] as String? ?? 'localhost',
        authToken: json['authToken'] as String?,
        accountUsername: json['accountUsername'] as String?,
        accountEmail: json['accountEmail'] as String?,
        accountName: json['accountName'] as String?,
        rememberedLoginName: json['rememberedLoginName'] as String?,
        rememberedLoginPassword: json['rememberedLoginPassword'] as String?,
        lastAutoUpdateTarget: json['lastAutoUpdateTarget'] as String?,
        lastAutoUpdateAttemptedAt: json['lastAutoUpdateAttemptedAt'] as String?,
        clients: clientsJson.map(
          (key, value) => MapEntry(
            key,
            SyncClientState.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
      );
    } catch (_) {
      return _defaultStore;
    }
  }

  static SyncAppStateStore loadSync() {
    try {
      final file = _stateFile();
      if (!file.existsSync()) {
        return _defaultStore;
      }

      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _defaultStore;
      }

      final json = Map<String, dynamic>.from(decoded);
      final clientsJson = Map<String, dynamic>.from(
        json['clients'] as Map? ?? const {},
      );
      return SyncAppStateStore(
        lastClientName: json['lastClientName'] as String? ?? 'Local Agent',
        hasOpenedOnce: json['hasOpenedOnce'] as bool? ?? false,
        startMinimized: json['startMinimized'] as bool? ?? false,
        startOnStartup: json['startOnStartup'] as bool? ?? false,
        server: json['server'] as String? ?? 'localhost',
        authToken: json['authToken'] as String?,
        accountUsername: json['accountUsername'] as String?,
        accountEmail: json['accountEmail'] as String?,
        accountName: json['accountName'] as String?,
        rememberedLoginName: json['rememberedLoginName'] as String?,
        rememberedLoginPassword: json['rememberedLoginPassword'] as String?,
        lastAutoUpdateTarget: json['lastAutoUpdateTarget'] as String?,
        lastAutoUpdateAttemptedAt: json['lastAutoUpdateAttemptedAt'] as String?,
        clients: clientsJson.map(
          (key, value) => MapEntry(
            key,
            SyncClientState.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
      );
    } catch (_) {
      return _defaultStore;
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
      'hasOpenedOnce': hasOpenedOnce,
      'startMinimized': startMinimized,
      'startOnStartup': startOnStartup,
      'server': server,
      'authToken': authToken,
      'accountUsername': accountUsername,
      'accountEmail': accountEmail,
      'accountName': accountName,
      'rememberedLoginName': rememberedLoginName,
      'rememberedLoginPassword': rememberedLoginPassword,
      'lastAutoUpdateTarget': lastAutoUpdateTarget,
      'lastAutoUpdateAttemptedAt': lastAutoUpdateAttemptedAt,
      'clients': clients.map((key, value) => MapEntry(key, value.toJson())),
    });
    await file.writeAsString(payload);
  }
}
