# Gerbil/Gambit runtime redefinition architecture

## Executive answer

Gerbil does **not** provide an automatic Emacs-style function/value cell behind every module binding. A module definition is compiled to a Gambit global whose identity is an interned namespaced symbol such as `app/lib#greeting`; imports and re-exports normally resolve to that same runtime binding ID.

Two architectures can satisfy the requested user ergonomics:

1. **Direct mutation of ordinary definitions**
   - User config imports one statically maintained customization facade and uses `set!`.
   - The facade re-exports bindings from application libraries; it does not create new cells.
   - Every module defining externally mutable globals must be compiled under `(declare (separate))` if same-module and optimized calls must consistently observe mutation.
   - This uses public Gerbil/Gambit forms, but runtime importing/re-evaluating the facade has loading and initialization risks, and full-program optimization plus runtime `eval` currently fails on the installed toolchain.

2. **One central registry plus macro-created mutable cells**
   - Each customizable definition is declared with a framework macro.
   - Ordinary source calls still look like `(greeting who)`, but expand to a box lookup or stable forwarding function.
   - User config references only one central runtime namespace and one generic `redefine!` operation.
   - This passed `gxi`, normal `gxc`, `gxc -O`, and—when configuration was invoked without runtime `eval`—full-program optimization.
   - It is a **custom framework built from supported Gerbil primitives**, not a built-in Gerbil redefinition facility.

There is no public Gerbil operation that takes an arbitrary symbol and mutates its global cell directly. Gambit has working internal primitives `##make-global-var`, `##global-var-ref`, and `##global-var-set!`, but they are undocumented implementation APIs and remain invisible to compiler optimization. They should not be the foundation of a portable application architecture.

## Authoritative baseline

Research was performed against:

- Gerbil `v18.2-20260722T1909420700`
- Gerbil source commit `0618730d4e30bf3f48538d6b09722ad3b6056414`, described as `v0.18.2-1-g0618730d`
- Gambit `v4.9.7-6-g64f4d369`

All disposable fixtures were created under `/tmp`.

---

## 1. Binding identity and ordinary calls

### Module definitions become namespaced Gambit globals

A file module derives its module name and namespace from its package and file path unless `namespace:` overrides it:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1098-1167`
- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:140-187`

Gerbil creates runtime binding IDs by joining the module namespace, `#`, and identifier:

- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:710-739`

For example:

```scheme
namespace: app/lib

(def (greeting) "default")
```

creates the runtime global symbol:

```scheme
app/lib#greeting
```

Gambit likewise documents that module `M` globals conventionally occupy namespace `M#`:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6290-6324`

`##namespace` is a **lexical identifier mapping**, not a runtime namespace object. It maps source identifiers to global symbols and has macro-like lexical scope:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6290-6314`

### Imports preserve the source runtime binding

Gerbil resolves an export to its original binding and creates an import binding with that binding ID:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:535-563`

Thus a client’s ordinary call:

```scheme
(import :app/lib)
(greeting)
```

normally compiles as a reference to `app/lib#greeting`, not a copied procedure value and not `client#greeting`.

Re-exporting also preserves that identity. A facade such as:

```scheme
namespace: app/customize

(import :app/a :app/b)
(export (import: :app/a)
        (import: :app/b))
```

does **not** create `app/customize#greeting`. It exports the original binding, e.g. `app/a#greeting`.

A `/tmp` probe confirmed:

```text
app/customize#greeting => unbound
app/a#greeting         => bound
```

Consequences:

- `(import :app/customize)` followed by `(set! greeting ...)` can mutate the original imported binding.
- `(extern namespace: app/customize greeting)` does **not** target a re-exported `app/a#greeting`, because no `app/customize#greeting` runtime global exists.
- `defalias` and export renaming are compile-time aliases, not new mutable runtime alias cells:
  - `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:82-86`
  - `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:710-719`

### Captured procedure values remain captured

Changing a global does not mutate a procedure value already saved elsewhere:

```scheme
(def old greeting)
(set! greeting replacement)

(old)       ; old procedure
(greeting)  ; replacement, if this call remains late-bound
```

No option can make arbitrary lexical captures retroactively change. The registry MWE likewise showed an explicitly captured procedure continuing to return the old result.

---

## 2. `extern`, namespaces, and runtime `eval`

Gerbil’s authoritative runtime-evaluation guide states:

- `eval` in compiled programs uses the top-level namespace rather than the enclosing module namespace.
- Fully qualified names work.
- `extern namespace:` is the intended convenient mapping.
- A compiled application must call `gerbil-load-expander!` before evaluating forms that require Gerbil expansion.

Evidence:

- `/home/jay/Code/gerbil/doc/guide/eval.md:11-93`
- `/home/jay/Code/gerbil/doc/guide/eval.md:95-158`
- `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:14-31`
- `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:248-258`

Example:

```scheme
(extern namespace: app/lib
  greeting)

(set! greeting
  (lambda () "configured"))
```

`extern` expands the local identifier to an external runtime symbol:

- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:445-475`

It registers an extern binding with the selected binding ID:

- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:687-693`

References and assignments then resolve that binding ID:

- `/home/jay/Code/gerbil/src/gerbil/expander/compile.ss:160-175`

Runtime evaluation compiles the expanded assignment into an actual Scheme `set!`; `extern` itself has no runtime effect after expansion:

- `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:429-510`

### `def` is not a replacement operation

A config-side `def` is not a reliable way to replace an existing extern or module binding. Top-level expander contexts may rebind syntax environments while module contexts do not:

- `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:670-674`

Use `set!`, a cell mutation, generic-method binding, or module re-evaluation.

### Eval environments are not first-class module namespaces

Gambit’s documented `eval` evaluates in the global interaction environment; its optional environment argument is ignored:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4626-4643`

Gerbil adds expansion and module-import handling, but does not expose an Emacs-like runtime namespace object. Runtime imports are compiled to `__eval-import`, whose module contexts are cached and evaluated once per context:

- `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:85-88`
- `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:104-188`

A dynamic `(import :app/customize)` therefore means “load and evaluate a module context”, not “select a harmless namespace map.” If source contexts must be reconstructed in a compiled process, initializers and imported source dependencies may be evaluated. The official config guide consequently demonstrates `extern`, not a runtime self-import of every application library.

---

## 3. Symbol-based creation, lookup, and mutation

### Supported `eval` route

A fully qualified symbol can be used as generated code:

```scheme
(def sym 'app/runtime#setting)

(eval `(define ,sym 7))
(eval sym)                    ; => 7
(eval `(set! ,sym 8))
(eval sym)                    ; => 8
```

This creates or updates a global through evaluated source code. The replacement expression must itself be valid code. A procedure object cannot simply be unquoted into source:

```scheme
(eval `(set! app/runtime#f ,some-procedure)) ; illegal expression
```

A lambda expression in the generated form works, but passing arbitrary already-created values requires an explicit transfer mechanism.

### Internal Gambit global-variable primitives

The installed Gambit supports:

```scheme
(def gv (##make-global-var 'app/runtime#setting))
(##global-var-ref gv)
(##global-var-set! gv value)
```

A `/tmp` MWE confirmed that these primitives:

- report a newly created global as unbound;
- can assign it;
- can subsequently look it up by the same symbol;
- work under `gxi`, normal `gxc`, and `gxc -O`.

Compiler primitive declarations are at:

- `/home/jay/Code/gerbil/src/gambit/gsc/_prims.scm:1641-1646`

These are `##` implementation primitives, absent from the public Gambit manual. They are not a Gerbil-approved application API. More importantly, the compiler does not infer from a symbolic `##global-var-set!` that a source binding is mutable.

---

## 4. Compilation, `block`, `separate`, `-O`, and FPO

### Gerbil emits `block` by default

Although standalone Gambit’s documented default is `separate`, Gerbil-generated module runtime files begin with:

```scheme
(declare (block) (standard-bindings) (extended-bindings))
```

Evidence:

- Gambit defaults: `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:5145-5174`
- Gerbil output: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:787-804`

Source declarations are carried into the generated module body, and declarations are module-local:

- `/home/jay/Code/gerbil/src/gerbil/compiler/compile.ss:453-464`
- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:698-704`

### Meaning of `block` and `separate`

Gambit documents:

- declarations are compiler directives ignored by the interpreter;
- they have macro-like lexical scope;
- `block` allows the compiler to assume that globals defined and not assigned in the current file will never be mutated;
- `separate` withholds that assumption.

Evidence:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4886-4910`

The optimizer recognizes a permanent single global definition only when its definition environment is `block`:

- `/home/jay/Code/gerbil/src/gambit/gsc/_ptree1.scm:323-331`

Global procedure inlining additionally requires a `block` definition site:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4921-4939`

Therefore, for direct external mutation:

```scheme
namespace: app/lib
(declare (separate))

(def setting "default")
(def (greeting) "default")
```

must be the policy for every provider module whose same-module or whole-program-optimized references must stay late-bound. `separate` is module-wide, not a per-binding declaration, so splitting customizable bindings into focused modules can limit its optimization cost.

Gerbil’s own optimizer also records visible `%#set!` forms as mutators and avoids type refinement for those bindings:

- `/home/jay/Code/gerbil/src/gerbil/compiler/optimize-xform.ss:99-106`
- `/home/jay/Code/gerbil/src/gerbil/compiler/optimize-top.ss:353-363`

A mutation appearing only later in evaluated config is not visible to that analysis.

### Tested matrix

#### Same-module private function, no `separate`

Fixture: `/tmp/wbg-block-matrix.T6Gl95`

| Mode | Before | After external `set!` |
|---|---|---|
| normal `gxc` | `default` | `default` |
| `gxc -O` | `default` | `default` |

This demonstrates the `block` hazard directly.

#### Exported binding called across modules through one facade

Fixture: `/tmp/wbg-runtime-direct.zSQ7bj`

A config imported one central facade, then assigned re-exported `greeting` and `value`. On this snapshot, `gxi`, normal `gxc`, and separate-module `gxc -O` all showed the configured values at imported and same-provider call sites.

That is useful current behavior, but it is not a guarantee for same-provider calls: the documented `block` permission and the private-binding control above require `separate` for an architectural contract.

#### Full-program optimization

Fixture: `/tmp/wbg-fpo-global.UYnGpL`

A symbolic global mutation followed by calls from the provider and importer produced:

```text
(default default default default-value default-value)
(default default default default-value default-value)
```

under `-O -full-program-optimization`.

Adding `(declare (separate))` to the provider changed the second line to configured values:

- fixture: `/tmp/wbg-fpo-separate.EeMCTA`

FPO additionally enables aggressive inline and dead-definition declarations and combines static module sources:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:343-388`

Definitions referenced only by dynamically constructed symbols may be tree-shaken. Gambit warns that externally used definitions may require `not optimize-dead-definitions`:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:5098-5114`

### Runtime `eval` under FPO is currently broken

The current playground built successfully with:

```text
gxc -O -full-program-optimization
```

but exited 70 in `gerbil-load-expander!`:

```text
Unbound variable: __eval-import
```

Fixture: `/tmp/wbg-current-fpo.JGyn48`

This matches Gerbil’s own FPO warning that the tree shaker may not retain complete compiled modules:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:370-389`

Accordingly:

- Separate-module `gxc -O` is viable and tested.
- FPO plus runtime Gerbil config evaluation is unsupported on this snapshot.
- A cell registry itself can survive FPO when configuration is installed without runtime `eval`; that was tested separately.

---

## 5. Central facade: what it can and cannot do

### Static re-export facade

A single user-facing import is possible:

```scheme
namespace: app/customize

(import :app/render
        :app/routes
        :app/settings)

(export (import: :app/render)
        (import: :app/routes)
        (import: :app/settings))
```

Trusted config:

```scheme
(import :app/customize)

(set! greeting
  (lambda (who) ...))

(set! site-name "My site")
```

Properties:

- User config names only `:app/customize`.
- There is no per-binding setter.
- The facade must statically import/re-export each contributing module.
- Conflicting names require explicit renaming.
- All provider modules need a suitable `separate` policy.
- Re-exported runtime identities remain their source globals.
- Runtime config must have usable module metadata/source and may trigger module evaluation.
- `(extern namespace: app/customize greeting)` will not find re-exported source globals.

This uses Gerbil’s documented import/export machinery:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1098-1146`

It is Gerbil-supported, but it is a statically maintained facade, not an arbitrary runtime namespace.

### No arbitrary runtime namespace aliasing

Neither of these creates a central runtime cell:

```scheme
(export (rename: source-name public-name))
(defalias public-name source-name)
```

Nor can a namespace declaration dynamically map unknown names discovered at runtime. Gambit `##namespace`, Gerbil imports, Gerbil re-exports, and `extern` are expansion-time mappings.

A central module can instead define actual wrapper globals, boxes, parameters, or a registry. At that point all callers must intentionally use those central bindings; this is a framework seam rather than transparent aliasing of arbitrary existing definitions.

---

## 6. Macro-defined rebindable cells and central registry

This is the strongest option when the contract includes:

- one config-facing namespace;
- no per-binding setter;
- ordinary-looking calls throughout many libraries;
- predictable behavior under optimization;
- no dependence on raw global-table internals.

### Tested framework sketch

```scheme
namespace: app/runtime

(export defrebindable redefine! rebindable-ref)

(def registry (make-hash-table-eq))

(def (register-rebindable! key cell)
  (when (hash-key? registry key)
    (error "duplicate rebindable key" key))
  (hash-put! registry key cell))

(def (rebindable-ref key)
  (cond
   ((hash-get registry key) => unbox)
   (else
    (error "unknown rebindable key" key))))

(def (redefine! key value)
  (cond
   ((hash-get registry key)
    => (cut set-box! <> value))
   (else
    (error "unknown rebindable key" key))))

(defsyntax (defrebindable stx)
  (syntax-case stx ()
    ((_ id key initial)
     (identifier? #'id)
     (with-syntax ((cell (stx-identifier #'id #'id "::cell")))
       #'(begin
           (def cell (box initial))
           (register-rebindable! key cell)
           (defsyntax id
             (syntax-rules ()
               ((_ arg (... ...))
                ((unbox cell) arg (... ...)))
               (id
                (identifier? #'id)
                (unbox cell)))))))))
```

Library A:

```scheme
namespace: app/a
(import :app/runtime)
(export greeting site-name call-inside)

(defrebindable greeting 'greeting
  (lambda (who)
    (string-append "default " who)))

(defrebindable site-name 'site-name
  "default-site")

(def (call-inside who)
  (greeting who))
```

Library B:

```scheme
namespace: app/b
(import :app/a)
(export call-imported read-site)

(def (call-imported who)
  (greeting who))

(def (read-site)
  site-name)
```

User config names only the central runtime namespace:

```scheme
(extern namespace: app/runtime
  redefine!)

(redefine! 'greeting
  (lambda (who)
    (string-append "configured " who)))

(redefine! 'site-name
  "configured-site")
```

The macro is compile-time machinery, but it expands each ordinary read or call to a runtime box dereference. The macro itself is not being redefined.

Fixture: `/tmp/wbg-registry-macro.pppRlk`

Passed:

- source-module `gxi`;
- normal `gxc`;
- separate-module `gxc -O`;
- `-O -full-program-optimization` when `redefine!` was invoked directly rather than through currently broken runtime `eval`.

All ordinary calls and variable reads observed the replacement. A procedure explicitly captured before replacement remained the old procedure.

### Stable wrapper variant

For functions, a generated stable forwarding procedure can make captured references remain late-bound:

```scheme
(defsyntax (defrebindable-function stx)
  (syntax-case stx ()
    ((_ (id arg ...) key body ...)
     (with-syntax ((cell (stx-identifier #'id #'id "::cell")))
       #'(begin
           (def cell
             (box (lambda (arg ...) body ...)))
           (register-rebindable! key cell)
           (def (id arg ...)
             ((unbox cell) arg ...)))))))
```

This keeps `id` as an ordinary runtime function, so importing and capturing `id` captures the stable forwarding procedure. It costs one extra call and box read. Variable bindings still need an identifier macro, explicit accessor, or ordinary registry lookup.

### Framework limitations

- Existing `def` bindings must be migrated and callers recompiled.
- Keys need a collision policy, preferably qualified symbolic keys.
- Duplicate registration and module reload need an explicit policy: preserve override, reset default, or replace registration.
- A plain hash table is not safe for concurrent mutation. Load configuration before starting workers or protect registry access with a mutex/synchronized table.
- Replacement type and procedure arity should be validated if config errors need early diagnosis.
- The framework is application code, not a Gerbil language guarantee.

Supported primitives underneath it are documented:

- boxes: `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4475-4504`
- Gerbil hash tables: `/home/jay/Code/gerbil/doc/reference/gerbil/runtime/hash-tables.md:3-33`
- hash lookup/mutation: `/home/jay/Code/gerbil/doc/reference/gerbil/runtime/hash-tables.md:75-96`

---

## 7. Parameters

A parameter can hold replaceable behavior:

```scheme
(def current-greeting
  (make-parameter
   (lambda (who)
     (string-append "default " who))))

;; ordinary use requires two calls
((current-greeting) who)

;; replace current cell
(current-greeting replacement)
```

Parameters are genuinely supported Gerbil/Gambit facilities:

- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:308-322`
- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:11182-11208`

However, their semantics are dynamic:

- there is one global dynamic environment plus thread-local dynamic environments;
- `parameterize` creates a new local cell;
- child threads inherit bindings/cells from their parent;
- extending one thread’s dynamic environment does not extend another’s.

Evidence:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:11099-11116`
- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:11273-11312`

Parameters are appropriate for dynamically scoped policy, temporary test overrides, ports, request context, or per-thread configuration. They are not the clearest model for a single Emacs-like process-wide function cell. They also require callers to know that the binding is a parameter.

---

## 8. Generic functions and MOP method rebinding

### `:std/generic`

Gerbil’s standard generic library is explicitly designed around mutable dispatch tables:

```scheme
(defgeneric render
  (lambda args
    (error "no render method")))

(defmethod (render (obj Widget))
  ...)
```

`defgeneric` creates a generic table and expands ordinary calls to generic dispatch:

- `/home/jay/Code/gerbil/src/std/generic/macros.ss:17-53`

A later `defmethod` for the same signature replaces the table entry. The implementation uses mutexes and invalidates dispatch caches after redefinition:

- `/home/jay/Code/gerbil/src/std/generic/dispatch.ss:40-104`
- `/home/jay/Code/gerbil/src/std/generic/dispatch.ss:119-151`

This is a genuinely supported runtime-redefinition mechanism where multimethod dispatch is already the correct domain abstraction. It is not a general replacement for arbitrary functions or variables, and config must load the generic’s compile-time metadata to use `defmethod`.

### Core class MOP

Core class methods support:

```scheme
(defmethod {method Type}
  implementation
  rebind: #t)
```

The macro emits `bind-method!`:

- `/home/jay/Code/gerbil/src/gerbil/core/mop.ss:624-659`

`bind-method!` replaces a method-table entry when `rebind?` is true:

- `/home/jay/Code/gerbil/src/gerbil/runtime/mop.ss:950-978`

Caution: specialized class method tables are cached:

- `/home/jay/Code/gerbil/src/gerbil/runtime/mop.ss:1018-1072`

Rebinding a base-class method does not visibly invalidate every already-specialized descendant cache. Sealed/specialized classes therefore require dedicated testing. `:std/generic` has clearer cache invalidation for runtime extension.

---

## 9. Module reload and re-evaluation

### Gerbil loader behavior

`load-module` caches modules by string and evaluates each once:

- `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:8-73`

`reload-module!`:

- rejects builtin modules;
- reloads a source `.scm`;
- loads a newer compiled path when one appears;
- otherwise leaves the loaded compiled module alone.

Evidence:

- `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:75-105`

The interactive `reload` utilities re-import module contexts and, for library prefixes, reload matching modules in original load order:

- `/home/jay/Code/gerbil/src/std/interactive.ss:13-64`

The expander’s `import-module` accepts `reload?` and `eval?` flags and replaces its cached module context when requested:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:91-120`
- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:140-187`

### Gambit dynamic loading constraints

Gambit `load` executes source or compiled object code:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6063-6083`

The same compiled `.oN` cannot be loaded twice in one process; a newly compiled `.oM` with a larger suffix can be loaded:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6093-6128`

### Tested source reload

Fixture: `/tmp/wbg-reload-source.qQWJ4X`

A library was imported as version 1, rewritten under `/tmp`, then re-imported with:

```scheme
(import-module path #t #t)
```

Both `gxi` and a normal compiled executable produced:

```text
(v1 v1 v1 v1)
(v2 v2 v2 v1)
```

Ordinary imported and same-module calls saw the newly defined globals. A procedure captured before reload remained version 1.

### Why reload is not the primary configuration architecture

Reload:

- reruns module initializers and may reset state or repeat side effects;
- changes runtime globals but not already captured values;
- does not retroactively re-expand macros in existing clients;
- can create incompatible class/type descriptors while old instances remain;
- may conflict with one-time registry registration;
- cannot reload builtin executable modules through `reload-module!`;
- still faces `block`, inlining, dead-definition, and FPO concerns;
- requires source or a new dynamic object version.

It is useful for interactive development and controlled plugin/module replacement, not as a small, predictable Emacs-like customization layer.

---

## 10. Design comparison

| Design | User config names | Ordinary call syntax | Existing ordinary `def` | Optimization contract | Classification |
|---|---|---:|---:|---|---|
| Direct `extern` + `set!` | Every provider namespace | Yes | Yes | Provider needs `separate`; FPO/eval problematic | Public forms; not a documented hot-reload framework |
| Static central re-export facade + `set!` | One facade module | Yes | Yes | Provider needs `separate`; dynamic import/re-evaluation concerns | Gerbil-supported static facade |
| Central map to raw global symbols | One registry | Yes | Yes | Needs `separate`, retention declarations; uses internal `##` API | Custom and non-portable |
| Macro-defined cells + registry | One central namespace/key API | Yes | No migration-free support | Strong across separate `-O`; cell path passed FPO | Custom framework on supported primitives |
| Parameters | One parameter namespace | Usually `((p) ...)` | No | Runtime cell semantics clear | Supported, dynamically scoped |
| `:std/generic` | Generic module/config context | Yes | Only generic calls | Cache invalidation implemented | Supported standard library |
| Core MOP methods | Type/generic context | Method syntax | Only method calls | Specialized-cache caveats | Supported MOP |
| Module reload | Module path | Yes after reload | Yes | Initializer, capture, optimizer, dynamic loader risks | Supported development facility |

### Practical boundary

If preserving completely ordinary existing `def` forms is mandatory, the closest supported design is:

1. statically maintained central re-export facade;
2. user config imports only that facade;
3. user config performs direct `set!`;
4. every defining module that may contain affected calls uses `(declare (separate))`;
5. configuration runs before threads;
6. FPO remains disabled until its runtime-eval failure and tree-shaking retention are solved.

If stronger optimization independence and one stable config namespace matter more than preserving ordinary definitions, macro-created cells plus one central registry provide the cleanest technical contract.

---

## 11. Current repository behavior

The repository currently demonstrates the direct-binding approach:

- `playground/lib.ss:1-5`
  - declares namespace `playground/lib`;
  - exports and ordinarily defines `greeting`.
- `playground/main.ss:1-13`
  - imports `lib`;
  - loads the runtime expander;
  - calls imported `greeting` before and after config evaluation.
- `playground/config.scm:1-5`
  - targets `playground/lib#greeting` with `extern`;
  - replaces it with `set!`.

There is no `(declare (separate))` in `lib.ss`, but `lib.ss` currently has no internal call site. Normal imported calls passed both source and compiled validation.

Exact observed stdout:

```text
default
configured
```

Current FPO compilation succeeds but execution fails while loading the runtime expander with unbound `__eval-import`.

No application files were modified during this research.

---

## 12. Evidence-backed validation commands

### Focused source-module validation

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

### Full normal compiled validation

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/build"

printf 'default\nconfigured\n' >"$tmpdir/expected"

/opt/gerbil/bin/gxc \
  -d "$tmpdir/build" \
  playground/lib.ss

/opt/gerbil/bin/gxc \
  -d "$tmpdir/build" \
  -exe \
  -o "$tmpdir/build/runtime-customization" \
  playground/main.ss

"$tmpdir/build/runtime-customization" >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

### Relevant optimized separate-module check

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/build"

printf 'default\nconfigured\n' >"$tmpdir/expected"

/opt/gerbil/bin/gxc -O \
  -d "$tmpdir/build" \
  playground/lib.ss

/opt/gerbil/bin/gxc -O \
  -d "$tmpdir/build" \
  -exe \
  -o "$tmpdir/build/runtime-customization" \
  playground/main.ss

"$tmpdir/build/runtime-customization" >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

This is an informative compatibility check, not proof that arbitrary future same-provider call sites are safe without `separate`.

### Scope and staging inspection

```sh
cd /home/jay/Code/workbench-gerbil
git status --short --untracked-files=all
git diff --cached --name-only
```

At research completion, no files were staged.

---

## Risks, unresolved gaps, and confidence

- **High:** FPO plus `gerbil-load-expander!`/runtime Gerbil `eval` fails on the installed snapshot.
- **High:** Direct symbolic mutation is not consistently observable without a `separate` policy; private same-module and FPO controls demonstrated stale calls.
- **High:** `##global-var-*` is internal Gambit machinery, not a stable public Gerbil API.
- **Medium:** Runtime importing a static customization facade may evaluate reconstructed module contexts and repeat initializers.
- **Medium:** FPO can remove definitions known only by dynamically generated symbols.
- **Medium:** Registry collision, reload, arity/type validation, and synchronization policies are application decisions.
- **Medium:** Core MOP rebinding and cached specialization need focused testing for each class hierarchy.
- **Low:** A central re-export facade handles only statically enumerated, non-conflicting exports.
- **Confidence:** High for binding identity, `extern`/`set!`, import/re-export identity, declaration semantics, loader behavior, and tested normal/`-O` behavior on this toolchain; medium-high across future Gerbil/Gambit releases; low for treating internal `##global-var-*` primitives as portable.