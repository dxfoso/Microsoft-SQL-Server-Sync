import 'dart:io';

import 'package:flutter/services.dart';

import 'startup_log.dart';

class WindowsAgentWindowSettings {
  const WindowsAgentWindowSettings._();

  static const MethodChannel _channel = MethodChannel(
    'sync_windows_agent/window',
  );
  static const String _shortcutName = 'SQL Sync Agent.lnk';

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

      final targetPath = Platform.resolvedExecutable;
      final script = '''
\$ErrorActionPreference = 'Stop'
\$shortcutPath = ${_quotePowerShellString(shortcut.path)}
\$targetPath = ${_quotePowerShellString(targetPath)}
\$workingDirectory = Split-Path -Parent \$targetPath
\$shell = New-Object -ComObject WScript.Shell
\$shortcut = \$shell.CreateShortcut(\$shortcutPath)
\$shortcut.TargetPath = \$targetPath
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

  static String _quotePowerShellString(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}
