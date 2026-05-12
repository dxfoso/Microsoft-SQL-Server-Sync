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
                ? const Color(0xFF0F766E)
                : const Color(0xFFB42318);
        final sqlColor =
            sqlConnected ? const Color(0xFF0F766E) : const Color(0xFFB7791F);
        final statusColor =
            !controlPlaneConnected
                ? controlPlaneColor
                : (sqlConnected ? controlPlaneColor : sqlColor);
        final statusLabel =
            '${controlPlaneConnected ? 'Online' : 'Offline'} / ${sqlConnected ? 'SQL ready' : 'SQL pending'}';

        return Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 8 : 9,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDDE3EA)),
          ),
          child: Wrap(
            spacing: 7,
            runSpacing: 7,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4F1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFB7DDD7)),
                ),
                child: const Text(
                  'Agent',
                  style: TextStyle(
                    color: Color(0xFF0F766E),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              AgentStatusPill(label: statusLabel, color: statusColor),
              AgentStatusPill(
                label: 'Every $syncIntervalMinutes min',
                color: const Color(0xFF475467),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF667085), height: 1.4),
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
    this.showHeader = true,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool expandChild;
  final Widget? titleWidget;
  final Widget? headerTrailing;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackHeader = constraints.maxWidth < 720;

        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(stackHeader ? 12 : 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDDE3EA)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showHeader) ...[
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
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                ] else
                  const SizedBox(height: 12),
              ],
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF667085),
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
        backgroundColor: const Color(0xFFE4E7EC),
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
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE3EA)),
      ),
      child: Text(
        message,
        style: const TextStyle(height: 1.45, color: Color(0xFF667085)),
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
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFDDE3EA)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF667085),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
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
        color = const Color(0xFF0F766E);
      case AgentEventLevel.warning:
        color = const Color(0xFFB7791F);
      case AgentEventLevel.error:
        color = const Color(0xFFB42318);
    }

    return Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
