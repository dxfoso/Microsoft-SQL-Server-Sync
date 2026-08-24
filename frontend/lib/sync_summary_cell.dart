import 'package:flutter/material.dart';

class SyncSummaryItem {
  const SyncSummaryItem({
    required this.label,
    required this.value,
    this.tooltip,
  });

  final String label;
  final String value;
  final String? tooltip;
}

class SyncSummaryCell extends StatelessWidget {
  const SyncSummaryCell({
    super.key,
    required this.items,
    this.width = 210,
    this.trailing,
  });

  final List<SyncSummaryItem> items;
  final double width;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    assert(items.length == 3);
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: items
                  .map(
                    (item) => Tooltip(
                      message: item.tooltip ?? '${item.label}: ${item.value}',
                      child: SizedBox(
                        height: 24,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 56,
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF667085),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                item.value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF101828),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
