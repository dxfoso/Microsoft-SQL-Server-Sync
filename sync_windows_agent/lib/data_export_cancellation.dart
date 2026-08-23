import 'dart:async';

class DataExportSupersededException implements Exception {
  const DataExportSupersededException(this.requestId);

  final String requestId;

  @override
  String toString() =>
      'Data export $requestId was superseded by a newer request.';
}

class DataExportCancellation {
  DataExportCancellation(this.requestId);

  final String requestId;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw DataExportSupersededException(requestId);
    }
  }

  Future<T> race<T>(Future<T> operation) {
    throwIfCancelled();
    return Future.any<T>(<Future<T>>[
      operation,
      _cancelled.future.then<T>(
        (_) => throw DataExportSupersededException(requestId),
      ),
    ]);
  }
}
