import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/data_export_cancellation.dart';

void main() {
  test('new request interrupts an obsolete in-flight operation', () async {
    final cancellation = DataExportCancellation('old-request');
    final neverCompletes = Completer<String>();

    final result = cancellation.race(neverCompletes.future);
    cancellation.cancel();

    await expectLater(result, throwsA(isA<DataExportSupersededException>()));
    expect(cancellation.isCancelled, isTrue);
  });

  test(
    'completed operation is preserved when request remains current',
    () async {
      final cancellation = DataExportCancellation('current-request');

      expect(await cancellation.race(Future<int>.value(42)), 42);
      expect(cancellation.isCancelled, isFalse);
    },
  );
}
