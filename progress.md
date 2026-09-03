# Progress

Overall: **75% complete — screenshot capture deployed; guarded input not started**

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
| Build stable visual anchors and a menu-only probe | In progress | 20% |
| Record business operations and prove `AmnDb048` rollback | Waiting for visual calibration | 0% |

Current result: Windows client `1.0.309+313` and production commit `ff1a11791038593fb5b753cd68ad67c66733dc32` are deployed and healthy. `alshallan2` is online on `DESKTOP-ALDNHIH`, is connected to `.\SQLEXPRESS` / `AmnDb048`, has zero active jobs, and is disabled from synchronization. `velvet home` remains offline and disabled. The client captured only the verified `Amn32` window at 1382×744 through `PrintWindow`, uploaded a bounded 800×431 JPEG with SHA-256 `574de4292f115254a7e526278b9e8ba8bfb4a3770dd63ff2fb35812be1542ae2`, and performed no input or database mutation.

## Blockers and stop conditions

Prior semantic-accessibility blocker: **confirmed; screenshot fallback is now being implemented without input or database mutation**.

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
