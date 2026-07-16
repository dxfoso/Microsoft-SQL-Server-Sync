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
    expect(sql, isNot(contains('BEGIN TRY\n  \n  END TRY')));
  });

  test(
    'staged delta apply updates existing rows without deleting absent rows',
    () {
      final sql = buildTargetSnapshotStageApplySql(
        database: 'db',
        schema: 'dbo',
        table: 'items',
        stageTableName: '#stage_items',
        columns: const [
          SqlSyncColumnDefinition(
            name: 'Id',
            sqlType: 'uniqueidentifier',
            maxLength: 16,
            precision: 0,
            scale: 0,
            isIdentity: false,
            isComputed: false,
          ),
          SqlSyncColumnDefinition(
            name: 'TenantId',
            sqlType: 'uniqueidentifier',
            maxLength: 16,
            precision: 0,
            scale: 0,
            isIdentity: false,
            isComputed: false,
          ),
          SqlSyncColumnDefinition(
            name: 'Code',
            sqlType: 'nvarchar',
            maxLength: 40,
            precision: 0,
            scale: 0,
            isIdentity: false,
            isComputed: false,
          ),
          SqlSyncColumnDefinition(
            name: 'Value',
            sqlType: 'nvarchar',
            maxLength: 100,
            precision: 0,
            scale: 0,
            isIdentity: false,
            isComputed: false,
          ),
        ],
        primaryKeyColumns: const ['Id'],
        matchColumnSets: const [
          ['Id'],
          ['TenantId', 'Code'],
        ],
        insertOnly: false,
        deleteMissing: false,
        manageTriggers: false,
      );

      expect(sql, contains('UPDATE target'));
      expect(sql, contains('WITH CHANGE_TRACKING_CONTEXT (0x53514C53594E43)'));
      expect(sql, isNot(contains('DELETE TOP')));
      expect(sql, isNot(contains('DISABLE TRIGGER')));
      expect(sql, contains('INSERT INTO [db].[dbo].[items]'));
      expect(sql, contains('WHERE NOT EXISTS ('));
      expect(sql, contains('target.[Id] = source.[Id]'));
      expect(sql, contains('target.[TenantId] = source.[TenantId]'));
      expect(sql, contains('target.[Code] COLLATE DATABASE_DEFAULT'));
      expect(sql, contains('__SQL_SYNC_INSERTED__='));
    },
  );

  test('delta delete removes only explicit primary keys', () {
    final sql = buildTargetDeltaDeleteSql(
      database: 'db',
      schema: 'dbo',
      table: 'items',
      columns: const [
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
          name: 'Value',
          sqlType: 'nvarchar',
          maxLength: 100,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['Id'],
      rows: const [
        {'Id': 7},
        {'Id': 9},
      ],
    );

    expect(sql, contains('CREATE TABLE #delete_rows'));
    expect(sql, contains('DELETE target'));
    expect(sql, contains('WITH CHANGE_TRACKING_CONTEXT (0x53514C53594E43)'));
    expect(sql, contains('INNER JOIN #delete_rows AS source'));
    expect(sql, contains('target.[Id] = source.[Id]'));
    expect(sql, contains('__SQL_SYNC_DELETED__='));
    expect(sql, contains('RAISERROR(@SqlSyncDeleteErrorMessage, 16, 1)'));
    expect(sql, isNot(contains('THROW;')));
    expect(sql, isNot(contains('[Value]')));
    expect(sql, isNot(contains('WHERE NOT EXISTS')));
  });

  test('non insert-only staged apply retains legacy update capability', () {
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
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'Value',
          sqlType: 'nvarchar',
          maxLength: 100,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['Id'],
      matchColumnSets: const [
        ['Id'],
      ],
      insertOnly: false,
    );

    expect(sql, contains('UPDATE target'));
    expect(sql, contains('DELETE TOP'));
  });

  test('delta rows keep the last value for duplicate primary keys', () {
    final rows = coalesceSqlSyncDeltaRows(
      rows: [
        {'Id': 7, 'Name': 'first'},
        {'Id': 8, 'Name': 'other'},
        {'Id': 7, 'Name': 'last'},
      ],
      primaryKeyColumns: const ['Id'],
    );

    expect(rows, [
      {'Id': 7, 'Name': 'last'},
      {'Id': 8, 'Name': 'other'},
    ]);
  });

  test('delta rows prefer the newest database commit timestamp', () {
    final latestByKey = <String, DateTime?>{};
    final first = coalesceSqlSyncDeltaRows(
      rows: [
        {
          'Id': 7,
          'Name': 'newer',
          '__sync_modified_at_utc': '2026-07-14T10:00:00Z',
        },
      ],
      primaryKeyColumns: const ['Id'],
      latestModifiedAtByKey: latestByKey,
    );
    final stale = coalesceSqlSyncDeltaRows(
      rows: [
        {
          'Id': 7,
          'Name': 'stale',
          '__sync_modified_at_utc': '2026-07-14T09:00:00Z',
        },
      ],
      primaryKeyColumns: const ['Id'],
      latestModifiedAtByKey: latestByKey,
    );

    expect(first.single['Name'], 'newer');
    expect(stale, isEmpty);
  });

  test(
    'delta rows coalesce different primary keys by alternate unique key',
    () {
      final rows = coalesceSqlSyncDeltaRows(
        rows: [
          {
            'Id': 'c1-id',
            'Tenant': 'tenant-1',
            'Code': 'shared',
            'Name': 'old',
            '__sync_modified_at_utc': '2026-07-15T10:00:00Z',
          },
          {
            'Id': 'c2-id',
            'Tenant': 'tenant-1',
            'Code': 'shared',
            'Name': 'new',
            '__sync_modified_at_utc': '2026-07-15T10:01:00Z',
          },
        ],
        primaryKeyColumns: const ['Id'],
        matchColumnSets: const [
          ['Id'],
          ['Tenant', 'Code'],
        ],
      );

      expect(rows, hasLength(1));
      expect(rows.single['Id'], 'c2-id');
      expect(rows.single['Name'], 'new');
    },
  );

  test('alternate unique identity protects later pages from stale rows', () {
    final latestByKey = <String, DateTime?>{};
    final newest = coalesceSqlSyncDeltaRows(
      rows: [
        {
          'Id': 'c2-id',
          'Code': 'shared',
          '__sync_modified_at_utc': '2026-07-15T10:01:00Z',
        },
      ],
      primaryKeyColumns: const ['Id'],
      matchColumnSets: const [
        ['Id'],
        ['Code'],
      ],
      latestModifiedAtByKey: latestByKey,
    );
    final stale = coalesceSqlSyncDeltaRows(
      rows: [
        {
          'Id': 'c1-id',
          'Code': 'shared',
          '__sync_modified_at_utc': '2026-07-15T10:00:00Z',
        },
      ],
      primaryKeyColumns: const ['Id'],
      matchColumnSets: const [
        ['Id'],
        ['Code'],
      ],
      latestModifiedAtByKey: latestByKey,
    );

    expect(newest, hasLength(1));
    expect(stale, isEmpty);
  });
}
