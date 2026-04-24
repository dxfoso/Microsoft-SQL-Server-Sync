import 'package:flutter/material.dart';

import 'models.dart';

class AgentHeroBanner extends StatelessWidget {
  const AgentHeroBanner({
    super.key,
    required this.controlPlaneConnected,
    required this.sqlConnected,
    required this.syncIntervalMinutes,
  });

  final bool controlPlaneConnected;
  final bool sqlConnected;
  final int syncIntervalMinutes;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final controlPlaneColor =
            controlPlaneConnected
                ? const Color(0xFF2F855A)
                : const Color(0xFFC53030);
        final sqlColor =
            sqlConnected ? const Color(0xFF2F855A) : const Color(0xFFD69E2E);

        return Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 16 : 20,
            vertical: compact ? 14 : 16,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF152630),
            borderRadius: BorderRadius.circular(compact ? 20 : 24),
            border: Border.all(color: const Color(0xFF233A48)),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF213643),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFF314855)),
                ),
                child: const Text(
                  'SQL Sync Agent',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AgentStatusPill(
                label:
                    controlPlaneConnected
                        ? 'Control Plane Online'
                        : 'Control Plane Offline',
                color: controlPlaneColor,
              ),
              AgentStatusPill(
                label: sqlConnected ? 'SQL Ready' : 'SQL Not Ready',
                color: sqlColor,
              ),
              AgentStatusPill(
                label: 'Sync every $syncIntervalMinutes min',
                color: const Color(0xFF4A6A77),
              ),
            ],
          ),
        );
      },
    );
  }
}

class AgentSectionShell extends StatelessWidget {
  const AgentSectionShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.scrollChild = false,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool scrollChild;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFD),
        borderRadius: BorderRadius.circular(22),
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
          if (scrollChild)
            Expanded(child: SingleChildScrollView(child: child))
          else
            child,
        ],
      ),
    );
  }
}

class AgentSurfaceCard extends StatelessWidget {
  const AgentSurfaceCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.expandChild = false,
    this.titleWidget,
    this.headerTrailing,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool expandChild;
  final Widget? titleWidget;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackHeader = constraints.maxWidth < 720;

        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(stackHeader ? 16 : 22),
          decoration: BoxDecoration(
            color: const Color(0xFFFBFBF8),
            borderRadius: BorderRadius.circular(stackHeader ? 22 : 28),
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
              if (stackHeader) ...[
                titleWidget ??
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                if (headerTrailing != null) ...[
                  const SizedBox(height: 12),
                  headerTrailing!,
                ],
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child:
                          titleWidget ??
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                    ),
                    if (headerTrailing != null) ...[
                      const SizedBox(width: 12),
                      Flexible(child: headerTrailing!),
                    ],
                  ],
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
      },
    );
  }
}

class AgentMetricPill extends StatelessWidget {
  const AgentMetricPill({super.key, required this.label, required this.value});

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

class AgentProgressStrip extends StatelessWidget {
  const AgentProgressStrip({
    super.key,
    required this.progress,
    required this.color,
  });

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

class AgentEmptyStateCard extends StatelessWidget {
  const AgentEmptyStateCard({super.key, required this.message});

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 280;

        return SizedBox(
          width: narrow ? double.infinity : 248,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD8E0E5)),
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
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(detail, style: const TextStyle(height: 1.35)),
              ],
            ),
          ),
        );
      },
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
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
