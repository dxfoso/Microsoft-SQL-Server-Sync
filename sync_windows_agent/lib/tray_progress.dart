import 'live_sync_api.dart';

class TraySyncProgress {
  const TraySyncProgress({
    required this.active,
    required this.progress,
    required this.status,
  });

  final bool active;
  final int progress;
  final String status;
}

TraySyncProgress calculateTraySyncProgress({
  required bool syncLoopBusy,
  required int processingJobCount,
  required Iterable<RemoteSyncJob> jobs,
}) {
  final activeJobs = jobs.where((job) => job.isActive).toList(growable: false);
  final active =
      syncLoopBusy || processingJobCount > 0 || activeJobs.isNotEmpty;
  if (!active) {
    return const TraySyncProgress(active: false, progress: 0, status: '');
  }

  final progress =
      activeJobs.isEmpty
          ? 0
          : (activeJobs
                      .map((job) => job.progress.clamp(0, 100))
                      .reduce((left, right) => left + right) /
                  activeJobs.length)
              .round()
              .clamp(0, 100);
  final status =
      activeJobs.length == 1
          ? 'Syncing ${activeJobs.single.table}'
          : activeJobs.isEmpty
          ? 'Syncing'
          : 'Syncing ${activeJobs.length} items';
  return TraySyncProgress(active: true, progress: progress, status: status);
}
