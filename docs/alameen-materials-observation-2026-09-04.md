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

Create only the new material in step 1, save it once, then stop and report `material created` together with the values entered. Do not edit it again until the post-create delta is captured.
