import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Durable, content-verified staging for restartable sync transfers.
///
/// SQL is still changed only by the existing final atomic transaction. These
/// files merely prevent a slow or interrupted network transfer from restarting
/// at byte/page zero after a process or connection failure.
class SyncTransferCache {
  SyncTransferCache({Directory? directory})
    : directory = directory ?? defaultDirectory();

  final Directory directory;

  static const int maxBytes = 2 * 1024 * 1024 * 1024;
  static const Duration maxAge = Duration(days: 7);

  static Directory defaultDirectory() {
    final base =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return Directory(
      path.join(base, 'Microsoft-SQL-Server-Sync', 'transfer-cache-v1'),
    );
  }

  String key({
    required String direction,
    required String jobId,
    required String batchId,
    required int protocolVersion,
    required String syncEpoch,
  }) =>
      sha256
          .convert(
            utf8.encode(
              '$direction\u0000$jobId\u0000$batchId\u0000$protocolVersion\u0000$syncEpoch',
            ),
          )
          .toString();

  Future<List<Map<String, dynamic>>> loadDownloadPages(String cacheKey) async {
    final transferDirectory = Directory(path.join(directory.path, cacheKey));
    final checkpoint = File(
      path.join(transferDirectory.path, 'checkpoint.json'),
    );
    if (!await checkpoint.exists()) return const [];
    try {
      final decoded = jsonDecode(await checkpoint.readAsString());
      if (decoded is! Map || decoded['pages'] is! List) return const [];
      final pages = <Map<String, dynamic>>[];
      for (final item in decoded['pages'] as List) {
        if (item is! Map) throw const FormatException('Invalid cache page');
        final fileName = item['file']?.toString() ?? '';
        final expectedHash = item['sha256']?.toString() ?? '';
        final file = File(path.join(transferDirectory.path, fileName));
        final bytes = await file.readAsBytes();
        if (sha256.convert(bytes).toString() != expectedHash) {
          throw const FormatException('Cached sync page hash mismatch');
        }
        final page = jsonDecode(utf8.decode(bytes));
        if (page is! Map) throw const FormatException('Invalid cached page');
        pages.add(Map<String, dynamic>.from(page));
      }
      return pages;
    } catch (_) {
      await clear(cacheKey);
      return const [];
    }
  }

  Future<void> appendDownloadPage(
    String cacheKey,
    Map<String, dynamic> page,
  ) async {
    final transferDirectory = Directory(path.join(directory.path, cacheKey));
    final checkpoint = File(
      path.join(transferDirectory.path, 'checkpoint.json'),
    );
    if (!await checkpoint.exists()) await cleanup();
    await transferDirectory.create(recursive: true);
    final entries = <Map<String, dynamic>>[];
    if (await checkpoint.exists()) {
      try {
        final decoded = jsonDecode(await checkpoint.readAsString());
        for (final entry
            in (decoded is Map ? decoded['pages'] as List? : null) ??
                const []) {
          if (entry is Map) entries.add(Map<String, dynamic>.from(entry));
        }
      } catch (_) {
        await clear(cacheKey);
        await transferDirectory.create(recursive: true);
        entries.clear();
      }
    }
    final index = entries.length;
    final bytes = utf8.encode(jsonEncode(page));
    final fileName = 'page-${index.toString().padLeft(8, '0')}.json';
    final finalFile = File(path.join(transferDirectory.path, fileName));
    final temporaryFile = File('${finalFile.path}.part');
    await temporaryFile.writeAsBytes(bytes, flush: true);
    await temporaryFile.rename(finalFile.path);

    entries.add({'file': fileName, 'sha256': sha256.convert(bytes).toString()});
    await _writeJsonAtomically(checkpoint, {
      'version': 1,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'pages': entries,
    });
  }

  Future<Map<String, dynamic>?> loadUploadSnapshot(String cacheKey) async {
    final file = File(path.join(directory.path, '$cacheKey.upload.json'));
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['payload'] is! Map) return null;
      final payload = Map<String, dynamic>.from(decoded['payload'] as Map);
      if (sha256.convert(utf8.encode(jsonEncode(payload))).toString() !=
          decoded['sha256']) {
        throw const FormatException('Cached upload snapshot hash mismatch');
      }
      return payload;
    } catch (_) {
      await file.delete().catchError((_) => file);
      return null;
    }
  }

  Future<void> saveUploadSnapshot(
    String cacheKey,
    Map<String, dynamic> payload,
  ) async {
    await cleanup();
    await directory.create(recursive: true);
    await _writeJsonAtomically(
      File(path.join(directory.path, '$cacheKey.upload.json')),
      {
        'version': 1,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'sha256': sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
        'payload': payload,
      },
    );
  }

  Future<void> clear(String cacheKey) async {
    final transferDirectory = Directory(path.join(directory.path, cacheKey));
    if (await transferDirectory.exists()) {
      await transferDirectory.delete(recursive: true);
    }
    final upload = File(path.join(directory.path, '$cacheKey.upload.json'));
    if (await upload.exists()) await upload.delete();
  }

  Future<void> cleanup({DateTime? now}) async {
    if (!await directory.exists()) return;
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(maxAge);
    final entities = <FileSystemEntity>[];
    await for (final entity in directory.list()) {
      entities.add(entity);
    }
    var total = 0;
    final retained =
        <({FileSystemEntity entity, DateTime modified, int size})>[];
    for (final entity in entities) {
      try {
        final stat = await entity.stat();
        final size = await _entitySize(entity);
        if (stat.modified.toUtc().isBefore(cutoff)) {
          await entity.delete(recursive: entity is Directory);
        } else {
          total += size;
          retained.add((entity: entity, modified: stat.modified, size: size));
        }
      } catch (_) {}
    }
    retained.sort((a, b) => a.modified.compareTo(b.modified));
    for (final item in retained) {
      if (total <= maxBytes) break;
      try {
        await item.entity.delete(recursive: item.entity is Directory);
        total -= item.size;
      } catch (_) {}
    }
  }

  Future<int> _entitySize(FileSystemEntity entity) async {
    if (entity is File) return (await entity.stat()).size;
    if (entity is! Directory) return 0;
    var total = 0;
    await for (final child in entity.list(recursive: true)) {
      if (child is File) total += (await child.stat()).size;
    }
    return total;
  }

  Future<void> _writeJsonAtomically(File file, Object value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
