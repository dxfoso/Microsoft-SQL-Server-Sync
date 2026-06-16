# Product

## Register

product

## Users

Administrators manage all accounts and the full sync topology from the web control plane. Server users own one SQL Server sync space and manage the client accounts under that server user. Clients are endpoint agents that upload their own unique rows to the server and receive copies of rows uploaded by other clients.

## Product Purpose

SQL Sync Control Plane gives operators a clear operational view of server users, clients, databases, tables, row movement, and sync health. Success means an admin can manage users quickly, and a server user can open a database, inspect its tables, and see which clients are syncing with each other without hunting through unrelated screens.

## Brand Personality

Calm, precise, operational. The interface should feel like a dependable infrastructure tool: dense enough for repeated use, direct in its labels, and restrained in visual treatment.

## Anti-references

Avoid marketing-style hero pages, decorative dashboard cards, unclear role names, and navigation that mixes account management with sync inspection. Avoid over-coloring inactive states or hiding operational data behind large empty visual treatments.

## Design Principles

Use role-first navigation so each user type lands on the work they are allowed to do.
Rename owner-facing concepts to server user language everywhere the web UI exposes that role.
Make database to table to client sync relationships visible in one predictable drilldown.
Keep controls compact, readable, and consistent for daily operations.
Treat empty, loading, and disconnected states as operational states with clear next actions.

## Accessibility & Inclusion

Target WCAG AA contrast for text and controls. Preserve keyboard-reachable controls, visible focus states, reduced-motion friendly interactions, and responsive layouts for narrow admin screens.
