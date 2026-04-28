import 'dart:io';

void logStartupEvent(String message) {
  try {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final logFile = File(
      '${executableDirectory.path}${Platform.pathSeparator}sync_windows_agent_startup.log',
    );
    final timestamp = DateTime.now().toIso8601String();
    logFile.writeAsStringSync(
      '[$timestamp] $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Best-effort only.
  }
}
