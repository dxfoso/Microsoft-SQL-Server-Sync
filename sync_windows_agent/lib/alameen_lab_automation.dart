import 'dart:convert';

const String alameenLabInspectAction = 'alameen_lab_inspect';

bool isAlameenLabAction(String action) =>
    action.trim().toLowerCase() == alameenLabInspectAction;

String buildAlameenWindowInspectionPowerShell() => r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient

$candidates = @(Get-Process | Where-Object {
  $_.MainWindowHandle -ne 0 -and (
    $_.ProcessName -match '(?i)amn|ameen' -or
    $_.MainWindowTitle -match 'الأمين|(?i)al[- ]?ameen|ameen'
  )
})

if ($candidates.Count -eq 0) {
  throw 'No visible Al-Ameen window was found.'
}
if ($candidates.Count -ne 1) {
  throw "Expected exactly one visible Al-Ameen window; found $($candidates.Count)."
}

$process = $candidates[0]
$root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
if ($null -eq $root) {
  throw 'Windows UI Automation could not attach to the Al-Ameen window.'
}

$controls = @()
$elements = $root.FindAll(
  [System.Windows.Automation.TreeScope]::Descendants,
  [System.Windows.Automation.Condition]::TrueCondition
)
$limit = [Math]::Min($elements.Count, 250)
for ($index = 0; $index -lt $limit; $index++) {
  $element = $elements.Item($index)
  $current = $element.Current
  if (-not [string]::IsNullOrWhiteSpace($current.Name) -or
      -not [string]::IsNullOrWhiteSpace($current.AutomationId)) {
    $controls += [ordered]@{
      name = $current.Name
      automationId = $current.AutomationId
      className = $current.ClassName
      controlType = $current.ControlType.ProgrammaticName
      enabled = $current.IsEnabled
    }
  }
}

$path = ''
try { $path = $process.Path } catch { $path = '' }
[ordered]@{
  processId = $process.Id
  processName = $process.ProcessName
  executablePath = $path
  windowHandle = [long]$process.MainWindowHandle
  windowTitle = $process.MainWindowTitle
  rootName = $root.Current.Name
  rootClassName = $root.Current.ClassName
  discoveredControlCount = $elements.Count
  returnedControlCount = $controls.Count
  controls = $controls
} | ConvertTo-Json -Depth 5 -Compress
''';

Map<String, dynamic> parseAlameenWindowInspection(String output) {
  final trimmed = output.trim().replaceFirst('\u{feff}', '');
  if (trimmed.isEmpty) {
    throw const FormatException('Al-Ameen inspection returned no output.');
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map) {
    throw const FormatException('Al-Ameen inspection returned invalid JSON.');
  }
  final result = Map<String, dynamic>.from(decoded);
  final processId = (result['processId'] as num?)?.round() ?? 0;
  final windowTitle = result['windowTitle']?.toString().trim() ?? '';
  if (processId <= 0 || windowTitle.isEmpty) {
    throw const FormatException(
      'Al-Ameen inspection did not identify a visible process and window.',
    );
  }
  return result;
}

String boundedAlameenInspectionSummary(
  Map<String, dynamic> inspection, {
  int maxCharacters = 3800,
}) {
  if (maxCharacters < 128) {
    throw ArgumentError.value(maxCharacters, 'maxCharacters', 'is too small');
  }
  final encoded = jsonEncode(inspection);
  if (encoded.length <= maxCharacters) return encoded;

  final bounded = Map<String, dynamic>.from(inspection);
  final controls = inspection['controls'];
  if (controls is List) {
    final retained = <dynamic>[];
    for (final control in controls) {
      retained.add(control);
      bounded['controls'] = retained;
      bounded['truncated'] = true;
      if (jsonEncode(bounded).length > maxCharacters) {
        retained.removeLast();
        break;
      }
    }
    bounded['controls'] = retained;
    bounded['truncated'] = true;
  }
  final result = jsonEncode(bounded);
  if (result.length > maxCharacters) {
    throw const FormatException(
      'Al-Ameen inspection identity exceeds the acknowledgement limit.',
    );
  }
  return result;
}
