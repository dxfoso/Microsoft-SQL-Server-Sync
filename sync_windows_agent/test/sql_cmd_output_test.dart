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

  test('decodes UTF-16LE sqlcmd output with a BOM', () {
    const value = '\u6570\u636e\u5e93\u9519\u8bef';
    final bytes = <int>[0xff, 0xfe];
    for (final codeUnit in value.codeUnits) {
      bytes.add(codeUnit & 0xff);
      bytes.add(codeUnit >> 8);
    }

    expect(decodeSqlCmdOutputBytes(bytes), value);
  });
}
