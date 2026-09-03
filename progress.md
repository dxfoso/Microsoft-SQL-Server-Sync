# Progress

Overall: **88% complete - visual automation stopped safely at Sales-form discovery**

| Step | Status | Progress |
|---|---|---:|
| Restricted laboratory and verified `AmnDb048` rollback backup | Done | 100% |
| Screenshot capture and fixed invoice-menu discovery | Done | 100% |
| Build/test/publish client `1.0.312+316` and production commit `1aaa67ab34e6b7b7c34228e46a59ea74f22aa192` | Done | 100% |
| Update and reconnect `alshallan2` with synchronization disabled | Done | 100% |
| Visually select Sales and capture the resulting form | Blocked - failed closed | 60% |
| Record business operations and prove full database rollback | Not started | 0% |

Current state: `alshallan2` is online on `DESKTOP-ALDNHIH`, connected to `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`, running `1.0.312+316`, synchronization disabled, and zero active sync jobs. `velvet home` remains ignored while disabled. The verified rollback backup remains 140,455,424 bytes with SHA-256 `e78b94ecef63b07b2687f423deb7b03fe6bdb2caeaaa330f08db8de3c4a82091`.

## Blocker and stop reason

Prior semantic-accessibility blocker: **confirmed; visual-only fallback was explicitly authorized and tested**.

The fixed request `ad9f26fb-ee70-4523-ada6-6361d074cac7` passed the exact `Amn32.exe`, `Afx:00400000:0`, 1382x744 window, `XTPPopupBar` geometry, and Sales-row pixel guards. After clicking the calibrated first invoice row, the main Al-Ameen window did not meet the required form-change threshold. The action failed closed, closed it with Escape, and changed no database record.

The read-only follow-up capture `916b2d9e-f492-4004-98b1-718d040a4b7e` visually confirmed that the normal account dashboard was restored. Its image is `artifacts/alameen-lab/post-sales-failure-dashboard.jpg`, SHA-256 `c3325c0f14bd45621a8fc32dda8670fbadfd85a182abc04e33bbcdec18d7ca07`.

Reason for stopping: current evidence cannot distinguish a missed/ignored coordinate click from a Sales form rendered in a separate process-owned top-level window. Lowering the threshold or entering data would guess on an accounting screen. The next safe step requires a new read-only post-click owned-window capture probe; no typing, save, database mutation, or synchronization was performed.
