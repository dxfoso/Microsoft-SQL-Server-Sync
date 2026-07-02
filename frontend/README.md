# frontend

Flutter web admin dashboard for the SQL Server sync control plane.

## Purpose

This app is the operator-facing website. It lets an admin:

- register and monitor Windows agent machines
- choose the source PC and one or more sink PCs
- choose the SQL tables to replicate
- trigger and monitor sync jobs
- review sync status, history, and diagnostics

## Run

```powershell
..\run.ps1 -SkipGet
```

For direct app-only work:

```bash
flutter run -d chrome
```
