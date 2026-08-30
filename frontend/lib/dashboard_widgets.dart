import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

/// Local table name without the `database::` prefix or a leading `dbo.`.
String shortLocalTableName(String raw) {
  var name = raw;
  final sep = name.indexOf('::');
  if (sep >= 0) name = name.substring(sep + 2);
  return name.replaceFirst(RegExp(r'^dbo\.', caseSensitive: false), '');
}

final RegExp _rtlScriptPattern = RegExp(r'[֐-׿؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]');

TextDirection directionForDisplayText(String value) {
  return _rtlScriptPattern.hasMatch(value)
      ? TextDirection.rtl
      : TextDirection.ltr;
}

/// Compact global readout: hairline-separated cells with monospace values,
/// the way an instrument panel shows status.
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
    final t = AppTokens.of(context);
    final statusLabel = isConnected ? 'Online' : 'Offline';
    final statusColor = isConnected ? t.ok : t.crit;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: t.hairline),
      ),
      child: Wrap(
        spacing: 0,
        runSpacing: 0,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _ReadoutCell(
            label: 'Status',
            value: statusLabel,
            valueColor: statusColor,
            first: true,
          ),
          _ReadoutCell(label: 'Updated', value: lastUpdated),
          _ReadoutCell(label: 'Agents', value: '$totalAgents'),
          _ReadoutCell(label: 'Jobs', value: '$totalJobs'),
          if (selectedAgent != null && selectedAgent!.trim().isNotEmpty)
            _ReadoutCell(label: 'Client', value: selectedAgent!.trim()),
        ],
      ),
    );
  }
}

class _ReadoutCell extends StatelessWidget {
  const _ReadoutCell({
    required this.label,
    required this.value,
    this.valueColor,
    this.first = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: first ? null : Border(left: BorderSide(color: t.hairline)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label, style: TextStyle(color: t.muted, fontSize: 12)),
          const SizedBox(width: 6),
          Text(
            value,
            textDirection: directionForDisplayText(value),
            style: TextStyle(
              color: valueColor ?? t.ink,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              fontFamilyFallback: kMonoFallback,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bordered content panel with a hairline header rule. `subtitle` renders as a
/// quiet hint on the right of the header on wide layouts.
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
    final t = AppTokens.of(context);
    final hasSubtitle = subtitle.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackHeader = constraints.maxWidth < 560;

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: t.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.hairline)),
                ),
                child:
                    stackHeader
                        ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SurfaceCardHeading(
                              title: title,
                              subtitle: subtitle,
                              hasSubtitle: hasSubtitle,
                            ),
                            if (headerTrailing != null) ...[
                              const SizedBox(height: 8),
                              headerTrailing!,
                            ],
                          ],
                        )
                        : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: _SurfaceCardHeading(
                                title: title,
                                subtitle: subtitle,
                                hasSubtitle: hasSubtitle,
                              ),
                            ),
                            if (headerTrailing != null) ...[
                              const SizedBox(width: 8),
                              Flexible(child: headerTrailing!),
                            ],
                          ],
                        ),
              ),
              if (expandChild)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: child,
                  ),
                )
              else
                Padding(padding: const EdgeInsets.all(14), child: child),
            ],
          ),
        );
      },
    );
  }
}

/// Pill-shaped status chip: a state dot plus a label, so status never reads by
/// colour alone.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              textDirection: directionForDisplayText(label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
            ),
          ),
        ],
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
    final t = AppTokens.of(context);
    final value = progress.clamp(0, 100) / 100;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 5,
        backgroundColor: t.hairline,
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
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.hairline),
      ),
      child: Text.rich(
        textDirection: directionForDisplayText('$label $value'),
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(color: t.muted, fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: t.ink,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
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
    final t = AppTokens.of(context);
    return Text.rich(
      textDirection: directionForDisplayText('$label $value'),
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(
              color: t.muted,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              color: t.ink,
              fontWeight: FontWeight.w600,
              fontSize: 12,
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
    final t = AppTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: t.hairline),
      ),
      child: Text(
        message,
        textDirection: directionForDisplayText(message),
        style: TextStyle(height: 1.45, color: t.muted),
      ),
    );
  }
}

/// Semantic state, kept separate from the interactive accent.
enum StateTone { neutral, ok, warn, crit, info }

Color toneColor(BuildContext context, StateTone tone) {
  final t = AppTokens.of(context);
  switch (tone) {
    case StateTone.ok:
      return t.ok;
    case StateTone.warn:
      return t.warn;
    case StateTone.crit:
      return t.crit;
    case StateTone.info:
      return t.info;
    case StateTone.neutral:
      return t.muted;
  }
}

Color toneWash(BuildContext context, StateTone tone) {
  final t = AppTokens.of(context);
  switch (tone) {
    case StateTone.ok:
      return t.okWash;
    case StateTone.warn:
      return t.warnWash;
    case StateTone.crit:
      return t.critWash;
    case StateTone.info:
      return t.infoWash;
    case StateTone.neutral:
      return t.surface2;
  }
}

/// A single readout in the dashboard "Situation" strip: a label, one large
/// value, a supporting line, and a left severity stripe.
class SituationTile extends StatelessWidget {
  const SituationTile({
    super.key,
    required this.label,
    required this.value,
    required this.detail,
    this.tone = StateTone.neutral,
    this.valueSuffix,
    this.detailTone,
  });

  final String label;
  final String value;
  final String? valueSuffix;
  final String detail;
  final StateTone tone;
  final StateTone? detailTone;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final stripe = toneColor(context, tone);
    final dotTone = detailTone ?? tone;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 26,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: stripe,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              text: value,
              children: [
                if (valueSuffix != null)
                  TextSpan(
                    text: ' ${valueSuffix!}',
                    style: TextStyle(
                      color: t.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            style: TextStyle(
              color: t.ink,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.02 * 24,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (detail.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(top: 4, right: 6),
                  decoration: BoxDecoration(
                    color: toneColor(context, dotTone),
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Text(
                    detail,
                    textDirection: directionForDisplayText(detail),
                    style: TextStyle(
                      color: t.ink2,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
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
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          textDirection: directionForDisplayText(title),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (hasSubtitle) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            textDirection: directionForDisplayText(subtitle),
            style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.3),
          ),
        ],
      ],
    );
  }
}

/// The dashboard "Situation" strip: five state tiles answering
/// "is anything wrong right now?" before any table. Reused by the merged
/// operations page and the legacy dashboard.
class SituationStrip extends StatelessWidget {
  const SituationStrip({super.key, required this.state, this.maxWidth});

  final AdminLiveState state;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final agents = state.agents;
    final onlineCount = agents.where((a) => a.isOnline).length;
    final offline = agents.where((a) => !a.isOnline).toList(growable: false);
    final activeJobs = state.jobs
        .where((j) => j.isActive)
        .toList(growable: false);
    final gate = state.syncGate;
    final uploads =
        activeJobs.where((j) => j.direction.toLowerCase() == 'upload').length;
    final downloads =
        activeJobs.where((j) => j.direction.toLowerCase() == 'download').length;
    final firstBatch = activeJobs.isNotEmpty ? activeJobs.first.batchId : '';

    final tiles = <Widget>[
      SituationTile(
        label: 'Sync gate',
        value: gate.blocked ? 'Blocked' : 'Ready',
        tone: gate.blocked ? StateTone.crit : StateTone.ok,
        detail:
            gate.blocked
                ? (gate.message.trim().isNotEmpty
                    ? gate.message.trim()
                    : 'Sync held')
                : 'Clear to sync',
      ),
      SituationTile(
        label: 'Clients online',
        value: '$onlineCount',
        valueSuffix: '/ ${agents.length}',
        tone:
            agents.isEmpty
                ? StateTone.neutral
                : (offline.isEmpty ? StateTone.ok : StateTone.warn),
        detailTone: offline.isEmpty ? StateTone.ok : StateTone.warn,
        detail:
            offline.isEmpty
                ? 'All connected'
                : '${offline.first.clientName} offline'
                    '${offline.length > 1 ? ' +${offline.length - 1}' : ''}',
      ),
      SituationTile(
        label: 'Active jobs',
        value: '${activeJobs.length}',
        tone: activeJobs.isEmpty ? StateTone.ok : StateTone.info,
        detail:
            activeJobs.isEmpty
                ? 'Idle'
                : '$uploads upload · $downloads download'
                    '${firstBatch.isNotEmpty ? ' · $firstBatch' : ''}',
      ),
      SituationTile(
        label: 'Pending decisions',
        value: '${gate.decisionCount}',
        tone: gate.decisionCount > 0 ? StateTone.crit : StateTone.ok,
        detailTone: gate.resolvingCount > 0 ? StateTone.warn : StateTone.ok,
        detail:
            gate.decisionCount > 0
                ? 'Resolve to unblock sync'
                : (gate.resolvingCount > 0
                    ? '${gate.resolvingCount} '
                        '${gate.resolvingCount == 1 ? 'conflict' : 'conflicts'} '
                        'resolving automatically'
                    : 'None'),
      ),
      SituationTile(
        label: 'Automatic sync',
        value: state.automaticSyncPaused ? 'Paused' : 'Active',
        tone: state.automaticSyncPaused ? StateTone.warn : StateTone.ok,
        detail: state.automaticSyncPaused ? 'Manual runs only' : 'Scheduled',
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final w = maxWidth ?? c.maxWidth;
        final columns = !w.isFinite || w >= 1180 ? 5 : (w >= 760 ? 3 : 2);
        const spacing = 10.0;
        final tileWidth =
            w.isFinite ? (w - spacing * (columns - 1)) / columns : 220.0;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }
}

/// Conditional panel: failed jobs and unsettled conflicts, with the
/// "resolving automatically" vs "waiting on you" split made explicit.
/// Renders nothing when there is nothing to act on.
class AttentionPanel extends StatelessWidget {
  const AttentionPanel({super.key, required this.state, this.onResolveBlocked});

  final AdminLiveState state;

  /// When sync is stopped on user decisions, this opens the in-page resolver.
  final VoidCallback? onResolveBlocked;

  @override
  Widget build(BuildContext context) {
    final failed = state.jobs
        .where((j) => j.status.toLowerCase() == 'failed')
        .toList(growable: false);
    final gate = state.syncGate;
    final blockers = gate.issues
        .where((i) => i.needsInput)
        .toList(growable: false);
    if (failed.isEmpty && gate.decisionCount == 0 && gate.resolvingCount == 0) {
      return const SizedBox.shrink();
    }
    final t = AppTokens.of(context);
    final stopped = gate.blocked && gate.decisionCount > 0;

    final rows = <Widget>[
      for (final issue in blockers.take(8))
        _AttentionRow(
          tone: StateTone.crit,
          table: shortLocalTableName(issue.table),
          description: _issueLine(issue),
          chipLabel: 'Decision needed',
        ),
      for (final job in failed.take(6))
        _AttentionRow(
          tone: StateTone.crit,
          table: shortLocalTableName(job.table),
          description:
              (job.error?.trim().isNotEmpty ?? false)
                  ? job.error!.trim()
                  : (job.message.trim().isNotEmpty
                      ? job.message.trim()
                      : 'Sync job failed'),
          chipLabel: 'Failed',
        ),
      if (gate.resolvingCount > 0)
        _AttentionRow(
          tone: StateTone.warn,
          table:
              '${gate.resolvingCount} ${gate.resolvingCount == 1 ? 'table' : 'tables'}',
          description:
              gate.message.trim().isNotEmpty
                  ? gate.message.trim()
                  : 'Automatic latest-change repair is verifying results. '
                      'No user decision is required.',
          chipLabel: 'Resolving',
        ),
    ];

    final decisionLine = '${gate.decisionCount} waiting on you';
    final headline =
        stopped
            ? 'All sync is stopped — $decisionLine'
            : (gate.resolvingCount > 0
                ? '${gate.resolvingCount} repairing · $decisionLine'
                : (failed.isNotEmpty
                    ? '${failed.length} failed ${failed.length == 1 ? 'job' : 'jobs'} · $decisionLine'
                    : decisionLine));

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: Color.lerp(t.hairline, stopped ? t.crit : t.warn, 0.5)!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
            decoration: BoxDecoration(
              color: stopped ? t.critWash : t.warnWash,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(6),
              ),
              border: Border(
                bottom: BorderSide(
                  color:
                      Color.lerp(t.hairline, stopped ? t.crit : t.warn, 0.35)!,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  stopped
                      ? Icons.pause_circle_outline_rounded
                      : Icons.report_problem_outlined,
                  size: 16,
                  color: stopped ? t.crit : t.warn,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stopped ? headline : 'Needs a look — $headline',
                    style: TextStyle(
                      color: stopped ? t.crit : t.warn,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (stopped && onResolveBlocked != null) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: onResolveBlocked,
                    icon: const Icon(Icons.build_circle_outlined, size: 16),
                    label: const Text('Show & resolve'),
                    style: FilledButton.styleFrom(
                      backgroundColor: t.crit,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.hairline2),
            rows[i],
          ],
        ],
      ),
    );
  }

  static String _issueLine(AdminTableSyncIssue issue) {
    final parts = <String>[];
    if (issue.clientName.trim().isNotEmpty) parts.add(issue.clientName.trim());
    final detail =
        issue.message.trim().isNotEmpty
            ? issue.message.trim()
            : (issue.reason.trim().isNotEmpty
                ? issue.reason.trim()
                : 'Waiting for a decision before sync can continue.');
    parts.add(detail);
    return parts.join(' · ');
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.tone,
    required this.table,
    required this.description,
    required this.chipLabel,
  });

  final StateTone tone;
  final String table;
  final String description;
  final String chipLabel;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 5, right: 10),
            decoration: BoxDecoration(
              color: toneColor(context, tone),
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(
            width: 104,
            child: Text(
              table,
              textDirection: directionForDisplayText(table),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              description,
              textDirection: directionForDisplayText(description),
              style: TextStyle(color: t.ink2, fontSize: 12.5, height: 1.3),
            ),
          ),
          const SizedBox(width: 12),
          StatusBadge(label: chipLabel, color: toneColor(context, tone)),
        ],
      ),
    );
  }
}
