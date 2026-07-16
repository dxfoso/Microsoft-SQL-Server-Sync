# Product

## Register

product

## Users

System administrators and database operators monitoring Microsoft SQL Server
replication across Windows clients. They use the control plane during active
operations and incident diagnosis, often scanning dense tables for current
state before taking an action.

## Product Purpose

Provide a reliable control plane for configuring clients, triggering and
monitoring multi-writer synchronization, inspecting per-client and per-table
logs, publishing client updates, and diagnosing failures. Success means an
operator can quickly understand what each client is doing and safely resolve
sync issues without inspecting raw infrastructure.

## Brand Personality

Precise, operational, and calm. The interface should communicate technical
confidence without hiding important state or adding decorative noise.

## Anti-references

Avoid marketing-style dashboards, oversized decorative metrics, ambiguous
status colors, novelty controls, excessive cards, and layouts that hide
operational details behind animation or modal flows.

## Design Principles

- Show current operational state before historical metrics.
- Make failures and pending work explicit and actionable.
- Keep dense information readable through consistent tables and controls.
- Preserve familiar administration patterns and predictable navigation.
- Prefer verified system truth over optimistic or inferred status.

## Accessibility & Inclusion

Target WCAG AA contrast and keyboard accessibility. Never communicate status
by color alone; pair semantic colors with explicit text and familiar icons.
Respect reduced-motion preferences and keep critical actions usable at desktop
and narrow viewport widths.
