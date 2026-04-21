import 'package:flutter/material.dart';

class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    required this.isConnected,
    required this.lastUpdated,
    required this.totalAgents,
    required this.totalJobs,
    this.selectedAgent,
    this.authenticatedEmail,
  });

  final bool isConnected;
  final String lastUpdated;
  final int totalAgents;
  final int totalJobs;
  final String? selectedAgent;
  final String? authenticatedEmail;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xFF143842), Color(0xFF1E6674), Color(0xFFD8A23A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 18,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [],
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _HeaderBadge(
                label: isConnected ? 'Backend online' : 'Backend offline',
                color:
                    isConnected
                        ? const Color(0xFFB8F2CF)
                        : const Color(0xFFFFD7D7),
                textColor:
                    isConnected
                        ? const Color(0xFF103D23)
                        : const Color(0xFF6D1F1F),
              ),
              _HeaderBadge(
                label: 'Agents $totalAgents',
                color: const Color(0x26FFFFFF),
                textColor: Colors.white,
              ),
              _HeaderBadge(
                label: 'Jobs $totalJobs',
                color: const Color(0x26FFFFFF),
                textColor: Colors.white,
              ),
              _HeaderBadge(
                label: 'Refresh $lastUpdated',
                color: const Color(0x26FFFFFF),
                textColor: Colors.white,
              ),
              if (authenticatedEmail != null)
                _HeaderBadge(
                  label: authenticatedEmail!,
                  color: const Color(0x26FFFFFF),
                  textColor: Colors.white,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.expandChild = false,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle.trim().isNotEmpty;
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
          if (hasSubtitle) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Color(0xFF58656B), height: 1.4),
            ),
            const SizedBox(height: 18),
          ] else
            const SizedBox(height: 14),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.color});

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

class ProgressStrip extends StatelessWidget {
  const ProgressStrip({super.key, required this.progress, required this.color});

  final int progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0, 100) / 100;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 6,
        backgroundColor: const Color(0xFFE7ECE6),
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}

class MetricPill extends StatelessWidget {
  const MetricPill({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD9DDD8)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: Color(0xFF58656B),
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class InfoLine extends StatelessWidget {
  const InfoLine({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
              color: Color(0xFF5E6C73),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xFF18212B),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD9DDD8)),
      ),
      child: Text(message, style: const TextStyle(height: 1.45)),
    );
  }
}

class _HeaderBadge extends StatelessWidget {
  const _HeaderBadge({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
      ),
    );
  }
}
