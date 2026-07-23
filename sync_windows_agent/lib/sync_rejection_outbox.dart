import 'dart:convert';
import 'dart:io';

enum SyncRejectionKind { dependency, permanentBusinessRule, transient }

const syncRejectionApplyPolicyVersion = 3;

class SyncRejectionObservation {
  const SyncRejectionObservation({required this.row, required this.error});

  final Map<String, dynamic> row;
  final String error;
}

class SyncRejectedChange {
  const SyncRejectedChange({
    required this.table,
    required this.keyColumns,
    required this.row,
    required this.error,
    required this.kind,
    required this.firstRejectedAt,
    required this.lastRejectedAt,
    required this.attemptCount,
    this.applyPolicyVersion = syncRejectionApplyPolicyVersion,
  });

  final String table;
  final List<String> keyColumns;
  final Map<String, dynamic> row;
  final String error;
  final SyncRejectionKind kind;
  final String firstRejectedAt;
  final String lastRejectedAt;
  final int attemptCount;
  final int applyPolicyVersion;

  String get identity => syncRejectedRowIdentity(row, keyColumns);

  factory SyncRejectedChange.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind']?.toString() ?? '';
    return SyncRejectedChange(
      table: json['table']?.toString() ?? '',
      keyColumns: (json['keyColumns'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      row: Map<String, dynamic>.from(json['row'] as Map? ?? const {}),
      error: json['error']?.toString() ?? '',
      kind: SyncRejectionKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => SyncRejectionKind.transient,
      ),
      firstRejectedAt: json['firstRejectedAt']?.toString() ?? '',
      lastRejectedAt: json['lastRejectedAt']?.toString() ?? '',
      attemptCount:
          (json['attemptCount'] as num? ?? 1).round().clamp(1, 1 << 30).toInt(),
      applyPolicyVersion: (json['applyPolicyVersion'] as num? ?? 1).round(),
    );
  }

  Map<String, dynamic> toJson() => {
    'table': table,
    'keyColumns': keyColumns,
    'row': row,
    'error': error,
    'kind': kind.name,
    'firstRejectedAt': firstRejectedAt,
    'lastRejectedAt': lastRejectedAt,
    'attemptCount': attemptCount,
    'applyPolicyVersion': applyPolicyVersion,
  };

  SyncRejectedChange retried({
    required Map<String, dynamic> nextRow,
    required String nextError,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    return SyncRejectedChange(
      table: table,
      keyColumns: keyColumns,
      row: nextRow,
      error: nextError,
      kind: classifySyncRejection(nextError),
      firstRejectedAt: firstRejectedAt.isEmpty ? now : firstRejectedAt,
      lastRejectedAt: now,
      attemptCount: attemptCount + 1,
      applyPolicyVersion: syncRejectionApplyPolicyVersion,
    );
  }
}

bool shouldRetrySyncRejectedChange(SyncRejectedChange change) {
  return change.kind != SyncRejectionKind.permanentBusinessRule ||
      change.applyPolicyVersion < syncRejectionApplyPolicyVersion;
}

SyncRejectionKind classifySyncRejection(String error) {
  final normalized = error.toLowerCase();
  if (normalized.contains('amne0271') ||
      normalized.contains("can't touch posted") ||
      normalized.contains('cannot touch posted') ||
      normalized.contains('duplicate key') ||
      normalized.contains('unique index') ||
      normalized.contains('unique constraint') ||
      normalized.contains('error 2601') ||
      normalized.contains('error 2627')) {
    return SyncRejectionKind.permanentBusinessRule;
  }
  if (normalized.contains('amnw0077') ||
      normalized.contains('no costjob') ||
      normalized.contains('foreign key') ||
      normalized.contains('reference constraint')) {
    return SyncRejectionKind.dependency;
  }
  return SyncRejectionKind.transient;
}

String syncRejectedRowIdentity(
  Map<String, dynamic> row,
  List<String> keyColumns,
) {
  if (keyColumns.isEmpty) {
    return jsonEncode(row);
  }
  return jsonEncode([
    for (final column in keyColumns) [column, row[column]?.toString()],
  ]);
}

List<SyncRejectedChange> reconcileSyncRejectedChanges({
  required String table,
  required List<SyncRejectedChange> existing,
  required Set<String> supersededIdentities,
  required List<SyncRejectedChange> attempted,
  required List<SyncRejectionObservation> retryRejections,
  required List<SyncRejectionObservation> currentRejections,
  required List<String> currentKeyColumns,
}) {
  final attemptedIdentities =
      attempted.map((change) => change.identity).toSet();
  final nextByIdentity = <String, SyncRejectedChange>{
    for (final change in existing)
      if (!supersededIdentities.contains(change.identity) &&
          !attemptedIdentities.contains(change.identity))
        change.identity: change,
  };
  for (final rejected in retryRejections) {
    for (final previous in attempted) {
      final identity = syncRejectedRowIdentity(
        rejected.row,
        previous.keyColumns,
      );
      if (identity != previous.identity) continue;
      nextByIdentity[identity] = previous.retried(
        nextRow: rejected.row,
        nextError: rejected.error,
      );
      break;
    }
  }
  final existingByIdentity = {
    for (final change in existing) change.identity: change,
  };
  final now = DateTime.now().toUtc().toIso8601String();
  for (final rejected in currentRejections) {
    final identity = syncRejectedRowIdentity(rejected.row, currentKeyColumns);
    final previous = existingByIdentity[identity];
    nextByIdentity[identity] =
        previous?.retried(nextRow: rejected.row, nextError: rejected.error) ??
        SyncRejectedChange(
          table: table,
          keyColumns: currentKeyColumns,
          row: rejected.row,
          error: rejected.error,
          kind: classifySyncRejection(rejected.error),
          firstRejectedAt: now,
          lastRejectedAt: now,
          attemptCount: 1,
          applyPolicyVersion: syncRejectionApplyPolicyVersion,
        );
  }
  return nextByIdentity.values.toList(growable: false);
}

class SyncRejectionOutbox {
  SyncRejectionOutbox({Directory? directory})
    : _directory = directory ?? _defaultDirectory();

  final Directory _directory;

  static Directory _defaultDirectory() {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.current.path;
    return Directory('$base${Platform.pathSeparator}Microsoft-SQL-Server-Sync');
  }

  Future<List<SyncRejectedChange>> loadTable(
    String clientName,
    String table,
  ) async {
    final all = await _load(clientName);
    return all.where((change) => change.table == table).toList(growable: false);
  }

  Future<void> saveTable(
    String clientName,
    String table,
    List<SyncRejectedChange> changes,
  ) async {
    final all = await _load(clientName);
    final next = <SyncRejectedChange>[
      ...all.where((change) => change.table != table),
      ...changes,
    ];
    await _save(clientName, next);
  }

  Future<List<SyncRejectedChange>> _load(String clientName) async {
    for (final file in [_temporaryFile(clientName), _file(clientName)]) {
      try {
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map || decoded['changes'] is! List) continue;
        return (decoded['changes'] as List)
            .whereType<Map>()
            .map(
              (value) =>
                  SyncRejectedChange.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList(growable: false);
      } catch (_) {
        continue;
      }
    }
    return const <SyncRejectedChange>[];
  }

  Future<void> _save(
    String clientName,
    List<SyncRejectedChange> changes,
  ) async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
    final payload = jsonEncode({
      'version': 1,
      'clientName': clientName,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'changes': changes
          .map((change) => change.toJson())
          .toList(growable: false),
    });
    final temporary = _temporaryFile(clientName);
    final target = _file(clientName);
    await temporary.writeAsString(payload, flush: true);
    await target.writeAsString(payload, flush: true);
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }

  File _file(String clientName) => File(
    '${_directory.path}${Platform.pathSeparator}sync_rejections_${_safeName(clientName)}.json',
  );

  File _temporaryFile(String clientName) =>
      File('${_file(clientName).path}.tmp');

  static String _safeName(String value) {
    final safe = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return safe.isEmpty ? 'client' : safe;
  }
}
