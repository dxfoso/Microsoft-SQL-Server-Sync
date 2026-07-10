import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/database_selection.dart';
import 'package:sync_admin_web/models.dart';

void main() {
  test(
    'database selection storage key is scoped to the authenticated user',
    () {
      final first = _user(id: 'user-1', username: 'Admin');
      final second = _user(id: 'user-2', username: 'Admin');

      expect(
        databaseSelectionStorageKey(first),
        isNot(databaseSelectionStorageKey(second)),
      );
      expect(databaseSelectionStorageKey(first), contains('user-1'));
    },
  );

  test('restores a saved database when it is still available', () {
    expect(
      resolveDatabaseSelection(
        preferred: 'orders',
        available: ['customers', 'orders'],
      ),
      'orders',
    );
  });

  test(
    'falls back to the first database when the saved value is unavailable',
    () {
      expect(
        resolveDatabaseSelection(
          preferred: 'removed-database',
          available: ['customers', 'orders'],
        ),
        'customers',
      );
    },
  );

  test('returns no selection when no databases are available', () {
    expect(
      resolveDatabaseSelection(preferred: 'orders', available: const []),
      isNull,
    );
  });
}

AuthenticatedUser _user({required String id, required String username}) {
  return AuthenticatedUser(
    id: id,
    username: username,
    email: '$username@example.com',
    name: username,
    role: 'admin',
    ownerUserId: null,
    ownerUsername: null,
    ownerEmail: null,
    ownerName: null,
    createdByUserId: null,
    createdAt: '2026-07-10T00:00:00Z',
  );
}
