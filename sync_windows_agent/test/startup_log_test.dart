import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/startup_log.dart';

void main() {
  test(
    'retains semantic and failure events but drops routine success noise',
    () {
      expect(
        shouldRetainAgentDiagnostic(
          'sync.download.buffered',
          AgentLogLevel.info,
        ),
        isTrue,
      );
      expect(
        shouldRetainAgentDiagnostic(
          'control_plane.request.failed',
          AgentLogLevel.error,
        ),
        isTrue,
      );
      expect(
        shouldRetainAgentDiagnostic('sqlcmd.completed', AgentLogLevel.error),
        isTrue,
      );
      expect(
        shouldRetainAgentDiagnostic('sqlcmd.completed', AgentLogLevel.debug),
        isFalse,
      );
      expect(
        shouldRetainAgentDiagnostic(
          'control_plane.request.completed',
          AgentLogLevel.debug,
        ),
        isFalse,
      );
      expect(
        shouldRetainAgentDiagnostic(
          'sync.policy.disabled_change_detected',
          AgentLogLevel.debug,
        ),
        isFalse,
      );
    },
  );

  test('redacts bearer tokens, passwords, cookies, and URL credentials', () {
    final redacted = redactAgentLogText(
      'Authorization: Bearer abc.def.ghi '
      'password=SuperSecret '
      'cookie: session-value '
      'https://user:pass@example.test/call',
    );

    expect(redacted, isNot(contains('abc.def.ghi')));
    expect(redacted, isNot(contains('SuperSecret')));
    expect(redacted, isNot(contains('session-value')));
    expect(redacted, isNot(contains('user:pass')));
    expect(redacted, contains('[REDACTED]'));
  });

  test('redacts sqlcmd password arguments without hiding safe context', () {
    final redacted = redactAgentLogText(
      'sqlcmd -S .\\SQLEXPRESS -U sync_user -P "private value" -d AmnDb028',
    );

    expect(redacted, contains('.\\SQLEXPRESS'));
    expect(redacted, contains('AmnDb028'));
    expect(redacted, isNot(contains('private value')));
    expect(redacted, contains('-P [REDACTED]'));
  });
}
