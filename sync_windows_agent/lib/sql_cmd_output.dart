import 'dart:convert';
import 'dart:typed_data';

const String sqlSyncBase64RowTerminator = '~SQLSYNC_ROW_END~';

String decodeSqlCmdOutputBytes(List<int> bytes) {
  if (bytes.isEmpty) {
    return '';
  }

  final data = Uint8List.fromList(bytes);
  if (_looksLikeUtf16Le(data)) {
    return _decodeUtf16Le(data);
  }

  // sqlcmd can emit UTF-8 even when the byte count is even. Never use byte
  // length alone as an encoding signal or Chinese/Arabic text becomes mojibake.
  return utf8.decode(data, allowMalformed: true);
}

bool shouldUseSqlCmdInputFile({
  required bool isWindows,
  required String query,
  int maxInlineQueryLength = 24000,
}) {
  return isWindows || query.length > maxInlineQueryLength;
}

String decodeSqlServerUtf16Hex(String hex) {
  if (hex.isEmpty) {
    return '';
  }
  if (hex.length % 4 != 0 || !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(hex)) {
    throw const FormatException('Invalid SQL Server UTF-16 hex payload.');
  }

  final codeUnits = <int>[];
  for (var offset = 0; offset < hex.length; offset += 4) {
    final lowByte = int.parse(hex.substring(offset, offset + 2), radix: 16);
    final highByte = int.parse(
      hex.substring(offset + 2, offset + 4),
      radix: 16,
    );
    codeUnits.add(lowByte | (highByte << 8));
  }
  return String.fromCharCodes(codeUnits);
}

List<Map<String, dynamic>> decodeSqlServerBase64JsonRows(
  String output, {
  String rowTerminator = sqlSyncBase64RowTerminator,
}) {
  if (rowTerminator.isEmpty) {
    throw ArgumentError('rowTerminator must not be empty.');
  }
  final rows = <Map<String, dynamic>>[];
  final fragments = output.split(rowTerminator);
  for (final fragment in fragments) {
    final encoded = fragment
        .replaceAll('\ufeff', '')
        .replaceAll(RegExp(r'\s+'), '');
    if (encoded.isEmpty) {
      continue;
    }
    late final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException(
        'Invalid Base64 Change Tracking row payload.',
      );
    }
    if (bytes.length.isOdd) {
      throw const FormatException(
        'Invalid UTF-16LE Change Tracking row payload.',
      );
    }
    final decoded = jsonDecode(_decodeUtf16Le(Uint8List.fromList(bytes)));
    if (decoded is! Map) {
      throw const FormatException(
        'Change Tracking row payload must be a JSON object.',
      );
    }
    rows.add(
      Map<String, dynamic>.fromEntries(
        decoded.entries.map(
          (entry) => MapEntry(entry.key.toString(), entry.value),
        ),
      ),
    );
  }
  return rows;
}

bool _looksLikeUtf16Le(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return true;
  }
  if (bytes.length < 4) {
    return false;
  }

  var oddZeroCount = 0;
  var sampledPairs = 0;
  for (var index = 1; index < bytes.length && sampledPairs < 32; index += 2) {
    sampledPairs += 1;
    if (bytes[index] == 0) {
      oddZeroCount += 1;
    }
  }
  return sampledPairs >= 4 && oddZeroCount * 2 >= sampledPairs;
}

String _decodeUtf16Le(Uint8List bytes) {
  var offset = 0;
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    offset = 2;
  }
  final usableLength = bytes.length - ((bytes.length - offset) % 2);
  final codeUnits = <int>[];
  for (var index = offset; index < usableLength; index += 2) {
    codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
  }
  return String.fromCharCodes(codeUnits);
}
