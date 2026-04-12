import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/app.dart';

void main() {
  testWidgets('renders the admin dashboard sections', (tester) async {
    await tester.pumpWidget(const SyncAdminApp());

    expect(find.text('SQL Sync Control Plane'), findsAtLeastNWidgets(1));
    expect(find.text('Sync Plan Builder'), findsOneWidget);
    expect(find.text('Synced Clients'), findsOneWidget);
    expect(find.text('Machine Topology'), findsOneWidget);
    expect(find.text('Recent Runs'), findsOneWidget);
  });
}
