# sync_windows_agent

Flutter Windows desktop agent for local SQL Server sync execution.

## Purpose

This app is installed on each Windows PC that hosts or can reach Microsoft SQL Server. It lets the user:

- register the PC against the central website domain
- configure the local SQL Server instance and database
- choose which tables are allowed to participate in sync
- upload and download snapshot-based sync jobs
- view local sync activity and diagnostics

## Run

```powershell
..\run.ps1 -SkipGet
```

For direct app-only work:

```bash
flutter run -d windows
```
