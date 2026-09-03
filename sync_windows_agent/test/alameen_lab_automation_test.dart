import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/alameen_lab_automation.dart';

void main() {
  test('laboratory action catalogue does not allow arbitrary commands', () {
    expect(isAlameenLabAction('alameen_lab_inspect'), isTrue);
    expect(isAlameenLabAction('alameen_lab_capture'), isTrue);
    expect(isAlameenLabAction('alameen_lab_invoice_menu_probe'), isTrue);
    expect(isAlameenLabAction('alameen_lab_sales_form_probe'), isTrue);
    expect(isAlameenLabAction(' ALAMEEN_LAB_INSPECT '), isTrue);
    expect(isAlameenLabAction('powershell'), isFalse);
    expect(isAlameenLabAction('alameen_lab_click'), isFalse);
  });

  test('sales form probe is visual fixed bounded and self restoring', () {
    final script = buildAlameenSalesFormProbePowerShell();
    expect(script, contains("className -ne 'XTPPopupBar'"));
    expect(script, contains(r'$popupInfo.left -ne 1099'));
    expect(script, contains(r'$popupInfo.top -ne 56'));
    expect(script, contains(r'$popupInfo.width -ne 234'));
    expect(script, contains(r'$popupInfo.height -ne 299'));
    expect(script, contains('Sales-row visual anchor did not match'));
    expect(script, contains(r'$rect.Left + 1216, $rect.Top + 70'));
    expect(script, contains(r'if ($salesChangedSamples -lt 1000)'));
    expect(script, contains(r'if ($restorationChangedSamples -gt 1500)'));
    expect(script, contains("probe = 'sales-form-open-only'"));
    expect(script, contains(r'$cleanupPerformed = $true'));
    expect(script, contains(r'if (-not $cleanupPerformed)'));
    expect(RegExp(r'keybd_event\(0x1B, 0, 0,').allMatches(script).length, 2);
    expect(script, isNot(contains('Invoke-Expression')));
    expect(script, isNot(contains('CopyFromScreen')));
    expect(script, isNot(contains('SendKeys')));
  });

  test('invoice menu probe is fixed screenshot guarded and self closing', () {
    final script = buildAlameenInvoiceMenuProbePowerShell();
    expect(script, contains(r'$width -ne 1382 -or $height -ne 744'));
    expect(
      script,
      contains(r"$path -notmatch '(?i)\\Al-Ameen\\81\\Bin\\Amn32\.exe$'"),
    );
    expect(script, contains(r"$classText.ToString() -notmatch '^Afx:'"));
    expect(script, contains('invoice-menu visual anchor did not match'));
    expect(script, contains(r'$rect.Left + 1295, $rect.Top + 48'));
    expect(script, contains('GetWindowThreadProcessId'));
    expect(script, contains('UIAutomationClient'));
    expect(script, contains(r'$menuControls.Add'));
    expect(script, contains('BoundingRectangle'));
    expect(script, contains('controlLimit = [Math]::Min'));
    expect(script, contains('PrintWindow'));
    expect(script, contains('changedSamples'));
    expect(script, contains(r'if ($changedSamples -lt 25)'));
    expect(
      script,
      isNot(contains(r'$changedSamples -lt 25 -and $ownedWindows.Count')),
    );
    expect(script, contains('keybd_event(0x1B'));
    expect(script, contains(r'SetCursorPos($cursor.X, $cursor.Y)'));
    expect(script, isNot(contains('Invoke-Expression')));
    expect(script, isNot(contains('CopyFromScreen')));
    expect(script, isNot(contains('SendKeys')));
  });

  test('invoice menu probe is valid Windows PowerShell syntax', () async {
    if (!Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp(
      'alameen_probe_parser_',
    );
    try {
      final script = File('${directory.path}\\probe.ps1');
      await script.writeAsString(buildAlameenInvoiceMenuProbePowerShell());
      final escapedPath = script.path.replaceAll("'", "''");
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$tokens=\$null;\$errors=\$null;[System.Management.Automation.Language.Parser]::ParseFile('$escapedPath',[ref]\$tokens,[ref]\$errors)|Out-Null;if(\$errors.Count -gt 0){\$errors|ForEach-Object{[Console]::Error.WriteLine(\$_.Message)};exit 1}",
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('sales form probe is valid Windows PowerShell syntax', () async {
    if (!Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp(
      'alameen_sales_probe_parser_',
    );
    try {
      final script = File('${directory.path}\\probe.ps1');
      await script.writeAsString(buildAlameenSalesFormProbePowerShell());
      final escapedPath = script.path.replaceAll("'", "''");
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$tokens=\$null;\$errors=\$null;[System.Management.Automation.Language.Parser]::ParseFile('$escapedPath',[ref]\$tokens,[ref]\$errors)|Out-Null;if(\$errors.Count -gt 0){\$errors|ForEach-Object{[Console]::Error.WriteLine(\$_.Message)};exit 1}",
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('capture script is read only window-scoped and payload bounded', () {
    final script = buildAlameenWindowCapturePowerShell();
    expect(script, contains('PrintWindow'));
    expect(script, contains('^amn32'));
    expect(script, contains(r'$candidate.Length -le 58000'));
    expect(script, isNot(contains('CopyFromScreen')));
    expect(script, isNot(contains('SendKeys')));
    expect(script, isNot(contains('mouse_event')));

    final capture = parseAlameenWindowCapture(
      jsonEncode({
        'processId': 42,
        'windowTitle': 'Al-Ameen test',
        'captureWidth': 480,
        'captureHeight': 270,
        'imageMimeType': 'image/jpeg',
        'imageBase64': base64Encode(<int>[0xff, 0xd8, 0xff, 0xd9]),
      }),
    );
    expect(capture['captureWidth'], 480);
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
