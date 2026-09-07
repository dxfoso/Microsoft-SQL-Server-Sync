# Al-Ameen two-client material-number collision observation

## Scope and safety

This observation used only the explicitly isolated `AmnDb048_SyncLab` databases on `alshallan2` and `velvet factory`. Both clients were disabled at the control plane, the owner automatic scheduler was confirmed paused, and there were zero active jobs before either bounded read-only export. No synchronization was started and `velvet home` remained disabled and excluded.

The user created one minimal material through Al-Ameen 8.1 on each isolated copy, left the application-assigned number unchanged, supplied no barcode, quantity, or price, and saved each material once.

## Exact captured inserts

| Client | CT baseline | CT upper | `mt000` version | Number | GUID | Name |
|---|---:|---:|---:|---:|---|---|
| `alshallan2` | 4519 | 4523 | 4523 | `209812` | `B3B00555-B6F1-4484-B53B-098BD31F58E2` | `SYNC TEST ALSHALLAN` |
| `velvet factory` | 4527 | 4531 | 4531 | `209812` | `B657F231-CBBC-4F38-A125-C4B4FB81879C` | `SYNC TEST VELVET` |

Both operations are explicit `I` records with different permanent primary GUIDs. Both applications independently selected the same next visible material number, `209812`. The rows also have different names, codes, group GUIDs, and physical GUIDs, so they are two real materials rather than competing versions of one identity. Selecting an authoritative client or applying latest-change-wins to the whole row would lose valid data.

The Alshallan bounded artifact contains 488 operations because Al-Ameen also rewrote option/detail state and the isolated audit recorded transaction images; exactly one operation is the `dbo.mt000` insert above. It is 14,672 bytes with SHA-256 `f925c7b4c068a769a26d17ed3b0d6194f8fcfc862a7dc87b7a37c05b75842479`. The Velvet artifact contains seven operations and exactly one `dbo.mt000` insert; it is 2,652 bytes with SHA-256 `1c8286b3f1b98dda53c9ae9c2bed4272e529eb69d73bf2c5d45d072d4260a8e9`.

## Dependency evidence

The verified Velvet backup was restored into disposable Docker database `AmnDb048Audit`; `RESTORE VERIFYONLY`, checksum restore, and `DBCC CHECKDB` passed. The read-only catalog scan established:

- `mt000` has primary key `GUID`; its `Number` index is not unique.
- No SQL foreign key references `dbo.mt000`.
- The schema has 119 columns whose names contain `Mat`; 91 are `uniqueidentifier` columns and none is a material-number-named column.
- Every relationship observed in the mapped Sales, Purchase, stock, customer-price, barcode, and material workflows identifies the material by GUID (`bi000.MatGUID`, `ms000.MatGUID`, `cp000.MatGUID`, and `MatExBarcode000.MatGuid`).
- The minimal creation itself inserted only `mt000`; it created no child row requiring a number rewrite.

This is sufficient for the explicitly mapped synchronization scope: retain each GUID, keep the first accepted owner-wide number, reserve the next owner-wide free number for the later colliding GUID, and change only that row's `mt000.Number`. It is not evidence that every optional Al-Ameen module among all 563 tables is mapped.

## Required automatic behavior

1. Treat `mt000.Number` as a validated application business key even though SQL Server does not declare it unique.
2. Initialize its owner-wide maximum only from a complete multi-client inventory.
3. If distinct GUIDs claim the same number, retain the first identity and reserve the next free number for the later identity using the existing durable reservation register.
4. Deliver the replacement number while preserving the material GUID and all GUID-linked children.
5. Keep retries atomic and idempotent; never delete a material because another snapshot omitted it.
6. If the complete inventory or required metadata is unavailable, stop without choosing a client or guessing.

Synchronization remained stopped after the observation so the pre-fix generic merge could not create duplicate visible material numbers.
