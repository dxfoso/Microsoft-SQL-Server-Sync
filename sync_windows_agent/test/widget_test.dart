import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/app.dart';

void main() {
  testWidgets('renders the windows agent tabs', (tester) async {
    await tester.pumpWidget(const SyncWindowsAgentApp(autoLoadOnStart: false));
    await tester.pump();

    expect(find.text('Table'), findsAtLeastNWidgets(1));
    expect(find.text('Sync'), findsAtLeastNWidgets(1));
  });
}
