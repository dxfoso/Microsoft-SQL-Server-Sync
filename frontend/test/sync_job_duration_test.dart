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
}
