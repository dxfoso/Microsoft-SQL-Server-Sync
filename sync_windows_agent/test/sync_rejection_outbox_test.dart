import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sync_rejection_outbox.dart';

void main() {
  SyncRejectedChange rejectedChange({
    required String id,
    required SyncRejectionKind kind,
    String error = 'error',
    int attemptCount = 1,
  }) {
    return SyncRejectedChange(
      table: 'db::a',
      keyColumns: const ['GUID'],
      row: {'GUID': id, 'value': 'old'},
      error: error,
      kind: kind,
      firstRejectedAt: '2026-07-17T00:00:00Z',
      lastRejectedAt: '2026-07-17T00:00:00Z',
      attemptCount: attemptCount,
    );
  }

  test('classifies permanent, dependency, and transient SQL failures', () {
    expect(
      classifySyncRejection("AmnE0271: Can't touch posted entry(ies)"),
      SyncRejectionKind.permanentBusinessRule,
    );
    expect(
      classifySyncRejection('AmnW0077: found no costJob in entry item'),
      SyncRejectionKind.dependency,
    );
    expect(
      classifySyncRejection('SQL transport timeout'),
      SyncRejectionKind.transient,
    );
  });

  test('persists rejected rows per client and table', () async {
    final directory = await Directory.systemTemp.createTemp('sync-rejections-');
    addTearDown(() => directory.delete(recursive: true));
    final outbox = SyncRejectionOutbox(directory: directory);
    final now = DateTime.now().toUtc().toIso8601String();
    final change = SyncRejectedChange(
      table: 'AmnDb028::ce000',
      keyColumns: const ['GUID'],
      row: const {'GUID': 'row-1', 'costJob': null},
      error: 'AmnW0077: found no costJob in entry item',
      kind: SyncRejectionKind.dependency,
      firstRejectedAt: now,
      lastRejectedAt: now,
      attemptCount: 1,
    );

    await outbox.saveTable('c1', change.table, [change]);
    final loaded = await outbox.loadTable('c1', change.table);

    expect(loaded, hasLength(1));
    expect(loaded.single.identity, change.identity);
    expect(loaded.single.kind, SyncRejectionKind.dependency);
    expect(loaded.single.row['costJob'], isNull);
  });

  test('table replacement preserves quarantines for other tables', () async {
    final directory = await Directory.systemTemp.createTemp('sync-rejections-');
    addTearDown(() => directory.delete(recursive: true));
    final outbox = SyncRejectionOutbox(directory: directory);
    final now = DateTime.now().toUtc().toIso8601String();
    SyncRejectedChange change(String table, String id) => SyncRejectedChange(
      table: table,
      keyColumns: const ['GUID'],
      row: {'GUID': id},
      error: 'temporary',
      kind: SyncRejectionKind.transient,
      firstRejectedAt: now,
      lastRejectedAt: now,
      attemptCount: 1,
    );

    await outbox.saveTable('c1', 'db::a', [change('db::a', 'a')]);
    await outbox.saveTable('c1', 'db::b', [change('db::b', 'b')]);
    await outbox.saveTable('c1', 'db::a', const []);

    expect(await outbox.loadTable('c1', 'db::a'), isEmpty);
    expect(await outbox.loadTable('c1', 'db::b'), hasLength(1));
  });

  test('recovers from a flushed temporary outbox after interruption', () async {
    final directory = await Directory.systemTemp.createTemp('sync-rejections-');
    addTearDown(() => directory.delete(recursive: true));
    final outbox = SyncRejectionOutbox(directory: directory);
    final temporary = File(
      '${directory.path}${Platform.pathSeparator}sync_rejections_c1.json.tmp',
    );
    await temporary.writeAsString('''
{"version":1,"clientName":"c1","changes":[{"table":"db::a","keyColumns":["GUID"],"row":{"GUID":"pending"},"error":"timeout","kind":"transient","firstRejectedAt":"2026-07-17T00:00:00Z","lastRejectedAt":"2026-07-17T00:00:00Z","attemptCount":1}]}
''', flush: true);

    final loaded = await outbox.loadTable('c1', 'db::a');

    expect(loaded, hasLength(1));
    expect(loaded.single.row['GUID'], 'pending');
  });

  test('retains permanent conflicts until a newer row supersedes them', () {
    final permanent = rejectedChange(
      id: 'posted',
      kind: SyncRejectionKind.permanentBusinessRule,
    );

    final retained = reconcileSyncRejectedChanges(
      table: 'db::a',
      existing: [permanent],
      supersededIdentities: const <String>{},
      attempted: const [],
      retryRejections: const [],
      currentRejections: const [],
      currentKeyColumns: const ['GUID'],
    );
    final superseded = reconcileSyncRejectedChanges(
      table: 'db::a',
      existing: [permanent],
      supersededIdentities: {permanent.identity},
      attempted: const [],
      retryRejections: const [],
      currentRejections: const [],
      currentKeyColumns: const ['GUID'],
    );

    expect(retained, hasLength(1));
    expect(superseded, isEmpty);
  });

  test('removes a successful targeted retry and retains a failed retry', () {
    final dependency = rejectedChange(
      id: 'dependency',
      kind: SyncRejectionKind.dependency,
      error: 'missing dependency',
      attemptCount: 2,
    );

    final succeeded = reconcileSyncRejectedChanges(
      table: 'db::a',
      existing: [dependency],
      supersededIdentities: const <String>{},
      attempted: [dependency],
      retryRejections: const [],
      currentRejections: const [],
      currentKeyColumns: const ['GUID'],
    );
    final failed = reconcileSyncRejectedChanges(
      table: 'db::a',
      existing: [dependency],
      supersededIdentities: const <String>{},
      attempted: [dependency],
      retryRejections: const [
        SyncRejectionObservation(
          row: {'GUID': 'dependency', 'value': 'old'},
          error: 'AmnW0077: found no costJob in entry item',
        ),
      ],
      currentRejections: const [],
      currentKeyColumns: const ['GUID'],
    );

    expect(succeeded, isEmpty);
    expect(failed, hasLength(1));
    expect(failed.single.attemptCount, 3);
    expect(failed.single.kind, SyncRejectionKind.dependency);
  });

  test('classifies and stores a newly rejected current change', () {
    final reconciled = reconcileSyncRejectedChanges(
      table: 'db::en000',
      existing: const [],
      supersededIdentities: const <String>{},
      attempted: const [],
      retryRejections: const [],
      currentRejections: const [
        SyncRejectionObservation(
          row: {'GUID': 'posted'},
          error: "AmnE0271: Can't touch posted entry(ies)",
        ),
      ],
      currentKeyColumns: const ['GUID'],
    );

    expect(reconciled, hasLength(1));
    expect(reconciled.single.table, 'db::en000');
    expect(reconciled.single.kind, SyncRejectionKind.permanentBusinessRule);
  });
}
