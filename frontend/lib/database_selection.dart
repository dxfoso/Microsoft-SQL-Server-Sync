import 'models.dart';

const String databaseSelectionStoragePrefix =
    'sync_admin_web.selected_database.';

String databaseSelectionStorageKey(AuthenticatedUser user) {
  final candidates = <String>[user.id, user.username, user.email];
  final identity = candidates
      .map((value) => value.trim().toLowerCase())
      .firstWhere((value) => value.isNotEmpty, orElse: () => 'unknown');
  return '$databaseSelectionStoragePrefix${Uri.encodeComponent(identity)}';
}

String? resolveDatabaseSelection({
  required String? preferred,
  required List<String> available,
}) {
  final normalizedPreferred = preferred?.trim();
  if (normalizedPreferred != null &&
      normalizedPreferred.isNotEmpty &&
      available.contains(normalizedPreferred)) {
    return normalizedPreferred;
  }
  return available.isEmpty ? null : available.first;
}
