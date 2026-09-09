import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/alameen_operation_boundary.dart';

void main() {
  test('boundary parser rejects intermediate document graphs', () {
    final intermediate = parseAlameenOperationBoundaryResult(
      '__SQL_SYNC_ALAMEEN_BOUNDARY__=5769|1|1',
    );
    final complete = parseAlameenOperationBoundaryResult(
      '__SQL_SYNC_ALAMEEN_BOUNDARY__=5770|1|0',
    );

    expect(intermediate, isNotNull);
    expect(intermediate!.isComplete, isFalse);
    expect(complete, isNotNull);
    expect(complete!.isComplete, isTrue);
    expect(complete.changeTrackingVersion, 5770);
  });

  test('boundary SQL validates the mapped final accounting graph', () {
    final sql = buildAlameenOperationBoundarySql(
      database: 'AmnDb048_SyncLab',
      tableBaselines: {
        for (final table in alameenOperationLocalTables) table: 5768,
      },
    );

    expect(sql, contains('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;'));
    expect(sql, contains('CHANGE_TRACKING_CURRENT_VERSION()'));
    expect(
      sql,
      contains('CHANGETABLE(CHANGES [AmnDb048_SyncLab].[dbo].[bi000], 5768)'),
    );
    expect(sql, contains('header.Total'));
    expect(sql, contains('lines.LineTotal'));
    expect(sql, contains('relations.RelationCount'));
    expect(
      sql,
      contains(
        'CONVERT(uniqueidentifier, MAX(CONVERT(binary(16), relation.EntryGUID)))',
      ),
    );
    expect(sql, isNot(contains('MAX(relation.EntryGUID)')));
    expect(sql, contains('vouchers.Debit'));
    expect(sql, contains('ledger.Credit'));
    expect(sql, contains('__SQL_SYNC_ALAMEEN_BOUNDARY__='));
    expect(sql, contains('COMMIT TRANSACTION;'));
  });

  test('boundary query fails closed when a mapped baseline is missing', () {
    expect(
      () => buildAlameenOperationBoundarySql(
        database: 'AmnDb048_SyncLab',
        tableBaselines: {'bu000': 1},
      ),
      throwsArgumentError,
    );
  });
}
