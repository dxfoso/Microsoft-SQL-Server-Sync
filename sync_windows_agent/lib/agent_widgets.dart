import 'package:flutter/material.dart';

import 'models.dart';

class AgentHeroBanner extends StatelessWidget {
  const AgentHeroBanner({
    super.key,
    required this.controlPlaneConnected,
    required this.sqlConnected,
    required this.pollMinutes,
  });

  final bool controlPlaneConnected;
  final bool sqlConnected;
  final int pollMinutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          colors: [Color(0xFF143842), Color(0xFF1E6674), Color(0xFFD8A23A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 20,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'SQL Sync Agent',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Run the machine-side sync service on Windows and keep the local SQL Server connection away from the browser.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Control plane: ${controlPlaneConnected ? 'connected' : 'offline'} | '
                  'SQL link: ${sqlConnected ? 'ready' : 'not ready'} | '
                  'Poll interval: every $pollMinutes minutes',
                  style: const TextStyle(color: Colors.white70, height: 1.45),
                ),
              ],
            ),
          ),
          Container(
            width: 280,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white24),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Agent Responsibilities',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  '1. Register with the domain',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 6),
                Text(
                  '2. Hold local SQL credentials',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 6),
                Text(
                  '3. Pull sync plans every 5 minutes',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 6),
                Text(
                  '4. Push status and logs back',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AgentSectionShell extends StatelessWidget {
  const AgentSectionShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFBF8),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 28,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF58656B), height: 1.4),
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class AgentMetricCard extends StatelessWidget {
  const AgentMetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.detail,
  });

  final String title;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 248,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFD9DDD8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF58656B),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(detail, style: const TextStyle(height: 1.35)),
          ],
        ),
      ),
    );
  }
}

class AgentStatusPill extends StatelessWidget {
  const AgentStatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class AgentEventDot extends StatelessWidget {
  const AgentEventDot({super.key, required this.level});

  final AgentEventLevel level;

  @override
  Widget build(BuildContext context) {
    late final Color color;
    switch (level) {
      case AgentEventLevel.info:
        color = const Color(0xFF2F855A);
      case AgentEventLevel.warning:
        color = const Color(0xFFD69E2E);
      case AgentEventLevel.error:
        color = const Color(0xFFC53030);
    }

    return Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
