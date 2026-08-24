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

  test('float and real transport uses legacy-safe exact IEEE bytes', () {
    SqlSyncColumnDefinition column(String sqlType) => SqlSyncColumnDefinition(
      name: 'Qty',
      sqlType: sqlType,
      maxLength: 8,
      precision: sqlType == 'real' ? 24 : 53,
      scale: 0,
      isIdentity: false,
      isComputed: false,
    );

    expect(
      buildSqlSyncTransportValueExpression(
        column: column('float'),
        columnReference: '[Qty]',
      ),
      r"N'\F' + CONVERT(nvarchar(16), CONVERT(varbinary(8), [Qty]), 2)",
    );
    expect(
      buildSqlSyncTransportValueExpression(
        column: column('real'),
        columnReference: '[Qty]',
      ),
      r"N'\F' + CONVERT(nvarchar(8), CONVERT(varbinary(4), [Qty]), 2)",
    );

    final floatColumn = column('float');
    expect(floatColumn.isFloatingPoint, isTrue);
    expect(column('real').isFloatingPoint, isTrue);
    expect(column('decimal').isFloatingPoint, isFalse);
    final velvet958 = decodeSqlSyncFloatingPointTransport(
      column: floatColumn,
      value: r'\F41717A79A0000000',
    );
    final al958 = decodeSqlSyncFloatingPointTransport(
      column: floatColumn,
      value: r'\F41717A7CC0000000',
    );
    final velvet983 = decodeSqlSyncFloatingPointTransport(
      column: floatColumn,
      value: r'\F416A940420000000',
    );
    final al983 = decodeSqlSyncFloatingPointTransport(
      column: floatColumn,
      value: r'\F416A940100000000',
    );
    expect(velvet958, '18327450.0');
    expect(al958, '18327500.0');
    expect(velvet983, '13934625.0');
    expect(al983, '13934600.0');
    expect(velvet958, isNot(al958));
    expect(velvet983, isNot(al983));
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
