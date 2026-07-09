import 'models.dart';

class ClientSyncProgressSummary {
  const ClientSyncProgressSummary({
    required this.progress,
    required this.label,
    required this.detail,
  });

  final int progress;
  final String label;
  final String detail;
}

ClientSyncProgressSummary computeClientSyncProgressSummary({
  required AdminAgent agent,
  required Iterable<AdminJob> jobs,
}) {
  final enabledTables =
      agent.tables
          .where((table) => table.enabled)
          .map((table) => table.table.trim())
          .where((table) => table.isNotEmpty)
          .toSet();
  var trackedTables =
      enabledTables.isEmpty
          ? agent.tables
              .map((table) => table.table.trim())
              .where((table) => table.isNotEmpty)
              .toSet()
          : enabledTables;

  final clientJobs = jobs
    .where((job) => job.clientName == agent.clientName)
    .toList(growable: false)..sort(_compareJobsByUpdatedAtDesc);
  if (trackedTables.isEmpty) {
    trackedTables =
        clientJobs
            .map((job) => job.table.trim())
            .where((table) => table.isNotEmpty)
            .toSet();
  }
  if (trackedTables.isEmpty) {
    return const ClientSyncProgressSummary(
      progress: 0,
      label: 'No sync jobs',
      detail: 'No enabled tables or sync jobs are available yet.',
    );
  }

  final latestJobsByTable = <String, AdminJob>{};
  for (final job in clientJobs) {
    final table = job.table.trim();
    if (table.isEmpty ||
        !trackedTables.contains(table) ||
        latestJobsByTable.containsKey(table)) {
      continue;
    }
    latestJobsByTable[table] = job;
  }

  var totalProgress = 0;
  var completedCount = 0;
  var activeCount = 0;
  var failedCount = 0;
  for (final table in trackedTables) {
    final job = latestJobsByTable[table];
    if (job != null) {
      final status = job.status.toLowerCase();
      var progress = job.progress.clamp(0, 100);
      if (status == 'completed') {
        progress = 100;
      } else if (job.isActive && progress == 0) {
        progress = status == 'queued' ? 4 : 8;
      }
      totalProgress += progress;
      if (status == 'completed') {
        completedCount += 1;
      } else if (status == 'failed') {
        failedCount += 1;
      } else if (job.isActive) {
        activeCount += 1;
      }
      continue;
    }

    AdminTableState? tableState;
    for (final state in agent.tables) {
      if (state.table.trim() == table) {
        tableState = state;
        break;
      }
    }
    final status = (tableState?.status ?? '').toLowerCase();
    final hasLastSync = (tableState?.lastSync.trim().isNotEmpty ?? false);
    var progress = (tableState?.progress ?? 0).clamp(0, 100);
    final isFailed = status.contains('fail') || status.contains('error');
    final isActive =
        status == 'running' ||
        status == 'applying' ||
        (status == 'queued' && !hasLastSync) ||
        status == 'syncing';
    final isComplete =
        status == 'completed' ||
        status == 'synced' ||
        status == 'success' ||
        (hasLastSync && !isFailed && !isActive);
    if (isComplete) {
      progress = 100;
    } else if (isActive && progress == 0) {
      progress = 4;
    }
    totalProgress += progress;
    if (isComplete) {
      completedCount += 1;
    } else if (isFailed) {
      failedCount += 1;
    } else if (isActive) {
      activeCount += 1;
    }
  }

  final progress = (totalProgress / trackedTables.length).round().clamp(0, 100);
  if (failedCount > 0) {
    return ClientSyncProgressSummary(
      progress: progress,
      label: 'Failed',
      detail:
          '$failedCount failed, $completedCount complete of ${trackedTables.length} tables.',
    );
  }
  if (completedCount == trackedTables.length && progress >= 100) {
    return ClientSyncProgressSummary(
      progress: 100,
      label: 'Complete',
      detail: 'All ${trackedTables.length} enabled tables are complete.',
    );
  }
  if (activeCount > 0) {
    return ClientSyncProgressSummary(
      progress: progress,
      label: 'Syncing',
      detail:
          '$activeCount active, $completedCount complete of ${trackedTables.length} tables.',
    );
  }
  return ClientSyncProgressSummary(
    progress: progress,
    label: completedCount > 0 ? 'Partial' : 'Waiting',
    detail:
        '$completedCount complete of ${trackedTables.length} enabled tables.',
  );
}

int _compareJobsByUpdatedAtDesc(AdminJob left, AdminJob right) {
  return _compareTimestamps(right.updatedAt, left.updatedAt);
}

int _compareTimestamps(String left, String right) {
  final leftParsed = DateTime.tryParse(left);
  final rightParsed = DateTime.tryParse(right);
  if (leftParsed != null && rightParsed != null) {
    return leftParsed.compareTo(rightParsed);
  }
  if (leftParsed != null) {
    return 1;
  }
  if (rightParsed != null) {
    return -1;
  }
  return left.compareTo(right);
}
