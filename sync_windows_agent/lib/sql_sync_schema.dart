class SqlSyncColumnDefinition {
  const SqlSyncColumnDefinition({
    required this.name,
    required this.sqlType,
    required this.maxLength,
    required this.precision,
    required this.scale,
    required this.isIdentity,
    required this.isComputed,
  });

  final String name;
  final String sqlType;
  final int maxLength;
  final int precision;
  final int scale;
  final bool isIdentity;
  final bool isComputed;

  bool get isRowVersion {
    final normalized = sqlType.trim().toLowerCase();
    return normalized == 'rowversion' || normalized == 'timestamp';
  }

  bool get isSupported {
    final normalized = sqlType.trim().toLowerCase();
    if (isComputed || isRowVersion) {
      return true;
    }
    return !const {
      'image',
      'text',
      'ntext',
      'sql_variant',
      'hierarchyid',
      'geometry',
      'geography',
      'cursor',
      'table',
    }.contains(normalized);
  }

  bool get isWritable => !isComputed && !isRowVersion;

  bool get isDateOrTimeType {
    final normalized = sqlType.trim().toLowerCase();
    return normalized == 'date' ||
        normalized == 'datetime' ||
        normalized == 'smalldatetime' ||
        normalized == 'datetime2' ||
        normalized == 'datetimeoffset' ||
        normalized == 'time';
  }

  bool get isTextLike {
    final normalized = sqlType.trim().toLowerCase();
    return normalized == 'char' ||
        normalized == 'nchar' ||
        normalized == 'varchar' ||
        normalized == 'nvarchar' ||
        normalized == 'sysname';
  }

  bool get usesHexTextTransport {
    final normalized = sqlType.trim().toLowerCase();
    return isTextLike || normalized == 'xml';
  }

  String get openJsonType {
    final normalized = sqlType.trim().toLowerCase();
    if (normalized == 'nvarchar' || normalized == 'nchar') {
      if (maxLength < 0) {
        return 'nvarchar(max)';
      }
      return 'nvarchar(${maxLength ~/ 2})';
    }
    if (normalized == 'varchar' || normalized == 'char') {
      if (maxLength < 0) {
        return 'varchar(max)';
      }
      return '$normalized($maxLength)';
    }
    if (normalized == 'varbinary' || normalized == 'binary') {
      if (maxLength < 0) {
        return 'varbinary(max)';
      }
      return '$normalized($maxLength)';
    }
    if (normalized == 'decimal' || normalized == 'numeric') {
      return '$normalized($precision,$scale)';
    }
    if (normalized == 'datetime2' ||
        normalized == 'datetimeoffset' ||
        normalized == 'time') {
      return '$normalized($scale)';
    }
    if (normalized == 'sysname') {
      return 'nvarchar(128)';
    }
    if (normalized == 'xml') {
      return 'nvarchar(max)';
    }
    return normalized;
  }

  String get sqlCastType {
    final normalized = sqlType.trim().toLowerCase();
    if (normalized == 'nvarchar' || normalized == 'nchar') {
      if (maxLength < 0) {
        return 'nvarchar(max)';
      }
      return 'nvarchar(${maxLength ~/ 2})';
    }
    if (normalized == 'varchar' || normalized == 'char') {
      if (maxLength < 0) {
        return 'varchar(max)';
      }
      return '$normalized($maxLength)';
    }
    if (normalized == 'varbinary' || normalized == 'binary') {
      if (maxLength < 0) {
        return 'varbinary(max)';
      }
      return '$normalized($maxLength)';
    }
    if (normalized == 'decimal' || normalized == 'numeric') {
      return '$normalized($precision,$scale)';
    }
    if (normalized == 'float' || normalized == 'real') {
      return normalized;
    }
    if (normalized == 'datetime2' ||
        normalized == 'datetimeoffset' ||
        normalized == 'time') {
      return '$normalized($scale)';
    }
    if (normalized == 'sysname') {
      return 'nvarchar(128)';
    }
    return normalized;
  }
}

String buildSqlSyncTransportValueExpression({
  required SqlSyncColumnDefinition column,
  required String columnReference,
}) {
  final normalized = column.sqlType.trim().toLowerCase();
  if (normalized == 'binary' || normalized == 'varbinary') {
    return 'master.dbo.fn_varbintohexstr(CONVERT(varbinary(max), $columnReference))';
  }
  if (column.usesHexTextTransport) {
    // Keep text output ASCII-only across sqlcmd. Windows console/code-page
    // conversion can otherwise replace Arabic and other Unicode characters
    // before Dart receives the bytes.
    return "N'\\U' + CONVERT(nvarchar(max), CONVERT(varchar(max), CONVERT(varbinary(max), CONVERT(nvarchar(max), $columnReference)), 2))";
  }
  if (normalized == 'date') {
    return 'CONVERT(nvarchar(10), $columnReference, 23)';
  }
  if (normalized == 'datetimeoffset') {
    return 'CONVERT(nvarchar(48), $columnReference, 127)';
  }
  if (normalized == 'datetime' ||
      normalized == 'smalldatetime' ||
      normalized == 'datetime2' ||
      normalized == 'time') {
    return 'CONVERT(nvarchar(33), $columnReference, 126)';
  }
  if (normalized == 'float' || normalized == 'real') {
    // Style 3 emits 17 significant digits and guarantees that distinct SQL
    // floating-point values have distinct text representations. The default
    // style emits at most six digits and turns values such as 9999999 into
    // 1e+007, silently changing the value when the target parses it.
    return 'CONVERT(nvarchar(100), $columnReference, 3)';
  }
  if (normalized == 'money' || normalized == 'smallmoney') {
    return 'CONVERT(nvarchar(100), $columnReference, 2)';
  }
  if (normalized == 'uniqueidentifier') {
    return 'CONVERT(nvarchar(36), $columnReference)';
  }
  return 'CONVERT(nvarchar(max), $columnReference)';
}

class SqlSyncColumnAssessment {
  const SqlSyncColumnAssessment({
    required this.columns,
    required this.unsupportedColumns,
    required this.writableColumns,
  });

  final List<SqlSyncColumnDefinition> columns;
  final List<SqlSyncColumnDefinition> unsupportedColumns;
  final List<SqlSyncColumnDefinition> writableColumns;

  bool get hasColumns => columns.isNotEmpty;
  bool get hasUnsupportedColumns => unsupportedColumns.isNotEmpty;
  bool get hasWritableColumns => writableColumns.isNotEmpty;
}

SqlSyncColumnAssessment assessSqlSyncColumns(
  Iterable<SqlSyncColumnDefinition> columns,
) {
  final materialized = List<SqlSyncColumnDefinition>.from(
    columns,
    growable: false,
  );
  return SqlSyncColumnAssessment(
    columns: materialized,
    unsupportedColumns: materialized
        .where((column) => !column.isSupported)
        .toList(growable: false),
    writableColumns: materialized
        .where((column) => column.isSupported && column.isWritable)
        .toList(growable: false),
  );
}
