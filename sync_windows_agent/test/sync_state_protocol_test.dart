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
}
