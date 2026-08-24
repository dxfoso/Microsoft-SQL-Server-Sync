import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/sync_summary_cell.dart';

void main() {
  testWidgets('sync summary renders the three workflow types consistently', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SyncSummaryCell(
            items: [
              SyncSummaryItem(label: 'Changes', value: 'Up 12 · Down 4'),
              SyncSummaryItem(label: 'Sync All', value: '25/31 tables'),
              SyncSummaryItem(label: 'Integrity', value: '120/551 tables'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Sync All'), findsOneWidget);
    expect(find.text('Integrity'), findsOneWidget);
    expect(find.text('Up 12 · Down 4'), findsOneWidget);
    expect(find.text('25/31 tables'), findsOneWidget);
    expect(find.text('120/551 tables'), findsOneWidget);
  });
}
