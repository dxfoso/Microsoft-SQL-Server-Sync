# Al-Ameen material-master observation — 2026-09-04

## Scope and safety boundary

- Test client: `alshallan2` on `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`.
- This is the test database covered by the existing verified rollback backup.
- Synchronization was confirmed disabled immediately before baseline capture.
- The client was online and SQL-connected with zero active synchronization jobs.
- No production client database is used for reproduction or automated mutation.
- Al-Ameen UI changes are made manually by the user. Repository tooling performs only bounded read-only Change Tracking exports.
- The controlled material must not be used in a Sale, Purchase, stock-opening transaction, or other document until the material-master sequence is complete.

## Sealed pre-change checkpoint

- Prior observation baseline: Change Tracking version `5796`.
- Fresh material pre-change upper version: `5796`.
- Net operations between those versions: **0**.
- Artifact size: **148 bytes**.
- SHA-256: `35f06299cab83535786419e143c41aee492f7381702f1e78551df2a01118abcb`.
- Evidence directory: `artifacts/alameen-lab/material-prechange-baseline-20260904T091741Z`.

This proves that the material experiment begins at a quiet, version-bounded database state. Baseline `5796` must be used for the first post-create delta; it must not be advanced from elapsed time or an unverified UI action.

## Controlled sequence

Each step is saved and captured separately. Do not combine two visible edits in one save.

1. Create one new material named `SQLSYNC مادة اختبار 20260904-01`. Allow Al-Ameen to assign its normal material number/code. Fill only fields the application requires, save once, stop, and report every value entered or selected.
2. After the create delta is captured and documented, change only the material name and save.
3. After that delta is captured, change only one selling-price field and save.
4. After that delta is captured, add or change only one barcode and save.
5. Test one classification relationship at a time—unit or category/group—only after its preceding delta is sealed.
6. Delete the controlled material only after database evidence proves it has no transactional reference. Capture the explicit Change Tracking delete separately.

For every step, record the exact Change Tracking versions, affected tables, primary and business keys, insert/update/delete operations, stable versus regenerated identities, relationship columns, row values, artifact bytes/checksum, and whether the operation is atomic or spans multiple commits. Synchronization remains disabled until the resulting material graph and completion boundary are proven safe.

## Current operator action

None. The controlled material create, name edit, price edit, barcode edit, group edit, and explicit deletion sequence is complete. Do not recreate or further modify this test identity.

## Material creation capture

The user created and saved one material. The captured values differ from the proposed test name, so the database evidence below—not the proposed input—is authoritative.

- Delta boundary: baseline `5796`, upper version `5798`.
- Net operations: **2** across two tables.
- Artifact size: **1,731 bytes**.
- SHA-256: `8a4963bdd59be6e5327cd36638195729c894aec8a5d6ce56fcf9c19490a56c52`.
- Evidence directory: `artifacts/alameen-lab/material-create-delta-20260904T092313Z`.
- Version `5797`: one unrelated `op000` insert recording the local material-group sorting preference `AmnCfg_SortFields.class TGrpNoSonsSearchStruct = 1` for `DESKTOP-ALDNHIH`. This is UI configuration, not part of the material business row.
- Version `5798`: one `mt000` insert. No second material table or relation row changed, so the observed creation itself is one atomic Change Tracking version.

### Identity and relationships

| Field | Saved value |
|---|---|
| `GUID` (declared primary key) | `D626944E-674A-4D38-B4BF-0A921995D17D` |
| `Number` | `209812` |
| `GroupGUID` | `2D305758-5D51-4820-AF24-A23EF8161974` |
| `CurrencyGUID` | `BCBCD2F1-24DD-4F86-9746-2537D7351DFE` |
| `PictureGUID` | zero GUID |
| `OldGUID` / `NewGUID` | zero GUID / zero GUID |
| `DefUnit` | `1` |

`GUID` is the physical primary key exposed by the delta. `Number` is the observed stable human/business identifier candidate, but this single insert does not yet prove its database uniqueness or immutability. `GroupGUID` and `CurrencyGUID` are application relationships and must be synchronized before or atomically with a material when their referenced rows do not already exist.

### Descriptive and classification values

| Field | Saved value |
|---|---|
| `Name` | `test 1` |
| `LatinName` | `test 1 en` |
| `Code` | `symbol` |
| `CodedCode` | empty |
| `Spec` | `fwerfew` |
| `Origin` | `gregerf` |
| `Company` | `grewggrgr` |
| `Pos` | `gregr` |
| `Dim` | `2XL-3XL` |
| `Color` | `grgrg,fef,fefe,` |
| `Provenance`, `Quality`, `Model` | empty |
| `Unity`, `Unit2`, `Unit3` | empty |
| `BarCode`, `BarCode2`, `BarCode3` | empty |

### Quantity, prices, and numeric configuration

- `Qty`, `High`, `Low`, `Whole`, `Half`, `Retail`, `EndUser`, `Export`, `Vendor`, `MaxPrice`, `AvgPrice`, `LastPrice`, `BonusOne`, `Bonus`, `UseFlag`, `Flag`, `VAT`, and `OrderLimit` were all `0.0`.
- Every secondary price field—`Whole2`, `Half2`, `Retail2`, `EndUser2`, `Export2`, `Vendor2`, `MaxPrice2`, `LastPrice2`, `Whole3`, `Half3`, `Retail3`, `EndUser3`, `Export3`, `Vendor3`, `MaxPrice3`, and `LastPrice3`—was `0.0`.
- `Unit2Fact` and `Unit3Fact` were `0.0`.
- `CurrencyVal` and `LastPriceCurVal` were `1.0`.
- `PriceType = 15`, `SellType = 0`, `Type = 0`, `Security = 1`, and `branchMask = 0`.

### Flags and dates

- False/zero flags: `ExpireFlag`, `ProductionFlag`, `Unit2FactFlag`, `Unit3FactFlag`, `SNFlag`, `ForceInSN`, `ForceOutSN`, `bHide`, `Assemble`, `CalPriceFromDetail`, `ForceInExpire`, `ForceOutExpire`, `IsIntegerQuantity`, and `DisableLastPrice`.
- `CreateDate = 2026-09-04T00:00:00`.
- `LastPriceDate = 2026-09-04T00:00:00`.
- `FirstCostDate = 1980-01-01T00:00:00`.

### Current conclusions

1. The observed material master row is `mt000`; creation inserted one complete row rather than a partial header followed by child rows.
2. The creation was atomic at version `5798`; the preceding `op000` preference commit is causally separate and must not be grouped into the material operation.
3. No stock movement, quantity aggregate, account, voucher, price-relation, barcode child, or transaction row was created.
4. The next safe bounded-delta baseline is `5798`.
5. Synchronization remains disabled. This one creation proves the insert shape only; update identity stability, group/currency dependencies, business-key behavior, and explicit deletion still require their separate experiments.

## Name-only edit capture

The user changed only the visible material name from `test 1` to `test 1 edited` and saved once.

- Delta boundary: baseline `5798`, upper version `5799`.
- Net operations: **1**—one `U` operation in `dbo.mt000` at version `5799`.
- Artifact size: **1,512 bytes**.
- SHA-256: `8a59049155175a0e8999de7cf5a15cf1426c9311915dc50ea55fdc46ee5b7d85`.
- Evidence directory: `artifacts/alameen-lab/material-name-edit-delta-20260904T190602Z`.
- Stable identity: `GUID D626944E-674A-4D38-B4BF-0A921995D17D` and material `Number 209812` were unchanged. `GroupGUID`, `CurrencyGUID`, and every other relationship identifier were also unchanged.

Complete comparison against the version-5798 inserted row found exactly two database business-value differences:

| Field | Before | After | Interpretation |
|---|---:|---:|---|
| `Name` | `test 1` | `test 1 edited` | The user's intended visible edit. |
| `BonusOne` | `0.0` | `1.0` | An automatic Al-Ameen normalization/side effect; the user did not intentionally edit it. |

The delta transport metadata also changed operation `I` to `U`, version `5798` to `5799`, and its capture clock offset; these are not `mt000` business columns. Every other saved `mt000` value—including `LatinName`, code, specification, group, currency, quantities, prices, barcodes, flags, dates, and classification text—matched the creation row exactly.

Conclusions:

1. A normal material edit preserves both the physical `GUID` and observed business number in this case; it is an in-place update, not delete/reinsert identity churn.
2. UI intent cannot be converted into a name-only database patch: Al-Ameen also changed `BonusOne`. Synchronization must transport the complete causally captured final row and must not reconstruct it from the field the operator remembers changing.
3. No related table changed, and the save completed in one atomic Change Tracking version.
4. The next safe bounded-delta baseline is `5799`.

## Wholesale-price-only edit capture

The user changed only the wholesale selling-price field of material 209812 from zero to 12,345 and saved once.

- Delta boundary: baseline `5799`, upper version `5800`.
- Net operations: **1**—one `U` operation in `dbo.mt000` at version `5800`.
- Artifact size: **1,522 bytes**.
- SHA-256: `a7ae5448632e145085c3132c773685134ef81f5218a56bc285cd13ee8d3269b4`.
- Evidence directory: `artifacts/alameen-lab/material-price-edit-delta-20260904T191048Z`.
- Stable identity: GUID `D626944E-674A-4D38-B4BF-0A921995D17D` and material number `209812` were unchanged.

Complete business-column comparison against the version-5799 final row found exactly one difference: `Whole` changed from floating-point text `0.0` to `12345.0`. All other prices—including `Half`, `Retail`, `EndUser`, secondary/tertiary price tiers, `MaxPrice`, `AvgPrice`, and `LastPrice`—remained unchanged. `Name`, `BonusOne`, quantity, relationships, barcodes, flags, and dates also remained unchanged. Delta metadata version and capture clock offset changed as expected and are not business columns.

Conclusions:

1. This price edit is one atomic in-place `mt000` update with stable physical and business identity.
2. Al-Ameen did not derive or recalculate another selling or cost price from `Whole` for this material configuration.
3. Numeric fingerprinting must canonicalize the SQL `float` value so equivalent textual representations do not become false conflicts, while preserving the actual value `12345.0`.
4. The next safe bounded-delta baseline is `5800`.

## Primary-barcode-only edit capture

The user changed only the primary barcode from empty to `9900209812005` and saved once.

- Delta boundary: baseline `5800`, upper version `5801`.
- Net operations: **2**, both at version `5801`.
- Artifact size: **1,646 bytes**.
- SHA-256: `3d77e52320ec38dd718db1501ac1fc212422642a12360f0ae28cd4f603d9f1f7`.
- Evidence directory: `artifacts/alameen-lab/material-barcode-edit-delta-20260904T191825Z`.

The atomic graph is:

| Table/operation | Identity and values |
|---|---|
| `mt000` update | Stable GUID `D626944E-674A-4D38-B4BF-0A921995D17D`, stable number `209812`; only `BarCode` changed from empty to `9900209812005`. |
| `MatExBarcode000` insert | Primary `Guid F336A6AC-2201-41E4-959A-524EAD5A2C72`; `Number=0`; `MatGuid=D626944E-674A-4D38-B4BF-0A921995D17D`; `MatUnit=1`; `Barcode=9900209812005`; `IsDefault=1`. |

The exact equality between `MatExBarcode000.MatGuid` and the stable `mt000.GUID` proves the application-level parent/child association in this captured operation. A declared SQL foreign key or unique barcode constraint was not proven: the attempted read-only check against the isolated Docker backup could not start because the local Docker Linux engine was unavailable, so no absent/present constraint conclusion is drawn from it.

Conclusions:

1. A primary barcode is duplicated in the material row and a dedicated barcode child row.
2. Both changes share version `5801`, so they must be captured and applied as one atomic material graph; apply the `mt000` parent before its new child when the target lacks the material.
3. The child has its own physical GUID. This experiment does not yet prove whether later barcode edits update that child, replace it with a new GUID, or enforce barcode uniqueness.
4. Snapshot absence must not delete barcode children; only explicit Change Tracking deletes may do so.
5. The next safe bounded-delta baseline is `5801`.

## Existing-group-only edit capture

The user changed only the material's group/category to another existing group and saved once. The user did not provide the displayed old/new group labels, and the unchanged group-master rows are not present in a Change Tracking delta; therefore this observation records the exact identifiers without inventing labels.

- Delta boundary: baseline `5801`, upper version `5802`.
- Net operations: **3**, all at version `5802`.
- Artifact size: **1,703 bytes**.
- SHA-256: `82ae1a7c314ed66196dbb010395aa277f8563e6e68b90b13e56de989becbd3b1`.
- Evidence directory: `artifacts/alameen-lab/material-group-edit-delta-20260904T192441Z`.

The atomic graph is:

| Table/operation | Exact change |
|---|---|
| `mt000` update | Stable material GUID and number; `GroupGUID` changed from `2D305758-5D51-4820-AF24-A23EF8161974` to `ACA0B3F8-A67A-4AB5-B147-AE4D8CE49EF0`. Every other business column was unchanged. |
| `MatExBarcode000` delete | Explicit complete-key delete of prior child GUID `F336A6AC-2201-41E4-959A-524EAD5A2C72`. Change Tracking correctly provides only its primary key on the tombstone. |
| `MatExBarcode000` insert | Replacement child GUID `48B21271-2FA8-4555-BF67-1912217E26CF`, with unchanged `Number=0`, material GUID, `MatUnit=1`, barcode `9900209812005`, and `IsDefault=1`. |

Conclusions:

1. Group reassignment is an in-place `mt000` update; the material GUID and number remain stable.
2. Al-Ameen rewrites the complete barcode child identity even when the barcode itself was not edited. The old and new child business values are identical, but their physical GUIDs differ.
3. All three operations share one version and must apply atomically. The exact old child tombstone must be applied, followed by the new child after its parent; retries must be idempotent and cannot resurrect the old child.
4. Synchronization must not collapse this into only a `GroupGUID` patch or infer that the child delete is accidental.
5. The next safe bounded-delta baseline is `5802`.

## Material deletion capture

The user deleted only controlled material 209812 through Al-Ameen's normal delete workflow.

- Delta boundary: baseline `5802`, upper version `5803`.
- Net operations: **2**, both explicit `D` operations at version `5803`.
- Artifact size: **1,428 bytes**.
- SHA-256: `e07d377baac98e64de9bb0375976a7149d9939d243635e3c82200520e0798a49`.
- Evidence directory: `artifacts/alameen-lab/material-delete-delta-20260904T194248Z`.

The exact tombstones are:

| Table | Declared primary key in capture | Deleted key |
|---|---|---|
| `MatExBarcode000` | `Guid` | `48B21271-2FA8-4555-BF67-1912217E26CF` |
| `mt000` | `GUID` | `D626944E-674A-4D38-B4BF-0A921995D17D` |

As expected for SQL Server Change Tracking deletes, every non-primary value is null in both tombstones. In particular, the deleted `mt000` tombstone does not contain material number 209812, name, barcode, or `GroupGUID`; safe deletion must use the complete physical primary key captured at version 5803 and must not attempt to reconstruct identity from snapshots or remembered business values.

Conclusions:

1. Al-Ameen explicitly deletes both the current barcode child and material parent in one atomic version.
2. Apply the child tombstone before the parent tombstone within the same transaction to respect the proven application association and any undeclared/declared target dependency.
3. Persist both tombstones durably with their causal version so retries are idempotent and an older material or barcode value cannot resurrect either row.
4. No group, currency, stock, movement, account, voucher, invoice, or other table changed during deletion.
5. The final safe bounded-delta baseline is `5803`. The controlled material-master observation sequence is complete; synchronization remains disabled while the general multi-commit completion blocker remains unresolved.

## Proven material graph summary

- Create: one `mt000` insert at version `5798`; a preceding version-5797 UI preference was separate.
- Name edit: stable in-place `mt000` update at `5799`, including Al-Ameen's automatic `BonusOne` normalization.
- Wholesale price edit: stable in-place `mt000.Whole` update at `5800` with no derived price changes.
- Primary barcode edit: atomic parent update plus `MatExBarcode000` child insert at `5801`.
- Existing-group edit: atomic parent `GroupGUID` update plus explicit barcode-child delete/reinsert identity churn at `5802`.
- Delete: explicit current-child and parent tombstones together at `5803`.

This establishes the observed table ownership, stable material identity, unstable barcode-child identity, atomic boundaries, parent/child ordering, and explicit-delete behavior for this controlled configuration. It does not prove every optional unit, picture, serial/expiry, assembly, tax, multi-currency, or group-creation workflow; those remain separate variants rather than assumptions.
