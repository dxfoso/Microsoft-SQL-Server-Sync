import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sync_transfer_policy.dart';

void main() {
  test('healthy transport uses bounded parallel fast compression', () {
    final tuning = AdaptiveSyncTransferPolicy().tuning;

    expect(tuning.parallelism, kSyncTransferHealthyParallelism);
    expect(tuning.parallelism, 2);
    expect(tuning.maxPackageRows, 100);
    expect(tuning.gzipLevel, 1);
  });

  test('one failure throttles immediately and recovery is hysteretic', () {
    final policy = AdaptiveSyncTransferPolicy(recoverySuccesses: 4);

    policy.recordFailure();
    expect(policy.tuning.parallelism, kSyncTransferConstrainedParallelism);
    expect(policy.tuning.maxPackageRows, 40);
    expect(policy.tuning.gzipLevel, 6);

    for (var index = 0; index < 3; index += 1) {
      policy.recordSuccess(const Duration(milliseconds: 20));
    }
    expect(policy.tuning.parallelism, 1);

    policy.recordSuccess(const Duration(milliseconds: 20));
    expect(policy.tuning.parallelism, 2);
  });

  test(
    'bounded runner preserves result order and concurrency ceiling',
    () async {
      var active = 0;
      var peak = 0;
      final gates = List.generate(5, (_) => Completer<void>());

      final future = runBoundedSyncTransfers<int>(
        List.generate(5, (index) {
          return () async {
            active += 1;
            if (active > peak) peak = active;
            await gates[index].future;
            active -= 1;
            return index;
          };
        }),
        parallelism: 2,
      );

      await Future<void>.delayed(Duration.zero);
      expect(peak, 2);
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      gates[2].complete();
      await Future<void>.delayed(Duration.zero);
      gates[3].complete();
      await Future<void>.delayed(Duration.zero);
      gates[4].complete();

      expect(await future, [0, 1, 2, 3, 4]);
      expect(peak, 2);
    },
  );

  test('invalid parallelism fails before running work', () async {
    await expectLater(
      runBoundedSyncTransfers<int>(const [], parallelism: 0),
      throwsArgumentError,
    );
  });
}
