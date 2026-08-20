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
