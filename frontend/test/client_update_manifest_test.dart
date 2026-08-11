import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/client_update_manifest.dart';

void main() {
  test('reads the latest Windows client version from its public manifest', () {
    expect(
      parseLatestWindowsClientVersion(
        '{"version":"1.0.255+259","commit":"abc"}',
      ),
      '1.0.255+259',
    );
  });

  test('returns an empty label when the manifest has no version', () {
    expect(parseLatestWindowsClientVersion('{"commit":"abc"}'), isEmpty);
  });
}
