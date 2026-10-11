# Gerbil v19 Emacsen Runtime — Corrected Source Review

## Decision

**Do not put every Gerbil binding behind an application box/registry.** That duplicates Gerbil’s mutable global bindings and v19 MOP dispatch, impedes optimization, and adds identity/lifecycle machinery without providing isolation.

The Gerbil-v19-idiomatic architecture is:

1. **Stable kernel modules and long-lived objects** own buffers, windows, editor state, protocol classes/interfaces, event loops, and resource identity.
2. **Reloadable separately compiled or interpreted modules** install ordinary functions and rebind methods against stable classes.
3. Use **one small stable registry/generation pointer at externally captured boundaries**—commands, hooks, timers, keymaps, plugin entry points—not per definition.
4. Keep reloadable editor code out of **full-program optimization (FPO)** and treat `-O` cross-module optimization cautiously.
5. For atomic upgrades, load implementations under distinct generation identities, validate them, then switch the stable boundary. Gerbil has no Racket-like fresh namespace/module-registry isolation or rollback facility.

If universal Emacs `symbol-function` semantics are mandatory—every previously captured callable must follow redefinition—per-binding trampolines implement a feature Gerbil does not natively guarantee. They are then intentional, not idiomatic ordinary Gerbil.

## Attestation

- Reviewed tree: `/home/jay/Code/workbench-gerbil/gerbil`
- `git describe`: `v0.19-dev-31-g4a4d1a30-dirty`
- `/opt/gerbil`: `Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369`
- Dirty files were generated Gambit C sources:
  - `src/gambit/lib/_kernel.c`
  - `src/gambit/lib/_module.c`
  - `src/gambit/lib/_num.c`
- No `/home/jay/Code/gerbil` source was used.

## Findings

| Severity | Finding |
|---|---|
| **High** | Gerbil’s reload facilities mutate a process-global expander/runtime environment. They do not provide Racket-style isolated module registries, staged instantiation, or rollback. |
| **High** | FPO is incompatible with a general live-redefinition contract: dependencies are included together under Gambit `(block)`, optimized and tree-shaken. Reloadable editor code should remain separately compiled/interpreted. |
| **High** | Reload is non-transactional. Module initialization and global redefinitions occur while evaluating/loading the replacement; failure can leave shared state or bindings partially changed. |
| **Medium** | Ordinary global rebinding should not be strengthened into a promise that all optimized same/cross-module calls follow reload. `-O` has cross-module optimization metadata and FPO can inline/tree-shake definitions. |
| **Medium** | A captured procedure or `bound-method-ref` remains the captured procedure. Use a stable trampoline only where old callbacks must follow the current generation. |
| **Medium** | Reloading a state-owning module reruns its definitions and can replace state identity. State placed in an unchanged imported module/object remains the appropriate stable identity seam. |
| **Medium** | v19 removed `std/generic`; the supported generic object protocol is the core MOP/classes/interfaces. MOP method rebinding explicitly flushes specialization caches and has REPL-development handling. |
| **Low** | `std/interactive` reload is development tooling implemented partly at macro-expansion time, not a production generation manager. |

## Concrete v19 behavior

### Evaluation and imports

`__load-gxi` installs the compiler, expander and evaluator, imports the core module, and hooks Gambit expansion:

- `gerbil/src/gerbil/runtime/init.ss:11-33`

Runtime imports compile to a call to `__eval-import`:

- `gerbil/src/gerbil/runtime/eval.ss:85-88`

`__eval-import`:

- walks phase-adjusted imports;
- evaluates only phase-zero runtime contexts;
- serializes concurrent forcing;
- caches `forcing`, `ready`, or `error` **by module-context identity**.

Evidence:

- `gerbil/src/gerbil/runtime/init.ss:123-190`

This means a previously evaluated context is instantiated once, but a forced reload creates a new context and therefore may run the module body again.

### Expander reload

`import-module` delegates to the current importer and optionally evaluates the returned context:

- `gerbil/src/gerbil/expander/module.ss:93-100`

Without `reload?`, `core-import-module` returns the context cached in the global module registry. With `reload?`, it rereads, re-expands and installs a newly created context under the same path and module ID:

- `gerbil/src/gerbil/expander/module.ss:139-179`
- `gerbil/src/gerbil/expander/module.ss:196-209`

There is no namespace argument or independently selectable registry comparable to Racket’s namespace/module registry.

### Runtime loader

The compiled runtime loader has one global `__modules` table and load-order table:

- `gerbil/src/gerbil/runtime/loader.ss:11-16`

`load-module` loads a module once, synchronizes concurrent loads, and permanently caches success or failure:

- `gerbil/src/gerbil/runtime/loader.ss:32-73`

`reload-module!`:

- rejects builtin modules;
- retries failed modules;
- reloads source `.scm` modules;
- reloads when resolution selects a different/new compiled object;
- otherwise leaves the current compiled object installed.

Evidence:

- `gerbil/src/gerbil/runtime/loader.ss:75-105`
- object/source lookup: `gerbil/src/gerbil/runtime/loader.ss:107-115`

This is replacement in a shared process, not a generation-isolation primitive.

### Interactive reload

For a file path, `std/interactive` calls `import-module` with both reload and evaluation enabled. For a library symbol it reloads runtime modules by original load order and then reimports the source context:

- `gerbil/src/std/interactive.ss:10-26`
- `gerbil/src/std/interactive.ss:28-46`

`reload!` performs this work in its syntax transformer and expands to a new import:

- `gerbil/src/std/interactive.ss:49-63`

`enter!` simply starts a nested REPL parameterized with the module’s expander context:

- `gerbil/src/std/interactive.ss:82-88`

These utilities optimize REPL convenience, not validation, atomic switching, rollback, or resource retirement.

## Compilation constraints

Separate compilation is the default executable path:

- dispatcher: `gerbil/src/gerbil/compiler/driver.ss:169-174`
- separate executable stub/runtime initialization: `gerbil/src/gerbil/compiler/driver.ss:174-186`
- documentation: `gerbil/doc/guide/intro.md:1289-1308`
- build guide: `gerbil/doc/guide/getting-started.md:324-334`

FPO includes dependencies together under a reset declaration containing:

- `(block)`
- `(inline)`
- constant folding and lambda lifting;
- dead-local and dead-definition elimination.

Evidence:

- `gerbil/src/gerbil/compiler/driver.ss:345-366`
- dependency inclusion begins at `gerbil/src/gerbil/compiler/driver.ss:368-383`
- documented invocation and trade-off: `gerbil/doc/guide/intro.md:1275-1308`

Compiler “blocks” around `begin-syntax` are generated phase-runtime modules loaded through `load-module`; they are not independent application generations:

- `gerbil/src/gerbil/compiler/compile.ss:1258-1298`
- block bookkeeping: `gerbil/src/gerbil/compiler/compile.ss:1500-1547`

**Consequence:** use separate compilation for the live editor. FPO should be reserved for sealed deliverables that do not promise live code replacement. Ordinary `-O` is less absolute, but cross-module inlining/specialization means hot seams should remain explicit and receive dedicated optimized-build tests.

## MOP and the removal of `std/generic`

The v19 cumulative diff from `v0.18.2` deletes:

- `src/std/generic.ss`
- `src/std/generic/dispatch.ss`
- `src/std/generic/macros.ss`
- `src/std/generic/generic-test.ss`

Core MOP classes hold mutable method and specialization tables:

- `gerbil/src/gerbil/runtime/mop.ss:26-33`

Normal method calls resolve through the object’s current class:

- `call-method`: `gerbil/src/gerbil/runtime/mop.ss:995-1021`
- `method-ref`: `gerbil/src/gerbil/runtime/mop.ss:1023-1029`
- method lookup: `gerbil/src/gerbil/runtime/mop.ss:1045-1088`

A `bound-method-ref` creates a closure over the method found at capture time:

- `gerbil/src/gerbil/runtime/mop.ss:1031-1043`

`bind-method!` invalidates specialization caches, propagates invalidation to subclasses, and clears interface tables when explicitly rebinding “to support repl development”:

- `gerbil/src/gerbil/runtime/mop.ss:1090-1133`

Therefore:

- Existing objects can use newly rebound methods when calls perform fresh method lookup.
- Already captured bound methods remain old.
- Stable protocol class identity should live in the unreloaded kernel.
- Redefining the class itself is not a migration strategy for existing objects.

## Architecture recommendation

### Stable kernel

Never reload modules owning:

- buffers/documents and their identity;
- window/display/event-loop state;
- protocol classes and interfaces;
- persistent parameters and services;
- command/hook/keymap registry;
- generation manager and logging.

Keep their import graph small so reloadable implementation code does not become part of the stable layer.

### Reloadable implementation

For each reload:

1. Expand/load replacement implementation without FPO.
2. Produce an explicit manifest of commands, hooks and supported protocol methods.
3. Validate it before publishing.
4. Rebind MOP methods on stable classes where object dispatch is appropriate.
5. Atomically switch one immutable command/hook generation snapshot.
6. Reject or drain callbacks belonging to the old generation.
7. Explicitly stop old threads, timers, ports and watchers.

Gerbil supplies no custodian equivalent; resource ownership and shutdown must be application-level.

### Indirection policy

Use:

- ordinary function calls inside a generation;
- MOP dispatch for behavior belonging to stable object protocols;
- one registry lookup/trampoline at externally retained callback boundaries.

Avoid:

- one box for every function/value;
- reloading modules that own persistent state;
- assuming source reload is transactional;
- FPO for the live editor;
- retaining raw implementation procedures in long-lived timers/hooks when they are expected to follow reload.

## Comparison with the Racket result

The Racket recommendation used fresh namespaces/module registries plus `namespace-attach-module` to share only stable state. That allows old and new optimized generations to coexist and makes failed new instantiation less destructive.

Gerbil v19 differs materially:

| Concern | Racket v9.2 | Gerbil v19 |
|---|---|---|
| Native generation isolation | Fresh namespace/module registry | No corresponding public facility found |
| Stable shared state | `namespace-attach-module` | Unreloaded global module/object |
| Reload | Module redeclaration or new registry | Replace expander context/load object in global registries |
| Failure containment | New namespace preserves old declarations | Shared global evaluation/loading; no rollback |
| Captured procedures | Remain old | Remain old |
| Dynamic protocol updates | Class/generic instances normally generation-bound | MOP can rebind methods on stable classes and flush caches |
| Production optimization | Fresh generations retain normal optimization | Live code should avoid FPO; optimized hot seams require verification |
| Resource retirement | Custodians | Application-managed ownership/shutdown |

Thus the Racket “fresh generation plus attached state” design cannot be copied literally. In Gerbil, the closest robust design is **unique implementation generations plus an explicit stable publication boundary**, while keeping protocol/state identity in unchanged modules.

## Relevant changes since `v0.18.2`

Relevant commits touching the reviewed areas include:

- `79725228` — **v0.19 development staging (#1393)**: major MOP rewrite and runtime/compiler changes; cumulative v19 tree removes `std/generic`.
- `650f7bf9` — **v0.19 abstract evaluation pass (#1433)**: substantial optimizer changes plus MOP adjustment.
- `d75eb411` — **v0.19-fixes (#1470)**: further MOP fixes.
- `f9f69c63`, `416a5cf2`, `c1603c3e`, `694265b1`, `0c276b3b`, `974a420d`, `b907c7dc` also touch compiler/MOP paths through their feature work.

The important architectural change is the v19 consolidation around the core MOP and removal of the separate `std/generic` subsystem—not the addition of a new isolated reload mechanism.

## Probe result and residual uncertainty

A bounded fixture was created at:

- `/tmp/gerbil-v19-emacsen.irfAWG`

The normal, `-O`, and FPO attempts did **not** produce semantic results because the disposable fixture used invalid relative import forms:

- source run: `cannot resolve relative module path; not in module context`
- optimized/FPO compilation: `cannot find library module ... :state`

Consequently, this review does **not** claim fixture verification for:

- same/cross-module optimized rebinding;
- captured procedure results;
- persistent state identity;
- FPO `__eval-import` behavior.

The source-level facts and architecture decision remain high confidence; exact optimized rebinding behavior is a material unresolved test gap.

### Focused validation commands

Evidence-backed compiler modes from the v19 guide:

```sh
/opt/gerbil/bin/gxi -v
/opt/gerbil/bin/gxc -O -exe -o <output> <main.ss>
/opt/gerbil/bin/gxc -O -full-program-optimization -exe -o <output> <main.ss>
```

A corrected fixture should use resolvable package/library module IDs, compile once with separate `-O`, rebuild the dependency to a newer `.oN`, call `reload-module!`, and assert:

- direct current call;
- same-module caller;
- cross-module caller;
- saved procedure;
- saved caller;
- stable imported state `eq?`;
- state defined in the reloaded module not `eq?`.

No evidence-backed full repository validation command was established during this bounded review.

## Confidence

- **High:** global registry architecture, eval/import context caching, loader behavior, interactive reload flow, separate/FPO distinction, MOP rebinding, and `std/generic` removal.
- **Medium-high:** recommended stable-kernel/MOP/boundary-registry architecture.
- **Medium:** ordinary unoptimized global rebinding follows reload.
- **Low/unverified:** behavior of all `-O` same/cross-module call shapes and FPO runtime eval against blocked/tree-shaken definitions.