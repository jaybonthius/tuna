# Gerbil v0.19 mapping for Emacsen runtime extensibility

## Conclusion

Gerbil is viable **only if Emacs-like live bindings are an explicit language/runtime seam**, such as a qualified registry containing mutable function, value, and property cells.

It is **not** viable if the requirement is that ordinary Gerbil `def`, imports, and calls transparently behave like Emacs symbol cells. Gerbil is a hygienic, lexically scoped Lisp-1 with phase-separated, namespaced modules. Optimized compilation deliberately recognizes known procedures, redirects calls to internal implementations, inlines declared rules, and performs whole-program optimization. That model conflicts directly with a process-wide Emacs-style namespace whose ordinary calls always consult mutable function cells.

The recommended decision boundary is therefore:

- **Go:** designated editor/runtime definitions use explicit late-bound cells, and this survives the complete compiler matrix.
- **No-go:** every ordinary Gerbil definition/call must remain transparently redefinable across already-compiled modules, or full runtime macro replacement of already-expanded code is required.

**Research baseline**

- Gerbil checkout: `/home/jay/Code/workbench-gerbil/gerbil`
- Commit: `4a4d1a3059824adf6319105bde496bef00d09834`
- Description: `v0.19-dev-31-g4a4d1a30-dirty`
- Existing checkout changes: `src/gambit/lib/_kernel.c`, `_module.c`, and `_num.c`
- No playground application files were inspected.
- No Gerbil spike programs were compiled because this assignment was read-only.

---

## Classification vocabulary

| Classification | Meaning |
|---|---|
| **Native Gerbil support** | Existing Gerbil/Gambit runtime or language facility provides the essential behavior. |
| **Small macro/prelude plus runtime library** | Ordinary Gerbil data structures, macros, parameters, exceptions, and explicit dispatch can provide it without changing the compiler. |
| **Substantial custom language/runtime work** | Transparent surface semantics require a custom prelude/language, pervasive rewriting, lifecycle tracking, or significant evaluator integration. |
| **Fundamental/optimizer risk** | Gerbil’s module or optimizer model may erase the required indirection; acceptance depends on an optimizer-mode spike. |

A capability can have both a feasible explicit implementation and a higher-risk transparent interpretation. Those are called out separately.

---

## 1. Capability mapping

### Must-test capabilities

| Capability | Classification | Gerbil mapping and constraint |
|---|---|---|
| Stable identity with separate function/value/property cells | **Small macro/prelude plus runtime library** for explicit cells; **substantial custom language/runtime work** for transparent ordinary identifiers | Runtime symbols are interned objects, but Gerbil does not attach Emacs value/function/property cells to them. Use a qualified symbolic-key registry with distinct slots. Lisp-1 lexical identifiers must not be confused with runtime symbols. |
| Same-form function definition/redefinition across compiled modules | **Fundamental/optimizer risk** for ordinary `def`; **small macro/prelude plus runtime library** for a designated `deflive`-style form | `def` expands to `define-values`, creating a module binding. Two modules defining the same printed name create namespaced bindings, not one shared function cell. Imports resolve syntax/module bindings. An explicit form can instead mutate an existing registry cell. |
| Already-compiled callers see function/value replacement | **Fundamental/optimizer risk** | Explicit hash/box lookup should be implementable, but must survive normal compilation, `-O`, and full-program optimization. Ordinary known-procedure calls are optimized and are not a supported hot-redefinition seam. |
| Runtime read/expand/eval/load | **Native Gerbil support**, with deployment constraints | `eval`, `read`, `include`, the expander, and module loading exist. A compiled executable must import `:gerbil/expander`, call `gerbil-load-expander!`, and use qualified module names or runtime `extern`. This is heavier and less ambient than Emacs. |
| Macro phase boundary | **Native Gerbil support** for compile-time expansion and stale compiled expansion; **substantial custom language work** for runtime macro namespace semantics | Gerbil has hygienic phased macros. Already-expanded or compiled code does not consult a mutable runtime macro cell. Re-expanding newly read forms can use the current expander context, but managing live macro replacement as an editor contract requires a controlled evaluation context. |
| Lexical binding | **Native Gerbil support** | Lexical scope is the normal language model. |
| Dynamic binding | **Native Gerbil support** | `make-parameter`, `parameterize`, and `call-with-parameters` provide dynamic extent. These are parameter objects, not ordinary variable cells. |
| Dynamic restoration and cleanup | **Native Gerbil support** | `dynamic-wind`, `with-unwind-protect`, exception handlers, continuations, and `unwind-protect` exist. Exact continuation/thread behavior still needs a spike. |
| Per-buffer/context-local lookup | **Small macro/prelude plus runtime library** | A current-buffer parameter plus per-buffer symbolic table and default cell can implement fallback, local assignment, and removal. Ordinary variable reference will not perform this lookup unless rewritten by the custom form/prelude. |
| Interactive command metadata | **Small macro/prelude plus runtime library** | Store argument acquisition, documentation, and command flags in the function-cell record or property cell; dispatch through the live function registry. Gerbil procedures do not natively carry Emacs interactive declarations. |

### Later-test capabilities

| Capability | Classification | Gerbil mapping and constraint |
|---|---|---|
| Hooks | **Small macro/prelude plus runtime library** | Store qualified live names rather than captured procedures when late replacement is desired. Ordering, local/global composition, and error policy are library contracts. |
| Advice | **Small macro/prelude plus runtime library**, with lifecycle complexity | Compose wrappers in a function-cell record so redefining the inner implementation preserves advice. Direct registry mutation needs a defined preservation policy. It cannot affect direct or already-inlined calls. |
| Keymaps and remapping | **Small macro/prelude plus runtime library** | Mutable tables, parent links, live command-name entries, and `[remap original]`-equivalent keys are ordinary data structures. Captured procedures remain snapshots. |
| Feature gates, autoload, deferred configuration | **Small macro/prelude plus runtime library** for editor features; **substantial work** for dependable unloading/history | Gerbil `provide`/`require` are expansion-time feature facilities, not Emacs runtime `features`/`require`. Runtime module loading exists, but an editor-level feature registry, pending callbacks, autoload descriptors, and retry/rollback rules must be built. |
| Runtime source expansion/evaluation | **Native Gerbil support**, with significant footprint/security constraints | Available after explicitly loading the expander in compiled programs. Evaluated names inhabit top-level/module namespaces rather than one ambient Emacs namespace. |
| Documentation/source introspection | **Small macro/prelude plus runtime library** | Gerbil syntax objects retain source locations and tooling can generate tags, but there is no native Emacs-like documentation/function-history property cell. Definition macros should record source, documentation, signature, and load provenance. |
| Function/value aliases | **Small macro/prelude plus runtime library** | Gerbil `defalias`/`define-alias` are syntactic aliases resolved by expansion, not mutable runtime alias cells. Live aliases need registry indirection and cycle detection; copying a procedure is a snapshot. |
| Errors and unwind cleanup | **Native Gerbil support** | Structured Gerbil/Gambit exceptions and dynamic cleanup exist. Arbitrary registry mutations are not transactional. |
| Customize-style metadata | **Small macro/prelude plus runtime library** | Property cells plus validators, setters, defaults, and provenance are sufficient. |
| Load history/unload restoration | **Substantial custom language/runtime work** | Every definition and registration must be attributed to a load transaction. Arbitrary side effects and anonymous closures remain undiscoverable, as in Emacs. |
| Concurrency visibility and transactions | **Substantial custom runtime work** | The loader itself uses mutexes, but a live-cell registry needs its own synchronization and atomic multi-cell policy. Parameter inheritance/task semantics need explicit tests. |
| Native/plugin module reload and type identity | **Fundamental/optimizer risk** | `reload-module!` reloads a compiled artifact when its resolved file changes, but existing captured objects, optimized calls, generated types, and whole-program-eliminated definitions are not thereby replaced. |

---

## 2. Where Gerbil’s model conflicts with an Emacs-like namespace

### Gerbil is a Lisp-1 with hygienic module bindings

Gerbil’s `def` expands to `define-values`; `defsyntax` expands to `define-syntax`; and `defalias` expands to `define-alias`. Function position and value position therefore refer to the same lexical/module binding rather than separate cells.

Evidence:

- `gerbil/doc/reference/gerbil/prelude/macros.md:5-47`
- `gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:15-85,142-171`

Consequences:

1. `(def foo 1)` and `(def (foo) 2)` are not independent value and function definitions.
2. An imported `foo` identifies an expander-resolved module binding.
3. A second module’s `foo` is a different namespaced binding.
4. Gerbil `define-alias` is a syntactic binding alias, not an Emacs function-cell alias.
5. Runtime symbols can serve as registry keys, but quoting `'foo` does not expose a compiler binding cell.

### Same-form redefinition is not a cross-module rendezvous mechanism

In `gxi`, repeated top-level evaluation can replace a top-level binding in the interactive context. That does not establish the crucial property that an already-compiled module’s direct call to its imported binding will consult the newly evaluated definition.

Compiled `eval` illustrates the namespace boundary directly: an unqualified module variable is unbound from top-level `eval`; the source must use `module#name` or introduce it with `extern`.

Evidence:

- `gerbil/doc/guide/eval.md:10-69`
- `gerbil/doc/guide/eval.md:71-119`

Therefore the exact Emacs-shaped requirement—

> load another source form named `foo`, then every already-compiled ordinary caller of `foo` sees it—

is not native Gerbil semantics. It requires either:

1. every eligible reference to be rewritten to an explicit live-cell operation; or
2. compiler/runtime changes making designated identifiers resolve through mutable cells.

The first is bounded and plausible. The second fights the compiler and module system.

---

## 3. Optimizer behavior

### `gxi`

The interpreter has a live top-level expander/evaluator and is the most permissive environment. Success here is necessary but weak evidence: it does not establish behavior in deployed compiled binaries or across module boundaries.

### Normal `gxc`

Separate compilation produces namespaced module bindings and loader-managed compiled objects. Explicit mutable registry lookup should remain dynamic, but ordinary direct calls remain module calls rather than Emacs function-cell lookup.

### `gxc -O`

The Gerbil optimizer:

- collects top-level types and tracks bindings mutated through syntactic `set!`;
- recognizes known procedures;
- performs direct or unchecked calls;
- redirects calls to generated dispatch procedures where available;
- applies inline rules;
- lifts lambda implementations.

Evidence:

- mutable-binding tracking: `gerbil/src/gerbil/compiler/optimize-top.ss:10-14`
- top-level type collection: `gerbil/src/gerbil/compiler/optimize-top.ss:16-37,124-151`
- direct/unchecked call rewriting: `gerbil/src/gerbil/compiler/optimize-call.ss:43-98`
- explicit inline-lambda substitution: `gerbil/src/gerbil/compiler/optimize-call.ss:99-146`
- local dispatch redirection and inlining: `gerbil/src/gerbil/compiler/optimize-call.ss:436-457`
- optimizer guidance to make direct calls: `gerbil/doc/reference/dev/optimizing.md:31-46`

A registry mutation invisible to Gerbil’s syntactic `set!` analysis must not be assumed to invalidate inferred procedure information. The safe shape is an explicit runtime lookup at each live call, not an ordinary exported procedure that happens to be replaced elsewhere.

### Full-program optimization

The full-program driver combines runtime, dependencies, and the executable module, and resets Gambit declarations to include:

- `block`;
- `inline`;
- constant folding;
- lambda lifting;
- dead-local and dead-definition optimization.

It also initializes the runtime with an empty built-in module list because tree shaking may remove compiled-in definitions; runtime loading remains possible only for artifacts available to the loader.

Evidence:

- `gerbil/src/gerbil/compiler/driver.ss:345-386`
- combined dependency stub and runtime-loading caveat: `gerbil/src/gerbil/compiler/driver.ss:387-412`
- optimizer documentation: `gerbil/doc/reference/dev/optimizing.md:48-61`

This is the highest-risk mode. A wrapper may be inlined, but its mutable table/box access must remain observable. If optimization turns a designated live call into a constant implementation call, Gerbil fails the core language criterion.

---

## 4. Runtime facilities and limits

### Symbols and registries

Gerbil exposes interned symbols, uninterned symbols, symbolic tables, mutable hash tables, and boxes. These are sufficient to represent:

```text
qualified-name → {
  function-cell,
  value-cell,
  property-table,
  source/provenance,
  generation
}
```

They do not natively supply attached Emacs cells.

Evidence:

- `gerbil/doc/reference/gerbil/runtime/symbols.md:1-37`
- exported symbol/table operations: `gerbil/doc/reference/gerbil/prelude/runtime-bindings.md:820-875`

Qualified keys are strongly preferable to a truly flat process-wide namespace. A flat namespace reproduces Emacs collision behavior and discards a major Gerbil advantage without improving extensibility.

### Dynamic binding and cleanup

`parameterize` is native macro support. `call-with-parameters` delegates to Gambit parameterization, and `with-unwind-protect` is implemented using `dynamic-wind` with re-entry protection.

Evidence:

- `gerbil/doc/reference/gerbil/prelude/macros.md:193-224`
- `gerbil/doc/reference/gerbil/runtime/control-flow.md:12-42`
- `gerbil/src/gerbil/runtime/control.ss:29-53`

Parameters are appropriate for current buffer, command context, prefix arguments, and temporary editor state. They are not a substitute for independently mutable process-global value cells.

### Runtime eval

`eval-syntax` expands then compiles/evaluates with the current expander hooks:

- `gerbil/src/gerbil/expander/core.ss:169-181`

Compiled applications must initialize the expander explicitly:

- `gerbil/src/gerbil/runtime/init.ss:248-258`
- `gerbil/doc/guide/eval.md:23-69`

Source-aware reading is available:

- `gerbil/src/gerbil/runtime/syntax.ss:312-321`
- exports in `gerbil/src/gerbil/core/runtime.ss:1854-1859`

Runtime configuration should consequently use a dedicated expander context and explicit imports/externs. Evaluating arbitrary editor configuration into the application’s module namespace is neither ambient nor isolated by default.

### Loading and reloading

`load-module` serializes loading, caches success/error state, waits on concurrent loading, records load order, and invokes Gambit `load`. `reload-module!` removes cached state and loads the latest matching object only under its documented path conditions.

Evidence:

- `gerbil/src/gerbil/runtime/loader.ss:7-73`
- reload behavior: `gerbil/src/gerbil/runtime/loader.ss:75-106`
- compiled/source selection: `gerbil/src/gerbil/runtime/loader.ss:108-137`
- interactive dependency-order reload: `gerbil/src/std/interactive.ss:7-46`

This is useful development infrastructure, not Emacs-compatible definition replacement:

- removed definitions can remain referenced;
- captured procedures remain old;
- initialization side effects rerun;
- generated class/type identity can diverge;
- advice/hooks are not automatically attributed or restored;
- full-program optimization can omit compiled-in definitions entirely.

---

## 5. Semantics by requested area

### Separate cells and properties

**Feasible explicit semantics:** one record per qualified runtime name, with independent mutable function and value slots plus a property table.

**Not native:** runtime symbols do not own these slots, and ordinary Gerbil identifiers do not route through them.

**Risk:** allowing the same textual name to denote both a lexical Gerbil binding and a live runtime binding creates confusing two-level resolution. A custom prelude should reserve a clearly recognizable definition/reference family.

### Lexical and dynamic binding

- Lexical binding: native and dominant.
- Dynamic parameters: native.
- Emacs-style “special declaration changes ordinary variable lookup”: custom language semantics.
- Temporary editor context: parameters are the idiomatic implementation.
- Process-global mutable defaults: registry value cells.
- Buffer-local overlays: explicit lookup combining current context, local table, and default cell.

### Per-buffer lookup

A small library can implement:

1. default value in the global value-cell record;
2. current buffer via a parameter;
3. local overrides keyed by variable symbol;
4. fallback to default;
5. local deletion restoring fallback.

The interaction with dynamic binding must be specified. The most tractable rule is that dynamic parameterization changes the active buffer/context, while buffer-local lookup remains data-driven. Trying to make ordinary lexical `set!` reproduce all Emacs interactions would require substantial language rewriting.

### Macros

Gerbil’s phase separation gives the same essential negative boundary as compiled Emacs Lisp:

- new forms expanded after a macro update can use the new transformer;
- already-expanded or compiled code retains its expansion;
- ordinary runtime function replacement cannot intercept it.

A live macro-definition registry for runtime-evaluated configuration is possible only by controlling the expander context. It should not be described as runtime replacement of compiled macros.

### Hooks and advice

Both are library-level once live function cells exist.

- Hook entries stored as qualified names remain live.
- Hook entries stored as procedures are snapshots.
- Advice should be stored separately from the inner definition and composed by the dispatcher.
- A redefinition operation can replace only the inner definition and increment a generation.
- Optimized direct calls outside the dispatcher remain unadvised.

### Interactive command metadata

A command record can carry:

- live function name;
- interactive argument reader;
- documentation;
- source location;
- command category/history flags.

The keymap should contain the live command name, not a procedure, when redefinition is expected.

### Keymaps and remapping

Native mutable hashes/lists are sufficient for:

- key-sequence mappings;
- parent maps;
- active-map precedence;
- semantic command remapping;
- symbol-name versus captured-procedure distinction.

This area is not a language-selection risk once live dispatch is proven.

### Feature loading, autoload, and deferred configuration

Gerbil compile-time `provide` and `require` do not map to Emacs runtime features. An editor library needs:

- a runtime loaded-feature set;
- `require` that invokes a loader then verifies provision;
- function-cell autoload descriptors;
- pending after-load callbacks;
- explicit failure/rollback policy.

Gerbil’s native loader provides synchronization and module caching but not these editor semantics.

### Documentation and source introspection

Native syntax objects and source locations cover parsing/diagnostics. Definition provenance should be recorded explicitly at live-definition time because native procedures do not expose an Emacs-equivalent documentation/source/history cell.

A reasonable initial guarantee is:

- name;
- source path and location;
- documentation string;
- load unit;
- generation;
- current implementation identity.

General recovery of original source from optimized procedures is not a realistic requirement.

### Aliases

Gerbil’s documented `defalias` is syntactic. Editor runtime aliases need separate function and value alias targets with:

- cycle detection;
- missing-target reporting;
- raw versus followed introspection;
- distinction between live alias and captured value/procedure.

### Errors and cleanup

Native exceptions and unwind support are sufficient for temporary bindings and resource restoration. They do not provide load transactions. A failed configuration load will otherwise leave earlier cell changes applied.

---

## 6. Ordered spike program

These are deliberately small language/runtime spikes, not an editor implementation.

### Spike 1 — Explicit live cells and aliases

**Question:** Can one qualified runtime name independently own function, value, and property state?

**Probe:**

- register `demo/x`;
- set value to `'value`;
- set function to procedure returning `'old`;
- set property `documentation`;
- replace only the function with one returning `'new`;
- create a live alias and a captured-procedure snapshot;
- remove each cell independently;
- reject an alias cycle.

**Acceptance behavior:**

```text
value-ref demo/x                  => value
live-call demo/x                  => old
after replacement:
  value-ref demo/x                => value
  live-call demo/x                => new
  live-call live-alias            => new
  captured procedure              => old
property documentation unchanged
removed function reports unbound-function without removing value/property
alias cycle is rejected deterministically
```

**Decision:** Failure is a no-go. This should require no compiler changes.

### Spike 2 — Cross-module, same-form replacement matrix

**Question:** Can a single designated definition form mutate the same live cell from different source modules, and can an already-compiled caller observe it?

Use three isolated modules:

- base defines `demo/target` as `old`;
- caller was compiled against the public live-call form;
- replacement evaluates the same designated definition form for `demo/target` as `new`.

Also include a negative control using ordinary `def`/direct import.

**Acceptance behavior in every claimed mode:**

```text
compiled caller before replacement => old
compiled caller after replacement  => new
ordinary direct-call control either remains old or is explicitly unsupported
value cell with same name remains unchanged
```

**Modes:**

1. `gxi`;
2. normal separate `gxc`;
3. separate `gxc -O`;
4. `gxc -full-program-optimization`.

**Decision:** If the explicit seam fails under `-O` or full-program optimization, no-go. Ordinary `def` failure is expected and must be documented, not hidden.

### Spike 3 — Captured wrapper versus captured implementation

**Question:** Which captured-object behavior is promised?

Probe both:

1. extracting the current implementation procedure;
2. capturing a stable forwarding procedure that performs cell lookup.

**Acceptance behavior:**

```text
captured implementation after replacement => old
captured stable forwarding procedure       => new
```

This makes the deviation from Emacs explicit: the stable wrapper is stronger than Emacs’s extracted function object, while the extracted implementation matches Emacs’s snapshot behavior.

### Spike 4 — Runtime read/expand/eval/load in a compiled executable

**Question:** Can a deployed compiled process repeatedly evaluate source configuration with useful names and source diagnostics?

**Probe:**

- executable imports `:gerbil/expander`;
- calls `gerbil-load-expander!`;
- loads a source file defining/redefining a live command;
- edits/reloads it within the same process;
- loads a form containing an unknown name and a syntax error;
- records definition provenance.

**Acceptance behavior:**

```text
first load command result       => old
second load command result      => new
unknown name identifies source path and location
syntax error identifies source path and location
definition metadata points to the second source definition
failed load follows a documented partial-apply or rollback policy
```

**Decision:** If this works only in `gxi`, no-go for an Emacsen configuration language.

### Spike 5 — Macro phase boundary

**Question:** Can newly read forms use a replaced transformer while compiled forms remain predictably stale?

**Probe:**

- define macro expansion `old`;
- compile one caller;
- replace the transformer in the controlled runtime expander context;
- evaluate a newly read caller;
- invoke the old compiled caller.

**Acceptance behavior:**

```text
newly expanded/evaluated caller => new expansion
already-compiled caller         => old expansion
recompiled caller               => new expansion
```

**Decision:** Go only if this boundary is stable and clearly documentable. Requiring the compiled caller to change without recompilation is no-go.

### Spike 6 — Dynamic context, unwind, and context-local values

**Question:** Do parameters and context overlays restore reliably across errors and continuations?

**Probe:**

- global default `demo/option`;
- two mock buffers with independent local tables;
- nested current-buffer parameterization;
- local override/remove;
- exception and escape continuation through the dynamic extent;
- cleanup that records exactly-once execution.

**Acceptance behavior:**

```text
buffer A local       => A
buffer B fallback    => default
remove A local       => default
nested buffer switch restores outer buffer
exception restores current buffer and dynamic option
escape continuation restores state
cleanup executes exactly once for the tested exit
```

Run under all four compiler modes.

### Spike 7 — Commands, hooks, advice, and keymaps

**Question:** Do higher-level conventions preserve live-name indirection?

**Probe:**

- command metadata with interactive argument acquisition;
- key binding stores command name;
- hook stores command name;
- around advice wraps the function cell;
- redefine the command’s inner implementation;
- remap it in a child keymap.

**Acceptance behavior:**

```text
command discovery finds metadata
key invocation after redefinition reaches new implementation
hook invocation after redefinition reaches new implementation
advice still wraps the new inner implementation
child remap changes semantic command without rebinding parent keys
captured-procedure negative control remains old
```

### Spike 8 — Loader and optimization boundary

**Question:** What does native module reload preserve, and can external runtime configuration still load from a full-program executable?

**Probe:**

- reload one ordinary module;
- retain an old exported procedure and type instance;
- compare with an explicit live registry entry;
- load an external configuration artifact from a full-program executable.

**Acceptance behavior:**

- report, rather than assume, whether old procedure/type objects remain old;
- live registry dispatch must update;
- external loading either works reliably or the supported deployment excludes full-program builds;
- absent/tree-shaken modules produce a controlled load error.

This spike determines whether module reload is merely a developer convenience or a supportable extension mechanism.

---

## 7. Go/no-go criteria

### Go criteria

Choose Gerbil if all are true:

1. Product semantics permit an explicit live-definition/reference family rather than transparent ordinary `def`.
2. The function/value/property registry preserves independent mutation and aliases.
3. Already-compiled designated callers observe replacement under `gxi`, normal `gxc`, `gxc -O`, and full-program optimization.
4. Compiled executables can initialize the expander and evaluate configuration with acceptable startup size, security, and diagnostics.
5. Macro behavior is documented as re-expansion, not mutation of already-expanded code.
6. Parameterized dynamic context and unwind restoration pass exception/continuation tests.
7. Context-local lookup remains understandable and does not rely on rewriting arbitrary lexical variables.
8. Qualified runtime names and explicit collision policy are acceptable.
9. External extensions are not required to redefine arbitrary optimized ordinary Gerbil procedures.

### No-go criteria

Reject Gerbil for this role if any is required:

1. Re-evaluating an ordinary `def` must transparently replace the meaning of the same printed name across arbitrary already-compiled modules.
2. Ordinary calls may not be routed through an explicit live dispatch seam.
3. Full-program optimization must retain Emacs-style late lookup without any source-level distinction.
4. Replacing a macro must alter already-expanded or compiled callers without recompilation.
5. Runtime evaluation must work without shipping/initializing the Gerbil expander.
6. One flat runtime namespace must simultaneously be the Gerbil compiler namespace.
7. Native module reload is expected to update captured procedures, existing type instances, and all optimized calls.
8. Configuration loads must be atomic without building explicit transactional cell/loading support.

---

## 8. Material implementation options

### Option A — Qualified live registry

Macros define and reference qualified live names; runtime records hold separate cells.

**Classification:** small prelude/runtime library, with optimizer validation.

**Advantages:**

- bounded;
- explicit;
- compatible with Gerbil modules;
- supports metadata, hooks, commands, aliases, and autoload.

**Constraint:** all extensible calls/reads must use the seam.

### Option B — Stable public forwarding procedures

Each live function has a stable exported procedure that looks up the current implementation.

**Classification:** small prelude/runtime library with greater optimizer risk.

**Advantages:** ergonomic ordinary-looking calls and live captured wrappers.

**Risks:** optimizer may inline or redirect the forwarding procedure; must prove the lookup survives every mode.

### Option C — Custom Emacsen Gerbil language/prelude

A custom `#lang`/prelude rewrites designated top-level definitions, references, assignments, and macro handling.

**Classification:** substantial custom language work.

**Advantages:** closest surface syntax.

**Risks:** phase/context complexity, confusing interaction with ordinary Gerbil libraries, source tooling requirements, and broad compiler assumptions.

### Option D — Compiler/runtime modification

Change compiled identifier/call semantics to consult runtime cells.

**Classification:** fundamental/optimizer risk and substantial runtime/compiler work.

**Assessment:** not recommended. It discards Gerbil’s direct-call/module optimization model and creates a long-term fork.

### Option E — Native module reload as the primary mechanism

**Classification:** fundamental risk.

**Assessment:** unsuitable as the semantic foundation. Use it only for development or coarse plugin replacement behind stable live dispatch interfaces.

---

## 9. Risks and unresolved gaps

- **Blocker until spiked — optimizer preservation:** explicit mutable lookup has not been tested under `-O` or full-program optimization.
- **High — ordinary definition mismatch:** Gerbil `def` is not Emacs `defun`; imports do not create shared function cells.
- **High — runtime evaluator footprint:** compiled eval requires explicitly shipping and initializing the expander.
- **High — namespace duality:** runtime registry names and hygienic compiler identifiers are different identities.
- **High — dirty baseline:** the Gerbil checkout contains local modifications in Gambit runtime files; compiler/runtime spike results must record whether these changes affect the tested behavior.
- **Medium — source provenance:** source locations exist, but comprehensive runtime definition history must be recorded by the custom forms.
- **Medium — concurrency:** loader locking does not automatically protect editor live cells or multi-cell updates.
- **Medium — continuation semantics:** `dynamic-wind` is native, but exact editor context behavior across continuation re-entry should be tested.
- **Medium — partial loads:** `eval` and module initialization mutate state incrementally unless a transaction layer is added.
- **Medium — unloading:** arbitrary side effects remain undiscoverable.
- **Medium — type identity:** module reload may leave old instances and captured constructors alive.
- **Low — keymaps/hooks:** these are straightforward libraries after the live binding seam succeeds.

**Confidence:** high on the Gerbil module, phase, eval, loader, parameter, unwind, and documented optimizer model; medium on exact observable optimized live-cell behavior because the required spike matrix has not yet been run.

---

## 10. Evidence-backed validation commands

These commands should be run from an isolated temporary spike directory, not against application files.

### Focused interpreter check

```sh
GERBIL_HOME=/home/jay/Code/workbench-gerbil/gerbil/build \
  /home/jay/Code/workbench-gerbil/gerbil/build/bin/gxi \
  ./spikes/live-cells-test.ss
```

Expected output must include the independent-cell, alias, captured-implementation, dynamic-binding, and cleanup assertions from Spikes 1, 3, and 6.

### Separate compiled modes

```sh
gxc -exe -o ./tmp/live-normal ./spikes/live-main.ss
./tmp/live-normal

gxc -O -exe -o ./tmp/live-opt ./spikes/live-main.ss
./tmp/live-opt

gxc -full-program-optimization -exe \
  -o ./tmp/live-full ./spikes/live-main.ss
./tmp/live-full
```

The relevant options are documented by:

- `gerbil/src/gerbil/gxc-main.ss:12-19`
- option parsing: `gerbil/src/gerbil/gxc-main.ss:104-109`

### Full focused matrix

```sh
set -eu

gxi ./spikes/live-cells-test.ss

for mode in normal opt full; do
  case "$mode" in
    normal) opts="" ;;
    opt)    opts="-O" ;;
    full)   opts="-full-program-optimization" ;;
  esac

  rm -rf "./tmp/$mode"
  mkdir -p "./tmp/$mode"

  gxc $opts -exe \
    -o "./tmp/$mode/live-spike" \
    ./spikes/live-main.ss

  "./tmp/$mode/live-spike"
done
```

Required observable summary per mode:

```text
cells: pass
cross-module replacement: pass
captured implementation: old
captured forwarding procedure: new
dynamic unwind: pass
context-local fallback: pass
runtime eval/reload: pass
macro compiled boundary: pass
command/hook/advice/keymap: pass
```

A successful `gxi` result without all three compiled results is insufficient.

---

## Acceptance report