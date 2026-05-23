# Microsoft SQL Server Sync Workspace

This repository contains the web control plane, the Windows desktop agent, and
the TRU backend business logic for a Microsoft SQL Server sync platform:

- `frontend`: Flutter web control plane for the website
- `backend`: upstream `tru` runtime as a git submodule
- `business`: project-owned TRU business logic for the backend
- `sync_windows_agent`: Flutter Windows desktop agent for each customer PC

## What Is In This Repo

The repo now includes:

- a responsive Flutter web dashboard where an operator can choose the source PC, sink PCs, tables, and 5-minute schedule
- the upstream TRU runtime mounted directly at `backend/`
- a root `business/` source tree for all backend `.tru` files
- a responsive Flutter Windows desktop agent where a user can enter the website domain, local SQL Server settings, and table exposure rules
- updated widget tests for both apps
- project-level documentation for the current repo layout

## Important Architecture Note

A Flutter web app running in the browser cannot safely or directly connect to Microsoft SQL Server on a user PC.

To make your product work correctly, you need 3 parts:

1. A web control plane
   This is `frontend`. It is where the admin creates sync plans and selects source and sink machines.
2. A Windows desktop agent on each PC
   This is `sync_windows_agent`. It runs locally on the machine, stores SQL credentials, and performs the actual sync work.
3. A backend API/orchestrator
   This runs on the TRU runtime in `backend/` and loads the app-specific logic
   from the root `business/` directory.

The first two parts are implemented here as separate Flutter apps. The backend is described below and should be the next build phase.

## Recommended Production Flow

1. The user installs `sync_windows_agent` on each Windows PC that should participate in sync.
2. The agent stores:
   the central domain URL, local SQL Server instance, database name, secure credentials, and machine identity.
3. The agent registers with the backend API.
4. An admin opens `frontend` and creates a sync plan:
   source PC, sink PCs, tables, and 5-minute cadence.
5. The backend saves the plan and assigns it to the relevant agents.
6. Every 5 minutes:
   the source agent reads changed rows, packages the delta, and sends it through the backend or a controlled direct transport.
7. The sink agents apply upserts and optional deletes.
8. The backend records success, warnings, retries, and failures for the website dashboard.

## Folder Structure

```text
.
|-- README.md
|-- frontend/
|   |-- lib/
|   |-- test/
|   `-- web/
|-- backend/
|-- business/
`-- sync_windows_agent/
    |-- lib/
    |-- test/
    `-- windows/
```

## What Each App Does

### `frontend`

Use this as the website that operators open in the browser.

Current UI supports:

- machine overview
- source PC selection
- sink PC selection
- table selection
- schedule selection, including every 5 minutes
- recent run history
- architecture guidance inside the UI

### `backend`

Use this as the upstream TRU runtime submodule. It contains the server,
tooling, tests, and TRU runtime source, but it should not contain this app's
custom business logic.

### `business`

Use this as the source of truth for backend `.tru` business logic, including the
app API and DB API for this project.

### `sync_windows_agent`

Use this as the installed Windows desktop app on each SQL Server host or trusted local machine.

Current UI supports:

- entering the website domain URL
- entering the local SQL Server instance and database
- toggling background/startup behavior
- selecting which tables are exposed for sync
- simulating manual sync and connection state
- viewing recent local agent activity

## How To Run

### Install SQL Server Management Studio

Install SSMS from Microsoft Learn: [Download SQL Server Management Studio (SSMS)](https://learn.microsoft.com/en-us/ssms/download-sql-server-management-studio-ssms?lang=en&view=sql-server-ver16&utm_source=openai)

### Web app

```bash
cd frontend
flutter run -d chrome
``` 

### Backend

```powershell
.\backend\run.ps1 -Server -ConfigPath ..\business\tru.json
```

### Windows app

```bash
cd sync_windows_agent
flutter run -d windows
```

## Practical Build Plan

### Phase 1: Control Plane and Agent UI

Status: done in this repo

- create separate Flutter web and Flutter Windows apps
- design responsive UI for plan management and agent configuration
- show source/sink/table selection workflow
- show sync history and agent activity

### Phase 2: Backend API and Authentication

Backend work lives on the TRU runtime in `backend/`, with project-owned API
logic in root `business/`.

### Phase 3: Real SQL Server Sync Engine

Implement in the Windows agent:

- secure local credential storage
- source-side change capture
- sink-side upsert and delete application
- retry logic and resumable batches
- conflict handling rules
- transaction-safe writes

Recommended SQL Server techniques:

- Change Tracking for light-weight deltas
- CDC if you need richer audit detail
- `rowversion` or `ModifiedAt` columns for custom delta logic
- primary keys on every synced table

### Phase 4: Deployment and Packaging

- publish the web app to your server domain
- package the Windows app for installer-based deployment
- add auto-start and background worker support
- add observability, alerts, and audit logging
- harden secrets and transport security

## Step-By-Step To Achieve The Full Product

1. Finalize the data model for agents, plans, and table mappings.
2. Build the backend API in `business/` that both Flutter apps will call.
3. Add agent registration and secure login.
4. Add machine heartbeat and online/offline tracking.
5. Add source/sink assignment APIs.
6. Add table discovery from the Windows agent.
7. Add SQL delta extraction from the source machine.
8. Add batch apply logic on sink machines.
9. Add a scheduler that runs every 5 minutes.
10. Add retry, audit logs, and admin alerts.
11. Package the Windows app into an installer.
12. Deploy the web app to the domain and connect both apps to the backend.

## Current Limitation

The Flutter apps in this repository are strong UI foundations, but they use mock
data today. The TRU backend is wired for health/readiness from `business/`, but
the full SQL sync API and DB flows still need to be implemented in the root
`business/` files.
