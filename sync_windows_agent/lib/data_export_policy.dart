import 'dart:convert';

bool shouldRetryBackupWithoutCompression({
  required int exitCode,
  required String stdout,
  required String stderr,
}) {
  if (exitCode == 0) return false;
  final details = '$stdout\n$stderr'.toLowerCase();
  return details.contains(
        'backup database with compression is not supported',
      ) ||
      (details.contains('msg 1844') && details.contains('compression'));
}

int parseSqlServerBlobLength(String output) {
  for (final line in const LineSplitter().convert(output)) {
    final value = int.tryParse(line.trim());
    if (value != null && value >= 0) return value;
  }
  throw const FormatException('SQL Server did not return a valid file length.');
}

List<int> decodeSqlServerHexBlob(String output) {
  final hex = StringBuffer();
  final hexLine = RegExp(r'^[0-9A-Fa-f]+$');
  for (final line in const LineSplitter().convert(output)) {
    final value = line.trim();
    if (value.isNotEmpty && hexLine.hasMatch(value)) hex.write(value);
  }
  final encoded = hex.toString();
  if (encoded.isEmpty || encoded.length.isOdd) {
    throw const FormatException('SQL Server returned an invalid binary chunk.');
  }
  return List<int>.generate(
    encoded.length ~/ 2,
    (index) =>
        int.parse(encoded.substring(index * 2, index * 2 + 2), radix: 16),
    growable: false,
  );
}
