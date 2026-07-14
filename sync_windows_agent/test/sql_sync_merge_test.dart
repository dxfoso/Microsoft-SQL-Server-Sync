import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_sync_merge.dart';
import 'package:sync_windows_agent/sql_sync_schema.dart';

void main() {
  test(
    'large snapshot apply uses segmented update and insert batches with batched delete',
    () {
      final columns = [
        const SqlSyncColumnDefinition(
          name: 'Id',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: true,
          isComputed: false,
        ),
        const SqlSyncColumnDefinition(
          name: 'Name',
          sqlType: 'nvarchar',
          maxLength: 100,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ];
      final rows = List<Map<String, dynamic>>.generate(
        1200,
        (index) => {'Id': index + 1, 'Name': 'Row $index'},
        growable: false,
      );

      final sql = buildTargetSnapshotMergeSql(
        database: 'db',
        schema: 'dbo',
        table: 'mt000',
        columns: columns,
        primaryKeyColumns: const ['Id'],
        matchColumnSets: const [
          ['Id'],
        ],
        rows: rows,
      );

      expect('UPDATE target'.allMatches(sql).length, greaterThan(1));
      expect(
        'INSERT INTO [db].[dbo].[mt000] ([Id], [Name])'.allMatches(sql).length,
        greaterThan(1),
      );
      expect(sql, contains('WHERE __row_num BETWEEN 1 AND 500'));
      expect(sql, contains('WHERE __row_num BETWEEN 501 AND 1000'));
      expect(
        sql,
        contains(
          'CREATE UNIQUE CLUSTERED INDEX IX_source_rows_row_num ON #source_rows (__row_num);',
        ),
      );
      expect(
        sql,
        contains('CREATE INDEX IX_source_rows_match_1 ON #source_rows ([Id]);'),
      );
      expect(sql, contains('DELETE TOP (500) target'));
      expect(sql, contains('WHERE NOT EXISTS ('));
      expect(sql, isNot(contains('MERGE [db].[dbo].[mt000] AS target')));
      expect(
        sql,
        isNot(contains('WHEN NOT MATCHED BY SOURCE THEN\n  DELETE;')),
      );
    },
  );

  test('text match columns keep database collation handling', () {
    final columns = [
      const SqlSyncColumnDefinition(
        name: 'Code',
        sqlType: 'nvarchar',
        maxLength: 40,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ];

    final clause = matchClauseForColumnSets(const [
      ['Code'],
    ], columns);

    expect(clause, contains('target.[Code] COLLATE DATABASE_DEFAULT'));
    expect(clause, contains('source.[Code] IS NOT NULL'));
  });

  test('staged delta apply does not delete rows absent from delta', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'items',
      stageTableName: '#stage_items',
      columns: const [
        SqlSyncColumnDefinition(
          name: 'Id',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: true,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['Id'],
      matchColumnSets: const [
        ['Id'],
      ],
      deleteMissing: false,
    );

    expect(sql, isNot(contains('DELETE TOP (500) target')));
  });

  test('staged delta apply does not toggle triggers', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'items',
      stageTableName: '#stage_items',
      columns: const [
        SqlSyncColumnDefinition(
          name: 'Id',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: true,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['Id'],
      matchColumnSets: const [
        ['Id'],
      ],
      deleteMissing: false,
      manageTriggers: false,
    );

    expect(sql, isNot(contains('DISABLE TRIGGER')));
    expect(sql, isNot(contains('ENABLE TRIGGER')));
  });
}
