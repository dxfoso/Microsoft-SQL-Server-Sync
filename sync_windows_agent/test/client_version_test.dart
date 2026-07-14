import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/client_version.dart';

void main() {
  test('only accepts strictly newer client versions', () {
    expect(
      isStrictlyNewerClientVersion(
        current: '1.0.146+150',
        candidate: '1.0.147+151',
      ),
      isTrue,
    );
    expect(
      isStrictlyNewerClientVersion(
        current: '1.0.146+150',
        candidate: '1.0.145+149',
      ),
      isFalse,
    );
    expect(
      isStrictlyNewerClientVersion(
        current: '1.0.146+150',
        candidate: '1.0.146+150',
      ),
      isFalse,
    );
  });

  test('compares build numbers numerically and rejects malformed input', () {
    expect(
      isStrictlyNewerClientVersion(
        current: '1.0.9+99',
        candidate: '1.0.10+100',
      ),
      isTrue,
    );
    expect(
      isStrictlyNewerClientVersion(current: 'dev', candidate: '1.0.10+100'),
      isFalse,
    );
  });
}
