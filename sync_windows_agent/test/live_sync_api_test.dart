import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_windows_agent/live_sync_api.dart';

class _DelayedClient extends http.BaseClient {
  _DelayedClient({required this.delay, required this.responseForName});

  final Duration delay;
  final Map<String, Object?> Function(String name) responseForName;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final payload = jsonDecode(await request.finalize().bytesToString()) as Map;
    final name = payload['name'] as String? ?? '';
    await Future<void>.delayed(delay);
    final body = jsonEncode({
      'status': 'success',
      'value': responseForName(name),
    });
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient({required this.responseForRequest});

  final ({int statusCode, Object? body}) Function(
    String name,
    Map<String, dynamic> args,
    int callIndex,
  )
  responseForRequest;
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final payload = jsonDecode(await request.finalize().bytesToString()) as Map;
    final name = payload['name'] as String? ?? '';
    final args = Map<String, dynamic>.from(payload['args'] as Map? ?? const {});
    final callIndex = requests.length;
    requests.add(<String, dynamic>{'name': name, 'args': args});
    final response = responseForRequest(name, args, callIndex);
    final body =
        response.body is String
            ? response.body as String
            : jsonEncode(response.body);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      response.statusCode,
      headers: const {'content-type': 'application/json'},
    );
  }
}

String _buildLargeSnapshotJson({
  required String clientName,
  required String table,
  required int rowCount,
}) {
  String uniqueToken(int rowIndex, int salt) {
    final value = ((rowIndex + 1) * 1103515245 + salt * 12345) & 0x7fffffff;
    return value.toRadixString(36).padLeft(8, '0');
  }

  final rows = List<Map<String, String>>.generate(rowCount, (index) {
    final suffix = index.toString().padLeft(5, '0');
    return {
      'Id': '${index + 1}',
      'Code':
          'code-$suffix-${uniqueToken(index, 1)}-${uniqueToken(index, 2)}-${uniqueToken(index, 3)}',
      'Description':
          'desc-$suffix-${uniqueToken(index, 4)}-${uniqueToken(index, 5)}-${uniqueToken(index, 6)}-${uniqueToken(index, 7)}-${uniqueToken(index, 8)}-${uniqueToken(index, 9)}',
    };
  }, growable: false);
  return jsonEncode({
    'id': 'snap-large-1',
    'clientName': clientName,
    'table': table,
    'createdAt': '2026-07-10T03:05:00Z',
    'rowCount': rowCount,
    'checksum': 'large-checksum',
    'snapshotBytes': 0,
    'columns': ['Id', 'Code', 'Description'],
    'rows': rows,
    'sourceJobId': 'job-large-1',
  });
}

void main() {
  test(
    'uploadDiagnostics uses its longer timeout than regular control plane calls',
    () async {
      final client = AgentControlPlaneClient(
        client: _DelayedClient(
          delay: const Duration(milliseconds: 100),
          responseForName: (name) {
            switch (name) {
              case 'agent_diagnostics_upload':
                return {
                  'diagnostics': {
                    'requestId': 'req-1',
                    'status': 'uploaded',
                    'summary': 'ok',
                  },
                };
              case 'agent_client_update_ack':
                return {
                  'clientUpdate': {'requestId': 'req-1', 'status': 'current'},
                };
              default:
                return <String, Object?>{};
            }
          },
        ),
        baseUrl: 'https://example.com/call',
        controlPlaneRequestTimeout: const Duration(milliseconds: 50),
        diagnosticsUploadRequestTimeout: const Duration(milliseconds: 200),
      );

      final diagnostics = await client.uploadDiagnostics(
        clientName: 'c1',
        requestId: 'req-1',
        summary: 'summary',
        payload: '{"ok":true}',
      );

      expect(diagnostics.requestId, 'req-1');
      expect(diagnostics.status, 'uploaded');

      await expectLater(
        client.acknowledgeClientUpdate(
          clientName: 'c1',
          requestId: 'req-1',
          status: 'current',
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('timed out during acknowledging client update request'),
          ),
        ),
      );
    },
  );

  test(
    'heartbeat parses pending window actions and acknowledges them through the dedicated call',
    () async {
      final client = AgentControlPlaneClient(
        client: _DelayedClient(
          delay: Duration.zero,
          responseForName: (name) {
            switch (name) {
              case 'agents_heartbeat':
                return {
                  'windowAction': {
                    'pending': true,
                    'requestId': 'win-1',
                    'action': 'minimize',
                    'status': 'requested',
                  },
                };
              case 'agent_window_action_ack':
                return {
                  'windowAction': {
                    'requestId': 'win-1',
                    'action': 'minimize',
                    'status': 'completed',
                  },
                };
              default:
                return <String, Object?>{};
            }
          },
        ),
        baseUrl: 'https://example.com/call',
      );

      final heartbeat = await client.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      );

      expect(heartbeat.windowAction.pending, isTrue);
      expect(heartbeat.windowAction.action, 'minimize');

      final ack = await client.acknowledgeWindowAction(
        clientName: 'c1',
        requestId: 'win-1',
        action: 'minimize',
        status: 'completed',
      );

      expect(ack.requestId, 'win-1');
      expect(ack.status, 'completed');
    },
  );

  test(
    'heartbeat parses diagnostics and client update metadata including offline and unsupported states',
    () async {
      final client = AgentControlPlaneClient(
        client: _DelayedClient(
          delay: Duration.zero,
          responseForName: (name) {
            expect(name, 'agents_heartbeat');
            return {
              'diagnostics': {
                'pending': false,
                'requestId': 'diag-1',
                'requestedAt': '2026-07-10T02:00:00Z',
                'requestedByUserId': 'user-1',
                'uploadedAt': '2026-07-10T02:01:00Z',
                'lastRequestId': 'diag-0',
                'status': 'client_offline',
                'summary': 'Waiting for heartbeat.',
                'payload': '{"small":true}',
              },
              'clientUpdate': {
                'pending': false,
                'requestId': 'upd-1',
                'requestedAt': '2026-07-10T02:02:00Z',
                'requestedByUserId': 'user-1',
                'targetVersion': '1.0.106+110',
                'lastRequestId': 'upd-0',
                'acknowledgedAt': '2026-07-10T02:03:00Z',
                'status': 'unsupported',
                'message':
                    'Automatic client updates are unavailable in this runtime.',
              },
            };
          },
        ),
        baseUrl: 'https://example.com/call',
      );

      final heartbeat = await client.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      );

      expect(heartbeat.diagnostics.pending, isFalse);
      expect(heartbeat.diagnostics.requestId, 'diag-1');
      expect(heartbeat.diagnostics.lastRequestId, 'diag-0');
      expect(heartbeat.diagnostics.status, 'client_offline');
      expect(heartbeat.diagnostics.summary, 'Waiting for heartbeat.');
      expect(heartbeat.diagnostics.payload, '{"small":true}');

      expect(heartbeat.clientUpdate.pending, isFalse);
      expect(heartbeat.clientUpdate.requestId, 'upd-1');
      expect(heartbeat.clientUpdate.targetVersion, '1.0.106+110');
      expect(heartbeat.clientUpdate.lastRequestId, 'upd-0');
      expect(heartbeat.clientUpdate.status, 'unsupported');
      expect(
        heartbeat.clientUpdate.message,
        contains('Automatic client updates are unavailable'),
      );
    },
  );

  test(
    'downloadSnapshot retries transient 503 manifest failures and succeeds',
    () async {
      final snapshotJson = jsonEncode({
        'id': 'snap-1',
        'clientName': 'c2',
        'table': 'db::mt000',
        'createdAt': '2026-07-10T02:00:00Z',
        'rowCount': 1,
        'checksum': 'abc123',
        'snapshotBytes': 32,
        'columns': ['Id', 'Name'],
        'rows': [
          {'Id': '1', 'Name': 'Row 1'},
        ],
        'sourceJobId': 'job-source-1',
      });
      final compressed = gzip.encode(utf8.encode(snapshotJson));
      final chunkData = base64Encode(compressed);
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              if (callIndex == 0) {
                return (
                  statusCode: 503,
                  body: {
                    'error':
                        'Control plane is temporarily unavailable. Retrying automatically.',
                  },
                );
              }
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-1',
                      'chunkCount': 1,
                      'encoding': 'gzip',
                      'compressedBytes': compressed.length,
                    },
                    'snapshot': {
                      'id': 'snap-1',
                      'clientName': 'c2',
                      'createdAt': '2026-07-10T02:00:00Z',
                      'rowCount': 1,
                      'checksum': 'abc123',
                      'snapshotBytes': 32,
                      'sourceJobId': 'job-source-1',
                    },
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              expect(args['jobId'], 'job-1');
              expect(args['chunkIndex'], 0);
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'chunkData': chunkData},
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      final snapshot = await api.downloadSnapshot('job-1');

      expect(snapshot.id, 'snap-1');
      expect(snapshot.table, 'db::mt000');
      expect(snapshot.rowCount, 1);
      expect(snapshot.rows, hasLength(1));
      expect(snapshot.rows.single['Name'], 'Row 1');
      expect(client.requests.map((item) => item['name']).toList(), [
        'jobs_download_snapshot_manifest',
        'jobs_download_snapshot_manifest',
        'jobs_download_snapshot_chunk',
      ]);
    },
  );

  test(
    'uploadSnapshot retries transient 503 start failures and finalizes resumed uploads',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              if (callIndex == 0) {
                return (
                  statusCode: 503,
                  body: {
                    'error':
                        'Control plane is temporarily unavailable. Retrying automatically.',
                  },
                );
              }
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'receivedIndexes': [0],
                  },
                },
              );
            case 'jobs_upload_chunk_complete':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'job': {
                      'id': 'job-1',
                      'clientName': 'c1',
                      'sourceClientName': 'c1',
                      'subscriberClientName': 'c2',
                      'table': 'db::mt000',
                      'direction': 'upload',
                      'publisherServer': '',
                      'publisherDatabase': '',
                      'publisherUseWindowsAuth': true,
                      'publisherUser': '',
                      'publisherPassword': '',
                      'status': 'completed',
                      'progress': 100,
                      'rowCount': 1,
                      'snapshotBytes': 32,
                      'snapshotCreatedAt': '2026-07-10T02:05:00Z',
                      'snapshotId': 'snap-1',
                      'createdAt': '2026-07-10T02:05:00Z',
                      'updatedAt': '2026-07-10T02:05:05Z',
                      'startedAt': '2026-07-10T02:05:01Z',
                      'completedAt': '2026-07-10T02:05:05Z',
                      'message': 'Uploaded snapshot.',
                      'error': null,
                    },
                    'snapshot': {
                      'id': 'snap-1',
                      'clientName': 'c1',
                      'table': 'db::mt000',
                      'createdAt': '2026-07-10T02:05:00Z',
                      'rowCount': 1,
                      'checksum': 'xyz',
                      'snapshotBytes': 32,
                      'columns': ['Id', 'Name'],
                      'rows': [
                        {'Id': '1', 'Name': 'Row 1'},
                      ],
                      'sourceJobId': 'job-1',
                    },
                  },
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );
      final progressEvents = <TransferProgressSnapshot>[];

      final result = await api.uploadSnapshot(
        'job-1',
        clientName: 'c1',
        table: 'db::mt000',
        rowCount: 1,
        snapshotCreatedAt: '2026-07-10T02:05:00Z',
        snapshotBytes: 32,
        snapshotJson: jsonEncode({
          'id': 'snap-1',
          'clientName': 'c1',
          'table': 'db::mt000',
          'rows': [
            {'Id': '1', 'Name': 'Row 1'},
          ],
        }),
        onProgress: progressEvents.add,
      );

      expect(result.job.id, 'job-1');
      expect(result.snapshot.id, 'snap-1');
      expect(client.requests.map((item) => item['name']).toList(), [
        'jobs_upload_chunk_start',
        'jobs_upload_chunk_start',
        'jobs_upload_chunk_complete',
      ]);
      expect(progressEvents, isNotEmpty);
      expect(
        progressEvents.last.bytesTransferred,
        progressEvents.last.totalBytes,
      );
    },
  );

  test(
    'downloadSnapshot retries transient 503 during chunk download and preserves all rows',
    () async {
      final snapshotJson = _buildLargeSnapshotJson(
        clientName: 'c2',
        table: 'db::gr000',
        rowCount: 20000,
      );
      final compressed = gzip.encode(utf8.encode(snapshotJson));
      expect(compressed.length, greaterThan(100 * 1024));
      final midpoint = compressed.length ~/ 2;
      final chunkPayloads = <String>[
        base64Encode(compressed.sublist(0, midpoint)),
        base64Encode(compressed.sublist(midpoint)),
      ];

      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-large-1',
                      'chunkCount': 2,
                      'encoding': 'gzip',
                      'compressedBytes': compressed.length,
                    },
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              final chunkIndex = args['chunkIndex'] as int? ?? -1;
              if (chunkIndex == 1 && callIndex == 2) {
                return (
                  statusCode: 503,
                  body: {
                    'error':
                        'Control plane is temporarily unavailable. Retrying automatically.',
                  },
                );
              }
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'chunkData': chunkPayloads[chunkIndex]},
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      final snapshot = await api.downloadSnapshot('job-large-1');

      expect(snapshot.rowCount, 20000);
      expect(snapshot.rows, hasLength(20000));
      expect(snapshot.rows.first['Code'], contains('code-00000'));
      expect(snapshot.rows.last['Code'], contains('code-19999'));
      expect(
        client.requests
            .map(
              (item) => '${item['name']}:${(item['args']['chunkIndex'] ?? '')}',
            )
            .toList(),
        [
          'jobs_download_snapshot_manifest:',
          'jobs_download_snapshot_chunk:0',
          'jobs_download_snapshot_chunk:1',
          'jobs_download_snapshot_chunk:1',
        ],
      );
    },
  );

  test(
    'uploadSnapshot retries transient API database failures during chunk upload',
    () async {
      final snapshotJson = _buildLargeSnapshotJson(
        clientName: 'c1',
        table: 'db::gr000',
        rowCount: 20000,
      );
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'receivedIndexes': const []},
                },
              );
            case 'jobs_upload_chunk':
              final chunkIndex = args['chunkIndex'] as int? ?? -1;
              if (chunkIndex == 1 && callIndex == 2) {
                return (
                  statusCode: 200,
                  body: {
                    'status': 'failed',
                    'error': 'runtime error: db error',
                  },
                );
              }
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'ok': true},
                },
              );
            case 'jobs_upload_chunk_complete':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'job': {
                      'id': 'job-large-1',
                      'clientName': 'c1',
                      'sourceClientName': 'c1',
                      'subscriberClientName': 'c2',
                      'table': 'db::gr000',
                      'direction': 'upload',
                      'publisherServer': '',
                      'publisherDatabase': '',
                      'publisherUseWindowsAuth': true,
                      'publisherUser': '',
                      'publisherPassword': '',
                      'status': 'completed',
                      'progress': 100,
                      'rowCount': 20000,
                      'snapshotBytes': 0,
                      'snapshotCreatedAt': '2026-07-10T03:05:00Z',
                      'snapshotId': 'snap-large-1',
                      'createdAt': '2026-07-10T03:05:00Z',
                      'updatedAt': '2026-07-10T03:05:05Z',
                      'startedAt': '2026-07-10T03:05:01Z',
                      'completedAt': '2026-07-10T03:05:05Z',
                      'message': 'Uploaded snapshot.',
                      'error': null,
                    },
                    'snapshot': {
                      'id': 'snap-large-1',
                      'clientName': 'c1',
                      'table': 'db::gr000',
                      'createdAt': '2026-07-10T03:05:00Z',
                      'rowCount': 20000,
                      'checksum': 'large-checksum',
                      'snapshotBytes': 0,
                      'columns': ['Id', 'Code', 'Description'],
                      'rows': const [],
                      'sourceJobId': 'job-large-1',
                    },
                  },
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );
      final progressEvents = <TransferProgressSnapshot>[];

      final result = await api.uploadSnapshot(
        'job-large-1',
        clientName: 'c1',
        table: 'db::gr000',
        rowCount: 20000,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: snapshotJson.length,
        snapshotJson: snapshotJson,
        onProgress: progressEvents.add,
      );

      expect(result.job.id, 'job-large-1');
      expect(result.job.rowCount, 20000);
      expect(
        client.requests
            .where((item) => item['name'] == 'jobs_upload_chunk')
            .length,
        greaterThanOrEqualTo(3),
      );
      expect(
        client.requests
            .where((item) => item['name'] == 'jobs_upload_chunk')
            .map((item) => item['args']['chunkIndex'])
            .toList(),
        containsAllInOrder([0, 1, 1]),
      );
      expect(progressEvents, isNotEmpty);
      expect(
        progressEvents.last.bytesTransferred,
        progressEvents.last.totalBytes,
      );
    },
  );

  test(
    'uploadSnapshot skips chunks already acknowledged by the server resume state',
    () async {
      final snapshotJson = _buildLargeSnapshotJson(
        clientName: 'c1',
        table: 'db::gr000',
        rowCount: 20000,
      );
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'receivedIndexes': [0],
                  },
                },
              );
            case 'jobs_upload_chunk':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'ok': true},
                },
              );
            case 'jobs_upload_chunk_complete':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'job': {
                      'id': 'job-resume-1',
                      'clientName': 'c1',
                      'sourceClientName': 'c1',
                      'subscriberClientName': 'c2',
                      'table': 'db::gr000',
                      'direction': 'upload',
                      'publisherServer': '',
                      'publisherDatabase': '',
                      'publisherUseWindowsAuth': true,
                      'publisherUser': '',
                      'publisherPassword': '',
                      'status': 'completed',
                      'progress': 100,
                      'rowCount': 20000,
                      'snapshotBytes': 0,
                      'snapshotCreatedAt': '2026-07-10T03:05:00Z',
                      'snapshotId': 'snap-large-1',
                      'createdAt': '2026-07-10T03:05:00Z',
                      'updatedAt': '2026-07-10T03:05:05Z',
                      'startedAt': '2026-07-10T03:05:01Z',
                      'completedAt': '2026-07-10T03:05:05Z',
                      'message': 'Uploaded snapshot.',
                      'error': null,
                    },
                    'snapshot': {
                      'id': 'snap-large-1',
                      'clientName': 'c1',
                      'table': 'db::gr000',
                      'createdAt': '2026-07-10T03:05:00Z',
                      'rowCount': 20000,
                      'checksum': 'large-checksum',
                      'snapshotBytes': 0,
                      'columns': ['Id', 'Code', 'Description'],
                      'rows': const [],
                      'sourceJobId': 'job-resume-1',
                    },
                  },
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );
      final progressEvents = <TransferProgressSnapshot>[];

      final result = await api.uploadSnapshot(
        'job-resume-1',
        clientName: 'c1',
        table: 'db::gr000',
        rowCount: 20000,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: snapshotJson.length,
        snapshotJson: snapshotJson,
        onProgress: progressEvents.add,
      );

      expect(result.job.id, 'job-resume-1');
      final uploadedChunkIndexes =
          client.requests
              .where((item) => item['name'] == 'jobs_upload_chunk')
              .map((item) => item['args']['chunkIndex'])
              .toList();
      expect(uploadedChunkIndexes, isNot(contains(0)));
      expect(uploadedChunkIndexes, isNotEmpty);
      expect(progressEvents, isNotEmpty);
      expect(
        progressEvents.last.bytesTransferred,
        progressEvents.last.totalBytes,
      );
    },
  );

  test(
    'downloadSnapshot rejects incomplete manifests before reading chunks',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          expect(name, 'jobs_download_snapshot_manifest');
          expect(callIndex, 0);
          return (
            statusCode: 200,
            body: {
              'status': 'success',
              'value': {
                'manifest': {
                  'id': '',
                  'chunkCount': 0,
                  'encoding': 'gzip',
                  'compressedBytes': 0,
                },
              },
            },
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.downloadSnapshot('job-bad-manifest'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Chunked download manifest is incomplete.'),
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'downloadSnapshot rejects payloads whose byte count does not match the manifest',
    () async {
      final snapshotJson = _buildLargeSnapshotJson(
        clientName: 'c2',
        table: 'db::gr000',
        rowCount: 10,
      );
      final compressed = gzip.encode(utf8.encode(snapshotJson));
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-mismatch-1',
                      'chunkCount': 1,
                      'encoding': 'gzip',
                      'compressedBytes': compressed.length + 5,
                    },
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'chunkData': base64Encode(compressed)},
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.downloadSnapshot('job-byte-mismatch'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains(
              'Downloaded snapshot byte count does not match the manifest.',
            ),
          ),
        ),
      );
    },
  );

  test('downloadSnapshot rejects unsupported manifest encodings', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'jobs_download_snapshot_manifest');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {
              'manifest': {
                'id': 'transfer-encoding-1',
                'chunkCount': 1,
                'encoding': 'brotli',
                'compressedBytes': 123,
              },
            },
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.downloadSnapshot('job-bad-encoding'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported snapshot encoding brotli.'),
        ),
      ),
    );
    expect(client.requests, hasLength(1));
  });

  test('downloadSnapshot rejects malformed chunk payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        switch (name) {
          case 'jobs_download_snapshot_manifest':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'manifest': {
                    'id': 'transfer-malformed-chunk-1',
                    'chunkCount': 1,
                    'encoding': 'gzip',
                    'compressedBytes': 10,
                  },
                },
              },
            );
          case 'jobs_download_snapshot_chunk':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {'notChunkData': 'abc'},
              },
            );
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.downloadSnapshot('job-malformed-chunk'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected snapshot chunk payload.'),
        ),
      ),
    );
  });

  test('downloadSnapshot rejects invalid base64 chunk payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        switch (name) {
          case 'jobs_download_snapshot_manifest':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'manifest': {
                    'id': 'transfer-bad-base64',
                    'chunkCount': 1,
                    'encoding': 'gzip',
                    'compressedBytes': 4,
                  },
                },
              },
            );
          case 'jobs_download_snapshot_chunk':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {'chunkData': '%%%not-base64%%%'},
              },
            );
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.downloadSnapshot('job-bad-base64'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected snapshot chunk payload.'),
        ),
      ),
    );
  });

  test('downloadSnapshot rejects corrupted compressed payloads', () async {
    final corruptedBytes = utf8.encode('not-gzip-data');
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        switch (name) {
          case 'jobs_download_snapshot_manifest':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'manifest': {
                    'id': 'transfer-corrupt-1',
                    'chunkCount': 1,
                    'encoding': 'gzip',
                    'compressedBytes': corruptedBytes.length,
                  },
                },
              },
            );
          case 'jobs_download_snapshot_chunk':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {'chunkData': base64Encode(corruptedBytes)},
              },
            );
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.downloadSnapshot('job-corrupt-gzip'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected decompressed snapshot payload.'),
        ),
      ),
    );
  });

  test(
    'downloadSnapshot rejects decompressed payloads that are not JSON objects',
    () async {
      final compressed = gzip.encode(
        utf8.encode(jsonEncode(['not', 'a', 'map'])),
      );
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-bad-json-1',
                      'chunkCount': 1,
                      'encoding': 'gzip',
                      'compressedBytes': compressed.length,
                    },
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'chunkData': base64Encode(compressed)},
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.downloadSnapshot('job-bad-json'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected decompressed snapshot payload.'),
          ),
        ),
      );
    },
  );

  test('downloadSnapshot rejects malformed decompressed JSON', () async {
    final compressed = gzip.encode(utf8.encode('{not-json'));
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        switch (name) {
          case 'jobs_download_snapshot_manifest':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'manifest': {
                    'id': 'transfer-bad-json-text',
                    'chunkCount': 1,
                    'encoding': 'gzip',
                    'compressedBytes': compressed.length,
                  },
                },
              },
            );
          case 'jobs_download_snapshot_chunk':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {'chunkData': base64Encode(compressed)},
              },
            );
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.downloadSnapshot('job-bad-json-text'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected decompressed snapshot payload.'),
        ),
      ),
    );
  });

  test('downloadSnapshot rejects invalid UTF-8 after decompression', () async {
    final compressed = gzip.encode(const [0x80, 0x80, 0x80]);
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        switch (name) {
          case 'jobs_download_snapshot_manifest':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'manifest': {
                    'id': 'transfer-bad-utf8',
                    'chunkCount': 1,
                    'encoding': 'gzip',
                    'compressedBytes': compressed.length,
                  },
                },
              },
            );
          case 'jobs_download_snapshot_chunk':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {'chunkData': base64Encode(compressed)},
              },
            );
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.downloadSnapshot('job-bad-utf8'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected decompressed snapshot payload.'),
        ),
      ),
    );
  });

  test(
    'downloadSnapshot rejects decompressed payloads whose rows are not maps',
    () async {
      final snapshotJson = jsonEncode({
        'id': 'snap-bad-rows',
        'columns': const ['id'],
        'rows': const ['not-a-map'],
      });
      final compressed = gzip.encode(utf8.encode(snapshotJson));
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-bad-rows',
                      'chunkCount': 1,
                      'encoding': 'gzip',
                      'compressedBytes': compressed.length,
                    },
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'chunkData': base64Encode(compressed)},
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.downloadSnapshot('job-bad-rows'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected decompressed snapshot payload.'),
          ),
        ),
      );
    },
  );

  test(
    'downloadSnapshot rejects malformed manifest snapshot metadata field types',
    () async {
      final snapshotJson = jsonEncode({
        'id': '',
        'clientName': '',
        'table': 'db::mt000',
        'createdAt': '',
        'rowCount': 1,
        'checksum': 'abc123',
        'snapshotBytes': 16,
        'columns': const ['Id'],
        'rows': const [
          {'Id': '1'},
        ],
      });
      final compressed = gzip.encode(utf8.encode(snapshotJson));
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-bad-metadata',
                      'chunkCount': 1,
                      'encoding': 'gzip',
                      'compressedBytes': compressed.length,
                    },
                    'snapshot': {'id': 123, 'clientName': 'c2'},
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'chunkData': base64Encode(compressed)},
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.downloadSnapshot('job-bad-metadata'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected chunked download manifest payload.'),
          ),
        ),
      );
    },
  );

  test('uploadSnapshot rejects malformed upload start payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'jobs_upload_chunk_start');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': ['not', 'a', 'map'],
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadSnapshot(
        'job-bad-start',
        clientName: 'c1',
        table: 'db::mt000',
        rowCount: 1,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: 32,
        snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected chunked upload start payload.'),
        ),
      ),
    );
  });

  test('uploadSnapshot rejects malformed upload start JSON', () async {
    final api = AgentControlPlaneClient(
      client: MockClient((request) async {
        return http.Response('not-json', 200);
      }),
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadSnapshot(
        'job-bad-start-json',
        clientName: 'c1',
        table: 'db::mt000',
        rowCount: 1,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: 32,
        snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected chunked upload start payload.'),
        ),
      ),
    );
  });

  test('uploadSnapshot rejects non-numeric resumed chunk indexes', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'jobs_upload_chunk_start');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {
              'receivedIndexes': ['bad-index'],
            },
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadSnapshot(
        'job-bad-indexes',
        clientName: 'c1',
        table: 'db::mt000',
        rowCount: 1,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: 32,
        snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected chunked upload start payload.'),
        ),
      ),
    );
  });

  test('uploadSnapshot rejects malformed upload completion payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        switch (name) {
          case 'jobs_upload_chunk_start':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'receivedIndexes': const [0],
                },
              },
            );
          case 'jobs_upload_chunk_complete':
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'job': {'id': 'job-bad-complete'},
                },
              },
            );
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadSnapshot(
        'job-bad-complete',
        clientName: 'c1',
        table: 'db::mt000',
        rowCount: 1,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: 32,
        snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected snapshot upload completion payload.'),
        ),
      ),
    );
  });

  test('uploadSnapshot rejects malformed upload completion JSON', () async {
    final client = MockClient((request) async {
      final payload =
          jsonDecode(request.body as String) as Map<String, dynamic>;
      if (payload['name'] == 'jobs_upload_chunk_start') {
        return http.Response(
          jsonEncode({
            'status': 'success',
            'value': {
              'receivedIndexes': const [0],
            },
          }),
          200,
        );
      }
      return http.Response('not-json', 200);
    });
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadSnapshot(
        'job-bad-complete-json',
        clientName: 'c1',
        table: 'db::mt000',
        rowCount: 1,
        snapshotCreatedAt: '2026-07-10T03:05:00Z',
        snapshotBytes: 32,
        snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected snapshot upload completion payload.'),
        ),
      ),
    );
  });

  test(
    'uploadSnapshot rejects malformed snapshot payloads in completion',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'receivedIndexes': const [0],
                  },
                },
              );
            case 'jobs_upload_chunk_complete':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'job': {'id': 'job-bad-snapshot'},
                    'snapshot': {
                      'id': 'snap-bad',
                      'columns': const ['id'],
                      'rows': const ['not-a-map'],
                    },
                  },
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.uploadSnapshot(
          'job-bad-snapshot',
          clientName: 'c1',
          table: 'db::mt000',
          rowCount: 1,
          snapshotCreatedAt: '2026-07-10T03:05:00Z',
          snapshotBytes: 32,
          snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected snapshot upload completion payload.'),
          ),
        ),
      );
    },
  );

  test(
    'uploadSnapshot rejects malformed job field types in completion',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'receivedIndexes': const [0],
                  },
                },
              );
            case 'jobs_upload_chunk_complete':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'job': {'id': 123},
                    'snapshot': {
                      'id': 'snap-ok',
                      'columns': const ['id'],
                      'rows': const [],
                    },
                  },
                },
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.uploadSnapshot(
          'job-bad-job-field',
          clientName: 'c1',
          table: 'db::mt000',
          rowCount: 1,
          snapshotCreatedAt: '2026-07-10T03:05:00Z',
          snapshotBytes: 32,
          snapshotJson: jsonEncode({'id': 'snap-1', 'rows': const []}),
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected snapshot upload completion payload.'),
          ),
        ),
      );
    },
  );

  test('fetchClientUpdateInfo rejects non-map manifest payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        fail('Unexpected function call $name');
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    client.requests.clear();
    final manifestClient = MockClient((request) async {
      return http.Response(jsonEncode(['bad', 'manifest']), 200);
    });
    final manifestApi = AgentControlPlaneClient(
      client: manifestClient,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      manifestApi.fetchClientUpdateInfo(),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected client update manifest payload.'),
        ),
      ),
    );
  });

  test('fetchClientUpdateInfo rejects malformed manifest JSON', () async {
    final manifestApi = AgentControlPlaneClient(
      client: MockClient((request) async {
        return http.Response('not-json', 200);
      }),
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      manifestApi.fetchClientUpdateInfo(),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected client update manifest payload.'),
        ),
      ),
    );
  });

  test(
    'fetchClientUpdateInfo rejects malformed manifest field types',
    () async {
      final manifestApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({'version': 123, 'commit': 'abc123'}),
            200,
          );
        }),
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        manifestApi.fetchClientUpdateInfo(),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected client update manifest payload.'),
          ),
        ),
      );
    },
  );

  test('heartbeat rejects non-map payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'agents_heartbeat');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': ['not', 'a', 'map'],
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed JSON payloads', () async {
    final api = AgentControlPlaneClient(
      client: MockClient((request) async {
        return http.Response('not-json', 200);
      }),
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected payload returned from sending heartbeat.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed tablePolicies entries', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agents_heartbeat');
        return {
          'tablePolicies': ['bad-policy'],
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed syncSettings field types', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agents_heartbeat');
        return {
          'syncSettings': {'historyLimit': 'bad'},
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed tablePolicy field types', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agents_heartbeat');
        return {
          'tablePolicies': [
            {'table': 123},
          ],
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed tableDependencies entries', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agents_heartbeat');
        return {
          'tableDependencies': ['bad-dependency'],
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed tableDependency field types', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agents_heartbeat');
        return {
          'tableDependencies': [
            {'table': 123},
          ],
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test('heartbeat rejects malformed jobs entries', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agents_heartbeat');
        return {
          'jobs': ['bad-job'],
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.heartbeat(
        clientName: 'c1',
        machineName: 'machine',
        historyLimit: 5,
        autoSyncIntervalMinutes: 15,
        server: '',
        database: '',
        replicationUseWindowsAuth: true,
        replicationUser: '',
        replicationPassword: '',
        serverConnected: true,
        sqlConnected: true,
        selectedTable: null,
        tables: const {},
        tableRelationships: const [],
        clientVersion: '1.0.91+95',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected heartbeat payload.'),
        ),
      ),
    );
  });

  test(
    'acknowledgeClientUpdate rejects malformed acknowledgement payloads',
    () async {
      final client = _DelayedClient(
        delay: Duration.zero,
        responseForName: (name) {
          expect(name, 'agent_client_update_ack');
          return {'notClientUpdate': true};
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.acknowledgeClientUpdate(
          clientName: 'c1',
          requestId: 'req-1',
          status: 'current',
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected client update acknowledgement payload.'),
          ),
        ),
      );
    },
  );

  test(
    'acknowledgeClientUpdate rejects malformed acknowledgement field types',
    () async {
      final client = _DelayedClient(
        delay: Duration.zero,
        responseForName: (name) {
          expect(name, 'agent_client_update_ack');
          return {
            'clientUpdate': {'status': 123},
          };
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.acknowledgeClientUpdate(
          clientName: 'c1',
          requestId: 'req-1',
          status: 'current',
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected client update acknowledgement payload.'),
          ),
        ),
      );
    },
  );

  test('uploadDiagnostics rejects malformed upload payloads', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agent_diagnostics_upload');
        return {'notDiagnostics': true};
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadDiagnostics(
        clientName: 'c1',
        requestId: 'req-1',
        summary: 'summary',
        payload: '{}',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected diagnostics upload payload.'),
        ),
      ),
    );
  });

  test('uploadDiagnostics rejects malformed diagnostics field types', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'agent_diagnostics_upload');
        return {
          'diagnostics': {'status': 123},
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.uploadDiagnostics(
        clientName: 'c1',
        requestId: 'req-1',
        summary: 'summary',
        payload: '{}',
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected diagnostics upload payload.'),
        ),
      ),
    );
  });

  test(
    'acknowledgeWindowAction rejects malformed acknowledgement payloads',
    () async {
      final client = _DelayedClient(
        delay: Duration.zero,
        responseForName: (name) {
          expect(name, 'agent_window_action_ack');
          return {'notWindowAction': true};
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.acknowledgeWindowAction(
          clientName: 'c1',
          requestId: 'req-1',
          action: 'minimize',
          status: 'completed',
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected window action acknowledgement payload.'),
          ),
        ),
      );
    },
  );

  test(
    'acknowledgeWindowAction rejects malformed acknowledgement field types',
    () async {
      final client = _DelayedClient(
        delay: Duration.zero,
        responseForName: (name) {
          expect(name, 'agent_window_action_ack');
          return {
            'windowAction': {'status': 123},
          };
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.acknowledgeWindowAction(
          clientName: 'c1',
          requestId: 'req-1',
          action: 'minimize',
          status: 'completed',
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Unexpected window action acknowledgement payload.'),
          ),
        ),
      );
    },
  );

  test('createJobs rejects malformed job queue payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'jobs_create');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': ['not', 'a', 'map'],
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.createJobs(clientName: 'c1', tables: const ['db::mt000']),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected job queue payload.'),
        ),
      ),
    );
  });

  test('createJobs rejects malformed job entries', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'jobs_create');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {
              'jobs': ['not-a-map'],
            },
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.createJobs(clientName: 'c1', tables: const ['db::mt000']),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected job queue payload.'),
        ),
      ),
    );
  });

  test('createJobs rejects malformed job field types', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'jobs_create');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {
              'jobs': [
                {'id': 123},
              ],
            },
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.createJobs(clientName: 'c1', tables: const ['db::mt000']),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected job queue payload.'),
        ),
      ),
    );
  });

  test('loginClient rejects malformed login payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'auth_login');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {'token': 'token-only'},
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.loginClient(name: 'user', password: 'pass'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected login payload.'),
        ),
      ),
    );
  });

  test('loginClient rejects malformed login field types', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'auth_login');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {
              'token': 123,
              'user': {'id': 456},
            },
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.loginClient(name: 'user', password: 'pass'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected login payload.'),
        ),
      ),
    );
  });

  test('fetchCurrentUser rejects malformed current-user payloads', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'auth_me');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {'token': 'ignored'},
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );
    api.setAuthToken('token-1');

    await expectLater(
      api.fetchCurrentUser(),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected current-user payload.'),
        ),
      ),
    );
  });

  test('fetchCurrentUser rejects malformed current-user field types', () async {
    final client = _ScriptedClient(
      responseForRequest: (name, args, callIndex) {
        expect(name, 'auth_me');
        return (
          statusCode: 200,
          body: {
            'status': 'success',
            'value': {
              'user': {'id': 123},
            },
          },
        );
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );
    api.setAuthToken('token-1');

    await expectLater(
      api.fetchCurrentUser(),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected current-user payload.'),
        ),
      ),
    );
  });

  test('updateTableSyncPolicy rejects malformed policy payloads', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'table_sync_policy_set');
        return {'notPolicy': true};
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.updateTableSyncPolicy(table: 'db::mt000', enabled: true),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected table sync policy payload.'),
        ),
      ),
    );
  });

  test('updateTableSyncPolicy rejects malformed policy field types', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'table_sync_policy_set');
        return {
          'policy': {'table': 123},
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.updateTableSyncPolicy(table: 'db::mt000', enabled: true),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected table sync policy payload.'),
        ),
      ),
    );
  });

  test('startJob rejects malformed job payloads', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'jobs_start');
        return {'notJob': true};
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.startJob('job-1', status: 'running', progress: 10, message: 'start'),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected payload returned from job start.'),
        ),
      ),
    );
  });

  test('updateJobProgress rejects malformed job payloads', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'jobs_progress');
        return {'notJob': true};
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.updateJobProgress(
        'job-1',
        status: 'running',
        progress: 50,
        message: 'progress',
        rowCount: 123,
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected payload returned from job progress.'),
        ),
      ),
    );
  });

  test('updateJobProgress rejects malformed job field types', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'jobs_progress');
        return {
          'job': {'id': 123},
        };
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.updateJobProgress(
        'job-1',
        status: 'running',
        progress: 50,
        message: 'progress',
        rowCount: 123,
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected payload returned from job progress.'),
        ),
      ),
    );
  });

  test('completeJob rejects malformed job payloads', () async {
    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        expect(name, 'jobs_complete');
        return {'notJob': true};
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    await expectLater(
      api.completeJob(
        'job-1',
        status: 'completed',
        progress: 100,
        message: 'done',
        rowCount: 123,
      ),
      throwsA(
        isA<AgentControlPlaneException>().having(
          (error) => error.message,
          'message',
          contains('Unexpected payload returned from job completion.'),
        ),
      ),
    );
  });

  test(
    'fetchClientUpdateInfo returns null for 404 and parses a valid manifest',
    () async {
      final missingApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response('missing', 404);
        }),
        baseUrl: 'https://example.com/call',
      );
      final foundApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'version': '1.0.106+110',
              'commit': 'abc123',
              'releaseDate': '2026-07-10',
              'zipUrl': 'https://example.com/client.zip',
              'updateScriptUrl': 'https://example.com/update.ps1',
              'sha256': 'deadbeef',
              'sizeBytes': 12345,
            }),
            200,
          );
        }),
        baseUrl: 'https://example.com/call',
      );

      expect(await missingApi.fetchClientUpdateInfo(), isNull);
      final manifest = await foundApi.fetchClientUpdateInfo();
      expect(manifest, isNotNull);
      expect(manifest!.version, '1.0.106+110');
      expect(manifest.commit, 'abc123');
      expect(manifest.sizeBytes, 12345);
    },
  );

  test(
    'checkHealth returns false for non-200 responses and request failures',
    () async {
      final unhealthyApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response('bad', 500);
        }),
        baseUrl: 'https://example.com/call',
      );
      final failingApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          throw const SocketException('offline');
        }),
        baseUrl: 'https://example.com/call',
      );

      expect(await unhealthyApi.checkHealth(), isFalse);
      expect(await failingApi.checkHealth(), isFalse);
    },
  );

  test(
    'logout calls auth_logout once and clears the stored auth token',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          expect(name, 'auth_logout');
          return (
            statusCode: 200,
            body: {'status': 'success', 'value': <String, Object?>{}},
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );
      api.setAuthToken('token-1');

      await api.logout();
      await api.logout();

      expect(client.requests, hasLength(1));
      expect(client.requests.single['name'], 'auth_logout');
    },
  );

  test(
    'failJob posts the expected payload including optional progress',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          expect(name, 'jobs_fail');
          expect(args['jobId'], 'job-1');
          expect(args['message'], 'boom');
          expect(args['progress'], 90);
          return (
            statusCode: 200,
            body: {'status': 'success', 'value': <String, Object?>{}},
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await api.failJob('job-1', 'boom', progress: 90);

      expect(client.requests, hasLength(1));
    },
  );

  test('job lifecycle methods parse valid job payloads', () async {
    Map<String, Object?> jobPayload(
      String status,
      int progress,
      String message,
    ) => {
      'job': {
        'id': 'job-1',
        'clientName': 'c1',
        'sourceClientName': 'c1',
        'subscriberClientName': 'c2',
        'table': 'db::mt000',
        'direction': 'upload',
        'publisherServer': '',
        'publisherDatabase': '',
        'publisherUseWindowsAuth': true,
        'publisherUser': '',
        'publisherPassword': '',
        'status': status,
        'progress': progress,
        'rowCount': 12,
        'snapshotBytes': 32,
        'snapshotCreatedAt': '2026-07-10T03:05:00Z',
        'snapshotId': 'snap-1',
        'createdAt': '2026-07-10T03:05:00Z',
        'updatedAt': '2026-07-10T03:05:05Z',
        'startedAt': '2026-07-10T03:05:01Z',
        'completedAt': status == 'completed' ? '2026-07-10T03:05:05Z' : null,
        'message': message,
        'error': null,
      },
    };

    final client = _DelayedClient(
      delay: Duration.zero,
      responseForName: (name) {
        switch (name) {
          case 'jobs_start':
            return jobPayload('running', 10, 'starting');
          case 'jobs_progress':
            return jobPayload('running', 50, 'progress');
          case 'jobs_complete':
            return jobPayload('completed', 100, 'done');
          default:
            fail('Unexpected request $name');
        }
      },
    );
    final api = AgentControlPlaneClient(
      client: client,
      baseUrl: 'https://example.com/call',
    );

    final started = await api.startJob(
      'job-1',
      status: 'running',
      progress: 10,
      message: 'starting',
    );
    final progressed = await api.updateJobProgress(
      'job-1',
      status: 'running',
      progress: 50,
      message: 'progress',
      rowCount: 12,
    );
    final completed = await api.completeJob(
      'job-1',
      status: 'completed',
      progress: 100,
      message: 'done',
      rowCount: 12,
    );

    expect(started.status, 'running');
    expect(progressed.progress, 50);
    expect(completed.status, 'completed');
    expect(completed.completedAt, isNotNull);
  });

  test(
    'base URL normalization falls back to the live control plane for localhost-style inputs',
    () {
      final blank = AgentControlPlaneClient(baseUrl: '');
      final localhost = AgentControlPlaneClient(
        baseUrl: 'http://127.0.0.1:6006/call',
      );
      final hostPortOnly = AgentControlPlaneClient(
        baseUrl: 'https://example.com:6006/call',
      );
      final trailingSlash = AgentControlPlaneClient(
        baseUrl: 'https://sync.velvet-leaf.com/call/',
      );
      final custom = AgentControlPlaneClient(
        baseUrl: 'https://example.com/custom-call',
      );

      expect(blank.baseUrl, 'https://sync.velvet-leaf.com/call');
      expect(localhost.baseUrl, 'https://sync.velvet-leaf.com/call');
      expect(hostPortOnly.baseUrl, 'https://sync.velvet-leaf.com/call');
      expect(trailingSlash.baseUrl, 'https://sync.velvet-leaf.com/call');
      expect(custom.baseUrl, 'https://example.com/custom-call');
    },
  );

  test(
    'authenticated function calls add token to args and skip auth_login injection',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          if (name == 'auth_login') {
            expect(args.containsKey('token'), isFalse);
            return (
              statusCode: 200,
              body: {
                'status': 'success',
                'value': {
                  'token': 'token-1',
                  'user': {
                    'id': 'u1',
                    'username': 'user',
                    'email': 'user@example.com',
                    'name': 'User',
                    'role': 'admin',
                  },
                },
              },
            );
          }

          expect(args['token'], 'token-1');
          expect(name, 'jobs_fail');
          return (
            statusCode: 200,
            body: {'status': 'success', 'value': <String, Object?>{}},
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      final user = await api.loginClient(name: 'user', password: 'pass');
      await api.failJob('job-1', 'boom');

      expect(user.token, 'token-1');
      expect(client.requests.map((item) => item['name']).toList(), [
        'auth_login',
        'jobs_fail',
      ]);
    },
  );

  test(
    'fetchClientUpdateInfo surfaces structured and generic HTTP errors clearly',
    () async {
      final structuredApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'messages': [
                {'text': 'manifest access denied'},
              ],
            }),
            403,
          );
        }),
        baseUrl: 'https://example.com/call',
      );
      final retryingApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response('busy', 503);
        }),
        baseUrl: 'https://example.com/call',
      );
      final genericApi = AgentControlPlaneClient(
        client: MockClient((request) async {
          return http.Response('plain-text', 418);
        }),
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        structuredApi.fetchClientUpdateInfo(),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('manifest access denied'),
          ),
        ),
      );
      await expectLater(
        retryingApi.fetchClientUpdateInfo(),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('temporarily unavailable'),
          ),
        ),
      );
      await expectLater(
        genericApi.fetchClientUpdateInfo(),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('Request failed with 418.'),
          ),
        ),
      );
    },
  );

  test(
    'downloadSnapshot does not retry non-retryable manifest failures',
    () async {
      var requestCount = 0;
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          requestCount += 1;
          expect(name, 'jobs_download_snapshot_manifest');
          return (
            statusCode: 401,
            body: {'error': 'unauthorized manifest request'},
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await expectLater(
        api.downloadSnapshot('job-no-retry'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('unauthorized manifest request'),
          ),
        ),
      );
      expect(requestCount, 1);
    },
  );

  test(
    'downloadSnapshot surfaces retry exhaustion for manifest failures',
    () async {
      var requestCount = 0;
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          requestCount += 1;
          expect(name, 'jobs_download_snapshot_manifest');
          return (statusCode: 503, body: {'error': 'temporary outage'});
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
        snapshotTransferMaxAttempts: 3,
        snapshotTransferRetryDelays: const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ],
      );

      await expectLater(
        api.downloadSnapshot('job-manifest-retry-exhausted'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('temporary outage'),
          ),
        ),
      );
      expect(requestCount, 3);
    },
  );

  test(
    'downloadSnapshot surfaces retry exhaustion for chunk failures',
    () async {
      var chunkRequestCount = 0;
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_download_snapshot_manifest':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {
                    'manifest': {
                      'id': 'transfer-exhausted-chunk',
                      'chunkCount': 1,
                      'encoding': 'gzip',
                      'compressedBytes': 10,
                    },
                  },
                },
              );
            case 'jobs_download_snapshot_chunk':
              chunkRequestCount += 1;
              return (
                statusCode: 503,
                body: {'error': 'chunk temporarily unavailable'},
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
        snapshotTransferMaxAttempts: 3,
        snapshotTransferRetryDelays: const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ],
      );

      await expectLater(
        api.downloadSnapshot('job-chunk-retry-exhausted'),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('chunk temporarily unavailable'),
          ),
        ),
      );
      expect(chunkRequestCount, 3);
    },
  );

  test(
    'uploadSnapshot stops immediately on non-retryable chunk upload failures',
    () async {
      var chunkRequestCount = 0;
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'receivedIndexes': const []},
                },
              );
            case 'jobs_upload_chunk':
              chunkRequestCount += 1;
              return (
                statusCode: 401,
                body: {'error': 'chunk upload unauthorized'},
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
        snapshotTransferMaxAttempts: 3,
        snapshotTransferRetryDelays: const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ],
      );

      await expectLater(
        api.uploadSnapshot(
          'job-non-retryable-upload',
          clientName: 'c1',
          table: 'db::mt000',
          rowCount: 1,
          snapshotCreatedAt: '2026-07-10T03:05:00Z',
          snapshotBytes: 32,
          snapshotJson: jsonEncode({
            'id': 'snap-1',
            'clientName': 'c1',
            'table': 'db::mt000',
            'rows': [
              {'Id': '1', 'Name': 'Row 1'},
            ],
          }),
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('chunk upload unauthorized'),
          ),
        ),
      );
      expect(chunkRequestCount, 1);
    },
  );

  test(
    'uploadSnapshot surfaces retry exhaustion for chunk upload failures',
    () async {
      var chunkRequestCount = 0;
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          switch (name) {
            case 'jobs_upload_chunk_start':
              return (
                statusCode: 200,
                body: {
                  'status': 'success',
                  'value': {'receivedIndexes': const []},
                },
              );
            case 'jobs_upload_chunk':
              chunkRequestCount += 1;
              return (
                statusCode: 503,
                body: {'error': 'chunk upload unavailable'},
              );
            default:
              fail('Unexpected request $name');
          }
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
        snapshotTransferMaxAttempts: 3,
        snapshotTransferRetryDelays: const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ],
      );

      await expectLater(
        api.uploadSnapshot(
          'job-retry-exhausted-upload',
          clientName: 'c1',
          table: 'db::mt000',
          rowCount: 1,
          snapshotCreatedAt: '2026-07-10T03:05:00Z',
          snapshotBytes: 32,
          snapshotJson: jsonEncode({
            'id': 'snap-1',
            'clientName': 'c1',
            'table': 'db::mt000',
            'rows': [
              {'Id': '1', 'Name': 'Row 1'},
            ],
          }),
        ),
        throwsA(
          isA<AgentControlPlaneException>().having(
            (error) => error.message,
            'message',
            contains('chunk upload unavailable'),
          ),
        ),
      );
      expect(chunkRequestCount, 3);
    },
  );

  test(
    'multi-writer upload sends base64 JSON payloads for storage-backed relay',
    () async {
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          expect(name, 'jobs_multi_writer_upload');
          expect(args['rows'], isEmpty);
          expect(args['payloadBase64'], isNotEmpty);
          expect(args['payloadRowCount'], 1);
          final decoded = jsonDecode(
            utf8.decode(base64Decode(args['payloadBase64'] as String)),
          );
          expect(decoded, [
            {'Id': '1', 'Name': 'Arabic مرحبا'},
          ]);
          return (
            statusCode: 200,
            body: {
              'status': 'success',
              'value': {
                'job': {
                  'id': 'job-mw-upload',
                  'clientName': 'c1',
                  'sourceClientName': 'c1',
                  'subscriberClientName': 'c2',
                  'table': 'db::mt000',
                  'direction': 'upload',
                  'publisherServer': '',
                  'publisherDatabase': '',
                  'publisherUseWindowsAuth': true,
                  'publisherUser': '',
                  'publisherPassword': '',
                  'status': 'completed',
                  'progress': 100,
                  'rowCount': 1,
                  'snapshotBytes': 32,
                  'createdAt': '2026-07-10T03:05:00Z',
                  'updatedAt': '2026-07-10T03:05:05Z',
                  'message': 'uploaded',
                  'error': null,
                },
              },
            },
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      await api.uploadMultiWriterDelta(
        'job-mw-upload',
        batchId: 'batch-1',
        clientName: 'c1',
        table: 'db::mt000',
        columns: const ['Id', 'Name'],
        keyColumns: const ['Id'],
        rows: const [
          {'Id': '1', 'Name': 'Arabic مرحبا'},
        ],
        chunkId: 'chunk-0',
        finalChunk: true,
        changeTrackingVersion: 4,
      );
    },
  );

  test(
    'multi-writer download decodes a storage-backed base64 payload',
    () async {
      final encoded = base64Encode(
        utf8.encode(
          jsonEncode([
            {'Id': '1', 'Name': 'Arabic مرحبا'},
          ]),
        ),
      );
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          expect(name, 'jobs_multi_writer_download');
          return (
            statusCode: 200,
            body: {
              'status': 'success',
              'value': {
                'done': true,
                'nextCursor': null,
                'payloadBase64': encoded,
                'snapshot': {
                  'id': 'batch-1-c2-first',
                  'clientName': 'server-merge',
                  'subscriberClientName': 'c2',
                  'table': 'db::mt000',
                  'createdAt': '2026-07-10T03:05:00Z',
                  'rowCount': 1,
                  'checksum': 'checksum-1',
                  'snapshotBytes': 32,
                  'columns': ['Id', 'Name'],
                  'rows': const [],
                  'sourceJobId': 'job-mw-download',
                  'clientChangeTrackingVersions': const [],
                },
              },
            },
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );

      final snapshot = await api.downloadMultiWriterDelta(
        'job-mw-download',
        batchId: 'batch-1',
      );

      expect(snapshot.rows, [
        {'Id': '1', 'Name': 'Arabic مرحبا'},
      ]);
    },
  );

  test(
    'multi-writer download streams pages without retaining all rows',
    () async {
      final payloads = [
        base64Encode(
          utf8.encode(
            jsonEncode([
              {'Id': '1', 'Name': 'first'},
            ]),
          ),
        ),
        base64Encode(
          utf8.encode(
            jsonEncode([
              {'Id': '2', 'Name': 'second'},
            ]),
          ),
        ),
      ];
      final client = _ScriptedClient(
        responseForRequest: (name, args, callIndex) {
          expect(name, 'jobs_multi_writer_download');
          final done = callIndex == 1;
          return (
            statusCode: 200,
            body: {
              'status': 'success',
              'value': {
                'done': done,
                'nextCursor': done ? null : 'next',
                'payloadBase64': payloads[callIndex],
                'snapshot': {
                  'id': 'batch-1-page-$callIndex',
                  'clientName': 'server-merge',
                  'subscriberClientName': 'c2',
                  'table': 'db::mt000',
                  'createdAt': '2026-07-10T03:05:00Z',
                  'rowCount': 1,
                  'checksum': 'checksum-$callIndex',
                  'snapshotBytes': 32,
                  'columns': ['Id', 'Name'],
                  'rows': const [],
                  'sourceJobId': 'job-mw-download',
                  'clientChangeTrackingVersions': const [],
                  'isDelta': true,
                },
              },
            },
          );
        },
      );
      final api = AgentControlPlaneClient(
        client: client,
        baseUrl: 'https://example.com/call',
      );
      final streamedRows = <List<Map<String, String?>>>[];

      final snapshot = await api.downloadMultiWriterDelta(
        'job-mw-download-streamed',
        batchId: 'batch-1',
        onChunk: (chunk) async => streamedRows.add(chunk.rows),
      );

      expect(streamedRows, [
        [
          {'Id': '1', 'Name': 'first'},
        ],
        [
          {'Id': '2', 'Name': 'second'},
        ],
      ]);
      expect(snapshot.rowCount, 2);
      expect(snapshot.rows, isEmpty);
    },
  );
}
