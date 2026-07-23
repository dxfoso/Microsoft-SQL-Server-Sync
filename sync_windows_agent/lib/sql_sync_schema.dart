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
