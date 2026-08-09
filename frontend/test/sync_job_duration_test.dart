import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/models.dart';

AdminJob _job({
  required String status,
  required String createdAt,
  String? updatedAt,
  String? completedAt,
}) => AdminJob.fromJson({
  'id': 'job-1',
  'clientName': 'client-a',
  'table': 'db::table',
  'direction': 'download',
  'status': status,
  'createdAt': createdAt,
  'updatedAt': updatedAt ?? createdAt,
  'completedAt': completedAt,
});

void main() {
  test('completed job duration includes queue and processing time', () {
    final job = _job(
      status: 'completed',
      createdAt: '2026-08-02T08:00:00Z',
      updatedAt: '2026-08-02T08:01:35Z',
      completedAt: '2026-08-02T08:01:35Z',
    );

    expect(job.duration(), const Duration(minutes: 1, seconds: 35));
    expect(formatSyncDuration(job.duration()), '1m 35s');
  });

  test('queued and waiting jobs show live elapsed time', () {
    final job = _job(status: 'waiting', createdAt: '2026-08-02T08:00:00Z');

    expect(
      job.duration(now: DateTime.parse('2026-08-02T08:00:04.250Z')),
      const Duration(milliseconds: 4250),
    );
    expect(
      formatSyncDuration(
        job.duration(now: DateTime.parse('2026-08-02T08:00:04.250Z')),
      ),
      '4.3s',
    );
  });

  test('failed jobs stop their duration at the recorded update', () {
    final job = _job(
      status: 'failed',
      createdAt: '2026-08-02T08:00:00Z',
      updatedAt: '2026-08-02T08:00:12Z',
    );

    expect(
      job.duration(now: DateTime.parse('2026-08-02T09:00:00Z')),
      const Duration(seconds: 12),
    );
  });

  test('client exposes its durable latest completed sync duration', () {
    final agent = AdminAgent.fromJson({
      'clientName': 'client-a',
      'lastSyncCompletedAt': '2026-08-06T22:20:16Z',
      'lastSyncDurationMs': 95250,
    });

    expect(agent.lastSyncDuration, const Duration(milliseconds: 95250));
    expect(formatSyncDuration(agent.lastSyncDuration), '1m 35s');
  });

  test('client keeps change-check time separate from completed sync time', () {
    final agent = AdminAgent.fromJson({
      'clientName': 'client-a',
      'lastChangeCheckAt': '2026-08-09T19:52:03Z',
      'lastSyncCompletedAt': '2026-08-09T19:20:33Z',
    });

    expect(agent.lastChangeCheckAt, '2026-08-09T19:52:03Z');
    expect(agent.lastSyncCompletedAt, '2026-08-09T19:20:33Z');
  });

  test('Sync All duration covers the complete durable operation', () {
    final completed = AdminSyncAllOperation.fromJson({
      'ownerUserId': 'owner-a',
      'status': 'completed',
      'startedAt': '2026-08-07T07:38:09Z',
      'completedAt': '2026-08-07T07:47:09Z',
      'durationMs': 540000,
      'tableCount': 31,
      'remainingTableCount': 0,
    });
    final running = AdminSyncAllOperation.fromJson({
      'ownerUserId': 'owner-a',
      'status': 'running',
      'startedAt': '2026-08-07T07:38:09Z',
      'tableCount': 31,
      'remainingTableCount': 12,
    });

    expect(completed.duration(), const Duration(minutes: 9));
    expect(formatSyncDuration(completed.duration()), '9m 0s');
    expect(completed.hasErrors, isFalse);

    final completedWithErrors = AdminSyncAllOperation.fromJson({
      'ownerUserId': 'owner-1',
      'status': 'completed_errors',
      'startedAt': '2026-08-07T07:38:09Z',
      'completedAt': '2026-08-07T07:47:09Z',
      'durationMs': 540000,
      'tableCount': 31,
      'remainingTableCount': 0,
    });
    expect(completedWithErrors.hasErrors, isTrue);
    expect(
      running.duration(now: DateTime.parse('2026-08-07T07:40:39Z')),
      const Duration(minutes: 2, seconds: 30),
    );
  });
}
