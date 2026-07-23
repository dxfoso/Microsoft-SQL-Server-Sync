import 'sql_sync_merge.dart';

class AutomaticChangeProbe {
  const AutomaticChangeProbe({
    required this.table,
    required this.currentVersion,
    required this.minValidVersion,
    required this.status,
  });

  final String table;
  final int? currentVersion;
  final int? minValidVersion;
  final String status;

  bool get hasChanges => status == 'changed';
  bool get canAdvanceBaseline => status == 'baseline' || status == 'unchanged';
  bool get baselineExpired => status == 'expired';
}

String _quoteIdentifier(String value) => '[${value.replaceAll(']', ']]')}]';

String _escapeSqlLiteral(String value) => value.replaceAll("'", "''");

({String schema, String table}) _splitTableName(String value) {
  final trimmed = value.trim();
  final separator = trimmed.indexOf('.');
  if (separator < 0) {
    return (schema: 'dbo', table: trimmed);
  }
  return (
    schema: trimmed.substring(0, separator).trim(),
    table: trimmed.substring(separator + 1).trim(),
  );
}

/// Builds one bounded SQL batch that detects real Change Tracking activity for
/// every known table. A missing cursor establishes a baseline; it never treats
/// pre-existing rows as a new change.
String buildAutomaticChangeDiscoveryQuery({
  required String database,
  required Map<String, int?> tableBaselines,
}) {
  final requested = tableBaselines.entries
      .where((entry) => entry.key.trim().isNotEmpty)
      .map((entry) {
        final parts = _splitTableName(entry.key);
        final baseline =
            entry.value == null
                ? 'NULL'
                : entry.value!.clamp(0, 9223372036854775807);
        return "(N'${_escapeSqlLiteral(parts.schema)}', "
            "N'${_escapeSqlLiteral(parts.table)}', "
            "N'${_escapeSqlLiteral(entry.key.trim())}', $baseline)";
      })
      .join(',\n');
  if (requested.isEmpty) {
    return 'SET NOCOUNT ON;';
  }

  return '''
SET NOCOUNT ON;
USE ${_quoteIdentifier(database)};
CREATE TABLE #requested (
  schema_name sysname NOT NULL,
  table_name sysname NOT NULL,
  display_name nvarchar(512) NOT NULL,
  baseline_version bigint NULL
);
INSERT INTO #requested(schema_name, table_name, display_name, baseline_version)
VALUES
$requested;

CREATE TABLE #results (
  display_name nvarchar(512) NOT NULL,
  current_version bigint NULL,
  min_valid_version bigint NULL,
  probe_status nvarchar(32) NOT NULL
);

DECLARE
  @schema sysname,
  @table sysname,
  @display nvarchar(512),
  @baseline bigint,
  @object_id int,
  @current bigint,
  @minimum bigint,
  @has_changes bit,
  @sql nvarchar(max);

DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT r.schema_name, r.table_name, r.display_name, r.baseline_version
FROM #requested AS r
ORDER BY r.display_name;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @schema, @table, @display, @baseline;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @object_id = OBJECT_ID(QUOTENAME(@schema) + N'.' + QUOTENAME(@table), N'U');
  SET @current = CHANGE_TRACKING_CURRENT_VERSION();
  SET @minimum = CASE WHEN @object_id IS NULL
    THEN NULL
    ELSE CHANGE_TRACKING_MIN_VALID_VERSION(@object_id)
  END;

  IF @object_id IS NULL
    INSERT #results VALUES (@display, @current, @minimum, N'missing');
  ELSE IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = @object_id AND is_primary_key = 1
  )
    INSERT #results VALUES (@display, @current, @minimum, N'no_primary_key');
  ELSE IF NOT EXISTS (
    SELECT 1 FROM sys.change_tracking_tables WHERE object_id = @object_id
  )
    INSERT #results VALUES (@display, @current, @minimum, N'not_tracked');
  ELSE IF @baseline IS NULL
    INSERT #results VALUES (@display, @current, @minimum, N'baseline');
  ELSE IF @minimum IS NULL OR @baseline < @minimum
    INSERT #results VALUES (@display, @current, @minimum, N'expired');
  ELSE
  BEGIN
    SET @has_changes = 0;
    SET @sql =
      N'IF EXISTS (SELECT TOP (1) 1 FROM CHANGETABLE(CHANGES ' +
      QUOTENAME(@schema) + N'.' + QUOTENAME(@table) +
      N', @cursor_version) AS ct WHERE ct.SYS_CHANGE_CONTEXT IS NULL ' +
      N'OR ct.SYS_CHANGE_CONTEXT <> $sqlSyncChangeTrackingContextHex) ' +
      N'SET @found = 1;';
    EXEC sys.sp_executesql
      @sql,
      N'@cursor_version bigint, @found bit OUTPUT',
      @cursor_version = @baseline,
      @found = @has_changes OUTPUT;
    INSERT #results VALUES (
      @display,
      @current,
      @minimum,
      CASE WHEN @has_changes = 1 THEN N'changed' ELSE N'unchanged' END
    );
  END;

  FETCH NEXT FROM table_cursor INTO @schema, @table, @display, @baseline;
END;
CLOSE table_cursor;
DEALLOCATE table_cursor;

SELECT
  N'auto_change',
  display_name,
  COALESCE(CONVERT(nvarchar(40), current_version), N''),
  COALESCE(CONVERT(nvarchar(40), min_valid_version), N''),
  probe_status
FROM #results
ORDER BY display_name;
''';
}

List<AutomaticChangeProbe> parseAutomaticChangeDiscoveryOutput(
  Iterable<List<String>> rows,
) {
  final probes = <AutomaticChangeProbe>[];
  for (final values in rows) {
    if (values.length < 5 || values.first != 'auto_change') {
      continue;
    }
    probes.add(
      AutomaticChangeProbe(
        table: values[1].trim(),
        currentVersion: int.tryParse(values[2]),
        minValidVersion: int.tryParse(values[3]),
        status: values[4].trim().toLowerCase(),
      ),
    );
  }
  return probes;
}
