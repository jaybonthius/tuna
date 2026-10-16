# Service-operation advice

Merged `f6c6f58` (2026-10-16), containing `59148f6`. Parent source/boundary review found no blocker; independent capped full `make test` passed: 49 Gerbil modules, 12 frontend tests and demo check. Kernel delta0; production net +105 (95-line library, routing/export, build wiring). No shared combinator, descriptor, provider or startup changes.

## Public surface / inspector handoff

`advise!`, `unadvise!` and `advice-for` now accept `(service service-expression operation)`. The service expression is evaluated once; the operation is a named identifier and the service type binding is unchanged. Existing callback/kind/source normalization and function/command routes are reused.

The library `tuna/lib/service-advice.ss` exports `add-service-advice!`, `remove-service-advice!`, `service-operation-advice` and `advised-service-operations`; the last is also in the prelude. Enumeration returns neutral target snapshots for installed/pending operations in the current registry only: kind service, name slot/operation, source #f, stable state identity and outermost-first layers. Advisor source stays on each layer. Unknown inspection/removal caches nothing; identities remain stable for registered targets while their receipt buckets live. The inspector should combine this query with advised-functions and advised-commands, requerying by identity after completion yields.

## Behavior / proof

One opaque policy object per actual service slot retains its bound installer and operation states. Every qualified base is separately composed with that operation's shared records; no callback executes during construction. No records restores exact raw identity. Pending records survive no provider, missing operations and replacement with a different complete interface. No matching operation returns raw, not an unnecessary wrapper. Mutation/rank refresh does not change provider receipts/provenance/events or restart dependents. The original caller thread/task and shared context/error/value policy remain intact; real function advice stays inside service advice through redefinition.

Source/compiled fixtures and real Commands/Keys integration prove expression/type/name hygiene, named callback liveness, inline methods, values/checked results, qualified paths/recasts/raw state, two owners/operations, order/replacement/rank refresh, provider survival, three-cycle bounded receipts, cleanup, caller restoration/error/quits, and A's refresh while B is current without affecting B. Tests enumerate only actual current-registry policy state and ignore unrelated opaque values.

Worker report/failures: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/service-advice-report.md` and `service-advice-evidence/`. Parent log: `parent-service-advice-make-test.log` beside them. Earlier fixture/type/cleanup-expectation failures were repaired; neither final worker nor parent full test retried. No new timing claim: measured unadvised kernel path is unchanged.

Captured interfaces remain snapshots, provider self-calls are not intercepted, and replacement results must satisfy declared operation contracts. All three target kinds now work; inspector UI still lists functions until its next task.
