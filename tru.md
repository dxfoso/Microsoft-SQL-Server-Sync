# TRU Server Gaps Found During Sync Verification

## Required TRU Server Features

### Compiler and runtime symbol parity

The TRU release compiler must reject function or namespace calls that the
runtime cannot resolve.

Confirmed failure:

```tru
bool.from(bypassCooldown)
```

This passed the release compilation gate, but production execution failed with:

```text
runtime error (function auto_sync_tick): undefined variable: bool
```

Required behavior:

- If `bool.from` is unsupported, compilation must fail with an undefined symbol
  diagnostic and the exact source location.
- If boolean conversion is intended to be supported, `bool.from` must be
  implemented consistently in both the compiler and runtime.
- Built-in namespaces and functions must come from one shared registry so the
  compiler cannot accept symbols missing from the runtime.

Current safe workaround:

```tru
bypassCooldown != true
```

### Executable release validation

Syntax and type compilation alone did not detect the undefined runtime symbol.
The TRU server needs an optional release-validation mode that executes selected
functions against an isolated or rolled-back database context.

The validation should support:

- A list of smoke-test function names and arguments in `tru.json`.
- Authentication setup for protected functions.
- Transaction rollback or an isolated temporary database.
- Failure on runtime errors, unresolved symbols, invalid built-in calls, or
  unexpected return payloads.
- Machine-readable results suitable for CI and deployment health gates.

For this repository, `auto_sync_tick` should be included because it exercises
the scheduler path that compilation alone did not validate.

### Runtime diagnostics in the compile gate

`/admin/health` correctly reported `compile_errors=0` even though the deployed
function contained a runtime-only unresolved symbol. The health contract should
distinguish these states:

- `compile_errors`: source compilation failures.
- `startup_smoke_errors`: failures from configured executable validation.
- `runtime_errors`: recent production function failures.

Deployment readiness should be false when a required startup smoke test fails.

## What Did Not Work

### `bool.from(...)`

This approach did not work at all in the current TRU runtime. It compiled but
failed every scheduler invocation before any sync work could be queued.

Impact:

- Kubernetes scheduler jobs failed.
- Deferred Sync All tables stopped draining.
- The failure was visible only after executing the function in production.

Resolution in this repository:

- Replaced `bool.from(bypassCooldown)` with `bypassCooldown != true`.
- Added a contract test that rejects `bool.from(` in this scheduler function.
- Captured scheduler runtime errors during live deployment verification.

## Repository-Level Safeguards

Until TRU provides compiler/runtime parity and executable release validation:

1. Avoid unverified built-in conversion namespaces.
2. Follow boolean comparison patterns already used by compiled production TRU
   files.
3. Add contract tests for previously observed runtime-only failures.
4. Execute critical scheduled functions after deployment.
5. Require successful cron output, `ready=true`, and `compile_errors=0` before
   treating a release as healthy.
