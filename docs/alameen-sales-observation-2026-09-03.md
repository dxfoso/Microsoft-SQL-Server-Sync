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

## Existing-sale quantity edit (`SYS_CHANGE_VERSION = 5767`)

The user reported changing one value from quantity 1 to quantity 10 in the last sale shown by Al-Ameen. The bounded read-only delta proves that the edited database object was posted Sales number **110**, dated 2026-08-25, rather than the newly created Sales number 1615 described above.

- Delta boundary: baseline `5766`, upper version `5767`; every operation belongs to the single version `5767`.
- Artifact: 15,792 compressed bytes, 172 operations, SHA-256 `ca1d9088f10ce1dbf9b19b344438ef710fb3df71cd006b1fbc4c9bce620bfbd8`.
- Exact user-visible change: `bi000` line number 0 changed quantity from 1 to 10. Its unit price remained 430,000.
- Sales total: `bu000.Total` changed from 5,756,000 to 9,626,000, an exact increase of 3,870,000 (`9 * 430,000`).
- The posted voucher retained business key type 1 / number 2317 and changed from balanced debit/credit 5,756,000 to balanced debit/credit 9,626,000.
- The 27 ledger entries remained balanced: aggregate debit and credit each changed from 5,756,000 to 9,626,000.
- The payment/term row changed its credit from 5,756,000 to 9,626,000.
- The matching `ms000` quantity and material `mt000` number 207987 quantity each changed from 1 to 10.
- Six `ac000` account aggregates each moved by exactly 3,870,000 on the applicable debit or credit side. One use counter also advanced by one.

Al-Ameen implemented this one-field edit as a wider atomic object rewrite:

| Table | Change Tracking operations | Verified meaning |
|---|---:|---|
| `bu000` | 1 update | Same Sales header identity; total increased by 3,870,000. |
| `bi000` | 26 deletes + 26 inserts | All 26 line GUIDs were regenerated; only line 0's business quantity changed. |
| `ce000` | 1 delete + 1 insert | Voucher GUID regenerated; business voucher number stayed 2317 and balanced amount increased. |
| `en000` | 27 deletes + 27 inserts | All ledger-line GUIDs regenerated; total debit and credit stayed balanced. |
| `er000` | 1 delete + 1 insert | Voucher-to-Sales relation regenerated and still points to Sales number 110. |
| `pt000` | 1 delete + 1 insert | Payment/term identity regenerated and amount increased. |
| `ms000` | 26 updates | All sale movement rows were touched; only one observed quantity value changed. |
| `mt000` | 26 updates | All related material rows were touched; only material 207987's observed quantity changed. |
| `ac000` | 6 updates | Six account aggregates changed by the exact sale-total difference. |
| `mc000` | 1 update | Tracked as updated, but all exported business values matched the restored baseline. |

This is a long-term synchronization requirement, not evidence of 172 independent user edits. Version `5767` must be transported and applied as one atomic ordered unit. The explicit deletes must be preserved as tombstones, the inserts must retain their new primary identities, and retries must be idempotent. The existing sync architecture's atomic transaction, explicit-delete, primary-key-change, relational-integrity, and interrupted-retry regression gates are designed for this pattern; snapshot absence must never be used to simplify it.

## Existing-sale price edit (`SYS_CHANGE_VERSION = 5768`)

The user next reported changing the price of another item in the same sale. The bounded delta from `5767` proves that Al-Ameen saved the following exact values on posted Sales number 110:

- Delta boundary: baseline `5767`, upper version `5768`; every operation belongs to the single version `5768`.
- Artifact: 15,889 compressed bytes, 172 operations, SHA-256 `1f3b1b39be3dc9fc79f73c764093943114b7c950a9f3fc7e39eb56ae695c96db`.
- `bi000` line number 1 retained quantity 1 and changed price from 312,000 to **3,120,100**.
- The exact difference is 2,808,100. `bu000.Total` changed from 9,626,000 to 12,434,100 by that same amount.
- Voucher type 1 / number 2317 remained balanced; its debit and credit each changed from 9,626,000 to 12,434,100.
- Two of the 27 regenerated ledger entries carried the monetary effect: one debit changed from 312,000 to 3,120,100, and the balancing credit changed from 9,626,000 to 12,434,100.
- The payment/term credit changed from 9,626,000 to 12,434,100.
- Six account aggregates moved by exactly 2,808,100 on their applicable debit or credit side, and one use counter advanced by one.
- No `ms000` quantity value changed. Material `mt000` number 198293 retained its quantity but changed `MaxPrice`, `AvgPrice`, and `LastPrice` from 312,000 to 3,120,100.

As with the quantity edit, Al-Ameen represented this single visible field edit as 172 Change Tracking operations across the same 10 tables: 26 Sales lines, 27 ledger lines, and the voucher, relation, and payment identities were deleted and recreated with new GUIDs; the header, movements, materials, accounts, and one custom-field row were tracked as updates. Only the price and its mathematically corresponding totals and aggregates changed in the compared business values. The entire version must therefore remain atomic and idempotent during synchronization.

## Next controlled observation

Use `5768` as the next read-only baseline. A controlled delete, refund, payment, or a second-client concurrent edit can now be captured with another bounded delta. Do not run a new full backup unless Change Tracking reports that this baseline expired; expiration must fail closed.
