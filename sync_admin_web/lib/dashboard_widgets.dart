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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;

        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(compact ? 14 : 18),
          decoration: BoxDecoration(
            color: const Color(0xFF152630),
            borderRadius: BorderRadius.circular(compact ? 20 : 24),
            border: Border.all(color: const Color(0xFF233A48)),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _HeaderBadge(
                label: isConnected ? 'Backend online' : 'Backend offline',
                color:
                    isConnected
                        ? const Color(0xFF173D2A)
                        : const Color(0xFF482222),
                textColor:
                    isConnected
                        ? const Color(0xFFB7F2CC)
                        : const Color(0xFFFFD4CE),
              ),
              _HeaderBadge(
                label: 'Agents $totalAgents',
                color: const Color(0xFF1E313D),
                textColor: const Color(0xFFD7E2E8),
              ),
              _HeaderBadge(
                label: 'Jobs $totalJobs',
                color: const Color(0xFF1E313D),
                textColor: const Color(0xFFD7E2E8),
              ),
              _HeaderBadge(
                label: 'Refresh $lastUpdated',
                color: const Color(0xFF1E313D),
                textColor: const Color(0xFFD7E2E8),
              ),
              if (selectedAgent != null && selectedAgent!.trim().isNotEmpty)
                _HeaderBadge(
                  label: 'Selected $selectedAgent',
                  color: const Color(0xFF1E313D),
                  textColor: const Color(0xFFD7E2E8),
                ),
              if (authenticatedEmail != null)
                _HeaderBadge(
                  label: authenticatedEmail!,
                  color: const Color(0xFF1E313D),
                  textColor: const Color(0xFFD7E2E8),
                ),
            ],
          ),
        );
      },
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
    this.headerTrailing,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool expandChild;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackHeader = constraints.maxWidth < 720;

        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(stackHeader ? 14 : 18),
          decoration: BoxDecoration(
            color: const Color(0xFFFCFDFD),
            borderRadius: BorderRadius.circular(stackHeader ? 18 : 22),
            border: Border.all(color: const Color(0xFFD8E0E5)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0B14212B),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stackHeader) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SurfaceCardHeading(
                      title: title,
                      subtitle: subtitle,
                      hasSubtitle: hasSubtitle,
                    ),
                    if (headerTrailing != null) ...[
                      const SizedBox(height: 12),
                      headerTrailing!,
                    ],
                  ],
                ),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _SurfaceCardHeading(
                        title: title,
                        subtitle: subtitle,
                        hasSubtitle: hasSubtitle,
                      ),
                    ),
                    if (headerTrailing != null) ...[
                      const SizedBox(width: 12),
                      Flexible(child: headerTrailing!),
                    ],
                  ],
                ),
              const SizedBox(height: 16),
              if (expandChild) Expanded(child: child) else child,
            ],
          ),
        );
      },
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
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
        minHeight: 5,
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
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD8E0E5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF74818A),
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
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
              color: Color(0xFF6B7780),
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xFF14212B),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FBFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD8E0E5)),
      ),
      child: Text(
        message,
        style: const TextStyle(height: 1.45, color: Color(0xFF5B6872)),
      ),
    );
  }
}

class _SurfaceCardHeading extends StatelessWidget {
  const _SurfaceCardHeading({
    required this.title,
    required this.subtitle,
    required this.hasSubtitle,
  });

  final String title;
  final String subtitle;
  final bool hasSubtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        if (hasSubtitle) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF62717C), height: 1.42),
          ),
        ],
      ],
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
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
