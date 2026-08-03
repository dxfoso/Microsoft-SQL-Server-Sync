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

  test('parses SQL Server blob length from headerless output', () {
    expect(parseSqlServerBlobLength('\u{feff}  8388609\r\n'), 8388609);
  });

  test('decodes wrapped SQL Server hexadecimal output', () {
    expect(
      decodeSqlServerHexBlob('DEADBEEF\r\n0102\r\n(1 row affected)'),
      <int>[0xde, 0xad, 0xbe, 0xef, 1, 2],
    );
  });

  test('rejects empty or incomplete SQL Server hexadecimal output', () {
    expect(() => decodeSqlServerHexBlob(''), throwsFormatException);
    expect(() => decodeSqlServerHexBlob('ABC'), throwsFormatException);
  });
}
