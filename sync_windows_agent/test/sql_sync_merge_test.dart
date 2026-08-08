import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_sync_merge.dart';
import 'package:sync_windows_agent/sql_sync_schema.dart';

void main() {
  test(
    'large snapshot staging uses one script with bounded SQL statements',
    () {
      const columns = [
        SqlSyncColumnDefinition(
          name: 'Id',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ];
      final rows = List<Map<String, dynamic>>.generate(
        2501,
        (index) => {'Id': index + 1},
      );

      final sql = buildTargetSnapshotStageLoadSql(
        stageTableName: 'sqlsync_items_stage',
        columns: columns,
        rows: rows,
      );

      expect(targetSnapshotInsertRowsPerStatement, 1000);
      expect(RegExp(r'CREATE TABLE').allMatches(sql), hasLength(1));
      expect(RegExp(r'INSERT INTO').allMatches(sql), hasLength(3));
      expect(RegExp(r'^GO$', multiLine: true).allMatches(sql), hasLength(3));
      expect(RegExp(r"CAST\(N'2501' AS int\)").allMatches(sql), hasLength(1));
    },
  );

  test('large snapshot staging separates SQL Server batches in one script', () {
    const columns = [
      SqlSyncColumnDefinition(
        name: 'Id',
        sqlType: 'int',
        maxLength: 4,
        precision: 10,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ];
    final sql = buildTargetSnapshotStageLoadSql(
      stageTableName: 'sqlsync_memory_bounded_stage',
      columns: columns,
      rows: List<Map<String, dynamic>>.generate(
        2501,
        (index) => {'Id': index + 1},
      ),
    );

    // Setup plus three INSERT statements are four independent SQL Server
    // compilation batches, while sqlcmd still reads one input script.
    expect(RegExp(r'^GO$', multiLine: true).allMatches(sql), hasLength(3));
    expect(RegExp(r'INSERT INTO').allMatches(sql), hasLength(3));
  });

  test('complete snapshot verification defers only protected hot rows', () {
    expect(
      unexpectedCompleteSnapshotMismatchCount(
        unappliedRowCount: 1,
        protectedUpsertRowCount: 1,
      ),
      0,
    );
    expect(
      unexpectedCompleteSnapshotMismatchCount(
        unappliedRowCount: 2,
        protectedUpsertRowCount: 1,
      ),
      1,
    );
    expect(
      unexpectedCompleteSnapshotMismatchCount(
        unappliedRowCount: 1,
        protectedUpsertRowCount: 0,
      ),
      1,
    );
  });

  test('complete snapshot apply never deletes target-only rows', () {
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
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'mt000',
      stageTableName: '#stage_mt000',
      columns: columns,
      primaryKeyColumns: const ['Id'],
    );

    expect(sql, contains('UPDATE target'));
    expect(sql, contains('INSERT INTO [db].[dbo].[mt000] ([Id], [Name])'));
    expect(sql, contains('WHERE NOT EXISTS ('));
    expect(sql, isNot(contains('DELETE target')));
    expect(sql, isNot(contains('DELETE TOP')));
  });

  test('complete reconciliation has no table-wide replacement path', () {
    final columns = [
      const SqlSyncColumnDefinition(
        name: 'GUID',
        sqlType: 'uniqueidentifier',
        maxLength: 16,
        precision: 0,
        scale: 0,
        isIdentity: false,
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
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'ma000',
      stageTableName: '#stage_ma000',
      columns: columns,
      primaryKeyColumns: const ['GUID'],
    );

    final begin = sql.indexOf('BEGIN TRANSACTION;');
    final update = sql.indexOf('UPDATE target');
    final insert = sql.indexOf('INSERT INTO [db].[dbo].[ma000]');
    final commit = sql.indexOf('COMMIT TRANSACTION;');
    expect(update, greaterThan(begin));
    expect(insert, greaterThan(update));
    expect(commit, greaterThan(insert));
    expect(sql, isNot(contains('DELETE FROM [db].[dbo].[ma000];')));
    expect(sql, contains('ROLLBACK TRANSACTION'));
  });

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

    final clause = matchClauseForColumns(const ['Code'], columns);

    expect(clause, contains('target.[Code] COLLATE DATABASE_DEFAULT'));
    expect(
      clause,
      contains('source.[Code] COLLATE DATABASE_DEFAULT IS NOT NULL'),
    );
    expect(
      clause,
      contains(
        'target.[Code] COLLATE DATABASE_DEFAULT = source.[Code] COLLATE DATABASE_DEFAULT',
      ),
    );
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
    );

    expect(sql, isNot(contains('DELETE TOP (500) target')));
  });

  test(
    'staged delta protects only incoming keys changed locally after upload',
    () {
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
        deltaDeleteRows: const [
          {'Id': 9},
        ],
        protectLocalChangesAfterVersion: 42,
      );

      expect(sql, contains('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;'));
      expect(sql, contains('CREATE TABLE #sqlsync_incoming_keys'));
      expect(
        sql,
        contains(
          'LEFT JOIN [db].[dbo].[items] AS target WITH (UPDLOCK, HOLDLOCK)',
        ),
      );
      expect(
        sql,
        contains('CHANGETABLE(CHANGES [db].[dbo].[items], 42) AS ct'),
      );
      expect(sql, contains('ct.SYS_CHANGE_CONTEXT <> 0x53514C53594E43'));
      expect(
        sql,
        contains('DELETE source\n  FROM tempdb.dbo.[#stage_items] AS source'),
      );
      expect(sql, contains('INNER JOIN #sqlsync_protected_keys AS target'));
      expect(sql, contains('__SQL_SYNC_PROTECTED__='));
      expect(sql, contains('__SQL_SYNC_PROTECTED_UPSERTS__='));
      expect(sql, contains('__SQL_SYNC_PROTECTED_DELETES__='));
    },
  );

  test('post-upload protection collates every text key join', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'Connections',
      stageTableName: '#stage_connections',
      columns: const [
        SqlSyncColumnDefinition(
          name: 'Code',
          sqlType: 'nvarchar',
          maxLength: 40,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['Code'],
      protectLocalChangesAfterVersion: 42,
    );

    expect(
      sql,
      contains(
        'target.[Code] COLLATE DATABASE_DEFAULT = '
        'incoming.[Code] COLLATE DATABASE_DEFAULT',
      ),
    );
    expect(
      sql,
      contains(
        'ct.[Code] COLLATE DATABASE_DEFAULT = '
        'incoming.[Code] COLLATE DATABASE_DEFAULT',
      ),
    );
    expect(
      sql,
      contains(
        'protected.[Code] COLLATE DATABASE_DEFAULT = '
        'source.[Code] COLLATE DATABASE_DEFAULT',
      ),
    );
  });

  test('complete snapshot never deletes a conflicting old identity', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'ce000',
      stageTableName: '#stage_ce000',
      columns: const [
        SqlSyncColumnDefinition(
          name: 'GUID',
          sqlType: 'uniqueidentifier',
          maxLength: 16,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'Type',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'Number',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'Branch',
          sqlType: 'uniqueidentifier',
          maxLength: 16,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['GUID'],
      uniqueIndexColumnSets: const [
        ['Type', 'Number', 'Branch'],
      ],
    );

    expect(sql, contains('INSERT INTO [db].[dbo].[ce000]'));
    expect(sql, isNot(contains('DELETE target')));
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
      manageTriggers: false,
    );

    expect(sql, isNot(contains('DISABLE TRIGGER')));
    expect(sql, isNot(contains('ENABLE TRIGGER')));
    expect(sql, isNot(contains('BEGIN TRY\n  \n  END TRY')));
  });

  test('complete snapshot preserves rows missing from its stage', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'any_database',
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
      ],
      primaryKeyColumns: const ['Id'],
    );

    expect(sql, contains('INSERT INTO [any_database].[dbo].[items]'));
    expect(sql, isNot(contains('DELETE target')));
    expect(sql, isNot(contains('TABLOCKX')));
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
        insertOnly: false,
        manageTriggers: false,
      );

      expect(sql, contains('UPDATE target'));
      expect(sql, contains('WITH CHANGE_TRACKING_CONTEXT (0x53514C53594E43)'));
      expect(sql, isNot(contains('DELETE TOP')));
      expect(sql, isNot(contains('DISABLE TRIGGER')));
      expect(sql, contains('INSERT INTO [db].[dbo].[items]'));
      expect(sql, contains('WHERE NOT EXISTS ('));
      expect(sql, isNot(contains('target.[Id] = source.[Id]\n  OR')));
      expect(
        sql,
        contains('ON source.[Id] IS NOT NULL AND target.[Id] = source.[Id];'),
      );
      expect(sql, isNot(contains('OR source.[TenantId] IS NOT NULL')));
      expect(sql, contains('__SQL_SYNC_INSERTED__='));
    },
  );

  test('delta tombstone deletes only explicit primary keys', () {
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
      deltaDeleteRows: const [
        {'Id': 7},
        {'Id': 9},
      ],
    );

    expect(sql, contains('CREATE TABLE #delta_delete_rows'));
    expect(sql, contains('DELETE target'));
    expect(sql, contains('WITH CHANGE_TRACKING_CONTEXT (0x53514C53594E43)'));
    expect(sql, contains('INNER JOIN #delta_delete_rows AS source'));
    expect(sql, contains('target.[Id] = source.[Id]'));
    expect(
      sql,
      contains('ALTER TABLE [db].[dbo].[items] DISABLE TRIGGER ALL;'),
    );
    expect(sql, contains('ALTER TABLE [db].[dbo].[items] ENABLE TRIGGER ALL;'));
    expect(sql, contains('RAISERROR(@SqlSyncStageErrorMessage, 16, 1)'));
    expect(sql, isNot(contains('DELETE TOP')));
  });

  test(
    'non insert-only staged apply updates only by permanent primary key',
    () {
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
        insertOnly: false,
      );

      expect(sql, contains('UPDATE target'));
      expect(sql, isNot(contains('DELETE TOP')));
      expect(sql, isNot(contains('DELETE target')));
    },
  );

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
    final latestByKey = <String, Map<String, dynamic>>{};
    final first = coalesceSqlSyncDeltaRows(
      rows: [
        {
          'Id': 7,
          'Name': 'newer',
          '__sync_modified_at_utc': '2026-07-14T10:00:00Z',
        },
      ],
      primaryKeyColumns: const ['Id'],
      latestRowByKey: latestByKey,
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
      latestRowByKey: latestByKey,
    );

    expect(first.single['Name'], 'newer');
    expect(stale, isEmpty);
  });

  test('different GUIDs are never coalesced by an alternate business key', () {
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
    );

    expect(rows, hasLength(2));
    expect(rows.map((row) => row['Id']), ['c1-id', 'c2-id']);
  });

  test('invoice rows with different GUIDs remain independent', () {
    final rows = coalesceSqlSyncDeltaRows(
      rows: const [
        {
          'GUID': 'old-guid',
          '__sync_op': 'D',
          '__sync_modified_at_utc': '2026-07-24T18:31:00Z',
        },
        {
          'GUID': 'c1-guid',
          'ParentGUID': 'invoice-guid',
          'Number': 0,
          'Quantity': 123,
          '__sync_modified_at_utc': '2026-07-24T18:31:06.543Z',
          '__sync_origin_client': 'c1',
        },
        {
          'GUID': 'c2-guid',
          'ParentGUID': 'invoice-guid',
          'Number': 0,
          'Quantity': 234,
          '__sync_modified_at_utc': '2026-07-24T18:31:27.920Z',
          '__sync_origin_client': 'c2',
        },
      ],
      primaryKeyColumns: const ['GUID'],
    );

    expect(rows, hasLength(3));
    expect(rows.first['__sync_op'], 'D');
    expect(rows.map((row) => row['GUID']), ['old-guid', 'c1-guid', 'c2-guid']);
  });

  test('invoice replacement explicit delete and insert are atomic', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'db',
      schema: 'dbo',
      table: 'bi000',
      stageTableName: '#stage_bi000',
      columns: const [
        SqlSyncColumnDefinition(
          name: 'GUID',
          sqlType: 'uniqueidentifier',
          maxLength: 16,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'ParentGUID',
          sqlType: 'uniqueidentifier',
          maxLength: 16,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'Number',
          sqlType: 'int',
          maxLength: 4,
          precision: 10,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
        SqlSyncColumnDefinition(
          name: 'Quantity',
          sqlType: 'decimal',
          maxLength: 9,
          precision: 18,
          scale: 2,
          isIdentity: false,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['GUID'],
      deltaDeleteRows: const [
        {'GUID': '3F781CBB-66A5-461A-A92C-8F5EBF77968B'},
      ],
    );

    final begin = sql.indexOf('BEGIN TRANSACTION;');
    final explicitDelete = sql.indexOf('CREATE TABLE #delta_delete_rows');
    final update = sql.lastIndexOf('UPDATE target');
    final commit = sql.indexOf('COMMIT TRANSACTION;');
    expect(begin, greaterThanOrEqualTo(0));
    expect(explicitDelete, greaterThan(begin));
    expect(update, greaterThan(explicitDelete));
    expect(commit, greaterThan(update));
    expect(sql, contains('DELETE target'));
    expect(sql, isNot(contains('candidate.source_primary_key')));
  });

  test('different GUIDs remain independent across streamed pages', () {
    final latestByKey = <String, Map<String, dynamic>>{};
    final newest = coalesceSqlSyncDeltaRows(
      rows: [
        {
          'Id': 'c2-id',
          'Code': 'shared',
          '__sync_modified_at_utc': '2026-07-15T10:01:00Z',
        },
      ],
      primaryKeyColumns: const ['Id'],
      latestRowByKey: latestByKey,
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
      latestRowByKey: latestByKey,
    );

    expect(newest, hasLength(1));
    expect(stale, hasLength(1));
    expect(stale.single['Id'], 'c1-id');
  });

  test(
    'latest delta metadata uses timestamp then deterministic tie breakers',
    () {
      final latest = latestSqlSyncDeltaRow([
        {
          '__sync_modified_at_utc': '2026-07-24T18:31:06.543Z',
          '__sync_change_version': '50',
          '__sync_origin_client': 'c1',
          '__sync_operation_id': 'a',
        },
        {
          '__sync_modified_at_utc': '2026-07-24T18:31:27.920Z',
          '__sync_change_version': '36',
          '__sync_origin_client': 'c2',
          '__sync_operation_id': 'b',
        },
      ]);

      expect(latest?['__sync_origin_client'], 'c2');
      expect(latest?['__sync_modified_at_utc'], '2026-07-24T18:31:27.920Z');
    },
  );

  test(
    'server receipt order resolves equal cross-client database timestamps',
    () {
      final latest = latestSqlSyncDeltaRow([
        {
          'Id': 'same-row',
          '__sync_modified_at_utc': '2026-07-25T00:00:00.000Z',
          '__sync_change_version': '9999',
          '__sync_origin_client': 'c1',
          '__sync_server_received_at_utc': '2026-07-25T00:00:01.000Z',
          '__sync_server_sequence': '1',
          '__sync_operation_id': 'a',
        },
        {
          'Id': 'same-row',
          '__sync_modified_at_utc': '2026-07-25T00:00:00.000Z',
          '__sync_change_version': '1',
          '__sync_origin_client': 'c2',
          '__sync_server_received_at_utc': '2026-07-25T00:00:02.000Z',
          '__sync_server_sequence': '2',
          '__sync_operation_id': 'b',
        },
      ]);

      expect(latest?['__sync_origin_client'], 'c2');
    },
  );

  test(
    'latest change wins across different primary keys sharing a unique key',
    () {
      final rows = coalesceSqlSyncDeltaRows(
        rows: [
          {
            'Id': 'older-id',
            'Code': 'shared-code',
            '__sync_modified_at_utc': '2026-08-04T01:00:00Z',
            '__sync_operation_id': 'a',
          },
          {
            'Id': 'newer-id',
            'Code': 'shared-code',
            '__sync_modified_at_utc': '2026-08-04T02:00:00Z',
            '__sync_operation_id': 'b',
          },
        ],
        primaryKeyColumns: const ['Id'],
        uniqueKeyColumnSets: const [
          ['Code'],
        ],
      );

      expect(rows, hasLength(1));
      expect(rows.single['Id'], 'newer-id');
    },
  );

  test('latest unique-key replacement is atomic and narrowly scoped', () {
    final sql = buildTargetSnapshotStageApplySql(
      database: 'Db',
      schema: 'dbo',
      table: 'Rows',
      stageTableName: '#stage_rows',
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
          name: 'Code',
          sqlType: 'nvarchar',
          maxLength: 100,
          precision: 0,
          scale: 0,
          isIdentity: false,
          isComputed: false,
        ),
      ],
      primaryKeyColumns: const ['Id'],
      uniqueIndexColumnSets: const [
        ['Code'],
      ],
      protectLocalChangesAfterVersion: 10,
      resolveUniqueConflictsLatestWins: true,
    );

    expect(sql, contains('BEGIN TRANSACTION;'));
    expect(sql, contains('WITH CHANGE_TRACKING_CONTEXT (0x53514C53594E43)'));
    expect(sql, contains('DELETE target'));
    expect(sql, contains('WHERE NOT ('));
    expect(sql, contains('post-upload user change'));
    expect(sql, isNot(contains('DELETE FROM [Db].[dbo].[Rows];')));
  });
}
