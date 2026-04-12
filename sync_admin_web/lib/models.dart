class MachineNode {
  const MachineNode({
    required this.id,
    required this.name,
    required this.clientName,
    required this.office,
    required this.sqlInstance,
    required this.isOnline,
    required this.lastHeartbeat,
    required this.tags,
  });

  final String id;
  final String name;
  final String clientName;
  final String office;
  final String sqlInstance;
  final bool isOnline;
  final String lastHeartbeat;
  final List<String> tags;
}

class TableProfile {
  const TableProfile({
    required this.name,
    required this.primaryKey,
    required this.changeColumn,
    required this.estimatedRows,
  });

  final String name;
  final String primaryKey;
  final String changeColumn;
  final int estimatedRows;
}

class SyncRun {
  const SyncRun({
    required this.title,
    required this.startedAt,
    required this.outcome,
    required this.message,
  });

  final String title;
  final String startedAt;
  final SyncOutcome outcome;
  final String message;
}

enum SyncOutcome { success, warning, failed }
