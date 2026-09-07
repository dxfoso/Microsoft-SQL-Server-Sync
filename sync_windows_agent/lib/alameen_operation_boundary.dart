import 'sql_sync_merge.dart';

const alameenOperationLocalTables = <String>{
  'ac000',
  'bi000',
  'bu000',
  'ce000',
  'en000',
  'er000',
  'ms000',
  'mt000',
  'pt000',
};

class AlameenOperationBoundaryResult {
  const AlameenOperationBoundaryResult({
    required this.changeTrackingVersion,
    required this.candidateDocumentCount,
    required this.violationCount,
  });

  final int changeTrackingVersion;
  final int candidateDocumentCount;
  final int violationCount;

  bool get isComplete => violationCount == 0;
}

AlameenOperationBoundaryResult? parseAlameenOperationBoundaryResult(
  String output,
) {
  final match = RegExp(
    r'__SQL_SYNC_ALAMEEN_BOUNDARY__=(\d+)\|(\d+)\|(\d+)',
  ).firstMatch(output);
  if (match == null) return null;
  return AlameenOperationBoundaryResult(
    changeTrackingVersion: int.parse(match.group(1)!),
    candidateDocumentCount: int.parse(match.group(2)!),
    violationCount: int.parse(match.group(3)!),
  );
}

String buildAlameenOperationBoundarySql({
  required String database,
  required Map<String, int> tableBaselines,
}) {
  final missing = alameenOperationLocalTables
      .where((table) => !tableBaselines.containsKey(table))
      .toList(growable: false);
  if (missing.isNotEmpty) {
    throw ArgumentError(
      'Al-Ameen operation boundary is missing baselines for: ${missing.join(', ')}',
    );
  }
  final db = quoteIdentifier(database);
  int baseline(String table) => tableBaselines[table]!;
  return '''
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRANSACTION;
DECLARE @UpperVersion BIGINT = CHANGE_TRACKING_CURRENT_VERSION();
CREATE TABLE #CandidateDocuments (GUID UNIQUEIDENTIFIER NOT NULL PRIMARY KEY);

INSERT INTO #CandidateDocuments (GUID)
SELECT DISTINCT candidate.GUID
FROM (
  SELECT header.GUID
  FROM CHANGETABLE(CHANGES $db.[dbo].[bu000], ${baseline('bu000')}) AS changes
  INNER JOIN $db.[dbo].[bu000] AS header ON header.GUID = changes.GUID
  WHERE changes.SYS_CHANGE_VERSION <= @UpperVersion
  UNION ALL
  SELECT line.ParentGUID
  FROM CHANGETABLE(CHANGES $db.[dbo].[bi000], ${baseline('bi000')}) AS changes
  INNER JOIN $db.[dbo].[bi000] AS line ON line.GUID = changes.GUID
  WHERE changes.SYS_CHANGE_VERSION <= @UpperVersion AND line.ParentGUID IS NOT NULL
  UNION ALL
  SELECT relation.ParentGUID
  FROM CHANGETABLE(CHANGES $db.[dbo].[er000], ${baseline('er000')}) AS changes
  INNER JOIN $db.[dbo].[er000] AS relation ON relation.GUID = changes.GUID
  WHERE changes.SYS_CHANGE_VERSION <= @UpperVersion AND relation.ParentGUID IS NOT NULL
  UNION ALL
  SELECT payment.RefGUID
  FROM CHANGETABLE(CHANGES $db.[dbo].[pt000], ${baseline('pt000')}) AS changes
  INNER JOIN $db.[dbo].[pt000] AS payment ON payment.GUID = changes.GUID
  WHERE changes.SYS_CHANGE_VERSION <= @UpperVersion AND payment.RefGUID IS NOT NULL
) AS candidate
WHERE candidate.GUID IS NOT NULL;

DECLARE @CandidateCount INT = (SELECT COUNT(*) FROM #CandidateDocuments);
DECLARE @ViolationCount INT = 0;
SELECT @ViolationCount = COUNT(*)
FROM #CandidateDocuments AS candidate
LEFT JOIN $db.[dbo].[bu000] AS header ON header.GUID = candidate.GUID
OUTER APPLY (
  SELECT COUNT_BIG(*) AS LineCount,
         SUM(CONVERT(decimal(38,6), line.Qty) * CONVERT(decimal(38,6), line.Price)) AS LineTotal
  FROM $db.[dbo].[bi000] AS line
  WHERE line.ParentGUID = candidate.GUID
) AS lines
OUTER APPLY (
  SELECT COUNT_BIG(*) AS RelationCount, MAX(relation.EntryGUID) AS EntryGUID
  FROM $db.[dbo].[er000] AS relation
  WHERE relation.ParentGUID = candidate.GUID
) AS relations
OUTER APPLY (
  SELECT COUNT_BIG(*) AS VoucherCount,
         SUM(CONVERT(decimal(38,6), voucher.Debit)) AS Debit,
         SUM(CONVERT(decimal(38,6), voucher.Credit)) AS Credit
  FROM $db.[dbo].[ce000] AS voucher
  WHERE voucher.GUID = relations.EntryGUID
) AS vouchers
OUTER APPLY (
  SELECT COUNT_BIG(*) AS LedgerCount,
         SUM(CONVERT(decimal(38,6), ledger.Debit)) AS Debit,
         SUM(CONVERT(decimal(38,6), ledger.Credit)) AS Credit
  FROM $db.[dbo].[en000] AS ledger
  WHERE ledger.ParentGUID = relations.EntryGUID
) AS ledger
WHERE header.GUID IS NULL
   OR ISNULL(lines.LineCount, 0) = 0
   OR ABS(CONVERT(decimal(38,6), header.Total) - ISNULL(lines.LineTotal, 0)) > 0.01
   OR ISNULL(relations.RelationCount, 0) <> 1
   OR ISNULL(vouchers.VoucherCount, 0) <> 1
   OR ABS(ISNULL(vouchers.Debit, 0) - ISNULL(vouchers.Credit, 0)) > 0.01
   OR ISNULL(ledger.LedgerCount, 0) = 0
   OR ABS(ISNULL(ledger.Debit, 0) - ISNULL(vouchers.Debit, 0)) > 0.01
   OR ABS(ISNULL(ledger.Credit, 0) - ISNULL(vouchers.Credit, 0)) > 0.01;

SELECT N'__SQL_SYNC_ALAMEEN_BOUNDARY__=' + CONVERT(nvarchar(30), @UpperVersion)
  + N'|' + CONVERT(nvarchar(30), @CandidateCount)
  + N'|' + CONVERT(nvarchar(30), @ViolationCount);
COMMIT TRANSACTION;
''';
}
