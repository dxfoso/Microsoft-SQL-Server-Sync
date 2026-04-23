import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/app.dart';

void main() {
  testWidgets('renders the client login screen', (tester) async {
    await tester.pumpWidget(const SyncWindowsAgentApp(autoLoadOnStart: false));
    await tester.pump();

    expect(find.text('Client Login'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Open Agent'), findsOneWidget);
  });
}
