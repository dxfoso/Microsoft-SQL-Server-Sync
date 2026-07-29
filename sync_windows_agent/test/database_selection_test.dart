import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sync_state.dart';

void main() {
  test('velvet factory keeps AmnDb048 as its automatic database target', () {
    expect(
      automaticDatabaseTargetForClient(clientName: 'velvet factory'),
      'AmnDb048',
    );
    expect(
      automaticDatabaseTargetForClient(
        clientName: 'Local Agent',
        accountUsername: ' Velvet Factory ',
      ),
      'AmnDb048',
    );
  });

  test('other clients do not receive a forced automatic database target', () {
    expect(automaticDatabaseTargetForClient(clientName: 'velvet home'), isNull);
  });

  test('restores the saved database when it is still available', () {
    expect(
      resolveSavedDatabaseSelection(
        saved: 'orders',
        available: ['customers', 'orders'],
        defaultDatabase: 'customers',
      ),
      'orders',
    );
  });

  test('falls back safely when the saved database was removed', () {
    expect(
      resolveSavedDatabaseSelection(
        saved: 'removed-database',
        available: ['customers', 'orders'],
        defaultDatabase: 'orders',
      ),
      'orders',
    );
  });

  test('uses the first database when no saved or preferred value exists', () {
    expect(
      resolveSavedDatabaseSelection(
        saved: null,
        available: ['customers', 'orders'],
      ),
      'customers',
    );
  });

  test('returns null when database discovery is empty', () {
    expect(
      resolveSavedDatabaseSelection(saved: 'orders', available: const []),
      isNull,
    );
  });
}
