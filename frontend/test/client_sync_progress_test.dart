import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/client_sync_progress.dart';
import 'package:sync_admin_web/models.dart';

void main() {
  test('does not report an orphaned table failure as an active failure', () {
    final summary = computeClientSyncProgressSummary(
      agent: _agent(
        tables: [
          _tableState('dbo.Customers', enabled: true, status: 'Completed'),
          _tableState(
            'dbo.Orders',
            enabled: true,
            status: 'Failed',
            message: 'No writable columns were found.',
          ),
        ],
      ),
      jobs: const [],
    );

    expect(summary.label, 'Complete');
    expect(summary.detail, 'All 2 enabled tables are complete.');
  });

  test(
    'reports partial when some enabled tables completed and the rest are waiting',
    () {
      final summary = computeClientSyncProgressSummary(
        agent: _agent(
          tables: [
            _tableState('dbo.Customers', enabled: true, status: 'Completed'),
            _tableState(
              'dbo.Orders',
              enabled: true,
              status: 'Paused',
              lastSync: '',
              progress: 0,
            ),
          ],
        ),
        jobs: const [],
      );

      expect(summary.label, 'Partial');
      expect(summary.detail, '1 complete of 2 enabled tables.');
    },
  );

  test('reports syncing when a queued table has not completed a sync yet', () {
    final summary = computeClientSyncProgressSummary(
      agent: _agent(
        tables: [
          _tableState(
            'dbo.Customers',
            enabled: true,
            status: 'Queued',
            lastSync: '',
            progress: 0,
          ),
        ],
      ),
      jobs: const [],
    );

    expect(summary.label, 'Syncing');
    expect(summary.progress, 4);
    expect(summary.detail, '1 active, 0 complete of 1 tables.');
  });
}

AdminAgent _agent({required List<AdminTableState> tables}) {
  return AdminAgent(
    clientName: 'agent-a',
    clientUserId: null,
    ownerUserId: null,
    machineName: 'machine-a',
    server: 'localhost',
    database: 'velvet',
    isOnline: true,
    historyLimit: 5,
    autoSyncIntervalMinutes: 15,
    serverConnected: true,
    sqlConnected: true,
    clientVersion: '1.0.0',
    lastHeartbeat: '2026-07-06T10:00:00Z',
    selectedTable: null,
    diagnostics: const AdminAgentDiagnostics(),
    clientUpdate: const AdminAgentClientUpdate(),
    tables: tables,
  );
}

AdminTableState _tableState(
  String table, {
  required bool enabled,
  required String status,
  String lastSync = '2026-07-06T09:55:00Z',
  int progress = 100,
  int rowCount = 0,
  String message = '',
}) {
  return AdminTableState(
    table: table,
    enabled: enabled,
    status: status,
    lastSync: lastSync,
    progress: progress,
    rowCount: rowCount,
    message: message,
  );
}
