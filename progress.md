# Progress

Overall: **98% laboratory mapping complete - production automatic sync blocked by an unproven Al-Ameen multi-commit boundary**

| Step | Status | Progress |
|---|---|---:|
| Restricted laboratory and verified `AmnDb048` rollback backup | Done | 100% |
| Screenshot capture and fixed invoice-menu discovery | Done | 100% |
| Build, test, publish, and deploy owned-window capture release `1.0.313+317` / `88cc3026c94d3026c77e9bbbcd9b9bb7bec27105` | Done | 100% |
| Update and reconnect `alshallan2` with synchronization disabled | Done | 100% |
| Capture the user-opened Sales dialog without input | Done after delayed command delivery | 100% |
| Record the first manual Sales operation and compare its database effects | Done | 100% |
| Record the existing-sale quantity edit and compare its database effects | Done | 100% |
| Record the same-sale item price edit and compare its database effects | Done | 100% |
| Record the same-sale item removal and compare its database effects | Done | 100% |
| Capture the saved three-item sale boundary-test checkpoint | Done | 100% |
| Capture removal of the middle item before Save | Done - zero database changes | 100% |
| Capture state after only the first Save click | Done - zero database changes; warehouse confirmation open | 100% |
| Capture state after warehouse-quantity confirmation | Done - one complete version `5782` | 100% |
| Capture the first controlled three-item Purchase | Done - one complete version `5793` | 100% |
| Capture a Purchase quantity edit | Waiting for user action | 0% |
| Prove a safe Al-Ameen logical-operation completion boundary | Blocked - no vendor marker or proven invariant yet | 0% |
| Replace full-backup transfer with bounded Change Tracking delta export | Done | 100% |
| Prove full database rollback | Not started | 0% |

Current state: `alshallan2` is online on `DESKTOP-ALDNHIH`, connected to `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`, running `1.0.314+318`, synchronization disabled, and zero active sync jobs. `velvet factory` is also online/current on `1.0.314+318`; `velvet home` remains ignored and unchanged while disabled. The verified rollback backup remains 140,455,424 bytes with SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`.

## Resolved command delay and safety evidence

Prior semantic-accessibility blocker: **confirmed; visual-only fallback was explicitly authorized and remains fixed-action guarded**.

The new release passed its local startup, contract, Flutter, Docker, Standard verification, immutable deployment, public health, and portable-manifest checks. The targeted update request `5eb93493-e6ac-4d1b-aafc-4d681ab5fa73` completed, and a fresh healthy heartbeat confirmed `1.0.313+317` with both server and SQL connectivity.

The read-only owned-window capture request `f2dee5f9-750e-441d-bf5f-25b426fa0d66` and diagnostic request `d3116b6a-c565-4958-a4c1-c98dbcfaba20` were initially delayed across multiple healthy heartbeats. After the user restarted the client, both completed: the capture reported one separate process-owned window and diagnostics reported zero failed tables and zero active jobs. The prior fixed Sales probe had passed the exact `Amn32.exe`, `Afx:00400000:0`, 1382x744 window and popup guards, then closed it with Escape, and changed no database record.

The command-delivery blocker is cleared for this experiment. No automated Al-Ameen input, restore, or synchronization was performed; the only database mutation now in scope is the one Sales record the user subsequently created manually.

## Current controlled change

- Device/database: `alshallan2` on `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`.
- Before-state: verified backup `artifacts/alshallan2-pre-input-backup-20260903/YWxzaGFsbGFuMg-AmnDb048.bak`, SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`; isolated restore passed `DBCC CHECKDB`, contains 562 tables / 78,398 allocated rows, and records Change Tracking version `5754`.
- User-reported action: on 2026-09-03, the user manually created and saved exactly **one Sales record** in Al-Ameen after the before-state backup was sealed.
- Follow-up observation: Al-Ameen displayed its standard Print dialog after the save; the user was instructed to cancel printing and not add, edit, delete, or save another record.
- Verification status: invoice number, affected tables, primary keys, business keys, row values, and accounting/inventory side effects are **not yet verified**. They will be recorded only from the before/after database comparison.
- Sync status: disabled; this experiment has not been uploaded to another client.
- Low-bandwidth path: client `1.0.314+318` is being built to export only the version-bounded Change Tracking delta after `5754`; the redundant 140 MB transfer will be superseded only after release verification.
- Pre-release safety review caught and fixed upper-bound ordering before any live delta request: the client now captures the upper Change Tracking version before discovery, bounds every row query to it, and publishes no manifest if the ending version differs.
- Final local gates pass: 237 Flutter tests, Flutter static analysis, 551 repository contract/incident tests, and the disposable three-client SQL Server Docker suite including offline recovery, explicit deletes, collisions, retries, Unicode, fuzz, and scale. Production publication and the small live read-only delta remain.
- First immutable backend build stopped safely before push/deployment because TRU rejected two mixed-type optional-value ternaries (INC-399). The mode is now explicitly converted to `string` and the baseline uses a guarded nullable local; focused regression and the immutable compile gate are being rerun.
- The first no-push retry removed the type errors but exposed unsupported annotated local-variable syntax (INC-400). It was replaced with TRU's native inferred `let requestedBaselineVersion = null` form; no image or client update reached production.
- The corrected control plane passed the immutable backend/frontend no-push build. A later exact-commit Standard rerun exposed a pre-existing rollback-test observer bound (INC-401): it allowed one bounded supervisor launch although rollback may require two. The isolated retry passed; the observer now covers both launches without weakening rollback, hash, or restart assertions.
- The first catalog check after that test-only change found and corrected its stale 75-second meta-assertion (INC-402); it now enforces the 150-second complete two-launch bound.
- Final release: Standard verification passed all nine stages on commit `be128bacfe30fd17768bb106a9c15fac5857f97c`; immutable backend/frontend images are deployed, public health is stable with `ready=true` and `compile_errors=0`, UI is HTTP 200, and Windows client `1.0.314+318` is published and verified.
- The first live bounded delta completed on attempt 1: baseline `5754`, upper version `5766`, 526 exact operations, 19,678 bytes, SHA-256 `266d66cdf766b28dfda1e0021535529190842cf27b30e2d199d8b4891e7c1fea`. This is 99.985996% smaller than the 140,520,960-byte full after-backup.
- The controlled Sales save is documented in `docs/alameen-sales-observation-2026-09-03.md`. Its atomic commit was version `5755`, with 15 changes across 10 accounting, invoice, stock, and relation tables. Later UI/session commits are separated from the sale.
- `ma000` was not reduced: Al-Ameen explicitly replaced 12 rows with 12 new-GUID rows at versions `5763`–`5764`; all non-primary business fields matched the restored baseline exactly. This explains equal-count/different-hash behavior without treating snapshot absence as deletion.
- The user's quantity edit is captured and verified at Change Tracking version `5767`. The edited database object was posted Sales number 110: line 0 quantity changed 1 to 10 at unchanged unit price 430,000, and the total increased from 5,756,000 to 9,626,000. The 15,792-byte delta contains 172 operations because Al-Ameen regenerated all 26 Sales line GUIDs, all 27 ledger-line GUIDs, and related voucher/relation/payment identities in the same atomic commit. Inventory and account aggregates changed by the exact corresponding amounts. The next safe delta baseline is `5767`.
- The next price edit is captured and verified at version `5768`: Sales 110 line 1 price changed from 312,000 to 3,120,100, increasing the total and balanced accounting by exactly 2,808,100. Stock quantities did not change; material 198293's maximum, average, and last prices changed to the entered value. Al-Ameen again emitted the same 172-operation atomic identity-rewrite pattern. The next safe delta baseline is `5768`.
- The durable Sales observation now includes the complete per-table identity/correlation model, exact delete/insert versus stable-update behavior, before/after account aggregates, ledger and voucher arithmetic, material effects, cumulative state, evidence hashes, confidence boundary, and future sync requirements. Later implementation work can use this sanitized fact record without repeating the live database comparison.
- The one-line removal is captured from baseline `5768` through version `5770`: Sales 110 removed old line 5 (material 197190, quantity 1, price 158,000), renumbered the 20 later lines, reduced the final total and balanced accounting to 12,276,100, reduced the linked stock quantity to 0, and recalculated that material's last price to 198,000. The verified 17,512-byte artifact contains 224 net operations.
- **Production blocker (INC-403):** the one visible removal spans separate committed versions `5769` and `5770`. The current generic reader has no Al-Ameen completion marker and could legally capture the intermediate version. A delay is not proof of completion. `alshallan2` sync remains disabled; further laboratory observations may continue, but production automatic synchronization for this workflow must stop until a business-aware complete-document invariant or reliable application completion signal is implemented and regression-tested. The next safe observation baseline is version `5770`.
- The new boundary-test checkpoint is sealed. Sales 1616 was created at version `5771` with three quantity-1 lines: material 9 at 7,700, material 77577 at 174,000, and material 11162 at 54,000. Its posted header, balanced voucher 2322, four ledger entries, three stock movements, three material balances, five accounts, three customer prices, relation, and payment term reconcile exactly to 235,700. Later print/session maintenance brings the complete safe delta baseline to `5781`. The next action is to remove only the middle line without saving or closing, then request a capture.
- The unsaved-removal checkpoint is complete: after removing material 77577 from the open Sales 1616 dialog but before either Save click, Change Tracking remained `5781` with zero changed rows/tables. The UI deletion is therefore in-memory only. Baseline remains `5781`; the next action is exactly one first Save click followed by another capture before the second click.
- The first-Save checkpoint is complete: clicking Save once opened the warehouse-quantity confirmation but still produced zero database changes; Change Tracking remained `5781`, and the 148-byte empty artifact was identical to the unsaved checkpoint. This proves the first click is pre-commit validation. The next action is to accept the warehouse confirmation once, stop immediately, and capture from the unchanged baseline `5781`.
- The warehouse-confirmation checkpoint is complete. Accepting the prompt committed one atomic version `5782` with 35 operations: material 77577 (quantity 1, price 174,000) was removed; Sales 1616 fell from three lines/235,700 to two lines/61,700; voucher 2322, three ledger entries, payment term, stock, materials, customer prices, and five accounts reconcile exactly. This proves the confirmation is the commit trigger for this three-line workflow, but does not remove INC-403 because the earlier 26-line removal used two versions. The next observation baseline is `5782`; the next engineering step is the complete-Sales-graph validator.
- The first controlled Purchase is captured at version `5793` and documented separately. Purchase 111 contains three quantity-1 materials priced 24,000, 144,000, and 26,000; header, balanced voucher 2323, four ledger entries, supplier term, three inbound movements, material quantity/cost updates, and six account aggregates reconcile exactly to 194,000. The document type is proven through `bu000.TypeGUID -> bt000.GUID` type 1 (`Purchase`, input/cost-affecting). The full low-bandwidth artifact is 25,406 bytes with SHA-256 `e8edb4764ae35142d8efcea8b73b8a008edea4ac368cf36d961bdf193517a26e`; 749 earlier maintenance operations are excluded. The next baseline is `5793`.
