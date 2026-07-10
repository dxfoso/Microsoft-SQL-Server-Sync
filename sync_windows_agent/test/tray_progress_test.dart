import 'package:flutter_test/flutter_test.dart';

import 'package:sync_windows_agent/live_sync_api.dart';
import 'package:sync_windows_agent/tray_progress.dart';

RemoteSyncJob _job({
  required String id,
  required String status,
  required int progress,
}) {
  return RemoteSyncJob(
    id: id,
    clientName: 'c1',
    sourceClientName: 'c1',
    subscriberClientName: 'c2',
    table: 'AmnDb028::bi000',
    direction: 'upload',
    publisherServer: r'.\SQLEXPRESS',
    publisherDatabase: 'AmnConfig',
    publisherUseWindowsAuth: true,
    publisherUser: '',
    publisherPassword: '',
    status: status,
    progress: progress,
    rowCount: 0,
    snapshotBytes: 0,
    snapshotCreatedAt: null,
    snapshotId: null,
    createdAt: '',
    updatedAt: '',
    startedAt: null,
    completedAt: null,
    message: '',
    error: null,
  );
}

void main() {
  test('shows an indeterminate tray sync while the loop is busy', () {
    final result = calculateTraySyncProgress(
      syncLoopBusy: true,
      processingJobCount: 0,
      jobs: const <RemoteSyncJob>[],
    );

    expect(result.active, isTrue);
    expect(result.progress, 0);
    expect(result.status, 'Syncing');
  });

  test('averages active job progress for the tray indicator', () {
    final result = calculateTraySyncProgress(
      syncLoopBusy: false,
      processingJobCount: 1,
      jobs: <RemoteSyncJob>[
        _job(id: 'one', status: 'uploading', progress: 30),
        _job(id: 'two', status: 'downloading', progress: 70),
      ],
    );

    expect(result.active, isTrue);
    expect(result.progress, 50);
    expect(result.status, 'Syncing 2 items');
  });

  test('returns the normal tray state when no sync is active', () {
    final result = calculateTraySyncProgress(
      syncLoopBusy: false,
      processingJobCount: 0,
      jobs: <RemoteSyncJob>[
        _job(id: 'done', status: 'completed', progress: 100),
      ],
    );

    expect(result.active, isFalse);
    expect(result.progress, 0);
    expect(result.status, isEmpty);
  });
}
