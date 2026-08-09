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
