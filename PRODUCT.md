# Product

## Register

product

## Users

SQL administrators and sync operators use the Windows agent and web control plane to inspect SQL Server databases, configure synchronized tables, and monitor client status.

## Product Purpose

Microsoft SQL Server Sync keeps selected SQL Server tables synchronized across Windows clients through a central control plane. The primary workflow is reliable database/table selection followed by clear sync monitoring and recovery.

## Brand Personality

Trustworthy, direct, operational. The interface should reduce repeated setup work and make the current sync context obvious.

## Anti-references

Do not make users repeatedly reselect a valid database after reopening or refreshing the app. Do not silently restore a database that is no longer available.

## Design Principles

- Preserve valid user context across sessions.
- Scope saved choices to the authenticated user.
- Prefer deterministic, visible fallbacks when saved context is unavailable.
- Keep Windows and web behavior consistent.

## Accessibility & Inclusion

No special requirements were identified beyond standard accessible controls and readable existing UI patterns.
