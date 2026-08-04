import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/client_instance.dart';

void main() {
  test('default instance preserves legacy identity, state, and shortcut', () {
    const instance = ClientInstanceConfig.defaultInstance();

    expect(instance.clientNameFor('Alshallan2'), 'Alshallan2');
    expect(instance.startupShortcutFileName, 'SQL Sync Agent.lnk');
    expect(
      instance.stateDirectory(environment: {'APPDATA': r'C:\Profile'}).path,
      contains('Microsoft-SQL-Server-Sync'),
    );
    expect(
      instance.stateDirectory(environment: {'APPDATA': r'C:\Profile'}).path,
      isNot(contains('${Platform.pathSeparator}instances')),
    );
  });

  test('secondary instance has isolated identity, state, and shortcut', () {
    final install = Directory.systemTemp.createTempSync('sql-sync-instance-');
    addTearDown(() => install.deleteSync(recursive: true));
    File(
      '${install.path}${Platform.pathSeparator}client-instance.json',
    ).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'id': 'sql8',
        'displayName': 'Alshallan2 SQL8',
      }),
    );

    final instance = ClientInstanceConfig.loadSync(
      executableDirectory: install,
    );

    expect(instance.clientNameFor('Alshallan2'), 'Alshallan2--sql8');
    expect(instance.windowLabel, 'Alshallan2 SQL8');
    expect(instance.startupShortcutFileName, 'SQL Sync Agent (sql8).lnk');
    expect(
      instance.stateDirectory(environment: {'APPDATA': r'C:\Profile'}).path,
      endsWith(
        'Microsoft-SQL-Server-Sync${Platform.pathSeparator}instances'
        '${Platform.pathSeparator}sql8',
      ),
    );
  });

  test('invalid marker cannot silently share the default state', () {
    final install = Directory.systemTemp.createTempSync('sql-sync-instance-');
    addTearDown(() => install.deleteSync(recursive: true));
    File(
      '${install.path}${Platform.pathSeparator}client-instance.json',
    ).writeAsStringSync(jsonEncode({'id': '../default'}));

    expect(
      () => ClientInstanceConfig.loadSync(executableDirectory: install),
      throwsFormatException,
    );
  });
}
