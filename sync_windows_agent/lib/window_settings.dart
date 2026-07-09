import 'dart:io';

import 'package:flutter/services.dart';

import 'startup_log.dart';

class WindowsAgentWindowSettings {
  const WindowsAgentWindowSettings._();

  static const MethodChannel _channel = MethodChannel(
    'sync_windows_agent/window',
  );
  static const String _shortcutName = 'SQL Sync Agent.lnk';
  static const String _watchdogScriptName = 'sync_windows_agent_watchdog.ps1';

  static Future<void> minimizeWindow() async {
    if (!Platform.isWindows) {
      return;
    }
    logStartupEvent('WindowsAgentWindowSettings.minimizeWindow');
    await _channel.invokeMethod<void>('minimizeWindow');
  }

  static Future<void> setWindowTitle(String title) async {
    if (!Platform.isWindows) {
      return;
    }
    final normalized = title.trim().isEmpty ? 'SQL Sync Agent' : title.trim();
    await _channel.invokeMethod<void>('setWindowTitle', normalized);
  }

  static bool isStartOnStartupEnabledSync() {
    try {
      final shortcut = _startupShortcutFile();
      return shortcut != null && shortcut.existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<void> setStartOnStartup(bool enabled) async {
    if (!Platform.isWindows) {
      return;
    }

    if (enabled) {
      await ensureWatchdogInstalledAndRunning();
      await _createStartupShortcut();
      return;
    }

    final shortcut = _startupShortcutFile();
    try {
      if (shortcut != null && await shortcut.exists()) {
        await shortcut.delete();
      }
    } catch (_) {
      // If the startup folder is on an unavailable path, keep the app usable.
    }
  }

  static File? _startupShortcutFile() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.trim().isEmpty) {
      return null;
    }

    return File(
      '$appData${Platform.pathSeparator}Microsoft'
      '${Platform.pathSeparator}Windows'
      '${Platform.pathSeparator}Start Menu'
      '${Platform.pathSeparator}Programs'
      '${Platform.pathSeparator}Startup'
      '${Platform.pathSeparator}$_shortcutName',
    );
  }

  static Future<void> _createStartupShortcut() async {
    try {
      final shortcut = _startupShortcutFile();
      if (shortcut == null) {
        throw StateError('Windows startup folder is not available.');
      }

      final startupDirectory = shortcut.parent;
      if (!await startupDirectory.exists()) {
        await startupDirectory.create(recursive: true);
      }

      await _ensureWatchdogScript();
      final watchdogScript = _watchdogScriptFile();
      if (watchdogScript == null) {
        throw StateError('Could not resolve the watchdog script path.');
      }
      final targetPath =
          '${Platform.environment['WINDIR'] ?? r'C:\Windows'}'
          '${Platform.pathSeparator}System32'
          '${Platform.pathSeparator}WindowsPowerShell'
          '${Platform.pathSeparator}v1.0'
          '${Platform.pathSeparator}powershell.exe';
      final arguments =
          '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden '
          '-File ${_quotePowerShellString(watchdogScript.path)}';
      final script = '''
\$ErrorActionPreference = 'Stop'
\$shortcutPath = ${_quotePowerShellString(shortcut.path)}
\$targetPath = ${_quotePowerShellString(targetPath)}
\$workingDirectory = ${_quotePowerShellString(File(Platform.resolvedExecutable).parent.path)}
\$arguments = ${_quotePowerShellString(arguments)}
\$shell = New-Object -ComObject WScript.Shell
\$shortcut = \$shell.CreateShortcut(\$shortcutPath)
\$shortcut.TargetPath = \$targetPath
\$shortcut.Arguments = \$arguments
\$shortcut.WorkingDirectory = \$workingDirectory
\$shortcut.Description = 'SQL Sync Agent'
\$shortcut.Save()
''';

      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);

      if (result.exitCode != 0) {
        final stderrText = result.stderr.toString().trim();
        throw StateError(
          stderrText.isEmpty
              ? 'Could not create the Windows startup shortcut.'
              : stderrText,
        );
      }
    } on FileSystemException catch (error) {
      throw StateError(
        'Could not access the Windows Startup folder. '
        'Check whether your profile path is redirected or unavailable. '
        '$error',
      );
    }
  }

  static Future<void> ensureWatchdogInstalledAndRunning() async {
    if (!Platform.isWindows) {
      return;
    }
    final watchdogScript = await _ensureWatchdogScript();
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      watchdogScript.path,
      '-RunOnce',
    ]);
    if (result.exitCode != 0) {
      final stderrText = result.stderr.toString().trim();
      throw StateError(
        stderrText.isEmpty
            ? 'Could not start the SQL Sync Agent watchdog.'
            : stderrText,
      );
    }
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      watchdogScript.path,
    ], mode: ProcessStartMode.detached);
  }

  static File? _watchdogScriptFile() {
    try {
      return File(
        '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.pathSeparator}'
        '$_watchdogScriptName',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<File> _ensureWatchdogScript() async {
    final scriptFile = _watchdogScriptFile();
    if (scriptFile == null) {
      throw StateError('Could not resolve the watchdog script path.');
    }
    final desired = _watchdogScriptContents();
    final exists = await scriptFile.exists();
    if (!exists || await scriptFile.readAsString() != desired) {
      await scriptFile.writeAsString(desired, flush: true);
    }
    return scriptFile;
  }

  static String _watchdogScriptContents() {
    return r'''
param(
    [switch] $RunOnce
)

$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetInstallDir = [System.IO.Path]::GetFullPath($scriptDir)
$executablePath = Join-Path -Path $targetInstallDir -ChildPath 'sync_windows_agent.exe'
$logPath = Join-Path -Path $targetInstallDir -ChildPath 'sync_windows_agent_watchdog.log'

function Write-WatchdogLog {
    param([string] $Message)

    try {
        $timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -LiteralPath $logPath -Value "[$timestamp] $Message" -Encoding ASCII
    } catch {
    }
}

function Get-WatchdogMutexName {
    param([string] $InstallDir)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InstallDir.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return 'Local\SqlSyncAgentWatchdog_' + [System.Convert]::ToHexString($hash).Substring(0, 16)
}

function Get-AgentProcesses {
    param([string] $InstallDir)

    $targetFull = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
            ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Start-AgentProcess {
    param(
        [string] $ExecutablePath,
        [string] $InstallDir
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        Write-WatchdogLog "Executable not found: $ExecutablePath"
        return
    }

    Write-WatchdogLog "Starting sync_windows_agent.exe from watchdog."
    Start-Process -FilePath $ExecutablePath -ArgumentList '--start-minimized' -WorkingDirectory $InstallDir -WindowStyle Minimized -ErrorAction SilentlyContinue | Out-Null
}

function Ensure-AgentRunning {
    param(
        [string] $ExecutablePath,
        [string] $InstallDir
    )

    $processes = @(Get-AgentProcesses -InstallDir $InstallDir)
    if ($processes.Count -gt 0) {
        return
    }

    Start-AgentProcess -ExecutablePath $ExecutablePath -InstallDir $InstallDir
}

$mutexName = Get-WatchdogMutexName -InstallDir $targetInstallDir
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref] $createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    Ensure-AgentRunning -ExecutablePath $executablePath -InstallDir $targetInstallDir
    if ($RunOnce) {
        exit 0
    }

    Write-WatchdogLog 'Watchdog loop started.'
    while ($true) {
        Start-Sleep -Seconds 30
        Ensure-AgentRunning -ExecutablePath $executablePath -InstallDir $targetInstallDir
    }
} finally {
    try {
        $mutex.ReleaseMutex() | Out-Null
    } catch {
    }
    $mutex.Dispose()
}
''';
  }

  static String _quotePowerShellString(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}
