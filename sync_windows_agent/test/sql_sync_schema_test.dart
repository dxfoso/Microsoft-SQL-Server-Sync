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
}
