import 'dart:convert';

String parseLatestWindowsClientVersion(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return '';
  return decoded['version']?.toString().trim() ?? '';
}
