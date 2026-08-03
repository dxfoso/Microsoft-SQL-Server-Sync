import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/data_export_policy.dart';

void main() {
  test('retries SQL Server Express backup without compression', () {
    expect(
      shouldRetryBackupWithoutCompression(
        exitCode: 1,
        stdout:
            'Msg 1844, Level 16: BACKUP DATABASE WITH COMPRESSION is not supported on Express Edition (64-bit).',
        stderr: '',
      ),
      isTrue,
    );
  });

  test('does not hide unrelated backup failures', () {
    expect(
      shouldRetryBackupWithoutCompression(
        exitCode: 1,
        stdout: 'Msg 3201: Access is denied.',
        stderr: '',
      ),
      isFalse,
    );
    expect(
      shouldRetryBackupWithoutCompression(
        exitCode: 0,
        stdout: 'compression',
        stderr: '',
      ),
      isFalse,
    );
  });
}
