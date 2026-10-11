# Racket v9.2 as an Emacsen Runtime

## Conclusion

**Racket is a strong runtime for a long-lived programmable editor, but ordinary compiled Racket modules do not provide Emacs-style universal late-bound function cells.**

The most Racket-idiomatic architecture is:

1. A **stable kernel and state-service module instance** owns buffers, UI identity, persistent data, protocol structure types, commands, and hooks.
2. Reloadable code is loaded as a **new generation in a fresh namespace/module registry**, under a child **custodian**.
3. `namespace-attach-module` shares only the stable API/state instance with that generation.
4. The new generation is validated before a stable dispatcher switches to it.
5. Old resources are shut down through their custodian; old code is collected once no callbacks or objects retain it.

Namespaces/modules provide the native **loading, isolation, and lifecycle seam**. Units/signatures can strengthen component interfaces, but do not themselves redirect existing calls. A stable registry, cell, dispatcher, or actor/event-loop message remains appropriate at the final hot-swap boundary. Boxes are not required per definition, but some explicit indirection is necessary when already-captured callbacks must follow redefinitions or when a generation must be switched atomically.

Same-registry `dynamic-rerequire` is useful for interactive development, but is too non-transactional and optimization-sensitive to be the primary production reload mechanism for a large editor.

## Attestation and scope

- Runtime: **Racket v9.2 [CS]**, Chez target `ta6le`.
- Primary evidence: installed v9.2 Scribble sources, tagged v9.2 Racket source, and disposable `/tmp` fixtures.
- The repository prototype was treated only as a small runtime experiment; DSL convenience was not evaluated.
- Labels below:
  - **Verified-doc/source**: stated by official v9.2 documentation or implementation.
  - **Verified-fixture**: reproduced locally on v9.2.
  - **Assessment**: architectural inference from those results.

## Findings

| Severity | Finding |
|---|---|
| **High** | Ordinary compiled module definitions are constants unless mutation is visible or constant enforcement is disabled. They may be inlined within and across modules and cannot normally be redefined through `module->namespace` or module redeclaration. |
| **High** | A normal `.zo` compiled by `raco make` can prevent later `dynamic-rerequire`: the initial constant binding remains non-redefinable. `raco make --disable-constant` avoids this, at an optimization cost. |
| **High** | `dynamic-rerequire` is not transactional. It reloads dependencies before dependents; a later initialization error can leave a mixture of new dependency bindings and old dependent state. |
| **High** | `playground/racket/runtime.rkt:68-69` uses `dynamic-require`, not `dynamic-rerequire`. Reusing the same customization module path is therefore a no-op after its first instantiation. The demonstration instead loads two distinct paths at `playground/racket/main.rkt:7-8,23-26`. |
| **High** | Reloading `lib.rkt` itself through module redeclaration would rerun registration and conflict with the duplicate checks at `playground/racket/runtime.rkt:19-26`; the prototype is a customization-loader, not a general application reloader. |
| **Medium** | Mutable module locations update ordinary same-module and imported calls, but a procedure value captured before redefinition remains the old procedure. Stable trampoline procedures or registries are needed if captured callbacks must follow updates. |
| **Medium** | Reloaded module bodies rerun initialization and can overwrite state. Persistent state must live in an unchanged/attached stable instance, external storage, or undergo explicit migration. |
| **Medium** | `namespace-attach-module` transitively attaches same-phase imported instances. A “stable API” module that imports unstable implementation code can accidentally share much more than intended. |
| **Medium** | Units, class methods, and generic methods provide excellent extension contracts and dispatch, but existing unit instances, objects, structure instances, and captured methods do not automatically migrate to a redeclared implementation. |
| **Medium** | Official runtime introspection is useful but not image-browser-complete: known modules and namespace bindings can be inspected, while the module registry itself is opaque and stack information is explicitly approximate. |

## Runtime semantics

### Modules, declarations, instances, and ordinary calls

A module may be declared without executing its definitions. `require` or `dynamic-require` instantiates it, creating module variables, once per registry and phase. See the official [module declaration/instance model](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/eval-model.scrbl#L517-L557).

A declaration and an instance are therefore distinct:

- The declaration contains compiled module code.
- The instance contains the phase-specific variable locations and initialization effects.
- A fresh namespace normally has a fresh module registry and gets fresh instances.
- Two namespaces can share an instance through `namespace-attach-module`.

Ordinary optimized calls are not uniformly late-bound. When a definition has no visible `set!`, the compiler can mark it constant, inline it, and prohibit reflective assignment or redeclaration. Official source: [`compile-enforce-module-constants`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/eval.scrbl#L646-L681).

If a binding is intentionally mutable—either through visible `set!` or compilation with constants disabled—compiled references use its module location:

- Existing same-module functions can see its new value.
- Existing importing functions can see its new value.
- A procedure value copied out of the location remains the old object.
- An old function that itself reads the mutable location can observe the update.

This permits selective native indirection without boxing every call, but it requires deliberately marking hot bindings mutable.

### `eval` and `module->namespace`

`eval` operates in a namespace, not arbitrary lexical locals. `module->namespace` exposes an instantiated module body for evaluation; changing a mutable binding there changes what requiring modules see. Constants and code-inspector authority still apply. Official source: [`module->namespace`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/namespaces.scrbl#L384-L410).

This is useful for:

- REPL exploration;
- emergency inspection and repair;
- evaluating new internal definitions;
- redefining bindings explicitly compiled as mutable.

It is not a transparent, optimization-preserving substitute for application-wide source reload.

### Module redeclaration

On redeclaration, matching definitions assign into the old variable locations; removed definitions continue to exist but disappear from the new module lexical information. An already-instantiated module is immediately instantiated again. Cross-phase-persistent modules cannot be redeclared, and constants can make redeclaration fail. Official source: [module redeclarations](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/eval-model.scrbl#L804-L827).

Consequences:

- Existing variable references can follow a replacement.
- Captured values do not.
- Removed bindings can remain reachable as “ghost” state.
- Module initialization effects rerun.
- Cross-phase persistence is a restricted phase-identity mechanism, not an application-state persistence feature.

### `dynamic-require`

`dynamic-require` instantiates a module only if it is not already instantiated in the current registry. It can retrieve a named export, but repeating it does not reload the file. Concurrent loads into a shared registry can race unless coordinated with `namespace-call-with-registry-lock`. Official source: [`dynamic-require`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/module-reflect.scrbl#L547-L607).

### `dynamic-rerequire`

`dynamic-rerequire` records modification times and import dependencies for modules first reached through it. A changed dependency causes dependent modules on the route to the requested root to be redeclared. Official documentation: [Loading and Reloading Modules](https://docs.racket-lang.org/reference/interactive.html), pinned [v9.2 source](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/rerequire.scrbl#L8-L27).

Its implementation:

- installs a custom load handler;
- compiles source with `compile-enforce-module-constants` set to `#f`;
- records imports from compiled code;
- recursively reloads dependencies before dependents;
- uses a strict timestamp `>` comparison.

See [`racket/rerequire.rkt:20-107,130-189`](https://github.com/racket/racket/blob/v9.2/racket/collects/racket/rerequire.rkt#L20-L107).

Constraints for a large application:

1. All reloadable modules must initially be reached through `dynamic-rerequire`.
2. Modules previously loaded normally are not generally brought under its reload tracking.
3. Dependents rerun initialization, potentially across a large graph.
4. Reload is not atomic or rolled back on failure.
5. Same-second changes, clock rollback, or copied older timestamps can be missed because the source compares timestamps strictly.
6. A normal precompiled `.zo` may have constants enforced. Its first instantiation can therefore block later source redeclaration even though newly compiled source uses constants-disabled mode.
7. Development `.zo` files intended for this workflow must be produced with `raco make --disable-constant`; official option semantics are at [`raco/make.scrbl:52-58`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/raco/make.scrbl#L52-L58).

### Fresh namespaces and attached state

`namespace-attach-module` copies an existing module instance, together with same-phase transitive imported instances, into another registry. It does not instantiate a new copy. Official source: [`namespace-attach-module`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/namespaces.scrbl#L272-L318).

This is the strongest native seam for reloadable editor generations:

- The stable state/API instance preserves object identity.
- Each generation loads ordinary optimized modules into a separate registry.
- Identical source paths can have old and new declarations active simultaneously.
- Failure while loading the new generation does not redeclare the old generation.
- Ordinary production `.zo` optimization remains available.
- Old generations remain callable through old references until explicitly retired.

It is not complete isolation: attached state is genuinely shared, and plugin initialization can mutate it before validation. Staging APIs should therefore limit mutation, or state changes should use an explicit transaction/migration protocol.

### Captured references and boxes

The fixtures distinguish three cases:

1. **A later variable lookup** sees a replaced mutable module location.
2. **A captured procedure value** remains old.
3. **A captured stable wrapper** that dereferences a box or registry remains live.

The current prototype deliberately implements case 3:

- Function cells and value cells: `playground/racket/runtime.rkt:12-13,44-66`.
- Function wrapper dereferences on every call: `playground/racket/runtime.rkt:71-85`.
- A saved `greeting` wrapper therefore follows customization changes.
- A saved `site-name` value remains the old copied string, demonstrated by `playground/racket/main.rkt:19-26`.

Thus boxes are not necessary merely to make module calls reflect mutable locations. They are useful when the public object handed to clients must remain stable while its implementation changes.

### Parameters

Parameters are dynamically scoped, thread- and continuation-aware cells. New threads inherit the creator’s parameterization; direct assignment changes only the current thread’s cell. Official source: [`parameters.scrbl:12-31`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/parameters.scrbl#L12-L31).

Use them for ambient context such as:

- current buffer/window;
- current command transaction;
- current generation or logger;
- temporary permissions and load context.

They are not a global hot-redefinition mechanism. Redefining a module binding to a new parameter creates a new parameter object, while old threads and captured references can retain the old one. Long-lived parameters belong in the stable kernel.

### Units and signatures

Units are separately compilable, linkable components whose imports and exports are grouped by signatures. Official source: [Units](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/units.scrbl#L20-L29).

They are well suited to:

- editor subsystem interfaces;
- test substitution;
- loading a plugin component against explicit capabilities;
- checking that a generation supplies required operations.

They are not a transparent hot-patching mechanism. Unit exports cannot be `set!` from the unit or its importer (`units.scrbl:69-76`), and replacing a unit value affects only future linkage/invocation. Existing exported values still need a generation pointer, dispatcher, or reinvocation.

### Generic interfaces and classes

`racket/generic` associates per-structure-type methods with generic functions; dispatch locates a specialization from the instance. Official source: [`define-generics`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/generic.scrbl#L9-L70).

Racket classes similarly provide runtime `send`, interfaces, mixins, and method tables. These are natural extension protocols, but:

- Existing structures retain their structure type and method property.
- Existing objects retain their class and method table.
- Redefining a class, structure type, or generic implementation normally affects newly created values.
- Fresh namespaces create generation-specific type identity unless the protocol/type-defining module is attached from the stable kernel.

Stateful old objects therefore require migration, replacement, or an explicit forwarding layer.

## Recommended Emacsen architecture

### Stable kernel

Keep these in modules that are never source-redeclared:

- buffer and document state;
- window/editor eventspace;
- protocol structures, generic interfaces, and unit signatures;
- logging and diagnostics;
- command/hook/keymap registry;
- generation manager;
- persistent parameters;
- state migration API.

Keep this layer’s import graph small and stable so attaching it does not transitively attach reloadable implementation modules.

### Reloadable generation

For each load or reload:

1. Create a child custodian.
2. Create a fresh base-empty namespace/module registry.
3. Attach the stable protocol/state module instance.
4. Load the extension root with `dynamic-require`.
5. Retrieve and validate an explicit export/manifest, unit, or capability object.
6. Perform migration or staged registration.
7. On the stable editor event thread, switch an immutable registry snapshot or generation handle.
8. Stop accepting callbacks from the old generation, then shut down its custodian.

The stable command/hook entry should be a small trampoline keyed by command identity. Generation-internal calls remain ordinary optimized calls; only extension boundaries pay registry indirection.

### Custodians and eventspaces

Custodians own threads, ports, sockets, and GUI eventspaces created under `current-custodian`; shutdown closes or kills those resources. Official source: [`custodians.scrbl:18-66`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/custodians.scrbl#L18-L66).

Eventspaces provide a handler thread and callback queue. `queue-callback` schedules work on the current eventspace. Official source: [`eventspace-funcs.scrbl:6-56,151-160`](https://github.com/racket/gui/blob/v9.2/gui-doc/scribblings/gui/eventspace-funcs.scrbl#L6-L56).

The main editor GUI/eventspace should normally remain stable. Extension-owned worker threads, ports, timers, and optional auxiliary eventspaces should be created under the generation custodian. Custodian shutdown does not undo writes to attached state and cannot reclaim an old generation while external references still retain it.

## Materially different options

| Option | Advantages | Costs and risks |
|---|---|---|
| **Same registry + `dynamic-rerequire`** | Best REPL ergonomics; existing mutable module references update; `enter!` support. | Constants-disabled development build, broad reinitialization, stale captures, timestamp tracking, non-transactional failure, poor production lifecycle. |
| **Fresh namespace generations + attached stable state** | Failure containment, ordinary optimization, simultaneous old/new code, explicit type/state identity, clean lifecycle boundary. | Requires a generation manager, careful attachment graph, migration, and callback retirement. |
| **Units/signatures in one namespace** | Strong component contracts and dependency injection. | No unload, transaction, or automatic redirection of existing exports; best used inside either generation strategy. |
| **Explicit cells/registries only** | Closest to Emacs symbol-function semantics; stable captured trampolines; simple command replacement. | Manual lifecycle and validation; every hot dispatch is indirect; does not isolate module declarations or resource ownership. |
| **Places/processes** | Stronger failure and memory isolation. A place is effectively a separate VM with place-channel communication. | No shared live heap/state identity; reload must be broadcast and state serialized. Better for untrusted/heavy workers than the editor’s central live image. |

The recommended design combines fresh namespace generations with a small stable registry rather than choosing modules or registries exclusively.

## Live image, recovery, and observability

### Live image

Racket supports a genuinely long-lived heap with mutable state, threads, continuations, namespaces, eventspaces, and dynamically loaded code. It does not expose the whole application as a universally late-bound mutable global image, nor does the reviewed core provide an Emacs/Smalltalk-style heap-image persistence mechanism.

### Error recovery

Racket exceptions and custodians support supervisor-style recovery, but module initialization is arbitrary code:

- Same-registry rerequire can partially update bindings.
- Fresh-generation failure preserves the old registry/declaration generation.
- Shared-state writes still require transaction or migration discipline.
- Resource cleanup is strongest when all generation resources are created under its custodian.

### Runtime observability

Available facilities include:

- `module-declared?`, `module->imports`, and `module->exports`: [`module-reflect.scrbl:678-752`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/module-reflect.scrbl#L678-L752).
- `namespace-mapped-symbols`, `namespace-variable-value`, `module->namespace`.
- `custodian-managed-list` for resources under an authorized superior custodian.
- structured logging and exception continuation marks.
- `continuation-mark-set->context`, explicitly documented as approximate and unsuitable for reliable programmatic stack analysis: [`cont-marks.scrbl:225-246`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/cont-marks.scrbl#L225-L246).
- `racket/trace`, statistical profiling, Errortrace, DrRacket debugger, macro stepper, expansion and compiled-code inspection.

Limitations:

- Normal compilation allows inlining that loses stack frames unless context preservation is enabled.
- Errortrace is explicitly “not a complete debugger” and requires source instrumentation or specially compiled `.zo` files: [`errortrace.scrbl:10-15,75-89`](https://github.com/racket/errortrace/blob/v9.2/errortrace-doc/errortrace/scribblings/errortrace.scrbl#L10-L15).
- The module registry API exposes identity and locking, not general enumeration.
- DrRacket debugging is instrumentation/rerun oriented rather than a production process attach facility.

## Loading and security

In-process extension code should be considered trusted unless deliberately constrained.

- Security guards mediate primitive file and network access; already-open ports remain usable until closed or their custodian is shut down. Official source: [`security-guards.scrbl:12-28`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/security-guards.scrbl#L12-L28).
- Code inspectors control access to protected/private module bindings and redefinition authority; they are not a general side-effect sandbox.
- `racket/sandbox` provides evaluators with time, memory, filesystem, network, namespace, and load restrictions: [`sandbox.scrbl:10-18`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/sandbox.scrbl#L10-L18).
- Module paths should be resolved against approved roots rather than ambient `current-directory`.
- For hostile plugins, a place, subprocess, or OS sandbox is preferable to a shared-state namespace.

## Compiled and distributed behavior

- v9.2 CS defaults to target-specific compiled code (`ta6le` here). Setting `current-compile-target-machine` to `#f` produces machine-independent `.zo` code, with additional target compilation cost at load time. Official source: [`eval.scrbl:683-715`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/eval.scrbl#L683-L715).
- A fresh-generation architecture can use normally optimized compiled modules because it does not redeclare constants in the old registry.
- A same-registry development reload build must avoid normal constant inference.
- Dynamic references are not automatically visible to build/distribution dependency discovery. `define-runtime-module-path-index` records a dynamic module dependency for building and distributing executables: [`filesystem.scrbl:1091-1100`](https://github.com/racket/racket/blob/v9.2/pkgs/racket-doc/scribblings/reference/filesystem.scrbl#L1091-L1100). The prototype correctly uses it at `playground/racket/main.rkt:7-8`.
- `raco distribute` packages executables and declared runtime files for the same operating system; arbitrary extension collections/directories must be copied or installed explicitly.
- Separate places and processes have separate registries and state. Redefinition does not propagate automatically; each participant needs an explicit version/load protocol.

## Verified fixtures

All fixtures were created under `/tmp`; no application file was modified.

### Ordinary same-module and cross-module redefinition

Path: `/tmp/racket-live-ordinary.z1h6Iz`

A mutable `f` was called directly, through a same-module `call-f`, through a separately compiled importer, and through saved values. After redefining `f` with `eval` in `module->namespace`:

- direct `f`: new;
- current `call-f`: new;
- importer call: new;
- saved `f`: old;
- saved imported `f`: old;
- saved old `call-f`: new, because its body still read the mutable `f` location.

### Constants under ordinary compilation

Path: `/tmp/racket-live-constant.U6Muoj`

A normal `raco make` module rejected reflective redefinition with:

> `define-values: assignment disallowed; cannot re-define a constant`

### Same-source `dynamic-rerequire` with shared state

Path: `/tmp/racket-live-rerequire.TkYLFk`

Changing `impl.rkt` from v1 to v2 reloaded `impl.rkt` and dependent `client.rkt`. An unchanged `state.rkt` box retained `(mutated kept)` and its identity. A saved direct `f` remained v1; old callers that performed module-location lookup reached v2.

### Fresh generations, same source path, attached state

Path: `/tmp/racket-live-generations.lhPIa7`

Two namespaces loaded the same `impl.rkt` path before and after rewriting it:

```text
(v1 v2 #t #t #f (preserved))
```

The namespaces had different registries, both saw the same attached state box by `eq?`, and old/new implementations remained simultaneously callable.

### Non-transactional rerequire failure

Path: `/tmp/racket-rerequire-failure.CyLuUd`

After `impl.rkt` changed to v2, dependent client initialization rejected it. Post-failure observation was:

```text
(after-impl v2)
(after-client v1)
```

This verifies split-generation state after failed same-registry rerequire.

### Compiled `.zo` interaction

Paths:

- `/tmp/racket-rerequire-zo.V5tG39`
- `/tmp/racket-rerequire-zo-noconst.XLaUGf`

A normal `raco make` `.zo` caused later rerequire to fail on its constant `f`. Recompiling with `raco make --disable-constant` allowed the source reload and produced v2.

## Current prototype validation

Focused behavior:

```sh
racket playground/racket/main.rkt
```

Verified output:

```text
((default-site default Ada) default Ada default-site default Ada default-site)
((site-one one Ada) one Ada site-one one Ada default-site)
((site-two two Ada) two Ada site-two two Ada default-site)
```

Available full validation for the current prototype:

```sh
raco test \
  playground/racket/runtime.rkt \
  playground/racket/lib.rkt \
  playground/racket/config-lang.rkt \
  playground/racket/main.rkt &&
racket playground/racket/main.rkt
```

Do not use `raco test playground/racket/*.rkt` as the full command: it instantiates `config.rkt` and `config-v2.rkt` independently, before `lib.rkt` has registered their targets, and fails with “unknown function customization.” There are currently no assertion-bearing Racket tests.

For a future same-registry reload test, compile the disposable copy with:

```sh
raco make --disable-constant <reload-root.rkt>
```

For a production generation design, validate ordinary optimized compilation plus repeated fresh-namespace loads; `--disable-constant` should not be required.

## Evidence paths

Repository:

- `playground/racket/runtime.rkt:6-13,19-69,71-102`
- `playground/racket/lib.rkt:5-16`
- `playground/racket/main.rkt:7-26`
- `playground/racket/config-lang.rkt:3-23`
- `playground/racket/config.rkt:1-6`
- `playground/racket/config-v2.rkt:1-6`

Installed v9.2 primary sources:

- `/home/jay/racket/collects/racket/rerequire.rkt:9-31,40-107,130-189`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/eval-model.scrbl:517-580,781-827`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/namespaces.scrbl:272-410`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/eval.scrbl:646-715`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/module-reflect.scrbl:545-624,678-752`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/parameters.scrbl:8-85`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/units.scrbl:20-83`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/generic.scrbl:9-70`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/custodians.scrbl:18-79`
- `/home/jay/.local/share/racket/9.2/pkgs/gui-doc/scribblings/gui/eventspace-funcs.scrbl:6-68,151-160`
- `/home/jay/.local/share/racket/9.2/pkgs/errortrace-doc/errortrace/scribblings/errortrace.scrbl:10-89`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/security-guards.scrbl:12-42`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/reference/filesystem.scrbl:1091-1100`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/raco/make.scrbl:45-58`
- `/home/jay/.local/share/racket/9.2/pkgs/racket-doc/scribblings/raco/dist.scrbl:4-18,74-92`

## Residual risks and confidence

- **High confidence** in module-location, captured-reference, redeclaration, attached-state, failed-reload, and compiled-constant results; all were verified on v9.2.
- **Medium-high confidence** in the generation architecture; its central namespace/state-sharing behavior was verified, but not at full editor scale.
- No fixture covered macro-heavy phase graphs, GUI object migration, native extensions, contracts across generations, or a packaged executable.
- `namespace-attach-module` transitive attachment needs an application-specific dependency audit.
- Custodian shutdown and sandbox policy need hostile/error-path tests.
- Large-graph reload latency and memory retention from stale callbacks remain unmeasured.
- State schema evolution needs an explicit migration design.
- The repository currently has snapshots rather than assertion-bearing Racket tests.