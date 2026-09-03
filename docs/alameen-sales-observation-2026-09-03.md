# Al-Ameen 8.1 Sales observation — 2026-09-03

This report records one controlled Sales transaction created manually in the isolated `alshallan2` test database `AmnDb048`. Synchronization remained disabled and no automated Al-Ameen input or database write was performed.

## Evidence boundary

- Before backup: 140,455,424-byte verified `COPY_ONLY` backup, SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`.
- The backup restored into an isolated Docker SQL Server, passed `DBCC CHECKDB`, and recorded Change Tracking version `5754`.
- After observation: read-only Change Tracking delta from `5754` through `5766`, 526 operations, 19,678 compressed bytes, SHA-256 `266d66cdf766b28dfda1e0021535529190842cf27b30e2d199d8b4891e7c1fea`.
- The abandoned full after-backup would have transferred 140,520,960 bytes. The delta was 7,141 times smaller, a 99.985996% reduction.
- Raw row values remain only in the local ignored artifact. This report omits GUIDs, names, notes, credentials, and other personal/business-sensitive values.

## Sales commit (`SYS_CHANGE_VERSION = 5755`)

The sale was one database commit containing 15 row operations across 10 tables:

| Table | Observed role | Exact effect |
|---|---|---|
| `bu000` | Sales header | Inserted posted sale number 1615, date 2026-09-03, total 6,000, no discount, extra, VAT, or excise tax. |
| `bi000` | Sales line | Inserted one line with quantity 1 and price 6,000. |
| `ce000` | Accounting voucher header | Inserted posted voucher number 2321 with balanced debit 6,000 and credit 6,000. |
| `en000` | Voucher entries | Inserted two lines: one debit 6,000 and one credit 6,000. |
| `er000` | Voucher-to-document relation | Inserted a relation back to Sales number 1615. |
| `ms000` | Store/material movement | Inserted quantity -1. |
| `mt000` | Material balance | Updated material number 2 quantity from 0 to -1. |
| `ac000` | Account aggregates | Updated five account rows. Account numbers 4, 12, and 28 gained debit 6,000; account numbers 7 and 19 gained credit 6,000. Two aggregate-use counters also advanced. |
| `cp000` | Customer/material price relation | Inserted the observed price 6,000 for the sale line. |
| `pt000` | Payment/term entry | Inserted a receivable-side debit of 6,000 due on 2026-09-03. |

The table roles above are evidence-based interpretations from column names and cross-row linkage, not vendor documentation. They should be strengthened by repeating controlled create/edit/delete/refund/payment tests.

## Later non-sale commits

The remaining 511 operations were later Al-Ameen/UI/session activity and must not be attributed to the atomic Sales save:

| Versions | Table | Exact observation |
|---|---|---|
| 5756–5757 | `BPOptions000`, `BPOptionsDetails000` | One options header and 240 details were deleted, then one header and 240 details were inserted. This aligns temporally with the Print dialog but is not yet proven to be printing configuration. |
| 5758–5759 | `op000` | Two option/audit rows were updated. |
| 5760–5761, 5766 | `Connections` | Two session rows were deleted and one was inserted. |
| 5763–5764 | `ma000` | All 12 rows were explicitly deleted and 12 rows inserted with new primary GUIDs. Against the restored baseline, the complete set of non-primary business fields was identical and the row count remained 12. No declared SQL foreign key references `ma000`, although undeclared application references remain possible. |

The `ma000` result explains an equal-row-count/different-hash symptom: Al-Ameen can churn physical GUID identities without changing the table's business configuration. It is not missing-row evidence. Sync must still preserve the explicit Change Tracking `D` and `I` operations unless a verified table-specific business identity is established; it must never infer deletion from snapshots or choose an arbitrary client.

## Next controlled observation

For editing the existing sale, use `5766` as the next read-only baseline. Capture only the next bounded delta, then separate the edit's single commit from later UI/session commits by `SYS_CHANGE_VERSION`. Do not run a new full backup unless Change Tracking reports that the baseline expired; expiration must fail closed.
