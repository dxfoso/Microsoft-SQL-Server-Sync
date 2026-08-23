import 'dart:convert';

const int kPrivateExportArtifactBytes = 256 * 1024;

Duration privateExportUploadTimeout(int bytes) {
  if (bytes < 0) {
    throw ArgumentError.value(bytes, 'bytes', 'must not be negative');
  }
  const minimum = Duration(minutes: 5);
  const maximum = Duration(minutes: 15);
  const assumedMinimumBytesPerSecond = 512;
  const responseGraceSeconds = 120;
  final transferSeconds =
      ((bytes + assumedMinimumBytesPerSecond - 1) ~/
          assumedMinimumBytesPerSecond) +
      responseGraceSeconds;
  final boundedSeconds = transferSeconds.clamp(
    minimum.inSeconds,
    maximum.inSeconds,
  );
  return Duration(seconds: boundedSeconds);
}

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
