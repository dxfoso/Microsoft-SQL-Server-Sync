# sync_windows_agent

Flutter Windows desktop agent for local SQL Server sync execution.

## Purpose

This app is installed on each Windows PC that hosts or can reach Microsoft SQL Server. It lets the user:

- register the PC against the central website domain
- configure the local SQL Server instance and database
- choose which tables are allowed to participate in sync
- run or monitor scheduled sync activity every 5 minutes
- keep sync logic local to the PC instead of exposing SQL Server to the browser

## Run

```bash
flutter run -d windows
```

## Current State

The project currently contains a responsive desktop UI prototype with mock sync status and event data. For real sync execution it must be connected to a backend API and a SQL access layer.
