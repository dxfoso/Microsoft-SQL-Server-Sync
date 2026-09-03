# Progress

Overall: **82% complete — verified backup and first guarded menu probe complete**

| Step | Status | Progress |
|---|---|---:|
| Inspect existing client backup, restore, SQL and remote-command capabilities | Done | 100% |
| Design the restricted same-machine Al-Ameen laboratory and rollback safety gates | Done | 100% |
| Implement the read-only client and targeted server discovery controls | Done | 100% |
| Add incident documentation and automated regression tests | Done | 100% |
| Run required Flutter, contract, Docker and Standard verification | Done | 100% |
| Publish the Windows client and deploy the server/web changes | Done | 100% |
| Read-only inspect Al-Ameen on `alshallan2` | Done | 100% |
| Capture the verified Al-Ameen window for visual calibration | Done | 100% |
| Build stable visual anchors and a menu-only probe | Done | 100% |
| Create and verify the pre-input `AmnDb048` rollback backup | Done | 100% |
| Inspect semantic controls exposed by the opened invoice menu | In progress | 50% |
| Record business operations and prove `AmnDb048` rollback | Waiting for sales-form discovery | 5% |

Current result: Windows client `1.0.310+314` and production commit `7fc93951d9a0658ecf2b44767ed05aad181c4a54` are deployed and healthy. `alshallan2` is online on `DESKTOP-ALDNHIH`, is connected to `.\SQLEXPRESS` / `AmnDb048`, has zero active jobs, and is disabled from synchronization. `velvet home` remains offline and disabled. The exact pre-input backup is 140,455,424 bytes with SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`. The fixed invoice-menu probe verified 14,638 changed samples and one process-owned `XTPPopupBar` at window-relative bounds 1099,56 / 234×299, captured it, closed it with Escape, and changed no database record.

## Blockers and stop conditions

Prior semantic-accessibility blocker: **confirmed; mitigated for top-level menu discovery by the fixed screenshot-guarded adapter**.

Reason: Al-Ameen 8.1 runs as `Amn32.exe` and exposes only 14 Windows UI Automation descendants. The usable results are generic MFC/Codejock panes (`Afx...`, `XTP...`) plus unnamed generic button panes; the accounting menus, commands, and data-entry fields do not expose semantic names or actionable control types. The client can identify the exact application window, but it cannot deterministically prove which business command it would invoke. Coordinate-based clicking would guess on accounting data and is not safe.

The deployed version-specific screenshot adapter now provides a bounded fallback for top-level menu discovery: it verifies the executable, window class and dimensions, checks a calibrated pixel anchor, captures only process-owned windows, and restores the menu state. Deeper business input still remains fail-closed until an exact semantic popup control or a separately verified visual target is available.

The work will stop before any UI input or database mutation if the deployed discovery reports any of the following:

- Al-Ameen does not expose stable Windows UI Automation controls and cannot be driven deterministically.
- More than one Al-Ameen main window is visible, so the target cannot be identified exactly.
- `alshallan2` is not online, idle, and completely disabled from synchronization.
- The selected SQL identity is not exactly `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`.
- A full `COPY_ONLY` backup does not pass `RESTORE VERIFYONLY` before testing.
- Another Al-Ameen or SQL session prevents a verified rollback to the original database state.
- The before/after fingerprint cannot prove that rollback restored the original test state.

Observed discovery evidence: process `Amn32.exe`, path `C:\Program Files (x86)\alameensoft\Al-Ameen\81\Bin\Amn32.exe`, root class `Afx:00400000:0`, 14 descendants, and no semantic accounting command or input controls. No safe zero-input workaround was guessed.

Previous completed milestone: resumable typed SQL bulk staging was deployed and verified in Windows client `1.0.266+270` on production commit `bbcb3b4`.
