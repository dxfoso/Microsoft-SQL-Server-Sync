import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_bulk_stage.dart';
import 'package:sync_windows_agent/sql_sync_schema.dart';

void main() {
  const columns = <SqlSyncColumnDefinition>[
    SqlSyncColumnDefinition(
      name: 'Id',
      sqlType: 'int',
      maxLength: 4,
      precision: 10,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    ),
    SqlSyncColumnDefinition(
      name: 'ArabicName',
      sqlType: 'nvarchar',
      maxLength: 200,
      precision: 0,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    ),
    SqlSyncColumnDefinition(
      name: 'ComputedValue',
      sqlType: 'int',
      maxLength: 4,
      precision: 10,
      scale: 0,
      isIdentity: false,
      isComputed: true,
    ),
  ];

  test('bulk request preserves column order and excludes computed columns', () {
    final request = buildSqlBulkStageRequest(
      server: r'.\SQLEXPRESS',
      database: 'AmnDb048',
      useWindowsAuth: true,
      user: 'ignored',
      password: 'ignored',
      destinationTable: r'[tempdb].[dbo].[sqlsync_stage_1]',
      columns: columns,
      rows: const <Map<String, dynamic>>[
        <String, dynamic>{
          'Id': '7',
          'ArabicName': 'مرحبا',
          'ComputedValue': '99',
        },
      ],
    );

    expect(request['user'], isEmpty);
    expect(request['password'], isEmpty);
    expect(request['commitBatchRows'], targetSnapshotBulkCommitRows);
    expect(request['columns'], <Map<String, dynamic>>[
      <String, dynamic>{'name': 'Id', 'sqlType': 'int'},
      <String, dynamic>{'name': 'ArabicName', 'sqlType': 'nvarchar'},
    ]);
    expect(request['rows'], <List<dynamic>>[
      <dynamic>['7', 'مرحبا'],
    ]);
    expect(jsonEncode(request), contains('مرحبا'));
  });

  test('bulk completion marker is strict and bounded', () {
    expect(parseSqlBulkCopiedRowCount('__SQL_SYNC_BULK_ROWS__=5000'), 5000);
    expect(parseSqlBulkCopiedRowCount('copied 5000'), isNull);
  });
}
