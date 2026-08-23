import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sync_state.dart';

void main() {
  test('protocol version and sync epoch survive state serialization', () {
    const state = SyncClientState(
      tables: <String, SyncTableState>{},
      protocolVersion: 2,
      syncEpoch: 'epoch-v2-test',
    );

    final restored = SyncClientState.fromJson(state.toJson());

    expect(restored.protocolVersion, 2);
    expect(restored.syncEpoch, 'epoch-v2-test');
  });

  test('pre-v2 state is intentionally treated as unversioned', () {
    final restored = SyncClientState.fromJson(const {
      'tables': <String, dynamic>{},
    });

    expect(restored.protocolVersion, 0);
    expect(restored.syncEpoch, isEmpty);
    expect(restored.fingerprintRefreshCursor, 0);
  });

  test('physical fingerprint rotation cursor survives client restarts', () {
    const state = SyncClientState(
      tables: <String, SyncTableState>{},
      fingerprintRefreshCursor: 317,
    );

    final restored = SyncClientState.fromJson(state.toJson());

    expect(restored.fingerprintRefreshCursor, 317);
    expect(
      restored.copyWith(fingerprintRefreshCursor: 325).fingerprintRefreshCursor,
      325,
    );
    expect(
      SyncClientState.fromJson(const <String, dynamic>{
        'tables': <String, dynamic>{},
        'fingerprintRefreshCursor': -8,
      }).fingerprintRefreshCursor,
      0,
    );
  });

  test('detected local changes survive state and heartbeat serialization', () {
    final state = SyncTableState.fromJson(const <String, dynamic>{
      'enabled': true,
      'localChangesPending': true,
    });

    expect(state.localChangesPending, isTrue);
    expect(state.toJson()['localChangesPending'], isTrue);
    expect(
      state.copyWith(localChangesPending: false).localChangesPending,
      isFalse,
    );
  });

  test('range fingerprint manifest survives state serialization', () {
    final state = SyncTableState.fromJson(const <String, dynamic>{
      'enabled': true,
      'rowCount': 3,
      'tableChecksum': '3:abc',
      'rangeFingerprint': 'v1|16|3|3:abc|bucket-manifest',
    });

    expect(state.rangeFingerprint, 'v1|16|3|3:abc|bucket-manifest');
    expect(
      state
          .copyWith(rangeFingerprint: 'new-manifest')
          .toJson()['rangeFingerprint'],
      'new-manifest',
    );
  });

  test('state writes are serialized and recover from the valid backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sql-sync-state-regression-',
    );
    addTearDown(() => directory.delete(recursive: true));

    SyncAppStateStore storeForEpoch(String epoch) => SyncAppStateStore(
      lastClientName: 'client-a',
      clients: <String, SyncClientState>{
        'client-a': SyncClientState(
          tables: const <String, SyncTableState>{},
          protocolVersion: 4,
          syncEpoch: epoch,
        ),
      },
      server: 'server-a',
      hasOpenedOnce: true,
    );

    await storeForEpoch('epoch-one').save(stateDirectory: directory);
    await storeForEpoch('epoch-two').save(stateDirectory: directory);

    final primary = File(
      '${directory.path}${Platform.pathSeparator}sync_windows_agent_state.json',
    );
    await primary.writeAsString('{interrupted');
    final recovered = await SyncAppStateStore.load(stateDirectory: directory);

    expect(recovered.clients['client-a']?.syncEpoch, 'epoch-one');

    await Future.wait(
      List<Future<void>>.generate(
        20,
        (index) =>
            storeForEpoch('epoch-$index').save(stateDirectory: directory),
      ),
    );
    final latest = await SyncAppStateStore.load(stateDirectory: directory);
    expect(latest.clients['client-a']?.syncEpoch, 'epoch-19');
  });
}
