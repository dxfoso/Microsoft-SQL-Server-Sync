import 'dart:convert';
import 'dart:io';

const int kDefaultHistoryLimit = 5;
const int kMaxHistoryLimit = 100;
const int kDefaultAutoSyncIntervalMinutes = 15;
const int kMinAutoSyncIntervalMinutes = 1;
const int kMaxAutoSyncIntervalMinutes = 1440;
const Object _syncTableStateUnset = Object();

String? resolveSavedDatabaseSelection({
  required String? saved,
  required List<String> available,
  String? defaultDatabase,
}) {
  final normalizedSaved = saved?.trim();
  if (normalizedSaved != null &&
      normalizedSaved.isNotEmpty &&
      available.contains(normalizedSaved)) {
    return normalizedSaved;
  }

  final normalizedDefault = defaultDatabase?.trim();
  if (normalizedDefault != null &&
      normalizedDefault.isNotEmpty &&
      available.contains(normalizedDefault)) {
    return normalizedDefault;
  }
  return available.isEmpty ? null : available.first;
}

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
    required this.changeTrackingVersion,
    required this.changeTrackingOwner,
    required this.changeTrackingStatus,
    required this.changeTrackingMessage,
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
  final int? changeTrackingVersion;
  final String? changeTrackingOwner;
  final String changeTrackingStatus;
  final String changeTrackingMessage;
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
      changeTrackingVersion: (json['changeTrackingVersion'] as num?)?.round(),
      changeTrackingOwner: json['changeTrackingOwner'] as String?,
      changeTrackingStatus:
          json['changeTrackingStatus'] as String? ?? 'unknown',
      changeTrackingMessage: json['changeTrackingMessage'] as String? ?? '',
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
    'changeTrackingVersion': changeTrackingVersion,
    'changeTrackingOwner': changeTrackingOwner,
    'changeTrackingStatus': changeTrackingStatus,
    'changeTrackingMessage': changeTrackingMessage,
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
    Object? changeTrackingVersion = _syncTableStateUnset,
    Object? changeTrackingOwner = _syncTableStateUnset,
    String? changeTrackingStatus,
    String? changeTrackingMessage,
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
      changeTrackingVersion:
          identical(changeTrackingVersion, _syncTableStateUnset)
              ? this.changeTrackingVersion
              : changeTrackingVersion as int?,
      changeTrackingOwner:
          identical(changeTrackingOwner, _syncTableStateUnset)
              ? this.changeTrackingOwner
              : changeTrackingOwner as String?,
      changeTrackingStatus: changeTrackingStatus ?? this.changeTrackingStatus,
      changeTrackingMessage:
          changeTrackingMessage ?? this.changeTrackingMessage,
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
    this.protocolVersion = 0,
    this.syncEpoch = '',
  });

  final Map<String, SyncTableState> tables;
  final int historyLimit;
  final int autoSyncIntervalMinutes;
  final int protocolVersion;
  final String syncEpoch;

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
      protocolVersion: (json['protocolVersion'] as num? ?? 0).round(),
      syncEpoch: json['syncEpoch'] as String? ?? '',
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
    'protocolVersion': protocolVersion,
    'syncEpoch': syncEpoch,
    'tables': tables.map((key, value) => MapEntry(key, value.toJson())),
  };

  SyncClientState copyWith({
    Map<String, SyncTableState>? tables,
    int? historyLimit,
    int? autoSyncIntervalMinutes,
    int? protocolVersion,
    String? syncEpoch,
  }) {
    return SyncClientState(
      historyLimit: historyLimit ?? this.historyLimit,
      autoSyncIntervalMinutes:
          autoSyncIntervalMinutes ?? this.autoSyncIntervalMinutes,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      syncEpoch: syncEpoch ?? this.syncEpoch,
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
    this.selectedDatabasesByUser = const <String, String>{},
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
    selectedDatabasesByUser: {},
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
  final Map<String, String> selectedDatabasesByUser;
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

  static Future<void> _saveQueue = Future<void>.value();

  static Directory _stateDirectory([Directory? override]) {
    if (override != null) {
      return override;
    }
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.current.path;
    return Directory('$base${Platform.pathSeparator}Microsoft-SQL-Server-Sync');
  }

  static File _stateFile([Directory? stateDirectory]) {
    return File(
      '${_stateDirectory(stateDirectory).path}${Platform.pathSeparator}sync_windows_agent_state.json',
    );
  }

  static File _backupStateFile([Directory? stateDirectory]) {
    return File('${_stateFile(stateDirectory).path}.bak');
  }

  static SyncAppStateStore _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Windows client state must be a JSON map.');
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
      selectedDatabasesByUser: _readStringMap(json['selectedDatabasesByUser']),
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
  }

  static Future<SyncAppStateStore> load({Directory? stateDirectory}) async {
    for (final file in <File>[
      _stateFile(stateDirectory),
      _backupStateFile(stateDirectory),
    ]) {
      try {
        if (await file.exists()) {
          return _decode(await file.readAsString());
        }
      } catch (_) {
        // A killed updater or power loss can leave the primary incomplete.
        // Continue to the last known-good backup before using defaults.
      }
    }
    return _defaultStore;
  }

  static SyncAppStateStore loadSync({Directory? stateDirectory}) {
    for (final file in <File>[
      _stateFile(stateDirectory),
      _backupStateFile(stateDirectory),
    ]) {
      try {
        if (file.existsSync()) {
          return _decode(file.readAsStringSync());
        }
      } catch (_) {
        // Fall through to the last known-good backup.
      }
    }
    return _defaultStore;
  }

  Future<void> save({Directory? stateDirectory}) async {
    final dir = _stateDirectory(stateDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = _stateFile(stateDirectory);
    final payload = jsonEncode({
      'lastClientName': lastClientName,
      'hasOpenedOnce': hasOpenedOnce,
      'startMinimized': startMinimized,
      'startOnStartup': startOnStartup,
      'server': server,
      'selectedDatabasesByUser': selectedDatabasesByUser,
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
    final pending = _saveQueue.then(
      (_) => _writeAtomically(dir: dir, file: file, payload: payload),
    );
    _saveQueue = pending.catchError((Object _) {});
    await pending;
  }

  static Future<void> _writeAtomically({
    required Directory dir,
    required File file,
    required String payload,
  }) async {
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    try {
      await temporary.writeAsString(payload, flush: true);
      if (await file.exists()) {
        try {
          _decode(await file.readAsString());
          await file.copy(backup.path);
        } catch (_) {
          // Preserve an older valid backup instead of replacing it with a
          // corrupt primary file.
        }
        await file.delete();
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}

Map<String, String> _readStringMap(Object? value) {
  if (value is! Map) {
    return <String, String>{};
  }

  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is String && entry.value is String) {
      final key = (entry.key as String).trim();
      final selectedDatabase = (entry.value as String).trim();
      if (key.isNotEmpty && selectedDatabase.isNotEmpty) {
        result[key] = selectedDatabase;
      }
    }
  }
  return result;
}
