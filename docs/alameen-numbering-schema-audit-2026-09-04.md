# Al-Ameen numbering schema audit (2026-09-04)

## Safety boundary

This was a read-only catalog inspection of the checksum-verified pre-input backup restored into disposable Docker container `sql-sync-copy-20260904200405-ywxzagfsbgfumg` as database `LiveCopy_ywxzagfsbgfumg_AmnDb048`. `DBCC CHECKDB` passed. No active client database was queried or changed.

## Proven indexes

| Table | Primary key | Number-related SQL unique key | Consequence |
|---|---|---|---|
| `ce000` | `GUID` | `Type, Number, Branch` | The existing voucher allocator has a database-proven collision key and scope. |
| `bu000` | `GUID` | `TypeGUID, Number, Branch` | Sales/Purchase headers have a database-proven collision key; the two-copy observation now proves that independent copies allocate the same number to distinct GUIDs. |
| `mt000` | `GUID` | None | `Number` has a non-unique index only. The database permits duplicate material numbers; application semantics and a safe allocator scope cannot be inferred from SQL metadata. |
| `MatExBarcode000` | `Guid` | `Barcode, MatGuid` | This does not establish uniqueness for `mt000.Number`. |

The restored data currently contains zero duplicate `mt000.Number` values and zero duplicate `bu000(TypeGUID, Number, Branch)` values. Absence of existing duplicates is not proof that changing a material number is safe.

## Cross-table implications

`er000` stores both `ParentGUID` and `ParentNumber`. The controlled Sales and Purchase captures prove that `ParentNumber` mirrors `bu000.Number`. The isolated two-copy experiment on 2026-09-06 then produced distinct Sales GUIDs with the same `bu000.Number=1614`, distinct voucher GUIDs with the same `ce000.Number=2320`, and `er000.ParentNumber=1614` on both copies. The complete evidence is in `docs/alameen-two-client-number-collision-observation-2026-09-06.md`.

Header-only renumbering would still be unsafe. The implemented graph rule preserves the permanent `bu000.GUID`, reserves the next free number within `TypeGUID, Branch`, and rewrites every existing `er000.ParentNumber` selected by `ParentGUID` in the same SQL transaction and `SQLSYNC` Change Tracking context. Applying an `er000` job also derives the redundant value from the current `bu000` parent before merge, so job order or retry cannot revert the reservation.

Material dependents observed so far (`bi000`, `ms000`, `cp000`, and `MatExBarcode000`) link through the material GUID. That makes GUID preservation promising, but it does not prove that Al-Ameen accepts two physical materials with the same visible number or that no unobserved table/configuration stores the material number. A controlled two-copy Al-Ameen application test is required before enabling an `mt000` allocator.

## Fail-closed decision

1. Keep the existing `ce000` automatic voucher-number rule.
2. Enroll `bu000` in automatic number reservation only with the atomic `er000.ParentNumber` rewrite and relation-side derivation guarded by the three-client regression.
3. Do not enroll `mt000` until a controlled two-copy Al-Ameen test proves the material-number business invariant and a complete dependency scan proves the rewrite set.
4. Keep production Sales/Purchase synchronization disabled until the separate INC-403 complete-document boundary is proven. A timing delay, upload order, or arbitrary authoritative client is not a safe substitute.

## Exact next external evidence required

Using the same two isolated database copies, create one new material independently in each copy so Al-Ameen assigns the same local number. Before any synchronization, inspect both final rows and reopen/search both materials in Al-Ameen. This determines whether duplicate visible numbers are rejected, silently ambiguous, or supported. The same-number Sales experiment is complete; Purchase collision handling shares the same proven `bu000`/`er000` structure but production activation still awaits the complete-document boundary.

## Implementation feasibility review (2026-09-05)

The retained bounded delta proves the final Sales state across versions 5769 and 5770, but SQL Server Change Tracking does not retain the intermediate row images that existed after version 5769. Consequently, the final-state evidence cannot prove a validator that always rejects phase one of the multi-commit save. Implementing such a validator now would encode an assumption about accounting data.

The official SyrianSoft public site was checked for an Al-Ameen 8.1 database transaction marker, schema contract, synchronization interface, or numbering API. Its public product, download, contact, and technical-support entry points do not publish that contract. Vendor support may still provide private documentation, but none is available in this repository or on the public vendor site.

The same-number Sales experiment is now complete and proves the `bu000`/`ce000` collision plus the `er000` rewrite set. It makes automatic header/voucher number reservation implementable, but it does not supply the missing intermediate row images for the earlier two-commit Sales edit. The safe remaining evidence is to capture both phases of that known workflow and run the same-number material experiment in two isolated copies. `mt000` stays outside automatic allocation, and production Sales/Purchase synchronization stays disabled until the completion invariant is proven.
