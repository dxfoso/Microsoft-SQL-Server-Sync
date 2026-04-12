# sync_admin_web

Flutter web admin dashboard for the SQL Server sync control plane.

## Purpose

This app is the operator-facing website. It lets an admin:

- register and monitor Windows agent machines
- choose the source PC and one or more sink PCs
- choose the SQL tables to replicate
- define the sync cadence, including the default 5-minute interval
- review recent execution history

## Run

```bash
flutter run -d chrome
```

## Current State

The project currently contains a responsive UI prototype with realistic sync workflow screens and mock data. For real sync execution it must be connected to a backend API plus the Windows agent app in `../sync_windows_agent`.
