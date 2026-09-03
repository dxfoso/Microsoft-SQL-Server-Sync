import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/alameen_lab_automation.dart';

void main() {
  test('laboratory action catalogue does not allow arbitrary commands', () {
    expect(isAlameenLabAction('alameen_lab_inspect'), isTrue);
    expect(isAlameenLabAction(' ALAMEEN_LAB_INSPECT '), isTrue);
    expect(isAlameenLabAction('powershell'), isFalse);
    expect(isAlameenLabAction('alameen_lab_click'), isFalse);
  });

  test('inspection script is read only and bounded to a visible window', () {
    final script = buildAlameenWindowInspectionPowerShell();
    expect(script, contains('MainWindowHandle -ne 0'));
    expect(script, contains('Expected exactly one visible Al-Ameen window'));
    expect(script, contains('UIAutomationClient'));
    expect(script, isNot(contains('Invoke-Expression')));
    expect(script, isNot(contains('SendKeys')));
    expect(script, isNot(contains('Click')));
  });

  test('inspection parser requires a visible process identity', () {
    final parsed = parseAlameenWindowInspection(
      jsonEncode({
        'processId': 42,
        'windowTitle': 'Al-Ameen test',
        'controls': <Object>[],
      }),
    );
    expect(parsed['processId'], 42);
    expect(
      () => parseAlameenWindowInspection('{}'),
      throwsA(isA<FormatException>()),
    );
  });

  test('inspection acknowledgement remains below server field limit', () {
    final summary = boundedAlameenInspectionSummary({
      'processId': 42,
      'windowTitle': 'Al-Ameen test',
      'controls': List.generate(
        300,
        (index) => {'name': 'control-$index-${'x' * 80}'},
      ),
    });
    expect(summary.length, lessThanOrEqualTo(3800));
    final decoded = jsonDecode(summary) as Map<String, dynamic>;
    expect(decoded['truncated'], isTrue);
  });
}
