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

## Reusable identity and relationship findings

These rules were verified by comparing the complete version `5767` output with version `5768`, not inferred from row counts:

| Table | SQL primary identity | Stable correlation observed | Required synchronization interpretation |
|---|---|---|---|
| `bu000` | `GUID` | The same header GUID survived both edits; Sales `Number=110` also remained stable. | Treat as an in-place header update. Do not choose a different client's header merely from timestamp or row hash. |
| `bi000` | `GUID` | `ParentGUID` links to `bu000`; line `Number` remained the line ordinal and `MatGUID` identified the material. | The application replaces the complete 26-line collection. Every prior line GUID was explicitly deleted and every replacement received a new GUID. |
| `ce000` | `GUID` | Voucher business values `Type=1`, `Number=2317` remained stable. Production collision logic must use the complete configured business key, including branch/type context where applicable. | The voucher is delete-and-reinsert, not an in-place update. Preserve both the tombstone and replacement. |
| `en000` | `GUID` | `ParentGUID` links entries to `ce000`; `BiGUID` links item-side entries to the regenerated `bi000` line identities. | All 27 entry GUIDs are replaced together. Apply only after the replacement parent/line mapping is available, inside the same transaction. |
| `er000` | `GUID` | Replacement relation retained `ParentType=2`, `ParentNumber=110`; `EntryGUID`/`ParentGUID` carry physical links. | Relation identity is regenerated with the voucher graph. Do not preserve the stale relation GUID. |
| `pt000` | `GUID` | `RefGUID`/type fields relate the payment term to its regenerated document graph. | Payment/term identity is regenerated and its amount follows the new sale total. |
| `ms000` | `GUID` | All 26 GUIDs remained stable across the two edits; `StoreGUID` and `MatGUID` identify the stock dimension. | These are in-place tracked updates. A price-only save touched all rows even though none of their exported values changed. |
| `mt000` | `GUID` | All 26 GUIDs remained stable; `Number` is the observed material number. | Quantity and material price aggregates are in-place updates. Do not interpret all touched rows as changed business values. |
| `ac000` | `GUID` | The same six account GUIDs and account `Number` values appeared in both edits. | Apply aggregate changes in the same transaction as the sale/voucher rewrite. |
| `mc000` | composite `Type, Number, Item` | Observed key was `24, 100, 0`. All exported business values matched before and after both edits. | A Change Tracking `U` can be a semantic no-op; canonical fingerprints should prevent a false conflict. |

For each of `bi000`, `ce000`, `en000`, `er000`, and `pt000`, every identity inserted at version `5767` was exactly the identity deleted at version `5768`. None of those old identities was reused by the new version `5768` inserts, and no delete/insert pair reused the same primary key. Conversely, all 1 `bu000`, 26 `ms000`, 26 `mt000`, and 6 `ac000` GUIDs were shared between both edit versions. This proves the distinction between application-level collection replacement and ordinary SQL updates.

## Exact monetary audit trail

### Quantity edit, version 5767

| Location | Before | After | Difference |
|---|---:|---:|---:|
| `bi000` line 0 quantity | 1 | 10 | +9 |
| `bi000` line 0 price | 430,000 | 430,000 | 0 |
| `bu000.Total` | 5,756,000 | 9,626,000 | +3,870,000 |
| `ce000` debit and credit, each | 5,756,000 | 9,626,000 | +3,870,000 |
| Sum of 27 `en000` debits, and separately credits | 5,756,000 | 9,626,000 | +3,870,000 |
| `pt000.Credit` | 5,756,000 | 9,626,000 | +3,870,000 |
| `ms000.Qty` for the affected movement | 1 | 10 | +9 |
| `mt000.Qty`, material 207987 | 1 | 10 | +9 |

The six account aggregate changes were:

| `ac000.Number` | Field | Before | After | Difference |
|---:|---|---:|---:|---:|
| 14 | `Credit` | 1,125,570,000 | 1,129,440,000 | +3,870,000 |
| 32 | `Credit` | 1,125,570,000 | 1,129,440,000 | +3,870,000 |
| 6 | `Debit` | 955,142,000 | 959,012,000 | +3,870,000 |
| 15 | `Debit` | 941,432,000 | 945,302,000 | +3,870,000 |
| 5 | `Credit` | 1,382,620,496 | 1,386,490,496 | +3,870,000 |
| 46 | `Credit` | 1,125,570,000 | 1,129,440,000 | +3,870,000 |
| 46 | `UseFlag` | 39,367 | 39,368 | +1 |

Arithmetic checks: `10 - 1 = 9`; `9 * 430,000 = 3,870,000`; `5,756,000 + 3,870,000 = 9,626,000`. All checks match the database exactly.

### Price edit, version 5768

| Location | Before | After | Difference |
|---|---:|---:|---:|
| `bi000` line 1 quantity | 1 | 1 | 0 |
| `bi000` line 1 price | 312,000 | 3,120,100 | +2,808,100 |
| `bu000.Total` | 9,626,000 | 12,434,100 | +2,808,100 |
| `ce000` debit and credit, each | 9,626,000 | 12,434,100 | +2,808,100 |
| `en000` line 2 debit | 312,000 | 3,120,100 | +2,808,100 |
| `en000` line 27 credit | 9,626,000 | 12,434,100 | +2,808,100 |
| `pt000.Credit` | 9,626,000 | 12,434,100 | +2,808,100 |
| `mt000.MaxPrice`, material 198293 | 312,000 | 3,120,100 | +2,808,100 |
| `mt000.AvgPrice`, material 198293 | 312,000 | 3,120,100 | +2,808,100 |
| `mt000.LastPrice`, material 198293 | 312,000 | 3,120,100 | +2,808,100 |

The six account aggregate changes were:

| `ac000.Number` | Field | Before | After | Difference |
|---:|---|---:|---:|---:|
| 14 | `Credit` | 1,129,440,000 | 1,132,248,100 | +2,808,100 |
| 32 | `Credit` | 1,129,440,000 | 1,132,248,100 | +2,808,100 |
| 6 | `Debit` | 959,012,000 | 961,820,100 | +2,808,100 |
| 15 | `Debit` | 945,302,000 | 948,110,100 | +2,808,100 |
| 5 | `Credit` | 1,386,490,496 | 1,389,298,596 | +2,808,100 |
| 46 | `Credit` | 1,129,440,000 | 1,132,248,100 | +2,808,100 |
| 46 | `UseFlag` | 39,368 | 39,369 | +1 |

Arithmetic checks: `3,120,100 - 312,000 = 2,808,100`; `9,626,000 + 2,808,100 = 12,434,100`. No `ms000.Qty` changed. All checks match the database exactly.

## Cumulative verified state after version 5768

- Sales 110 remains posted, dated 2026-08-25, with 26 lines and total 12,434,100.
- Line 0 has quantity 10 and price 430,000; its linked material number is 207987.
- Line 1 has quantity 1 and price 3,120,100; its linked material number is 198293.
- Voucher type 1 / number 2317 is posted and balanced at debit 12,434,100 and credit 12,434,100.
- The 27 ledger entries sum independently to debit 12,434,100 and credit 12,434,100.
- Sales 1615 is a separate controlled record created at version 5755 and must not be confused with these edits to Sales 110.
- `5768` is the only valid next delta baseline for subsequent observations in this sequence.

## Evidence confidence and retention

The values above are a sanitized durable fact record derived from SHA-256-verified, version-bounded exports and comparisons against the restored pre-input backup or the immediately preceding complete delta. GUIDs, names, free-text notes, credentials, and customer-identifying values are intentionally excluded because they are database-instance-specific or sensitive and are not needed to reproduce the synchronization rules. Table roles are marked as observed interpretations because SyrianSoft vendor documentation for this schema was not available. Exact operations, keys, numeric values, version boundaries, hashes, and arithmetic checks are direct database evidence.

## Existing-sale line removal (`SYS_CHANGE_VERSION = 5769..5770`)

The user next removed one item from the same posted Sales number 110. Unlike the quantity and price edits, Al-Ameen committed this logical action across **two database Change Tracking versions**.

- Delta boundary: baseline `5768`, upper version `5770`.
- Artifact: 17,512 compressed bytes, 224 net Change Tracking operations, SHA-256 `051297320e3f4adf1f6d7251d2a6e6deef52c39b2db1c0b6c32288dab48d2823`.
- Removed row: prior `bi000` line number 5, quantity 1, price 158,000, linked material number 197190.
- Final line count: 25, down from 26. Prior line numbers 0 through 4 remained unchanged; the 20 retained items previously numbered 6 through 25 were renumbered to 5 through 24. Their quantities, prices, discounts, and extras did not change.
- `bu000.Total` changed from 12,434,100 to 12,276,100, exactly -158,000.
- Voucher type 1 / number 2317 remained posted and balanced; debit and credit each changed from 12,434,100 to 12,276,100.
- Ledger entry count changed from 27 to 26. The removed line's linked old ledger entry was number 6 with debit 158,000 and credit 0. Final ledger sums remained balanced at debit 12,276,100 and credit 12,276,100.
- `pt000.Credit` changed from 12,434,100 to 12,276,100.
- The affected `ms000.Qty` changed from 1 to 0 at version 5769.
- Material `mt000` number 197190 changed quantity from 1 to 0 and changed `LastPrice` from 158,000 to 198,000 at version 5769. The latter is an observed Al-Ameen recalculation; the experiment does not prove which historical price source supplied 198,000.
- The custom row `mc000` with composite key `Type=24, Number=100, Item=0` was tracked as updated at version 5770, but its compared exported business values remained unchanged.

### Exact version and operation manifest

| Version | Table | Operation | Count | Interpretation |
|---:|---|---|---:|---|
| 5769 | `bi000` | delete | 26 | Deletes all 26 line identities that existed at version 5768. |
| 5769 | `ce000` | delete | 1 | Deletes the version-5768 voucher identity. |
| 5769 | `en000` | delete | 27 | Deletes all version-5768 ledger identities. |
| 5769 | `er000` | delete | 1 | Deletes the version-5768 document relation identity. |
| 5769 | `pt000` | delete | 1 | Deletes the version-5768 payment/term identity. |
| 5769 | `ms000` | update | 1 | Sets the removed material's movement quantity from 1 to 0. |
| 5769 | `mt000` | update | 1 | Sets material 197190 quantity to 0 and last price to 198,000. |
| 5770 | `bi000` | delete | 25 | Deletes 25 intermediate identities created after the baseline and superseded before export. |
| 5770 | `bi000` | insert | 25 | Inserts the final retained and renumbered line collection. |
| 5770 | `ce000` | delete + insert | 1 + 1 | Replaces an intermediate voucher with the final voucher identity. |
| 5770 | `en000` | delete + insert | 26 + 26 | Replaces the intermediate 26-entry ledger collection with the final collection. |
| 5770 | `er000` | delete + insert | 1 + 1 | Replaces the intermediate relation with the final relation to Sales 110. |
| 5770 | `pt000` | delete + insert | 1 + 1 | Replaces the intermediate payment/term row with the final amount. |
| 5770 | `bu000` | update | 1 | Sets the final header total to 12,276,100. |
| 5770 | `ac000` | update | 6 | Applies the final account aggregate reductions. |
| 5770 | `ms000` | update | 25 | Touches the 25 retained movements; their compared quantity/book values did not change. |
| 5770 | `mt000` | update | 25 | Touches the 25 retained materials; their compared quantity/price values did not change. |
| 5770 | `mc000` | update | 1 | Semantic no-op in the exported business values. |

Change Tracking returns the latest net operation for each primary key since the supplied baseline. The version-5770 deletes for 25 previously unseen line identities prove those identities existed after baseline 5768 and were removed by 5770; their creation at version 5769 is therefore a SQL Change Tracking inference rather than a row image retained in the final bounded export. No final version-5770 insert reused an old or intermediate GUID.

### Exact account aggregate reductions

| `ac000.Number` | Field | Before | After | Difference |
|---:|---|---:|---:|---:|
| 14 | `Credit` | 1,132,248,100 | 1,132,090,100 | -158,000 |
| 32 | `Credit` | 1,132,248,100 | 1,132,090,100 | -158,000 |
| 6 | `Debit` | 961,820,100 | 961,662,100 | -158,000 |
| 15 | `Debit` | 948,110,100 | 947,952,100 | -158,000 |
| 15 | `UseFlag` | 27,505 | 27,504 | -1 |
| 5 | `Credit` | 1,389,298,596 | 1,389,140,596 | -158,000 |
| 46 | `Credit` | 1,132,248,100 | 1,132,090,100 | -158,000 |
| 46 | `UseFlag` | 39,369 | 39,370 | +1 |

Arithmetic checks: `1 * 158,000 = 158,000`; `12,434,100 - 158,000 = 12,276,100`. The header, voucher, ledger totals, payment term, and all six monetary account aggregates match that exact reduction.

## Multi-commit logical-operation safety blocker

Versions 5769 and 5770 are separate committed SQL Server transactions for one user-visible Al-Ameen action. A generic Change Tracking reader is allowed to observe 5769 before 5770 exists. The current client can bind an upload to `CHANGE_TRACKING_CURRENT_VERSION()` immediately and has no vendor-provided Al-Ameen marker that says the complete logical save has finished. Therefore it cannot prove that upper version 5769 is a safe cross-table business boundary.

A fixed delay or a moment with no active SQL transaction is not a proof: Al-Ameen may commit version 5769, wait for further UI/application work, and commit version 5770 later. Uploading the first committed phase could temporarily propagate deletion of the prior invoice graph while the old header/account totals remain. A later pass should eventually converge to 5770, but temporary inconsistency is not acceptable as a production safety guarantee for accounting data.

The long-term automatic solution requires one of the following to be proven before enabling this workflow in production:

1. A reliable Al-Ameen completion signal or database state invariant that identifies the final posted document graph; or
2. A business-aware assembler that groups the related `bu000`/`bi000`/`ce000`/`en000`/`er000`/`pt000`/`ms000`/`mt000`/`ac000` changes and validates header total, line total, voucher balance, ledger balance, relation count, and inventory effects before publishing one server batch.

Until that completion rule is implemented and regression-tested, `alshallan2` synchronization must remain disabled for these experiments. This is tracked as INC-403. No production data was synchronized during this observation.

## Cumulative verified state after version 5770

- Sales 110 remains posted, dated 2026-08-25, with 25 lines and total 12,276,100.
- The prior material-197190 line (old line 5, quantity 1, price 158,000) is absent.
- Retained line 0 remains quantity 10 at price 430,000, linked to material 207987.
- Retained line 1 remains quantity 1 at price 3,120,100, linked to material 198293.
- Voucher type 1 / number 2317 remains posted and balanced at 12,276,100 debit and credit.
- The final 26 ledger entries sum independently to 12,276,100 debit and 12,276,100 credit.
- Material 197190 has observed quantity 0 and last price 198,000.
- `5770` is the only valid next bounded-delta baseline for this sequence.

## Next controlled observation

Use `5770` as the next read-only baseline. Further controlled observations may continue while sync stays disabled, but production automatic synchronization is blocked on the multi-commit completion rule above. Do not use a full backup unless Change Tracking reports baseline expiration; expiration must fail closed.
