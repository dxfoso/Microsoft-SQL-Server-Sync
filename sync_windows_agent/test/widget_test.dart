import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/app.dart';

void main() {
  testWidgets('renders the windows agent dashboard sections', (tester) async {
    await tester.pumpWidget(const SyncWindowsAgentApp(autoLoadOnStart: false));

    expect(find.text('SQL Sync Agent'), findsOneWidget);
    expect(find.text('Sync'), findsOneWidget);
  });
}
