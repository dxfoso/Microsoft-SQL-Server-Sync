import 'dart:convert';
import 'dart:io';

enum AgentLogLevel { debug, info, warning, error }

const int _maxAgentLogFileBytes = 20 * 1024;
const int _maxAgentLogEntryChars = 8 * 1024;
const int _maxRetainedAgentLogChars = 40 * 1024;

final String _agentLogSessionId =
    '${DateTime.now().toUtc().toIso8601String()}-${pid.toString()}';

File _agentLogFile() {
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  return File(
    '${executableDirectory.path}${Platform.pathSeparator}sync_windows_agent_startup.log',
  );
}

File _agentLogBackupFile() => File('${_agentLogFile().path}.1');

bool _isSensitiveLogKey(String key) {
  final normalized = key.trim().toLowerCase();
  return normalized.contains('password') ||
      normalized.contains('passwd') ||
      normalized == 'pwd' ||
      normalized.contains('token') ||
      normalized.contains('authorization') ||
      normalized.contains('cookie') ||
      normalized.contains('secret');
}

String redactAgentLogText(String value) {
  var redacted = value;
  redacted = redacted.replaceAllMapped(
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (_) => 'Bearer [REDACTED]',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(
      r'''\b(password|passwd|pwd|token|authorization|cookie|secret)\b(\s*[:=]\s*["']?)([^"',\s}\]]+)''',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(r'(\s-P\s+)(?:"[^"]*"|[^\s]+)', caseSensitive: false),
    (match) => '${match.group(1)}[REDACTED]',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(r'(://)[^/@\s:]+:[^/@\s]+@', caseSensitive: false),
    (match) => '${match.group(1)}[REDACTED]@',
  );
  return redacted;
}

dynamic _safeLogValue(String key, dynamic value) {
  if (_isSensitiveLogKey(key)) {
    return '[REDACTED]';
  }
  if (value == null || value is num || value is bool) {
    return value;
  }
  if (value is String) {
    final redacted = redactAgentLogText(value);
    return redacted.length <= 2048
        ? redacted
        : '${redacted.substring(0, 2048)}…[truncated]';
  }
  if (value is Iterable) {
    return value
        .take(50)
        .map((item) => _safeLogValue(key, item))
        .toList(growable: false);
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries.take(100)) {
      final entryKey = entry.key.toString();
      result[entryKey] = _safeLogValue(entryKey, entry.value);
    }
    return result;
  }
  return _safeLogValue(key, value.toString());
}

void _rotateAgentLogIfNeeded(File logFile, int incomingBytes) {
  if (!logFile.existsSync() ||
      logFile.lengthSync() + incomingBytes <= _maxAgentLogFileBytes) {
    return;
  }
  final backup = _agentLogBackupFile();
  if (backup.existsSync()) {
    backup.deleteSync();
  }
  logFile.renameSync(backup.path);
  if (backup.lengthSync() > _maxAgentLogFileBytes) {
    final content = backup.readAsStringSync();
    var retained = content;
    if (content.length > _maxAgentLogFileBytes) {
      final start = content.length - _maxAgentLogFileBytes;
      final nextLine = content.indexOf('\n', start);
      retained = content.substring(nextLine < 0 ? start : nextLine + 1);
    }
    backup.writeAsStringSync(retained, flush: true);
  }
}

void logAgentDiagnostic(
  String event, {
  AgentLogLevel level = AgentLogLevel.info,
  String message = '',
  Map<String, dynamic> context = const <String, dynamic>{},
  Object? error,
  StackTrace? stackTrace,
}) {
  try {
    final logFile = _agentLogFile();
    final safeContext = <String, dynamic>{};
    for (final entry in context.entries) {
      safeContext[entry.key] = _safeLogValue(entry.key, entry.value);
    }
    var safeMessage = redactAgentLogText(message);
    final safeError =
        error == null ? null : redactAgentLogText(error.toString());
    final safeStack =
        stackTrace == null ? null : redactAgentLogText(stackTrace.toString());
    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level.name.toUpperCase(),
      'event': redactAgentLogText(event),
      'sessionId': _agentLogSessionId,
      'pid': pid,
      if (safeMessage.isNotEmpty) 'message': safeMessage,
      if (safeContext.isNotEmpty) 'context': safeContext,
      if (safeError != null && safeError.isNotEmpty) 'error': safeError,
      if (safeStack != null && safeStack.isNotEmpty) 'stackTrace': safeStack,
    };
    var encoded = jsonEncode(entry);
    if (encoded.length > _maxAgentLogEntryChars) {
      safeMessage =
          safeMessage.length > 2048
              ? '${safeMessage.substring(0, 2048)}…[truncated]'
              : safeMessage;
      entry['message'] = safeMessage;
      if (safeStack != null) {
        entry['stackTrace'] =
            safeStack.length > 4096
                ? '${safeStack.substring(0, 4096)}…[truncated]'
                : safeStack;
      }
      encoded = jsonEncode(entry);
      if (encoded.length > _maxAgentLogEntryChars) {
        entry['context'] = {'truncated': true};
        if (safeError != null) {
          entry['error'] =
              safeError.length > 1024
                  ? '${safeError.substring(0, 1024)}…[truncated]'
                  : safeError;
        }
        encoded = jsonEncode(entry);
      }
    }
    final line = '$encoded\n';
    _rotateAgentLogIfNeeded(logFile, utf8.encode(line).length);
    logFile.writeAsStringSync(line, mode: FileMode.append, flush: true);
  } catch (_) {
    // Diagnostic logging must never interrupt the client.
  }
}

void logStartupEvent(String message) {
  logAgentDiagnostic('client.event', message: message);
}

String readRetainedAgentLog({int maxChars = _maxRetainedAgentLogChars}) {
  try {
    final sections = <String>[];
    final backup = _agentLogBackupFile();
    final current = _agentLogFile();
    if (backup.existsSync()) {
      sections.add(backup.readAsStringSync());
    }
    if (current.existsSync()) {
      sections.add(current.readAsStringSync());
    }
    final content = sections.join();
    final redacted = redactAgentLogText(content);
    if (redacted.length <= maxChars) {
      return redacted;
    }
    return redacted.substring(redacted.length - maxChars);
  } catch (_) {
    return '';
  }
}
