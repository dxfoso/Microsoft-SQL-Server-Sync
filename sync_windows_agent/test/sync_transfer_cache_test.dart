import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sync_transfer_cache.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sql-sync-transfer-cache-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('verified download pages survive a new client process', () async {
    final cache = SyncTransferCache(directory: temporaryDirectory);
    const key = 'resume-key';
    await cache.appendDownloadPage(key, {
      'done': false,
      'nextCursor': 'page-2',
      'payloadBase64': base64Encode(utf8.encode('[{"Id":"1"}]')),
    });

    final reopened = SyncTransferCache(directory: temporaryDirectory);
    final pages = await reopened.loadDownloadPages(key);

    expect(pages, hasLength(1));
    expect(pages.single['nextCursor'], 'page-2');
  });

  test('corrupt cached page is discarded instead of applied', () async {
    final cache = SyncTransferCache(directory: temporaryDirectory);
    const key = 'corrupt-key';
    await cache.appendDownloadPage(key, {
      'done': false,
      'nextCursor': 'page-2',
    });
    final page = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}$key'
      '${Platform.pathSeparator}page-00000000.json',
    );
    await page.writeAsString('corrupted', flush: true);

    expect(await cache.loadDownloadPages(key), isEmpty);
    expect(await page.parent.exists(), isFalse);
  });

  test(
    'upload snapshot is immutable and hash verified across restart',
    () async {
      final cache = SyncTransferCache(directory: temporaryDirectory);
      const key = 'upload-key';
      final payload = {
        'snapshotJson': '{"rows":[{"Name":"مرحبا"}]}',
        'changeTrackingVersion': 42,
      };
      await cache.saveUploadSnapshot(key, payload);

      final reopened = SyncTransferCache(directory: temporaryDirectory);
      expect(await reopened.loadUploadSnapshot(key), payload);
    },
  );

  test('cleanup removes expired transfer state', () async {
    final cache = SyncTransferCache(directory: temporaryDirectory);
    const key = 'expired-key';
    await cache.appendDownloadPage(key, {'done': true});

    await cache.cleanup(
      now: DateTime.now().toUtc().add(const Duration(days: 8)),
    );

    expect(await cache.loadDownloadPages(key), isEmpty);
  });
}
