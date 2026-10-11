# Emacsy runtime customization design for Gerbil

**Artifact:** `/home/jay/Code/workbench-gerbil/research/emacsy-runtime-customization-design.md`

## Decision

Use a **custom customization framework with macro-declared bindings, per-binding mutable cells, stable forwarding procedures for functions, identifier macros for values, and one central typed registry**.

Load trusted runtime configuration as ordinary Gambit source using `load` and fully qualified registry entry points. This avoids importing target libraries and avoids Gerbil’s runtime expander, which currently fails under full-program optimization.

This best satisfies the owner’s priorities:

- ordinary calls and reads remain unchanged;
- one runtime file can redefine bindings from many libraries;
- that file imports no target libraries;
- it can be loaded repeatedly in one process;
- stable function references remain live;
- normal `gxc`, `gxc -O`, and FPO can retain late binding;
- preserving the current direct-global prototype is not required.

The registry should only be consulted during registration and redefinition. Each ordinary call should dereference its own cell, avoiding a global hash lookup per call.

## 1. What Emacs actually does

Emacs libraries normally share interned symbol objects in a process-wide namespace. Each symbol has independent function and value cells:

- `(foo ...)` resolves `foo`’s current function cell.
- `foo` in value position resolves its current value binding.
- `defun`/`fset` replaces the function cell.
- `setq`/`set` changes the current value binding.

Thus already-loaded ordinary callers continue to name the symbol and normally resolve its latest cell contents at execution time. Evidence and authoritative links are collected in:

- `research/emacs-runtime-redefinition-semantics.md:3-33`
- `research/emacs-runtime-redefinition-semantics.md:35-87`

This is **late binding, not atomic module replacement**. It does not update:

- an already active invocation;
- an actual procedure object obtained through `symbol-function`;
- lexical closures or previously captured values;
- expanded macros or inlined/compiler-transformed calls;
- direct native/C calls that bypass symbol lookup;
- definitions removed from a subsequently loaded file.

Emacs native speed-3 intra-unit optimization can likewise turn calls into direct or inlined calls that are unsafe to redefine without recompilation:

- `research/emacs-runtime-redefinition-semantics.md:220-250`

Reloading an Emacs file sequentially evaluates its remaining forms. Side effects can repeat, removed definitions can remain, and an error can leave partial state. It is not transactional:

- `research/emacs-runtime-redefinition-semantics.md:283-292`

A live symbol alias differs from a captured function object: the alias follows later definitions, while the captured object does not:

- `research/emacs-runtime-redefinition-semantics.md:60-75`

## 2. What Gerbil lacks

Gerbil has no automatic Emacs-style function and value cell behind every module binding.

A module definition usually becomes a namespaced Gambit global such as `app/lib#greeting`. Imports and re-exports preserve that source runtime binding ID, but they are expansion-time mappings rather than process-wide runtime symbol-cell indirection:

- `research/gerbil-runtime-redefinition-architecture.md:36-75`
- `research/gerbil-runtime-redefinition-architecture.md:90-111`

In particular, Gerbil lacks:

1. A public operation that accepts an arbitrary symbol and safely mutates its global binding.
2. A runtime namespace object equivalent to Emacs’s interned symbol table.
3. Automatic function/value-cell separation.
4. A compiler guarantee that external mutation remains observable after optimization.
5. Atomic, side-effect-safe module or configuration reload.

The internal Gambit `##global-var-*` primitives can mutate symbolic globals, but they are undocumented implementation APIs and invisible to optimizer reasoning. They should not underpin the application architecture:

- `research/gerbil-runtime-redefinition-architecture.md:225-238`

Gerbil emits Gambit `block` declarations by default. This permits defined, apparently unassigned globals to be treated as permanent and possibly inlined. Direct external `set!` therefore requires `(declare (separate))` in every affected provider module to form a reliable contract:

- `research/gerbil-runtime-redefinition-architecture.md:242-300`
- stale same-module behavior was observed at `research/gerbil-runtime-redefinition-architecture.md:302-321`

## 3. Architecture comparison

| Architecture | Ordinary use | Config coupling | Optimization behavior | Captured function reference | Assessment |
|---|---|---|---|---|---|
| Direct globals plus central re-export facade | `(greeting who)`, `site-name` | One facade import, but facade statically enumerates every provider | Every provider needs `separate`; Gerbil runtime `eval` is currently broken under FPO | Captures old procedure | Closest migration path, not the robust long-term choice |
| Macro-defined cells plus central registry | Ordinary call/read syntax | Only central runtime namespace and qualified keys | Explicit box dereference remains visible; tested through `-O` and FPO with retention | **Live with stable forwarding wrapper** | **Recommended** |
| Parameters | Usually `((current-greeting) who)` | Central parameter namespace | Reliable cell semantics | Captures parameter procedure, but semantics are dynamically scoped/thread-sensitive | Use for request/thread policy, not process-wide Emacs-like definitions |
| `:std/generic` | Ordinary generic call | Generic metadata must be available | Mutable dispatch table with cache invalidation | Generic procedure remains a dispatcher | Use where multimethod dispatch is intrinsically correct |
| Module reload | Ordinary syntax after reload | Module path/source or new object | Still exposed to initializer, `block`, inlining, type identity and FPO risks | Captures old procedure | Development/plugin mechanism, not customization foundation |

### Direct globals and facade

A static facade allows one config import and direct `set!`:

```scheme
(import :app/customize)
(set! greeting replacement)
(set! site-name "Configured")
```

But re-exports do not create facade-owned runtime cells. The facade must statically import every provider, every provider must obey `separate`, and runtime imports can reconstruct/evaluate module contexts:

- `research/gerbil-runtime-redefinition-architecture.md:376-433`

This preserves existing `def` forms but makes compiler policy application-wide and fragile.

### Parameters and generics

Parameters have documented dynamic and thread-local semantics, including `parameterize` and inherited thread environments. They are appropriate for temporary or per-request policy, not one process-wide replacement cell:

- `research/gerbil-runtime-redefinition-architecture.md:586-620`

`:std/generic` supports runtime method replacement, mutex protection and dispatch-cache invalidation. It is appropriate for actual polymorphic dispatch, not ordinary values or every application function:

- `research/gerbil-runtime-redefinition-architecture.md:624-648`

### Module reload

Gerbil and Gambit expose module/source loading facilities, but reload can rerun initializers, leave captured procedures stale, preserve expanded macros, create incompatible type descriptors and face optimizer/tree-shaking constraints:

- `research/gerbil-runtime-redefinition-architecture.md:676-746`

Reload the **configuration file that mutates stable cells**, not the application libraries themselves.

## 4. Recommended binding model

### Functions

A library-author macro should create:

1. a private box containing the current implementation;
2. a stable exported forwarding procedure;
3. a typed registry entry pointing to the box.

Conceptually:

```scheme
(defcustom-function (greeting who) 'app/greeting
  (string-append "Hello, " who))
```

expands to the equivalent of:

```scheme
(def greeting::cell
  (box (lambda (who)
         (string-append "Hello, " who))))

(register-function! 'app/greeting greeting::cell)

(def (greeting who)
  ((unbox greeting::cell) who))
```

The public `greeting` procedure is never replaced. Its implementation cell is.

Consequences:

- `(greeting "Ada")` remains ordinary syntax.
- Same-library and imported calls both dereference the current implementation.
- `(def saved greeting)` captures the stable forwarder, so `(saved "Ada")` remains live after later redefinitions.
- A currently executing implementation continues executing; only later calls select the replacement.
- A deliberately extracted implementation procedure remains captured and stale.

The stable wrapper variant is described at:

- `research/gerbil-runtime-redefinition-architecture.md:550-567`

### Values

A value declaration should create a box and export an identifier macro:

```scheme
(defcustom-value site-name 'app/site-name
  "Default Site")
```

Ordinary expression use:

```scheme
site-name
```

expands to:

```scheme
(unbox site-name::cell)
```

Already-compiled readers therefore retain the stable box reference and see later contents. A lexical capture such as `(def old-name site-name)` remains the old value, as expected.

Ordinary `set! site-name` should not be promised. Runtime changes go through the registry API.

### Typed registry

Use separate function and value APIs or distinct key domains:

```scheme
(redefine-function! 'app/greeting replacement)
(redefine-value! 'app/site-name replacement)
```

This preserves Emacs’s important function/value distinction and permits early validation of procedure shape versus ordinary values. Qualified keys avoid collisions across a large application.

For FPO, dynamically named registry entry points must be retained. The disposable probe required a declaration such as:

```scheme
(declare (not optimize-dead-definitions))
```

in the small central runtime module. Without it, FPO stripped `mwe/runtime#redefine!`; with it, repeated configuration loads passed. The underlying requirement is documented at:

- `research/gerbil-runtime-redefinition-architecture.md:323-346`

## 5. Smallest useful MWE

### Layout

```text
mwe/
  runtime.ss       ; registry, declaration macros, redefinition API, loader
  library.ss       ; one customizable function and value
  main.ss          ; ordinary calls, capture, repeated reload
  user-config.scm  ; trusted runtime configuration; no imports
```

### `library.ss`

```scheme
namespace: demo/library

(import "runtime")
(export greeting site-name describe)

(defcustom-function (greeting who) 'demo/greeting
  (string-append "default " who))

(defcustom-value site-name 'demo/site-name
  "default-site")

(def (describe who)
  [site-name (greeting who)])
```

### Exact user runtime file

`user-config.scm` contains no `import`, no target-library namespace and no Gerbil expansion forms:

```scheme
(demo/runtime#redefine-function!
 'demo/greeting
 (lambda (who)
   (string-append "configured " who)))

(demo/runtime#redefine-value!
 'demo/site-name
 "configured-site")
```

The fully qualified identifiers address only the central runtime module.

### Reloading

`runtime.ss` should expose:

```scheme
(reload-customizations! path)
```

whose minimal implementation uses public Gambit source loading:

```scheme
(load path)
```

Application or REPL use:

```scheme
(def saved greeting)

(displayln [(describe "Ada") (saved "Ada")])
(reload-customizations! "/path/to/user-config.scm")
(displayln [(describe "Ada") (saved "Ada")])

;; Edit the same file, then call again in the same process.
(reload-customizations! "/path/to/user-config.scm")
(displayln [(describe "Ada") (saved "Ada")])
```

Each call rereads and executes the source forms. It does not reload target libraries or reset the registry.

This deliberately uses portable runtime Scheme and fully qualified Gambit globals rather than Gerbil `eval`/`include`. It therefore avoids `gerbil-load-expander!`, whose FPO execution currently fails with unbound `__eval-import`:

- `research/gerbil-runtime-redefinition-architecture.md:348-372`

Trade-off: this minimal config language cannot depend on arbitrary Gerbil module imports or expansion-time macros. Supporting those would require either the runtime expander, compiled plugins, or a custom configuration DSL.

## 6. Observability contract

| Situation | Recommended behavior |
|---|---|
| Ordinary function call after replacement | Live |
| Same-library ordinary call | Live |
| Imported ordinary call | Live |
| Stable function reference captured before replacement | Live |
| Current implementation explicitly extracted before replacement | Stale |
| Invocation already executing during replacement | Continues old implementation |
| Ordinary customizable value read | Live |
| Lexically captured value | Stale |
| Expanded macro/inlined body | Stale unless expansion itself dereferences the cell |
| Removed form on config reload | Previous override remains |
| Error halfway through simple reload | Earlier mutations remain unless transactions are added |

This is slightly stronger than Emacs for an ordinary Gerbil capture such as `(def saved greeting)`: it captures the stable wrapper and stays live. Emacs only stays live when the captured object remains symbolic indirection; an actual captured function object is stale.

## 7. Public facilities versus custom framework

### Public Gerbil/Gambit facilities

- modules, imports and exports;
- namespaced global identifiers;
- boxes and mutation;
- hash tables;
- procedures and syntax transformers;
- `load`;
- compiler declarations, including dead-definition retention;
- parameters;
- `:std/generic` and the class MOP.

Sources:

- boxes and hash tables: `research/gerbil-runtime-redefinition-architecture.md:578-582`
- Gambit `load`: `research/gerbil-runtime-redefinition-architecture.md:704-712`
- parameters/generics: `research/gerbil-runtime-redefinition-architecture.md:586-648`

### Custom application framework

Gerbil does not supply these as one feature:

- `defcustom-function` and `defcustom-value`;
- typed registry and key policy;
- stable forwarding semantics;
- replacement validation;
- `reload-customizations!`;
- pending override/load-order policy;
- atomic reload or rollback;
- synchronization policy;
- introspection, provenance or reset-to-default behavior.

Do not describe the result as built-in Gerbil global redefinition. It is a framework built on public primitives.

## 8. Risks and open decisions

- **High — migration boundary:** Every customizable definition must use the framework macro, and existing callers must be recompiled. Arbitrary existing `def` bindings do not become live automatically.
- **High — FPO retention:** Dynamically referenced registry entry points are tree-shaken without an explicit retention policy. A disposable FPO probe failed with `Unbound variable: mwe/runtime#redefine!` before adding `not optimize-dead-definitions`.
- **High — Gerbil runtime eval:** `gerbil-load-expander!` currently fails under FPO. The recommended portable Scheme config avoids it, but limits config syntax.
- **Medium — partial reload:** Plain `load` is sequential and nontransactional. A production loader may need staging and commit-on-success.
- **Medium — concurrency:** A plain registry/hash table is not safe for concurrent registration and mutation. Prefer loading before workers start, or define locking and visibility guarantees.
- **Medium — multi-binding consistency:** Independent box updates allow readers to observe mixed versions. Add transaction/version semantics if related values must change atomically.
- **Medium — validation:** Procedure arity and value predicates require per-binding metadata and a policy for variadic procedures.
- **Medium — load ordering:** Decide whether unknown keys fail immediately or become pending overrides applied when a library later registers.
- **Medium — library reload:** Duplicate registration must preserve stable cell identity or explicitly reset it; replacing the cell would strand compiled callers.
- **Low — overhead:** Each function call adds a box read and forwarding call. Benchmark hot paths and exclude bindings that do not need customization.
- **Low — semantic scope:** This does not emulate Emacs dynamic/special variables, buffer-local values, advice, autoload rollback or feature unloading.

## 9. Validation matrix

| Case | `gxi` | normal `gxc` | `gxc -O` | FPO |
|---|---:|---:|---:|---:|
| Same-library ordinary function call changes | Required | Required | Required | Required |
| Imported ordinary function call changes | Required | Required | Required | Required |
| Ordinary value read changes | Required | Required | Required | Required |
| Captured stable wrapper remains live | Required | Required | Required | Required |
| Extracted implementation remains stale | Required | Required | Required | Required |
| Load config v1, then v2 in one process | Required | Required | Required | Required |
| Runtime file contains no imports | Inspect | Inspect | Inspect | Inspect |
| Unknown/duplicate key diagnostics | Required | Required | Required | Required |
| Function/value key separation | Required | Required | Required | Required |
| Partial-file error behavior | Required | Required | Required | Required |
| Concurrent reads during replacement | Optional MWE; required before production | Same | Same | Same |
| FPO entry-point retention | N/A | N/A | N/A | Required |

### Focused current-prototype check

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf 'default\nconfigured\n' >"$tmpdir/expected"

/opt/gerbil/bin/gxi \
  -e '(begin (import "playground/main") (main))' \
  >"$tmpdir/actual"

cmp "$tmpdir/expected" "$tmpdir/actual"
```

### Normal compiled current-prototype check

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/build"
printf 'default\nconfigured\n' >"$tmpdir/expected"

/opt/gerbil/bin/gxc -d "$tmpdir/build" playground/lib.ss
/opt/gerbil/bin/gxc \
  -d "$tmpdir/build" \
  -exe \
  -o "$tmpdir/build/runtime-customization" \
  playground/main.ss

"$tmpdir/build/runtime-customization" >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

These validate only the existing direct-function prototype, not the recommended value/capture/FPO contract. Current repository behavior is at:

- `playground/lib.ss:1-5`
- `playground/main.ss:1-12`
- `playground/config.scm:1-6`

It demonstrates one imported function replacement but no value cell, internal call, stable capture, repeated reload or optimization contract.

## 10. Additional probe result

Disposable fixture `/tmp/wbg-gambit-load.SdgnQ5` used stable function wrappers, an identifier-macro value, fully qualified config calls and two runtime source loads.

Observed under `gxi`, normal `gxc`, and `gxc -O`:

```text
((default-site default x) default x)
((site-one one x) one x)
((site-two two x) two x)
```

The second element came from a function reference captured before either reload, confirming stable-wrapper liveness.

FPO initially stripped the dynamically referenced registry entry point. A corrected fixture at `/tmp/wbg-gambit-fpo-retain.yk2LKX` added:

```scheme
(declare (not optimize-dead-definitions))
```

and produced the same three lines under `-O -full-program-optimization`.

**Confidence:** High for the architectural recommendation on the installed Gerbil/Gambit snapshot; medium-high across future releases because FPO and retention behavior require regression testing.