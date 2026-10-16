# Complete service-interface descriptions

Merged as `e7a39d0` (2026-10-16), containing `ee0e7f3` and qualified-dispatch fix `b126cc9`. Parent reviewed placement/generation and independently ran capped `make test`; passed (46 Gerbil modules, 12 frontend tests, demo check). ADR12 records the actual generic exports/fields and why they must sit below libraries. Production net +212; kernel net +211, including the 195-line generator.

## Consumer API

`service-interface` emits an ordinary interface, typed wrapper builder and its own explicit signature metadata. `service-interface-out` exports the ordinary interface bindings, `Type-service-view` and `Type-service-signatures` companion. Actual provider-interface declarations use this form; non-provider CompletionSession/Prompt/Job interfaces remain ordinary.

`service-view` has two read-only-by-convention fields: `operations` (deduplicated symbols) and `build` (procedure). Public accessors/constructor/predicate are `service-view-operations`, `service-view-build`, `make-service-view`, `service-view?`. `((service-view-build description) raw compose)` returns the selected complete interface and all ancestors. `compose(operation, base-procedure)` can be called more than once for the same operation, with different qualified base paths. The consumer must share advice records by operation but compose EACH supplied base separately; never collapse them by name.

## Parent correction

The first generator incorrectly called the derived implementation through a parent facade: raw Base-run returned `base`, identity-wrapped Base-run returned `extra-run`. Parent's one-chain-per-operation instruction was too restrictive. Red source/compiled proofs preceded the fix. Now every qualified path retains its own base, defaults, predicates, argument and checked return contract; advice still runs once per call. Independent parent repro now returns `base` through Base and `extra-run` through Extra both before/after wrapping.

Inherited dispatch identifiers are retained as ordinary bound syntax from the declaration site; no private Gerbil signature reflection, guessed internal method names, cache mutation or runtime discovery registry. Actual Keys/EchoArea integration and compiled Base/Extra/multiple-parent/diamond/default/rest/keyword/nullable/multiple-value/invalid-output proofs pass. Full failed-attempt history and worker logs: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/service-interfaces-report.md`; parent logs `parent-service-interfaces-make-test.log`, `parent-service-qualified-{probe,fixed}.log` beside it.

## Limits and next step

Only the explicitly declared complete interface and ancestors are preserved, not incidental capabilities. Foreign parents need generated companions; ordinary inherited type/default names must be in scope. Captured handles/provider self-calls are not interception points. This stage adds no registration argument, provider-cache field or actual service advice. Next: provider registration carries the complete description; a per-kernel slot caches the effective interface through a small opaque library-state/rebuild seam, leaving warm dispatch and raw provenance intact. Library policy/routing follows separately.
