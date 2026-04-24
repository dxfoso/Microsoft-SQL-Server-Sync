import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/app.dart';

void main() {
  testWidgets('renders the website login gate', (tester) async {
    await tester.pumpWidget(const SyncAdminApp());

    expect(find.text('Website Login'), findsOneWidget);
    expect(find.text('Open Dashboard'), findsOneWidget);
  });
}
