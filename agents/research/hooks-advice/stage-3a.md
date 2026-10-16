# Shared advice target seam

Merged as `af16541` (2026-10-15), containing `5aaf7fc` and hygiene fix `f2c8d68`. Parent reviewed the production diff and independently ran capped `make test`; it passed without retry. Actual command/service targets are not implemented by this stage.

## Shared API

`new-advice-state kind name source changed` owns records, ordering and receipts. Its change callback receives installed outermost-first records; target owners rebuild caches with `compose-advice`, which returns the exact base for an empty chain. `advice-state-records` supports rebuilding when a target definition/provider changes. Registration/removal/inspection use `register-advice!`, `remove-advice!`, `inspect-advice`; configuration rank batches call `refresh-advice!`.

Public inspection names are now `advice-for` and `advice-target-info`, with kind, name, source, stable identity and installed layers. Every current consumer was migrated, without aliases. `advised-functions` remains function-only; the inspector still honestly lists functions only.

`(command NAME)` routes through a macro imported under the canonical `command-advice-target` name. The prelude imports no concept contract. The contract must implement `(command-advice-target add: ctx 'NAME advice-name kind callback source: source options ...)`, `(command-advice-target remove: ctx 'NAME advice-name)`, and `(command-advice-target inspect: 'NAME)`. Automatic router-import renaming is not supported. Service routing is deferred.

## Review and validation

Parent review found that caller-local `add`, `remove` and `inspect` bindings captured the initial identifier control tokens. The worker reproduced all three failures in source and separately compiled callers before replacing them with unbindable keyword controls. Source, compiled routing, private-function, callback-liveness, tail-call and recompilation proofs pass after the fix. All ten combinators and open-function call generation remain unchanged.

The final worker suite and independent parent suite passed: 43 Gerbil modules, 12 frontend tests and demo configuration check. Parent log: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/parent-shared-make-test.log`. Full worker report, including earlier syntax/test-invocation failures and the expected-red hygiene evidence: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/shared-report.md`.

Production changes are limited to advice library, prelude, startup rank-refresh name and inspection consumer: net +45 lines. Kernel delta zero. No new per-call work, runtime scope API, target-discovery registry or interface reflection. Commands and service writers must reuse this state and composition mechanism; their actual registries own enumeration and execution/cache boundaries.
