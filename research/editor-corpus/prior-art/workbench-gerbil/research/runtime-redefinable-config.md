# Runtime-redefinable Gerbil configuration research

## Answer

The idiomatic minimal design is an **explicit mutable runtime hook owned by the application**, plus an exported setter. The trusted config uses `extern` to resolve that setter’s module-qualified runtime binding, calls it, and later application calls dereference the updated hook.

This is preferable to silently redefining a module function with `def`:

- Runtime `eval` operates in a top-level namespace, not the application module namespace.
- `extern` maps a config-local identifier to the exact module runtime symbol.
- `set!` mutates that runtime binding; `def` in the config generally creates/rebinds a top-level binding instead.
- Keeping an explicit `set!` in compiled application code also tells Gerbil’s optimizer that the hook is mutable.
- No `lib.ss` or custom macro is required.

## Recommended two-file MWE

### `playground/main.ss`

```scheme
namespace: playground/main

(import :gerbil/expander)

(export main set-greeting!)

;; A variable containing replaceable behavior.
(def greeting
  (lambda ()
    "default"))

;; The application owns mutation of its hook.
(def (set-greeting! proc)
  (set! greeting proc))

(def (main . args)
  (gerbil-load-expander!)
  (eval '(include "playground/config.scm"))
  ;; This lookup occurs after configuration, so it sees the replacement.
  (displayln (greeting)))
```

### `playground/config.scm`

```scheme
(extern namespace: playground/main
  set-greeting!)

(set-greeting!
 (lambda ()
   "configured"))
```

Expected stdout:

```text
configured
```

The explicit `namespace:` declaration makes the runtime name stable and obvious. Without it, a file module derives its namespace from its module/package path.

`set-greeting!` is exported to document it as the public customization seam. Export is not what makes `extern` work: `extern` links directly to a runtime symbol and can therefore bypass the export boundary. Export should not be treated as a security boundary.

## Why this works

1. `gerbil-load-expander!` installs Gerbil’s runtime expander/compiler and is idempotent:  
   `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:14-30,248-258`.
2. In compiled programs, unqualified `eval` identifiers live in the top-level namespace rather than the enclosing module namespace:  
   `/home/jay/Code/gerbil/doc/guide/eval.md:19-60`.
3. The documented solution is to load the expander and use `extern namespace:`:  
   `/home/jay/Code/gerbil/doc/guide/eval.md:62-93`.
4. `extern` registers a local identifier against an external runtime binding ID:  
   `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:195-213`.
5. References and assignments resolve that binding ID:  
   `/home/jay/Code/gerbil/src/gerbil/expander/compile.ss:160-175`.
6. Runtime evaluation compiles `%#set!` into an actual Scheme `set!`; `extern` itself has no runtime action after expansion:  
   `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:429-444,488-510`.
7. Gerbil’s optimizer records explicit assignments as mutators and avoids type refinement for mutable bindings:  
   `/home/jay/Code/gerbil/src/gerbil/compiler/optimize-xform.ss:99-106`;  
   `/home/jay/Code/gerbil/src/gerbil/compiler/optimize-top.ss:353-363`.

## Binding distinctions

### Ordinary module/lexical binding

A module `def` creates a module-scoped binding with a namespaced runtime symbol. A lexical binding inside `let` or a function activation is not discoverable through `eval`.

Existing procedure values already captured before configuration also remain unchanged:

```scheme
(let (old-greeting greeting)
  ;; Updating greeting does not mutate old-greeting.
  ...)
```

Application call sites must dereference `greeting` after configuration, or call a wrapper that does so.

### `def` is not runtime replacement

This does **not** reliably replace the application binding:

```scheme
(extern namespace: playground/main greeting)
(def greeting (lambda () "configured"))
```

Top-level contexts permit rebinding their expander environment, whereas module contexts do not:  
`/home/jay/Code/gerbil/src/gerbil/expander/core.ss:670-674`.

An in-memory Gerbil check confirmed that `def` after `extern` left the module’s caller observing `"old"`, while `set!` made it observe `"new"`.

### Imported and exported bindings

Exports define what ordinary module clients may import:  
`/home/jay/Code/gerbil/doc/guide/intro.md:1098-1146`.

On the installed Gerbil, assigning an ordinarily imported binding mutated the shared module binding in an interpreter check. For runtime-loaded config, however, the authoritative guide uses `extern` rather than a self-import or runtime import. That avoids dependency loading and module metadata complications.

### Macros

No custom macro is needed. `extern`, `include`, and `set!` are existing syntax forms; loading the expander is necessary in a compiled executable. A macro itself is compile-time behavior and is not an Emacs-like runtime-rebindable function. A macro can only support this design by expanding calls into a runtime hook lookup.

## Does the function need to live in `lib.ss`?

No. The official guide introduces `lib.ss` only to demonstrate configuration access to a separate library namespace:

- Runtime configuration layout and `lib.ss`:  
  `/home/jay/Code/gerbil/doc/guide/eval.md:95-127`.
- Package/module namespace derivation:  
  `/home/jay/Code/gerbil/doc/guide/eval.md:129-158`.

For this MWE, `main.ss` already owns and links the hook. A `lib.ss` becomes useful when:

- multiple modules use the hook;
- the hook needs an application-independent stable namespace;
- the executable should only orchestrate startup.

In that variant, `main.ss` must import the library, and the config should `extern` its setter from the library’s declared namespace.

## Alternatives

### 1. Config directly mutates the hook

Config:

```scheme
(extern namespace: playground/main
  greeting)

(set! greeting
  (lambda ()
    "configured"))
```

This is the smallest and most Emacs-like direct replacement. It was confirmed in an in-memory module test: a module caller returned `"old"` before the external `set!` and `"new"` afterward.

**Tradeoff:** the application compiler cannot see that the dynamically evaluated config mutates `greeting`. With `-O` or whole-program optimization, an apparently immutable function could be specialized or inlined. The explicit application setter is more robust because its `set!` is visible during compilation. Direct mutation also exposes application representation rather than an intentional API.

### 2. Config evaluates to the replacement value

Application:

```scheme
(def greeting
  (lambda () "default"))

(def (main . args)
  (gerbil-load-expander!)
  (set! greeting
        (eval '(include "playground/config.scm")))
  (displayln (greeting)))
```

Config:

```scheme
(lambda ()
  "configured")
```

This avoids namespaces and `extern` entirely. The application receives and installs the config’s result, and its `set!` remains visible to the optimizer.

**Tradeoff:** this is a narrow result protocol rather than an imperative Emacs-style config. Multiple settings would require a record, association list, hash table, or installer procedure.

## Parameters and method tables

### Parameters

A hook may be stored in a parameter:

```scheme
(def current-greeting
  (make-parameter (lambda () "default")))

;; later
(displayln ((current-greeting)))
```

The config can resolve `current-greeting` with `extern` and call:

```scheme
(current-greeting (lambda () "configured"))
```

Gerbil documents parameter creation and dynamic `parameterize` use at:  
`/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:308-322`.

Parameters are best for dynamically scoped or temporarily overridden behavior. Their value is associated with a dynamic/thread parameterization, so they are not automatically equivalent to one process-wide Emacs function cell. For startup customization in one thread they work, but an ordinary global hook plus setter has clearer global semantics.

### Method tables

Gerbil supports method rebinding through `defmethod ... rebind:` and `bind-method!`:

- Syntax: `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:455-464`.
- Macro expansion: `/home/jay/Code/gerbil/src/gerbil/core/mop.ss:624-659`.
- Runtime method-table mutation: `/home/jay/Code/gerbil/src/gerbil/runtime/mop.ss:950-969`.

This is unnecessary for one replaceable function. Moreover, specialized class method tables are cached:  
`/home/jay/Code/gerbil/src/gerbil/runtime/mop.ss:1018-1042`. Runtime rebinding after specialization therefore needs additional careful validation and is not the smallest reliable customization mechanism.

## Current repository behavior

- `playground/main.ss:1-7` only loads and evaluates the config.
- `playground/config.scm:1` prints `Hello from config!`.
- Running `/opt/gerbil/bin/gxi playground/main.ss` currently succeeds and prints `Hello from config!`.
- The current example demonstrates runtime code loading but defines no application hook and performs no subsequent application call, so it does not yet demonstrate runtime replacement.
- `plans/` is empty. The repository is on unborn `main`; `playground/` is untracked and nothing is staged.
- Installed toolchain: `/opt/gerbil/bin`, Gerbil `v18.2-20260722T1909420700`.

## Findings and risks

- **Medium — semantic:** A config-side `def` is not a replacement for an existing module binding. Use `set!`, an explicit setter, or a returned-value protocol.
- **Medium — optimization:** Direct config-only mutation is invisible while compiling the application. Prefer an application setter or application-side assignment, particularly when using `-O`. Whole-program optimization remains unverified for name-based runtime `extern` entry points.
- **Medium — security:** `eval` executes arbitrary Scheme. `extern` is not sandboxing and module exports do not constrain it. Only trusted configuration is appropriate.
- **Medium — concurrency:** Load process-global customization before worker threads begin, or synchronize both updates and reads.
- **Low — path:** The quoted include path is resolved relative to the process working directory in the current example; supported commands must run from the repository root.
- **Low — errors:** Missing files, malformed forms, wrong namespaces, non-procedure replacements, and config exceptions propagate unless explicitly handled.
- **Confidence:** High on Gerbil binding/eval semantics and the recommended mechanism; medium-high on the exact compiled MWE until its proposed files are compiled and run. Full-program optimization is unresolved.

## Evidence-backed validation commands

### Focused interpreted check

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf 'configured\n' >"$tmpdir/expected"
/opt/gerbil/bin/gxi playground/main.ss >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

`gxi file` invokes an exported `main`:  
`/home/jay/Code/gerbil/doc/reference/dev/bach.md:78-103`.

### Full compiled-runtime check

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf 'configured\n' >"$tmpdir/expected"
/opt/gerbil/bin/gxc \
  -d "$tmpdir" \
  -exe \
  -o "$tmpdir/runtime-customization" \
  playground/main.ss
"$tmpdir/runtime-customization" >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

Executable modules must export `main`, and `gxc -exe -o` is the documented compilation route:  
`/home/jay/Code/gerbil/doc/guide/intro.md:1250-1277`;  
`/home/jay/Code/gerbil/doc/reference/dev/bach.md:88-107`.

An additional `-O` build is advisable if optimized builds are intended. Do not assume `-full-program-optimization` preserves dynamically named `extern` entry points until separately attested.