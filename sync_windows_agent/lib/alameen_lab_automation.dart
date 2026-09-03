import 'dart:convert';

const String alameenLabInspectAction = 'alameen_lab_inspect';
const String alameenLabCaptureAction = 'alameen_lab_capture';

bool isAlameenLabAction(String action) => <String>{
  alameenLabInspectAction,
  alameenLabCaptureAction,
}.contains(action.trim().toLowerCase());

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

String buildAlameenWindowCapturePowerShell() => r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AlameenCaptureNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
}
'@

$candidates = @(Get-Process | Where-Object {
  $_.MainWindowHandle -ne 0 -and (
    $_.ProcessName -match '(?i)^amn32$|ameen' -or
    $_.MainWindowTitle -match 'الأمين|(?i)al[- ]?ameen|ameen'
  )
})
if ($candidates.Count -ne 1) {
  throw "Expected exactly one visible Al-Ameen window; found $($candidates.Count)."
}
$process = $candidates[0]
$rect = New-Object AlameenCaptureNative+RECT
if (-not [AlameenCaptureNative]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
  throw 'Could not read the Al-Ameen window bounds.'
}
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -lt 800 -or $height -lt 500 -or $width -gt 7680 -or $height -gt 4320) {
  throw "Al-Ameen window bounds are outside the safe capture range: ${width}x${height}."
}
$source = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [System.Drawing.Graphics]::FromImage($source)
$hdc = $graphics.GetHdc()
try {
  if (-not [AlameenCaptureNative]::PrintWindow($process.MainWindowHandle, $hdc, 2)) {
    throw 'PrintWindow could not capture the Al-Ameen window.'
  }
} finally {
  $graphics.ReleaseHdc($hdc)
  $graphics.Dispose()
}

$jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
  Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
$encoded = ''
$captureWidth = 0
$captureHeight = 0
$captureQuality = 0
foreach ($targetWidth in @(800, 640, 480)) {
  $targetHeight = [Math]::Max(1, [int][Math]::Round($height * $targetWidth / $width))
  $resized = New-Object System.Drawing.Bitmap($targetWidth, $targetHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $draw = [System.Drawing.Graphics]::FromImage($resized)
  $draw.DrawImage($source, 0, 0, $targetWidth, $targetHeight)
  $draw.Dispose()
  foreach ($quality in @(40, 30, 20)) {
    $stream = New-Object System.IO.MemoryStream
    $parameters = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $parameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
    $resized.Save($stream, $jpeg, $parameters)
    $candidate = [Convert]::ToBase64String($stream.ToArray())
    $stream.Dispose()
    $parameters.Dispose()
    if ($candidate.Length -le 58000) {
      $encoded = $candidate
      $captureWidth = $targetWidth
      $captureHeight = $targetHeight
      $captureQuality = $quality
      break
    }
  }
  $resized.Dispose()
  if ($encoded.Length -ne 0) { break }
}
$source.Dispose()
if ($encoded.Length -eq 0) {
  throw 'The Al-Ameen window capture could not fit the bounded diagnostic payload.'
}
$bytes = [Convert]::FromBase64String($encoded)
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
[ordered]@{
  processId = $process.Id
  processName = $process.ProcessName
  windowTitle = $process.MainWindowTitle
  sourceWidth = $width
  sourceHeight = $height
  captureWidth = $captureWidth
  captureHeight = $captureHeight
  jpegQuality = $captureQuality
  imageMimeType = 'image/jpeg'
  imageSha256 = $digest
  imageBase64 = $encoded
} | ConvertTo-Json -Compress
''';

Map<String, dynamic> parseAlameenWindowCapture(String output) {
  final capture = parseAlameenWindowInspection(output);
  final mimeType = capture['imageMimeType']?.toString() ?? '';
  final encoded = capture['imageBase64']?.toString() ?? '';
  final width = (capture['captureWidth'] as num?)?.round() ?? 0;
  final height = (capture['captureHeight'] as num?)?.round() ?? 0;
  if (mimeType != 'image/jpeg' ||
      encoded.isEmpty ||
      width <= 0 ||
      height <= 0) {
    throw const FormatException('Al-Ameen capture payload is incomplete.');
  }
  base64Decode(encoded);
  final payload = jsonEncode(capture);
  if (payload.length > 64000) {
    throw const FormatException(
      'Al-Ameen capture exceeds the server payload limit.',
    );
  }
  return capture;
}
