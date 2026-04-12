import 'package:flutter/material.dart';

import 'models.dart';

class HeroBanner extends StatelessWidget {
  const HeroBanner({
    super.key,
    required this.onlineMachines,
    required this.totalMachines,
    required this.selectedTables,
    required this.syncEveryMinutes,
  });

  final int onlineMachines;
  final int totalMachines;
  final int selectedTables;
  final int syncEveryMinutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF20313C),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF20313C)),
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
                    color: const Color(0xFF2A3E4A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'SQL Sync Control Plane',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Manage source PCs, sink PCs, and table-level SQL Server replication from one web dashboard.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$onlineMachines of $totalMachines agents are online. '
                  '$selectedTables tables are selected, with a default cadence of every $syncEveryMinutes minutes.',
                  style: const TextStyle(color: Colors.white70, height: 1.45),
                ),
              ],
            ),
          ),
          Container(
            width: 280,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF2A3E4A),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF385668)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recommended Production Flow',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  '1. Agent registers with domain',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 6),
                Text(
                  '2. Web app saves sync plan',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 6),
                Text(
                  '3. Agent polls and runs delta sync',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 6),
                Text(
                  '4. Backend stores results and alerts',
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

class SectionShell extends StatelessWidget {
  const SectionShell({
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE5E9E2)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF60707A), height: 1.4),
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
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
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE1E6DD)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF60707A),
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

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class OutcomeDot extends StatelessWidget {
  const OutcomeDot({super.key, required this.outcome});

  final SyncOutcome outcome;

  @override
  Widget build(BuildContext context) {
    late final Color color;
    switch (outcome) {
      case SyncOutcome.success:
        color = const Color(0xFF2F855A);
      case SyncOutcome.warning:
        color = const Color(0xFFD69E2E);
      case SyncOutcome.failed:
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
