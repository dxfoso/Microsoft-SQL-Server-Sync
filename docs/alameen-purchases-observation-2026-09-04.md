# Al-Ameen 8.1 Purchase observation — 2026-09-04

This report is the durable sanitized evidence record for the first controlled Purchase experiment in the isolated `alshallan2` test database `AmnDb048`. The user entered the Purchase manually. Synchronization remained disabled, and the collection process performed only a version-bounded read.

## Evidence boundary

- Prior sealed state: Change Tracking version `5782`, documented by the Sales boundary experiment.
- Captured upper version: `5793`.
- Artifact: 25,406 compressed bytes, 772 net Change Tracking operations, SHA-256 `e8edb4764ae35142d8efcea8b73b8a008edea4ac368cf36d961bdf193517a26e`.
- The Purchase itself is exactly version `5793`: 23 operations across 9 tables.
- The other 749 net operations are earlier Al-Ameen option/session/`ma000` maintenance and are excluded from the Purchase.
- Raw GUIDs, supplier/customer names, notes, credentials, and other instance-specific sensitive values remain excluded. Numeric keys, relationships, exact values, versions, and hashes needed for sync engineering are retained here.

## Document type proof

The `bu000.TypeGUID` resolves to `bt000` type 1. Its configuration row contains:

| `bt000` field | Value |
|---|---:|
| `Type` | 1 |
| `BillGroup` | 0 |
| `BillType` | 0 |
| `Name` / `LatinName` | Purchases / Purchase |
| `bIsInput` | 1 |
| `bIsOutput` | 0 |
| `bAffectCostPrice` | 1 |
| `bAffectLastPrice` | 1 |
| `bAffectCustPrice` | 0 |
| `bAutoEntry` | 1 |
| `bAutoEntryPost` | 1 |
| `bAutoPost` | 1 |
| `bPayTerms` | 0 |

This is direct database evidence that Purchase versus Sales semantics are defined by the `bu000.TypeGUID -> bt000.GUID` relationship. `bu000.Number`, `ce000.Type/Number`, or `er000.ParentType` alone must not be used to identify the business document kind.

## Purchase commit (`SYS_CHANGE_VERSION = 5793`)

- Header: posted Purchase number 111, date 2026-09-04, total 194,000.
- Header discount, extra, item discount, bonus discount, first payment, and VAT are all zero.
- Voucher: posted type 1 / number 2323, debit 194,000 and credit 194,000.
- Relation: `er000.ParentType=2`, `ParentNumber=111`.
- Payment term: debit 0, credit 194,000, currency value 1, due 2026-09-04.

### Exact lines, ledger, and inventory

| Line | Material | Quantity | `bi000.Price` | Discount | Extra | `bi000.PurchaseVal` | Ledger | `ms000.Qty` | `mt000.Qty` after | New max/average/last price |
|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| 0 | 12666 | 1 | 24,000 | 0 | 0 | 0 | debit 24,000 | +1 | 1 | 24,000 |
| 1 | 20960 | 1 | 144,000 | 0 | 0 | 0 | debit 144,000 | +1 | 1 | 144,000 |
| 2 | 2374 | 1 | 26,000 | 0 | 0 | 0 | debit 26,000 | +1 | 1 | 26,000 |

The fourth ledger entry is the balancing supplier credit of 194,000. The restored version-5754 database proves all three materials previously had quantity, maximum price, average price, and last price equal to zero. No controlled operation between versions 5754 and 5793 touched these material GUIDs, so the before/after comparison is exact.

Unlike a Sales creation, this Purchase created no `cp000` customer/material-price rows. The line purchase amount is carried in `bi000.Price`; `bi000.PurchaseVal` remained zero for all three lines.

### Exact operation manifest

| Table | Operation | Count | Verified role and effect |
|---|---|---:|---|
| `bu000` | insert | 1 | Posted Purchase 111 header, selected as Purchase through `TypeGUID -> bt000`. |
| `bi000` | insert | 3 | Three Purchase lines listed above. |
| `ce000` | insert | 1 | Balanced posted voucher 2323. |
| `en000` | insert | 4 | Three material debits and one supplier credit. |
| `er000` | insert | 1 | Voucher/document relation to Purchase 111. |
| `ms000` | insert | 3 | Three inbound warehouse movements of +1. |
| `mt000` | update | 3 | Quantity 0 to 1 and max/average/last price 0 to Purchase price for each material. |
| `ac000` | update | 6 | Two account hierarchies received replicated 194,000 debit or credit aggregates; two use counters advanced. |
| `pt000` | insert | 1 | Supplier-side credit/payment-term amount of 194,000. |

All 23 rows carry the same Change Tracking version 5793, proving this creation committed in one SQL Server transaction.

## Accounting relationship proof

The four `en000` entries link through `AccountGUID` as follows:

| Ledger number | Debit | Credit | Leaf `ac000.Number` |
|---:|---:|---:|---:|
| 1 | 24,000 | 0 | 15 |
| 2 | 144,000 | 0 | 15 |
| 3 | 26,000 | 0 | 15 |
| 4 | 0 | 194,000 | 110 |

The Purchase header's `CustAccGUID` matches account 110, proving that this header field is the supplier account reference in the observed Purchase configuration. The changed account hierarchy is:

- Debit leaf 15 rolls up to account 6.
- Supplier credit leaf 110 rolls up through accounts 26, 11, and 4.

### Exact account changes

| `ac000.Number` | Field | Before | After | Difference |
|---:|---|---:|---:|---:|
| 15 | `Debit` | 947,952,100 | 948,146,100 | +194,000 |
| 6 | `Debit` | 961,662,100 | 961,856,100 | +194,000 |
| 110 | `Credit` | 0 | 194,000 | +194,000 |
| 26 | `Credit` | 40,022,500 | 40,216,500 | +194,000 |
| 11 | `Credit` | 37,968,000 | 38,162,000 | +194,000 |
| 4 | `Credit` | 1,744,248,000 | 1,744,442,000 | +194,000 |
| 15 | `UseFlag` | 27,504 | 27,508 | +4 |
| 110 | `UseFlag` | 1 | 6 | +5 |

Arithmetic checks: `24,000 + 144,000 + 26,000 = 194,000`. Header total, voucher debit, voucher credit, ledger debit sum, ledger credit sum, payment-term credit, and every monetary account aggregate change equal 194,000.

## Maintenance operations excluded from the Purchase

The 749 non-Purchase net operations occurred before version 5793:

| Versions | Net operations and interpretation |
|---|---|
| 5783, 5791–5792 | `BPOptions000` and 240 `BPOptionsDetails000` identities were replaced through the already observed options/printing maintenance pattern. Net Change Tracking retains one earlier deleted generation, one later deleted intermediate generation, and the final inserted generation. |
| 5785, 5790 | One `Connections` identity deleted and one inserted. |
| 5787–5788 | All 12 `ma000` identities deleted and reinserted, matching the previously documented Al-Ameen identity-churn pattern. |

They must not be attributed to the Purchase or used to infer missing business records.

## Reusable Purchase synchronization rules established

1. Resolve the document type through `bu000.TypeGUID -> bt000.GUID`; numeric document and voucher numbers overlap across business modules.
2. A Purchase increases warehouse movement and material quantity, whereas the observed Sales creation decreased both.
3. Purchase line `Price`, not `PurchaseVal`, carried the entered amount in this configuration.
4. Material `MaxPrice`, `AvgPrice`, and `LastPrice` were all recalculated to the Purchase price because the selected `bt000` type enables cost-price and last-price effects.
5. `en000` material debits point to account 15, and the supplier credit points to the header's account 110.
6. `pt000` is credit-sided for this Purchase, opposite the debit-sided term observed for the controlled Sales creation.
7. A complete Purchase graph must reconcile header total, line arithmetic, voucher balance, ledger balance, supplier term, inbound movements, material balances/prices, relation, and both account hierarchies before publication.
8. These rules are proven only for the observed zero-tax, zero-discount, zero-extra, quantity-1 posted Purchase type. Unknown configurations must fail closed until separately observed.

## Current checkpoint and next observation

The next bounded-delta baseline is `5793`. To expand Purchase behavior safely, edit Purchase 111 by changing only line 0 material 12666 quantity from 1 to 2, complete the save/warehouse confirmation, make no other change, and capture from baseline 5793. Synchronization must remain disabled.
