import 'package:flutter/material.dart';

import 'theme.dart';

final RegExp _rtlScriptPattern = RegExp(
  r'[֐-׿؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]',
);

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
        border: first
            ? null
            : Border(left: BorderSide(color: t.hairline)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            label,
            style: TextStyle(color: t.muted, fontSize: 12),
          ),
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
                child: stackHeader
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
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: child,
                ),
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
              style: TextStyle(
                color: t.muted,
                fontWeight: FontWeight.w600,
              ),
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
