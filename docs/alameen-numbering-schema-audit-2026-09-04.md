# Al-Ameen numbering schema audit (2026-09-04)

## Safety boundary

This was a read-only catalog inspection of the checksum-verified pre-input backup restored into disposable Docker container `sql-sync-copy-20260904200405-ywxzagfsbgfumg` as database `LiveCopy_ywxzagfsbgfumg_AmnDb048`. `DBCC CHECKDB` passed. No active client database was queried or changed.

## Proven indexes

| Table | Primary key | Number-related SQL unique key | Consequence |
|---|---|---|---|
| `ce000` | `GUID` | `Type, Number, Branch` | The existing voucher allocator has a database-proven collision key and scope. |
| `bu000` | `GUID` | `TypeGUID, Number, Branch` | Sales/Purchase headers have a database-proven collision key; the two-copy observation now proves that independent copies allocate the same number to distinct GUIDs. |
| `mt000` | `GUID` | None | `Number` has a non-unique index, but the 2026-09-07 two-copy application observation proves it is an independently allocated visible business number that collides across offline copies. |
| `MatExBarcode000` | `Guid` | `Barcode, MatGuid` | This does not establish uniqueness for `mt000.Number`. |

The restored data currently contains zero duplicate `mt000.Number` values and zero duplicate `bu000(TypeGUID, Number, Branch)` values. Absence of existing duplicates is not proof that changing a material number is safe.

## Cross-table implications

`er000` stores both `ParentGUID` and `ParentNumber`. The controlled Sales and Purchase captures prove that `ParentNumber` mirrors `bu000.Number`. The isolated two-copy experiment on 2026-09-06 then produced distinct Sales GUIDs with the same `bu000.Number=1614`, distinct voucher GUIDs with the same `ce000.Number=2320`, and `er000.ParentNumber=1614` on both copies. The complete evidence is in `docs/alameen-two-client-number-collision-observation-2026-09-06.md`.

Header-only renumbering would still be unsafe. The implemented graph rule preserves the permanent `bu000.GUID`, reserves the next free number within `TypeGUID, Branch`, and rewrites every existing `er000.ParentNumber` selected by `ParentGUID` in the same SQL transaction and `SQLSYNC` Change Tracking context. Applying an `er000` job also derives the redundant value from the current `bu000` parent before merge, so job order or retry cannot revert the reservation.

The controlled 2026-09-07 material experiment produced two different material GUIDs with the same application-assigned `Number=209812`. Material dependents observed in the complete mapped workflows (`bi000`, `ms000`, `cp000`, and `MatExBarcode000`) link through the material GUID. A second disposable-backup catalog scan found zero SQL foreign keys to `mt000`, 119 material-named columns of which 91 are GUIDs, and zero material-number-named columns. The validated rule can therefore renumber only `mt000.Number` while retaining the permanent GUID and its mapped children. This remains scoped evidence, not a mapping of every optional module among all 563 tables. Exact rows and artifacts are recorded in `docs/alameen-two-client-material-number-collision-observation-2026-09-07.md`.

## Fail-closed decision

1. Keep the existing `ce000` automatic voucher-number rule.
2. Enroll `bu000` in automatic number reservation only with the atomic `er000.ParentNumber` rewrite and relation-side derivation guarded by the three-client regression.
3. Enroll `mt000` in owner-wide automatic number reservation using `Number` as its observed application business key, an empty/global table scope, permanent GUID preservation, and no child-number rewrite.
4. Keep production Sales/Purchase synchronization disabled until the separate INC-403 complete-document boundary is proven. A timing delay, upload order, or arbitrary authoritative client is not a safe substitute.

## Completed external evidence

The same two isolated database copies independently assigned number `209812` to GUIDs `B3B00555-B6F1-4484-B53B-098BD31F58E2` and `B657F231-CBBC-4F38-A125-C4B4FB81879C`. Synchronization was stopped before the generic pre-fix merge could place duplicate visible numbers in one database. The bounded deltas and disposable dependency scan now supply the evidence required for the scoped `mt000` allocator. Purchase collision handling shares the proven `bu000`/`er000` structure, while general production activation still awaits the separate complete-document boundary.

## Implementation feasibility review (2026-09-05)

The retained bounded delta proves the final Sales state across versions 5769 and 5770, but SQL Server Change Tracking does not retain the intermediate row images that existed after version 5769. Consequently, the final-state evidence cannot prove a validator that always rejects phase one of the multi-commit save. Implementing such a validator now would encode an assumption about accounting data.

The official SyrianSoft public site was checked for an Al-Ameen 8.1 database transaction marker, schema contract, synchronization interface, or numbering API. Its public product, download, contact, and technical-support entry points do not publish that contract. Vendor support may still provide private documentation, but none is available in this repository or on the public vendor site.

The same-number Sales experiment proves the `bu000`/`ce000` collision plus the `er000` rewrite set. The same-number material experiment now also proves the `mt000` collision and its GUID-preserving owner-wide allocation scope. Neither experiment supplies the missing intermediate row images for the earlier two-commit Sales edit, so general production Sales/Purchase synchronization remains disabled until that completion invariant is proven.
