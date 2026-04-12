class AgentTable {
  const AgentTable({
    required this.name,
    required this.keyColumn,
    required this.changeColumn,
    required this.rows,
  });

  final String name;
  final String keyColumn;
  final String changeColumn;
  final int rows;
}

class AgentEvent {
  const AgentEvent({
    required this.time,
    required this.title,
    required this.message,
    required this.level,
  });

  final String time;
  final String title;
  final String message;
  final AgentEventLevel level;
}

enum AgentEventLevel { info, warning, error }
