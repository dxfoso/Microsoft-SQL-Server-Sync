# Al-Ameen two-client Sales-number collision observation (2026-09-06)

## Safety and provenance

This observation used only the two explicitly isolated `AmnDb048_SyncLab`
databases. Both were restored from the same checksum-verified Velvet Factory
backup, passed `DBCC CHECKDB`, had the transaction-versioned
`SqlSyncLabAudit` installed, and remained synchronization-disabled with zero
active sync jobs. `velvet home` remained disabled and was not involved.

Al-Ameen 8.1 required an SDF descriptor on each computer before it could open
the restored SQL database. The user copied the existing descriptor directory,
changed only its database reference from `AmnDb048` to
`AmnDb048_SyncLab`, opened it on both computers, and confirmed the lab
database. Opening the descriptors produced the same non-business pattern on
both copies: baseline `4492` through `4500`, 28 operations in `Connections`,
`op000`, and Al-Ameen's replace-in-place `ma000` maintenance. An independent
bounded export from `4500` through `4500` then contained zero operations. That
exact version is the before-state for the collision experiment.

## User action

The user created and fully saved exactly one Sales invoice on each copy,
accepting Al-Ameen's automatic numbers. The `alshallan2` invoice contained one
unit of an existing material. The `velvet factory` invoice contained two units
of a different existing material. Printing was cancelled and no second invoice,
manual number change, edit, delete, restore, or synchronization was performed.

## Bounded evidence

| Client | Boundary | Operations | Compressed bytes | SHA-256 |
|---|---:|---:|---:|---|
| `alshallan2` | `4500`–`4511` | 555 | 24,825 | `3b8b628fb53670b31e6a40fd23fa4b4cb4b985284751bc93d76f35dc16e0d6bc` |
| `velvet factory` | `4500`–`4511` | 555 | 24,774 | `d3b9f95732b2de99415585b4480ef428fc00257930c13758db16cb116e66c287` |

On both clients the complete business graph committed atomically at Change
Tracking version `4501`. Later versions were preferences, connections, and
the already-known `ma000` maintenance pattern. Each `4501` transaction
contained the Sales header, line, stock, material, customer-price, voucher,
two balanced ledger lines, payment term, relation, and five account aggregate
updates, plus the corresponding lab audit row images.

## Proven collision

The two invoices are distinct business documents but Al-Ameen assigned both
the same local numbers:

| Field | `alshallan2` | `velvet factory` | Meaning |
|---|---|---|---|
| `bu000.Number` | `1614` | `1614` | SQL-unique Sales/Purchase header number collided. |
| `bu000.TypeGUID` | `E69CCB78-C70D-47E3-B9BC-D366381A9384` | same | Same Sales document type/scope. |
| `bu000.Branch` | zero GUID | zero GUID | Same SQL unique-key branch scope. |
| `bu000.GUID` | `81C33C4E-0430-4AF9-8A25-C71115FF1F7F` | `7D14C2A2-2F20-4146-8C71-D89A532EFE30` | Permanent identities prove these are not versions of one row. |
| `ce000.Number` | `2320` | `2320` | SQL-unique voucher number also collided. |
| `ce000.Type` / `Branch` | `1` / zero GUID | same | Same voucher unique-key scope. |
| `ce000.GUID` | `01C26F04-24CD-4751-B8AF-047017482D35` | `9F001306-B522-4317-8241-936961249F3A` | Distinct permanent voucher identities. |
| `er000.ParentNumber` | `1614` | `1614` | Confirms the redundant reference that must follow any header renumber. |

The invoices also have different totals (`216000.0` and `17600.0`), different
materials, quantities, line GUIDs, stock GUIDs, relation GUIDs, and ledger
GUIDs. Selecting one client as authoritative would therefore destroy a real
sale. Latest-change-wins on the SQL business key would have the same data-loss
problem. Both documents must survive; only the later colliding visible numbers
may change.

## Proven graph rule

All structural children use permanent GUID relationships:

- `bi000.ParentGUID`, `pt000.RefGUID`, and `er000.ParentGUID` reference the
  `bu000.GUID`.
- `en000.ParentGUID` and `er000.EntryGUID` reference the `ce000.GUID`.
- The sole observed duplicated Sales/Purchase header number is
  `er000.ParentNumber`, and it equals `bu000.Number` on both independent saves.
- No voucher child in this observed graph duplicates `ce000.Number`; voucher
  children remain connected through its GUID.

Therefore a safe automatic resolution preserves every GUID, keeps the first
`bu000` identity at `1614` and first `ce000` identity at `2320`, assigns the
next owner-wide free number to each later identity, and rewrites
`er000.ParentNumber` from the resolved `bu000` parent inside the same SQL
transaction. Any incoming `er000` row must also derive this redundant number
from `ParentGUID`, preventing a later relation-table job from reverting the
reservation.

## Remaining boundary

This simple one-line Sales workflow was atomic at version `4501`; it does not
erase the earlier evidence that a larger Sales edit committed across versions
`5769` and `5770`. Automatic number allocation and graph rewriting can now be
implemented and regression-tested, but production Sales synchronization must
remain disabled until the general complete-document boundary validator is
proven. The isolated databases remain at version `4511`; no live database was
used or changed.
