import 'dart:async';

const int kSyncTransferHealthyParallelism = 2;
const int kSyncTransferConstrainedParallelism = 1;

class SyncTransferTuning {
  const SyncTransferTuning({
    required this.parallelism,
    required this.maxPackageRows,
    required this.maxUncompressedBytes,
    required this.maxCompressedBytes,
    required this.gzipLevel,
  });

  final int parallelism;
  final int maxPackageRows;
  final int maxUncompressedBytes;
  final int maxCompressedBytes;
  final int gzipLevel;
}

/// Conservative adaptive policy for restartable sync transport.
///
/// It never changes SQL transaction boundaries or durable operation IDs. A
/// transient failure immediately returns transport to one request at a time;
/// several successful requests are required before bounded parallelism is
/// restored.
class AdaptiveSyncTransferPolicy {
  AdaptiveSyncTransferPolicy({
    this.healthyLatency = const Duration(seconds: 2),
    this.recoverySuccesses = 4,
  });

  final Duration healthyLatency;
  final int recoverySuccesses;

  int _successesSinceFailure = 0;
  bool _constrained = false;
  double? _latencyMs;

  SyncTransferTuning get tuning {
    final latencyConstrained =
        _latencyMs != null && _latencyMs! > healthyLatency.inMilliseconds;
    final constrained = _constrained || latencyConstrained;
    return SyncTransferTuning(
      parallelism:
          constrained
              ? kSyncTransferConstrainedParallelism
              : kSyncTransferHealthyParallelism,
      maxPackageRows: constrained ? 40 : 100,
      maxUncompressedBytes: constrained ? 192000 : 512000,
      maxCompressedBytes: constrained ? 144000 : 384000,
      // Fast gzip reduces client CPU and starts WAN transfer sooner on healthy
      // links. Stronger compression is preferable when the link is slow.
      gzipLevel: constrained ? 6 : 1,
    );
  }

  void recordSuccess(Duration elapsed) {
    final elapsedMs = elapsed.inMicroseconds / 1000.0;
    _latencyMs =
        _latencyMs == null
            ? elapsedMs
            : (_latencyMs! * 0.75) + (elapsedMs * 0.25);
    _successesSinceFailure += 1;
    if (_constrained && _successesSinceFailure >= recoverySuccesses) {
      _constrained = false;
      _successesSinceFailure = 0;
    }
  }

  void recordFailure() {
    _constrained = true;
    _successesSinceFailure = 0;
  }
}

Future<List<T>> runBoundedSyncTransfers<T>(
  Iterable<Future<T> Function()> tasks, {
  required int parallelism,
}) async {
  if (parallelism < 1) {
    throw ArgumentError.value(parallelism, 'parallelism', 'must be positive');
  }
  final pending = tasks.toList(growable: false);
  if (pending.isEmpty) return <T>[];

  final results = List<T?>.filled(pending.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex;
      if (index >= pending.length) return;
      nextIndex += 1;
      results[index] = await pending[index]();
    }
  }

  await Future.wait(
    List.generate(
      parallelism > pending.length ? pending.length : parallelism,
      (_) => worker(),
    ),
    eagerError: true,
  );
  return results.cast<T>();
}
