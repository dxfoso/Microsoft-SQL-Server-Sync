# Al-Ameen numbering schema audit (2026-09-04)

## Safety boundary

This was a read-only catalog inspection of the checksum-verified pre-input backup restored into disposable Docker container `sql-sync-copy-20260904200405-ywxzagfsbgfumg` as database `LiveCopy_ywxzagfsbgfumg_AmnDb048`. `DBCC CHECKDB` passed. No active client database was queried or changed.

## Proven indexes

| Table | Primary key | Number-related SQL unique key | Consequence |
|---|---|---|---|
| `ce000` | `GUID` | `Type, Number, Branch` | The existing voucher allocator has a database-proven collision key and scope. |
| `bu000` | `GUID` | `TypeGUID, Number, Branch` | Sales/Purchase headers have a database-proven collision key, but header-only renumbering is unsafe because the document graph contains duplicated business references. |
| `mt000` | `GUID` | None | `Number` has a non-unique index only. The database permits duplicate material numbers; application semantics and a safe allocator scope cannot be inferred from SQL metadata. |
| `MatExBarcode000` | `Guid` | `Barcode, MatGuid` | This does not establish uniqueness for `mt000.Number`. |

The restored data currently contains zero duplicate `mt000.Number` values and zero duplicate `bu000(TypeGUID, Number, Branch)` values. Absence of existing duplicates is not proof that changing a material number is safe.

## Cross-table implications

`er000` stores both `ParentGUID` and `ParentNumber`. The controlled Sales and Purchase captures prove that `ParentNumber` mirrors `bu000.Number`. Consequently, applying an automatic-number directive only to `bu000` would leave a mismatched relation row. Sales and Purchase renumbering must be performed on a complete validated document graph and applied atomically across its participating tables.

Material dependents observed so far (`bi000`, `ms000`, `cp000`, and `MatExBarcode000`) link through the material GUID. That makes GUID preservation promising, but it does not prove that Al-Ameen accepts two physical materials with the same visible number or that no unobserved table/configuration stores the material number. A controlled two-copy Al-Ameen application test is required before enabling an `mt000` allocator.

## Fail-closed decision

1. Keep the existing automatic-number rule restricted to `ce000`.
2. Do not enroll `bu000` until the INC-403 complete-document boundary and atomic cross-table number-reference rewrite are implemented and tested.
3. Do not enroll `mt000` until a controlled two-copy Al-Ameen test proves the material-number business invariant and a complete dependency scan proves the rewrite set.
4. Keep production synchronization disabled for these Al-Ameen workflows. A timing delay, upload order, or arbitrary authoritative client is not a safe substitute.

## Exact next external evidence required

Using two isolated database copies made from the same backup, create one new material independently in each copy so Al-Ameen assigns the same local number. Before any synchronization, inspect both final rows and reopen/search both materials in Al-Ameen. This determines whether duplicate visible numbers are rejected, silently ambiguous, or supported. Repeat the same-number Sales and Purchase creation only after the complete-document collector exists; those operations must not be tested through active production clients.

## Implementation feasibility review (2026-09-05)

The retained bounded delta proves the final Sales state across versions 5769 and 5770, but SQL Server Change Tracking does not retain the intermediate row images that existed after version 5769. Consequently, the final-state evidence cannot prove a validator that always rejects phase one of the multi-commit save. Implementing such a validator now would encode an assumption about accounting data.

The official SyrianSoft public site was checked for an Al-Ameen 8.1 database transaction marker, schema contract, synchronization interface, or numbering API. Its public product, download, contact, and technical-support entry points do not publish that contract. Vendor support may still provide private documentation, but none is available in this repository or on the public vendor site.

The safe next evidence remains unchanged: capture both phases of the known two-commit Sales workflow from an isolated Al-Ameen application/database copy, and run the same-number material experiment in two isolated copies. Until one of those experiments or a vendor contract supplies the missing invariant, `bu000` and `mt000` stay outside automatic-number allocation and production synchronization stays disabled for these workflows.
