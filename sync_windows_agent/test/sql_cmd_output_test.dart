import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_cmd_output.dart';

void main() {
  test('keeps even-length UTF-8 Chinese output intact', () {
    const value = '\u6570\u636e\u5e93\u9519\u8bef\u4e2d';
    final bytes = utf8.encode(value);

    expect(bytes.length.isEven, isTrue);
    expect(decodeSqlCmdOutputBytes(bytes), value);
  });

  test('keeps UTF-8 Arabic SQL errors intact', () {
    const value = 'AmnW0062: رصيد المنتج أقل من صفر';

    expect(decodeSqlCmdOutputBytes(utf8.encode(value)), value);
  });

  test('decodes UTF-16LE sqlcmd output with a BOM', () {
    const value = '\u6570\u636e\u5e93\u9519\u8bef';
    final bytes = <int>[0xff, 0xfe];
    for (final codeUnit in value.codeUnits) {
      bytes.add(codeUnit & 0xff);
      bytes.add(codeUnit >> 8);
    }

    expect(decodeSqlCmdOutputBytes(bytes), value);
  });

  test('decodes SQL Server UTF-16 hex without a console code page', () {
    const value = 'العربية 🌍 漢字';
    final hex =
        value.codeUnits
            .expand(
              (codeUnit) => [
                (codeUnit & 0xff).toRadixString(16).padLeft(2, '0'),
                (codeUnit >> 8).toRadixString(16).padLeft(2, '0'),
              ],
            )
            .join();

    expect(decodeSqlServerUtf16Hex(hex), value);
  });

  test('rejects malformed SQL Server UTF-16 hex', () {
    expect(
      () => decodeSqlServerUtf16Hex('062'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => decodeSqlServerUtf16Hex('GGGG'),
      throwsA(isA<FormatException>()),
    );
  });

  test('decodes framed UTF-16 hex rows without delimiter ambiguity', () {
    final rows = [
      <String?>[
        'U',
        '42',
        '2026-07-25T19:13:15.123Z',
        'العربية 🌍 漢字',
        'contains ${String.fromCharCode(31)} and | and \r\n text',
        null,
      ],
      <String?>[
        'D',
        '43',
        '',
        r'literal \n \u001f \\ stays literal',
        List.filled(40000, 'X').join(),
        '🙂',
      ],
    ];
    final output = rows
        .map((row) {
          final encoded = row.map((value) {
            if (value == null) return 'N';
            final hex = value.codeUnits
                .map(
                  (codeUnit) =>
                      '${(codeUnit & 0xff).toRadixString(16).padLeft(2, '0')}'
                      '${(codeUnit >> 8).toRadixString(16).padLeft(2, '0')}',
                )
                .join();
            return 'H$hex';
          }).join('|');
          final framed = '$encoded$sqlSyncHexRowTerminator';
          return RegExp(
            '.{1,97}',
          ).allMatches(framed).map((match) => match.group(0)).join('\r\n');
        })
        .join('\r\n');

    expect(decodeSqlServerHexRows(output), rows);
  });

  test('decodes a row when sqlcmd splits the row terminator', () {
    final splitTerminator =
        '${sqlSyncHexRowTerminator.substring(0, 7)}\r\n'
        '${sqlSyncHexRowTerminator.substring(7)}';

    expect(decodeSqlServerHexRows('H5500$splitTerminator'), [
      ['U'],
    ]);
  });

  test('rejects malformed framed UTF-16 hex rows', () {
    expect(
      () => decodeSqlServerHexRows(
        'invalid$sqlSyncHexRowTerminator',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => decodeSqlServerHexRows(
        'H001$sqlSyncHexRowTerminator',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('always uses an input file for Windows sqlcmd queries', () {
    expect(
      shouldUseSqlCmdInputFile(isWindows: true, query: 'SELECT Nالعربية'),
      isTrue,
    );
    expect(
      shouldUseSqlCmdInputFile(isWindows: false, query: 'SELECT 1'),
      isFalse,
    );
    expect(
      shouldUseSqlCmdInputFile(
        isWindows: false,
        query: List.filled(24001, 'x').join(),
      ),
      isTrue,
    );
  });
}
