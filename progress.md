# Progress

Overall: **65% complete — stopped at a confirmed blocker**

| Step | Status | Progress |
|---|---|---:|
| Inspect existing client backup, restore, SQL and remote-command capabilities | Done | 100% |
| Design the restricted same-machine Al-Ameen laboratory and rollback safety gates | Done | 100% |
| Implement the read-only client and targeted server discovery controls | Done | 100% |
| Add incident documentation and automated regression tests | Done | 100% |
| Run required Flutter, contract, Docker and Standard verification | Done | 100% |
| Publish the Windows client and deploy the server/web changes | Done | 100% |
| Read-only inspect Al-Ameen on `alshallan2` | Done | 100% |
| Record business operations and prove `AmnDb048` rollback | Blocked — stopped | 0% |

Current result: Windows client `1.0.308+312` and production commit `21c592d87aeb9f2c0004f06d6174a519efb0776d` are deployed and healthy. `alshallan2` is online on `DESKTOP-ALDNHIH`, is connected to `.\SQLEXPRESS` / `AmnDb048`, has zero active jobs, and is disabled from synchronization. `velvet home` remains offline and disabled. The read-only Al-Ameen inspection completed without clicking, typing, or changing the database.

## Blockers and stop conditions

Confirmed blocker: **yes — automatic UI recording is stopped before input or database mutation**.

Reason: Al-Ameen 8.1 runs as `Amn32.exe` and exposes only 14 Windows UI Automation descendants. The usable results are generic MFC/Codejock panes (`Afx...`, `XTP...`) plus unnamed generic button panes; the accounting menus, commands, and data-entry fields do not expose semantic names or actionable control types. The client can identify the exact application window, but it cannot deterministically prove which business command it would invoke. Coordinate-based clicking would guess on accounting data and is not safe.

This does not prove that automation is impossible forever. Continuing safely requires a separate version-specific adapter based on a documented/vendor API, stable MSAA/Win32 command identifiers, or an isolated disposable environment in which those identifiers can be reverse-engineered and rollback independently proven. None is currently available, and the user required work to stop when such a blocker was confirmed.

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
