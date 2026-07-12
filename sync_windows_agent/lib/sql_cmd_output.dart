import 'dart:convert';
import 'dart:typed_data';

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
