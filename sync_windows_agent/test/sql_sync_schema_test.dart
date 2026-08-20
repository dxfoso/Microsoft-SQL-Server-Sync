import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/sql_sync_schema.dart';

void main() {
  test('computed and rowversion columns are not writable sync columns', () {
    final assessment = assessSqlSyncColumns([
      const SqlSyncColumnDefinition(
        name: 'ComputedName',
        sqlType: 'nvarchar',
        maxLength: 40,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: true,
      ),
      const SqlSyncColumnDefinition(
        name: 'Version',
        sqlType: 'rowversion',
        maxLength: 8,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ]);

    expect(assessment.hasColumns, isTrue);
    expect(assessment.hasUnsupportedColumns, isFalse);
    expect(assessment.hasWritableColumns, isFalse);
  });

  test('unsupported sql types are surfaced explicitly', () {
    final assessment = assessSqlSyncColumns([
      const SqlSyncColumnDefinition(
        name: 'Shape',
        sqlType: 'geography',
        maxLength: 0,
        precision: 0,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ]);

    expect(assessment.hasUnsupportedColumns, isTrue);
    expect(assessment.unsupportedColumns.single.name, 'Shape');
    expect(assessment.hasWritableColumns, isFalse);
  });

  test('identity columns remain writable for snapshot merge paths', () {
    final assessment = assessSqlSyncColumns([
      const SqlSyncColumnDefinition(
        name: 'Id',
        sqlType: 'int',
        maxLength: 4,
        precision: 10,
        scale: 0,
        isIdentity: true,
        isComputed: false,
      ),
    ]);

    expect(assessment.hasUnsupportedColumns, isFalse);
    expect(assessment.hasWritableColumns, isTrue);
    expect(assessment.writableColumns.single.isIdentity, isTrue);
  });

  test('ac000 volatile aggregate columns remain local', () {
    SqlSyncColumnDefinition column(String name) => SqlSyncColumnDefinition(
      name: name,
      sqlType: 'float',
      maxLength: 8,
      precision: 53,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    );

    final filtered = filterApplicationMaintainedSyncColumns(
      table: 'dbo.AC000',
      columns: [
        column('GUID'),
        column('Name'),
        column('Debit'),
        column('Credit'),
        column('UseFlag'),
        column('InitDebit'),
        column('InitCredit'),
      ],
    );

    expect(filtered.map((item) => item.name), [
      'GUID',
      'Name',
      'InitDebit',
      'InitCredit',
    ]);
  });

  test('application-maintained filter does not change other tables', () {
    final columns = [
      const SqlSyncColumnDefinition(
        name: 'Debit',
        sqlType: 'float',
        maxLength: 8,
        precision: 53,
        scale: 0,
        isIdentity: false,
        isComputed: false,
      ),
    ];

    expect(
      filterApplicationMaintainedSyncColumns(
        table: 'dbo.en000',
        columns: columns,
      ),
      equals(columns),
    );
  });

  test('three clients keep ac000 aggregate caches local', () {
    SqlSyncColumnDefinition column(String name) => SqlSyncColumnDefinition(
      name: name,
      sqlType: name == 'Name' ? 'nvarchar' : 'float',
      maxLength: name == 'Name' ? 100 : 8,
      precision: name == 'Name' ? 0 : 53,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    );

    final synchronizedNames = filterApplicationMaintainedSyncColumns(
      table: 'ac000',
      columns: [
        column('GUID'),
        column('Name'),
        column('Debit'),
        column('Credit'),
        column('UseFlag'),
        column('InitDebit'),
      ],
    ).map((item) => item.name).toList(growable: false);

    Map<String, Object> projection(Map<String, Object> row) => {
      for (final name in synchronizedNames) name: row[name]!,
    };

    final velvet = {
      'GUID': 'account-121006',
      'Name': 'shared account',
      'Debit': 3373000,
      'Credit': 19000,
      'UseFlag': 55,
      'InitDebit': 0,
    };
    final alshallan = {...velvet, 'Debit': 2044000, 'UseFlag': 49};
    final offlinePeer = {...velvet, 'Debit': 0, 'Credit': 0, 'UseFlag': 0};

    expect(projection(velvet), projection(alshallan));
    expect(projection(alshallan), projection(offlinePeer));
    expect(
      synchronizedNames,
      isNot(containsAll(['Debit', 'Credit', 'UseFlag'])),
    );
  });

  test('text and XML columns use code-page-independent hex transport', () {
    SqlSyncColumnDefinition column(String sqlType) => SqlSyncColumnDefinition(
      name: 'Value',
      sqlType: sqlType,
      maxLength: -1,
      precision: 0,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    );

    for (final sqlType in [
      'char',
      'varchar',
      'nchar',
      'nvarchar',
      'sysname',
      'xml',
    ]) {
      expect(column(sqlType).usesHexTextTransport, isTrue);
    }
    expect(column('int').usesHexTextTransport, isFalse);
  });

  test('float and real transport uses lossless style 3 conversion', () {
    SqlSyncColumnDefinition column(String sqlType) => SqlSyncColumnDefinition(
      name: 'Qty',
      sqlType: sqlType,
      maxLength: 8,
      precision: sqlType == 'real' ? 24 : 53,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    );

    for (final sqlType in ['float', 'real']) {
      expect(
        buildSqlSyncTransportValueExpression(
          column: column(sqlType),
          columnReference: '[Qty]',
        ),
        'CONVERT(nvarchar(100), [Qty], 3)',
      );
    }
  });

  test('exact SQL types retain their type-specific transport formats', () {
    SqlSyncColumnDefinition column(String sqlType) => SqlSyncColumnDefinition(
      name: 'Value',
      sqlType: sqlType,
      maxLength: 16,
      precision: 18,
      scale: 4,
      isIdentity: false,
      isComputed: false,
    );

    expect(
      buildSqlSyncTransportValueExpression(
        column: column('decimal'),
        columnReference: '[Value]',
      ),
      'CONVERT(nvarchar(max), [Value])',
    );
    expect(
      buildSqlSyncTransportValueExpression(
        column: column('money'),
        columnReference: '[Value]',
      ),
      'CONVERT(nvarchar(100), [Value], 2)',
    );
    expect(
      buildSqlSyncTransportValueExpression(
        column: column('datetime2'),
        columnReference: '[Value]',
      ),
      'CONVERT(nvarchar(33), [Value], 126)',
    );
  });
}
