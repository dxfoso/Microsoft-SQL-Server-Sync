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
