import 'dart:convert';

const String alameenLabInspectAction = 'alameen_lab_inspect';
const String alameenLabCaptureAction = 'alameen_lab_capture';
const String alameenLabInvoiceMenuProbeAction =
    'alameen_lab_invoice_menu_probe';
const String alameenLabSalesFormProbeAction = 'alameen_lab_sales_form_probe';

bool isAlameenLabAction(String action) => <String>{
  alameenLabInspectAction,
  alameenLabCaptureAction,
  alameenLabInvoiceMenuProbeAction,
  alameenLabSalesFormProbeAction,
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

String buildAlameenInvoiceMenuProbePowerShell() => r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AlameenProbeNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
}
'@

function Capture-VerifiedWindow([IntPtr]$handle, [int]$width, [int]$height) {
  $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $hdc = $graphics.GetHdc()
  try {
    if (-not [AlameenProbeNative]::PrintWindow($handle, $hdc, 2)) {
      throw 'PrintWindow could not capture a verified Al-Ameen window.'
    }
  } finally {
    $graphics.ReleaseHdc($hdc)
    $graphics.Dispose()
  }
  return $bitmap
}

$candidates = @(Get-Process | Where-Object {
  $_.MainWindowHandle -ne 0 -and $_.ProcessName -match '(?i)^amn32$'
})
if ($candidates.Count -ne 1) {
  throw "Expected exactly one visible Amn32 window; found $($candidates.Count)."
}
$process = $candidates[0]
$path = ''
try { $path = $process.Path } catch { $path = '' }
if ($path -notmatch '(?i)\\Al-Ameen\\81\\Bin\\Amn32\.exe$') {
  throw 'The visible Amn32 executable is not the calibrated Al-Ameen 8.1 binary.'
}
$rect = New-Object AlameenProbeNative+RECT
if (-not [AlameenProbeNative]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
  throw 'Could not read the Al-Ameen window bounds.'
}
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -ne 1382 -or $height -ne 744) {
  throw "The Al-Ameen window is not at the calibrated 1382x744 size: ${width}x${height}."
}
$classText = New-Object System.Text.StringBuilder 256
[void][AlameenProbeNative]::GetClassName($process.MainWindowHandle, $classText, $classText.Capacity)
if ($classText.ToString() -notmatch '^Afx:') {
  throw 'The Al-Ameen root window class no longer matches the calibrated MFC application.'
}

$before = Capture-VerifiedWindow $process.MainWindowHandle $width $height
$darkPixels = 0
$brightPixels = 0
for ($x = 1260; $x -le 1325; $x += 1) {
  for ($y = 34; $y -le 62; $y += 1) {
    $pixel = $before.GetPixel($x, $y)
    $luma = ($pixel.R + $pixel.G + $pixel.B) / 3
    if ($luma -lt 170) { $darkPixels += 1 }
    if ($luma -gt 205) { $brightPixels += 1 }
  }
}
if ($darkPixels -lt 10 -or $darkPixels -gt 700 -or $brightPixels -lt 900) {
  $before.Dispose()
  throw "The calibrated invoice-menu visual anchor did not match (dark=$darkPixels bright=$brightPixels)."
}

$previousForeground = [AlameenProbeNative]::GetForegroundWindow()
$cursor = New-Object AlameenProbeNative+POINT
[void][AlameenProbeNative]::GetCursorPos([ref]$cursor)
$ownedWindows = New-Object System.Collections.ArrayList
$menuControls = New-Object System.Collections.ArrayList
try {
  if (-not [AlameenProbeNative]::SetForegroundWindow($process.MainWindowHandle)) {
    throw 'Could not focus the verified Al-Ameen window for the menu-only probe.'
  }
  Start-Sleep -Milliseconds 150
  if (-not [AlameenProbeNative]::SetCursorPos($rect.Left + 1295, $rect.Top + 48)) {
    throw 'Could not position the pointer on the calibrated invoice menu.'
  }
  [AlameenProbeNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [AlameenProbeNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 500

  $after = Capture-VerifiedWindow $process.MainWindowHandle $width $height
  $callback = [AlameenProbeNative+EnumWindowsProc]{
    param([IntPtr]$handle, [IntPtr]$state)
    $windowProcessId = [uint32]0
    [void][AlameenProbeNative]::GetWindowThreadProcessId($handle, [ref]$windowProcessId)
    if ($windowProcessId -eq [uint32]$process.Id -and
        $handle -ne $process.MainWindowHandle -and
        [AlameenProbeNative]::IsWindowVisible($handle)) {
      $popupRect = New-Object AlameenProbeNative+RECT
      if ([AlameenProbeNative]::GetWindowRect($handle, [ref]$popupRect)) {
        $popupWidth = $popupRect.Right - $popupRect.Left
        $popupHeight = $popupRect.Bottom - $popupRect.Top
        $inside = $popupRect.Left -ge $rect.Left -and $popupRect.Top -ge $rect.Top -and
          $popupRect.Right -le $rect.Right -and $popupRect.Bottom -le $rect.Bottom
        if ($inside -and $popupWidth -gt 20 -and $popupHeight -gt 20 -and
            $popupWidth -lt $width -and $popupHeight -lt $height) {
          $popupClass = New-Object System.Text.StringBuilder 256
          [void][AlameenProbeNative]::GetClassName($handle, $popupClass, $popupClass.Capacity)
          [void]$ownedWindows.Add([ordered]@{
            handle = [long]$handle
            className = $popupClass.ToString()
            left = $popupRect.Left - $rect.Left
            top = $popupRect.Top - $rect.Top
            width = $popupWidth
            height = $popupHeight
          })
          try {
            $popupRoot = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if ($null -ne $popupRoot) {
              $elements = $popupRoot.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
              )
              $controlLimit = [Math]::Min($elements.Count, 80)
              for ($controlIndex = 0; $controlIndex -lt $controlLimit; $controlIndex++) {
                $current = $elements.Item($controlIndex).Current
                if (-not [string]::IsNullOrWhiteSpace($current.Name)) {
                  [void]$menuControls.Add([ordered]@{
                    name = $current.Name
                    automationId = $current.AutomationId
                    className = $current.ClassName
                    controlType = $current.ControlType.ProgrammaticName
                    enabled = $current.IsEnabled
                    left = [int][Math]::Round($current.BoundingRectangle.Left - $rect.Left)
                    top = [int][Math]::Round($current.BoundingRectangle.Top - $rect.Top)
                    width = [int][Math]::Round($current.BoundingRectangle.Width)
                    height = [int][Math]::Round($current.BoundingRectangle.Height)
                  })
                }
              }
            }
          } catch {
            # The bounded screenshot remains authoritative when this legacy
            # Codejock popup does not expose UI Automation descendants.
          }
          $popup = Capture-VerifiedWindow $handle $popupWidth $popupHeight
          $draw = [System.Drawing.Graphics]::FromImage($after)
          $draw.DrawImage($popup, $popupRect.Left - $rect.Left, $popupRect.Top - $rect.Top)
          $draw.Dispose()
          $popup.Dispose()
        }
      }
    }
    return $true
  }
  [void][AlameenProbeNative]::EnumWindows($callback, [IntPtr]::Zero)

  $changedSamples = 0
  for ($x = 1050; $x -lt 1370; $x += 2) {
    for ($y = 30; $y -lt 500; $y += 2) {
      if ($before.GetPixel($x, $y).ToArgb() -ne $after.GetPixel($x, $y).ToArgb()) {
        $changedSamples += 1
      }
    }
  }
  if ($changedSamples -lt 25) {
    $after.Dispose()
    throw 'The invoice menu did not produce a verified visual change.'
  }

  $targetWidth = 800
  $targetHeight = [int][Math]::Round($height * $targetWidth / $width)
  $resized = New-Object System.Drawing.Bitmap($targetWidth, $targetHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $draw = [System.Drawing.Graphics]::FromImage($resized)
  $draw.DrawImage($after, 0, 0, $targetWidth, $targetHeight)
  $draw.Dispose()
  $after.Dispose()
  $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
  $stream = New-Object System.IO.MemoryStream
  $parameters = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $parameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]35)
  $resized.Save($stream, $jpeg, $parameters)
  $resized.Dispose()
  $parameters.Dispose()
  $bytes = $stream.ToArray()
  $stream.Dispose()
  $encoded = [Convert]::ToBase64String($bytes)
  if ($encoded.Length -gt 58000) { throw 'The invoice-menu probe image exceeds the bounded payload.' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  [ordered]@{
    processId = $process.Id
    processName = $process.ProcessName
    windowTitle = $process.MainWindowTitle
    executablePath = $path
    sourceWidth = $width
    sourceHeight = $height
    captureWidth = $targetWidth
    captureHeight = $targetHeight
    imageMimeType = 'image/jpeg'
    imageSha256 = $digest
    imageBase64 = $encoded
    probe = 'invoice-menu-only'
    visualAnchorDarkPixels = $darkPixels
    visualAnchorBrightPixels = $brightPixels
    changedSamples = $changedSamples
    ownedWindows = $ownedWindows
    menuControls = $menuControls
  } | ConvertTo-Json -Depth 5 -Compress
} finally {
  [AlameenProbeNative]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
  [AlameenProbeNative]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 100
  [void][AlameenProbeNative]::SetCursorPos($cursor.X, $cursor.Y)
  if ($previousForeground -ne [IntPtr]::Zero) {
    [void][AlameenProbeNative]::SetForegroundWindow($previousForeground)
  }
  $before.Dispose()
}
''';

String buildAlameenSalesFormProbePowerShell() {
  const visualSalesSelection = r'''
  if ($ownedWindows.Count -ne 1) {
    $after.Dispose()
    throw "Expected exactly one process-owned invoice popup; found $($ownedWindows.Count)."
  }
  $popupInfo = $ownedWindows[0]
  if ($popupInfo.className -ne 'XTPPopupBar' -or
      $popupInfo.left -ne 1099 -or $popupInfo.top -ne 56 -or
      $popupInfo.width -ne 234 -or $popupInfo.height -ne 299) {
    $after.Dispose()
    throw 'The invoice popup geometry no longer matches the calibrated visual target.'
  }
  $salesRowDarkPixels = 0
  $salesRowBrightPixels = 0
  for ($sampleX = 1110; $sampleX -le 1365; $sampleX += 1) {
    for ($sampleY = 58; $sampleY -le 80; $sampleY += 1) {
      $samplePixel = $after.GetPixel($sampleX, $sampleY)
      $sampleLuma = ($samplePixel.R + $samplePixel.G + $samplePixel.B) / 3
      if ($sampleLuma -lt 170) { $salesRowDarkPixels += 1 }
      if ($sampleLuma -gt 205) { $salesRowBrightPixels += 1 }
    }
  }
  if ($salesRowDarkPixels -lt 5 -or $salesRowBrightPixels -lt 2500) {
    $after.Dispose()
    throw "The calibrated Sales-row visual anchor did not match (dark=$salesRowDarkPixels bright=$salesRowBrightPixels)."
  }
  if (-not [AlameenProbeNative]::SetCursorPos($rect.Left + 1216, $rect.Top + 70)) {
    $after.Dispose()
    throw 'Could not position the pointer on the calibrated Sales row.'
  }
  [AlameenProbeNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [AlameenProbeNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 900
  $sales = Capture-VerifiedWindow $process.MainWindowHandle $width $height
  $salesChangedSamples = 0
  for ($sampleX = 80; $sampleX -lt 1360; $sampleX += 2) {
    for ($sampleY = 70; $sampleY -lt 710; $sampleY += 2) {
      if ($before.GetPixel($sampleX, $sampleY).ToArgb() -ne $sales.GetPixel($sampleX, $sampleY).ToArgb()) {
        $salesChangedSamples += 1
      }
    }
  }
  if ($salesChangedSamples -lt 1000) {
    $sales.Dispose()
    $after.Dispose()
    throw 'The calibrated Sales selection did not produce a verified form-level visual change.'
  }
  $after.Dispose()
  $after = $sales
''';
  const cleanupAndProof = r'''
  [AlameenProbeNative]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
  [AlameenProbeNative]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 700
  $restored = Capture-VerifiedWindow $process.MainWindowHandle $width $height
  $restorationChangedSamples = 0
  for ($sampleX = 80; $sampleX -lt 1360; $sampleX += 2) {
    for ($sampleY = 70; $sampleY -lt 710; $sampleY += 2) {
      if ($before.GetPixel($sampleX, $sampleY).ToArgb() -ne $restored.GetPixel($sampleX, $sampleY).ToArgb()) {
        $restorationChangedSamples += 1
      }
    }
  }
  $restored.Dispose()
  if ($restorationChangedSamples -gt 1500) {
    throw "Escape did not restore the calibrated dashboard (changed=$restorationChangedSamples)."
  }
  $cleanupPerformed = $true
''';

  return buildAlameenInvoiceMenuProbePowerShell()
      .replaceFirst(
        r'$menuControls = New-Object System.Collections.ArrayList',
        r'''$menuControls = New-Object System.Collections.ArrayList
$cleanupPerformed = $false''',
      )
      .replaceFirst(
        r'$targetWidth = 800',
        '$visualSalesSelection\n  \$targetWidth = 800',
      )
      .replaceFirst(
        r'''  [ordered]@{
    processId = $process.Id''',
        '''$cleanupAndProof\n  [ordered]@{\n    processId = \$process.Id''',
      )
      .replaceFirst(
        "probe = 'invoice-menu-only'",
        "probe = 'sales-form-open-only'",
      )
      .replaceFirst(
        r'changedSamples = $changedSamples',
        r'''menuChangedSamples = $changedSamples
    salesRowDarkPixels = $salesRowDarkPixels
    salesRowBrightPixels = $salesRowBrightPixels
    salesChangedSamples = $salesChangedSamples
    restorationChangedSamples = $restorationChangedSamples''',
      )
      .replaceFirst(
        r'''} finally {
  [AlameenProbeNative]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
  [AlameenProbeNative]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)''',
        r'''} finally {
  if (-not $cleanupPerformed) {
    [AlameenProbeNative]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    [AlameenProbeNative]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
  }''',
      );
}
