# GNU Emacs definition and redefinition model

## Concise answer

When Emacs reads the same name in separate forms, it normally interns that name to the same symbol in the default obarray. A symbol has distinct function and variable-value cells. `defun` expands to `defalias`, which normally records load/history metadata and calls `fset` to replace that symbol’s function cell.

Consequently, evaluating the same `defun` again replaces the live global function definition. Ordinary interpreted and byte-compiled calls retain the function-name symbol and consult its current function cell at call time. No module import is involved: `require` and `provide` control loading, not namespace visibility.

Lexical binding changes local variable and closure behavior, but does not make a named top-level `defun` lexically private. The name still denotes the process-visible symbol function cell.

Research baseline:

- Installed GNU Emacs: 30.2
- Official tag: `emacs-30.2`
- Tag commit: `29f3f150af5c5b065c3a9f39969429e5bb3285da`
- Local manual: `/nix/store/m8rvbsn5h1nx27wvk9ch9gxr8l2m8avx-emacs-nox-30.2/share/info/elisp.info.gz`

## 1. Interned symbols and separate cells

### Verified facts

Emacs symbols contain separate components for:

- print name;
- variable value;
- function definition;
- property list.

The reader normally interns a symbol name in the default global obarray. Reading the same name again therefore returns the same symbol object. Other obarrays and uninterned symbols created with `make-symbol` are exceptions.

A symbol in variable position uses its value binding, while a symbol naming a function uses its function cell:

```elisp
(setq example :value)

(defun example ()
  :function)

(list example (example))
;; => (:value :function)
```

The function and value definitions do not overwrite one another. This Lisp-2 separation is central to Emacs behavior.

Authoritative manual:

- [Symbol Components](https://www.gnu.org/software/emacs/manual/html_node/elisp/Symbol-Components.html)
- [Creating and Interning Symbols](https://www.gnu.org/software/emacs/manual/html_node/elisp/Creating-Symbols.html)
- [Symbol Forms](https://www.gnu.org/software/emacs/manual/html_node/elisp/Symbol-Forms.html)
- [Naming a Function](https://www.gnu.org/software/emacs/manual/html_node/elisp/Function-Names.html)

Official source locates `intern` and its canonicalizing intern-table implementation at:

- [`src/lread.c:4941-5047`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/lread.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n4941)

### Constraint

The ordinary global obarray is convenient but collision-prone. Two packages defining the same function symbol target the same cell; the later definition wins. Emacs packages conventionally prefix public and private names rather than receiving isolated module namespaces automatically.

## 2. `defun`, `defalias`, and `fset`

### Verified implementation

`defun` is a macro. In Emacs 30.2 it parses declarations, documentation, and the interactive specification, constructs a function/lambda object, and expands to `defalias`:

- [`lisp/emacs-lisp/byte-run.el:402-443`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/byte-run.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n402)

The essential expansion is equivalent to:

```elisp
(defalias 'name
  (function
   (lambda (arguments ...)
     body ...)))
```

`defalias`:

1. associates the definition with the current load file;
2. records the previous definition in function history;
3. honors the `defalias-fset-function` property used by advice;
4. otherwise invokes `fset`;
5. optionally stores explicit documentation metadata.

Source:

- load/function history: [`src/data.c:924-981`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n924)
- advice hook and `fset` delegation: [`src/data.c:984-990`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n984)
- Lisp-visible `defalias`: [`src/data.c:993-1021`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n993)

`fset` is the low-level mutation operation. It checks for circular symbol indirection and then stores the supplied object in the function cell:

- [`src/data.c:889-921`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n889)
- [Accessing Function Cell Contents](https://www.gnu.org/software/emacs/manual/html_node/elisp/Function-Cells.html)

Thus:

```elisp
(defun greeting () "initial")
(defun greeting () "replacement")
```

mutates one shared function cell twice. It does not create two module-scoped functions or modify callers.

### Aliases versus captured function objects

These differ materially:

```elisp
(defalias 'live-alias 'target)
(defalias 'snapshot (symbol-function 'target))
```

`live-alias` stores a symbol and follows its function indirection, so replacing `target` is observed later. `snapshot` stores the current procedure object and remains attached to that old object.

## 3. Global function namespace under lexical binding

### Verified facts

Lexical binding controls local variable bindings and which variables a closure captures. It does not turn a top-level named `defun` into a file-private lexical definition.

With `lexical-binding: t`:

- a top-level `defun` still installs into the named symbol’s function cell;
- ordinary `(name ...)` calls still resolve that function name;
- lambda objects can capture lexical variables;
- lexical variable bindings are not stored in the symbol’s global value cell;
- macro-based local function constructs can rewrite or introduce local call behavior, but do not change what top-level `defun` means.

Authoritative manual:

- [Lexical Binding](https://www.gnu.org/software/emacs/manual/html_node/elisp/Lexical-Binding.html)
- [Naming a Function](https://www.gnu.org/software/emacs/manual/html_node/elisp/Function-Names.html)
- [Defining Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Defining-Functions.html)

The evaluator’s ordinary function-position path reads the symbol’s function field and follows symbolic indirection:

- [`src/eval.c:2512-2535`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n2512)

`funcall` similarly resolves a symbol’s current function definition:

- [`src/eval.c:3031-3064`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n3031)

## 4. Byte-compiled calls and redefinition

### Verified ordinary behavior

Ordinary byte-compiled named calls remain late-bound. The byte-code constant vector contains the function-name symbol; the call instruction looks up that symbol’s current function cell.

Relevant interpreter paths:

- global variable lookup: [`src/bytecode.c:608-633`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/bytecode.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n608)
- function call and symbol-function lookup: [`src/bytecode.c:740-815`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/bytecode.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n740)

Therefore an already-byte-compiled ordinary caller normally observes a subsequent `defun`, `defalias`, or `fset` replacement without recompilation.

### Exceptions

Late redefinition does not apply if compilation removed the named lookup:

- macros were expanded into other code;
- `defsubst` or `define-inline` inlined an old body;
- a compiler macro rewrote the call;
- a compiler optimization converted it to a direct operation;
- code captured the actual function object instead of retaining its symbol;
- native speed-3 compilation made direct intra-unit calls or inlined them.

Manual:

- [Inline Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Inline-Functions.html)
- [Macros and Byte Compilation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Compiling-Macros.html)
- [Advice and Byte Code](https://www.gnu.org/software/emacs/manual/html_node/elisp/Advice-and-Byte-Code.html)

The native compiler explicitly warns that speed-3 intra-unit direct calls make such functions unsafe to redefine without recompiling the unit:

- [`lisp/emacs-lisp/comp.el:2805-2818`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/comp.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n2805)
- [`lisp/emacs-lisp/comp.el:2865-2881`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/comp.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n2865)

## 5. Autoloads

### Verified behavior

`autoload` installs an autoload descriptor in the same function cell that will eventually hold the real definition. The descriptor includes the source file and optional documentation, interactive, and type metadata.

It does not overwrite an existing non-autoload definition:

- [`src/eval.c:2305-2343`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n2305)

On the first call, Emacs:

1. recognizes the autoload descriptor;
2. loads the named file;
3. checks that loading replaced the descriptor;
4. retries the original function call.

Source:

- load and verification: [`src/eval.c:2394-2442`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n2394)
- call retry: [`src/eval.c:3054-3060`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n3054)
- [Autoload](https://www.gnu.org/software/emacs/manual/html_node/elisp/Autoload.html)

Autoloading has targeted rollback: if loading fails, function definitions and `provide` changes made during that failed autoload are undone:

- [`src/eval.c:2346-2387`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n2346)

### Ordering implication

A user `defun` evaluated before an `autoload` form prevents that autoload form from replacing the definition. A later explicit `load` or `require`, however, can execute the library’s real `defun` and overwrite the user definition.

## 6. Features, `require`, `provide`, and after-load evaluation

### Verified behavior

`provide` adds a feature symbol to the global `features` list and runs callbacks waiting for that feature:

- [`src/fns.c:3650-3674`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/fns.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n3650)

`require`:

1. checks whether the feature is already in `features`;
2. loads a file only when it is absent;
3. verifies that loading provided the requested feature.

- [`src/fns.c:3689-3796`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/fns.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n3689)
- [Features](https://www.gnu.org/software/emacs/manual/html_node/elisp/Named-Features.html)

These operations are load coordination, not module imports:

- they do not create local binding copies;
- they do not qualify names;
- calling `require` again normally does not reload a provided feature;
- replacing a function cell does not require another `require`.

`with-eval-after-load` is an ordering facility. It arranges for its body to run after a feature is provided or matching file finishes loading, and runs immediately when the target is already loaded:

- local source: `/nix/store/m8rvbsn5h1nx27wvk9ch9gxr8l2m8avx-emacs-nox-30.2/share/emacs/30.2/lisp/subr.el.gz:6015-6062`
- [Hooks for Loading](https://www.gnu.org/software/emacs/manual/html_node/elisp/Hooks-for-Loading.html)

This is useful when a library’s later `defun` would otherwise overwrite an earlier user replacement. It is not part of the underlying function-cell mechanism.

## 7. Advice and documentation metadata

### Advice

Modern named-function advice composes wrappers around the symbol’s definition. `advice-add` installs:

- an advice representation around the current function;
- pending advice when the target is undefined or autoloaded;
- a `defalias-fset-function` hook so later `defun`/`defalias` replaces the inner implementation while preserving advice.

Source:

- advice representation and pending metadata: [`lisp/emacs-lisp/nadvice.el:454-470`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/nadvice.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n454)
- replacement of the advised inner definition: [`nadvice.el:472-498`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/nadvice.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n472)
- `advice-add` metadata and hook installation: [`nadvice.el:500-532`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/nadvice.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n500)
- [Advising Named Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Advising-Named-Functions.html)

A later ordinary `defun` therefore normally preserves named advice. Direct `fset` bypasses the `defalias` hook and can replace the whole advised wrapper.

### Documentation

A normal `defun` embeds its documentation string in the function definition. `defalias` can additionally place an explicit `function-documentation` property on the symbol:

- [`src/data.c:993-1017`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n993)

Advice replaces that property with dynamically generated documentation describing the advised function:

- [`nadvice.el:500-530`](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/nadvice.el?id=29f3f150af5c5b065c3a9f39969429e5bb3285da#n500)

Documentation and advice metadata are properties associated with the symbol and definition lifecycle; they are not needed merely to replace a callable function. Direct low-level mutation can leave metadata stale or discard wrapper behavior.

## 8. What redefinition does not do

Evaluating another `defun` is cell replacement, not atomic file or module replacement.

It does not:

- alter an invocation already executing the old function object;
- update procedure objects previously obtained through `symbol-function`;
- rewrite arbitrary closures that captured old values;
- update already-expanded macros or inlined call sites;
- undo definitions whose forms were removed from a reloaded file;
- roll back earlier top-level side effects after a later form errors;
- prevent a subsequently loaded library from redefining the same name;
- isolate packages from name collisions.

Reloading a file executes its top-level forms again. Registrations and other side effects may therefore occur twice, and a failure can leave a partially updated process.

## 9. Essential Gerbil mapping

### Verified Gerbil constraints

Existing repository research traces these Gerbil/Gambit facts:

- Gerbil module definitions compile to namespaced Gambit globals such as `app/lib#greeting`.
- Imports and re-exports normally preserve the source runtime binding identity.
- Gerbil has no automatic Emacs-style function and value cell behind every binding.
- Direct external mutation can be hidden by Gambit `block` assumptions or compiler optimization.
- Runtime `extern` is an expansion-time mapping to a qualified binding, not a process-wide runtime namespace object.
- Internal `##global-var-*` primitives exist but are undocumented implementation APIs.

Evidence:

- `research/gerbil-runtime-redefinition-architecture.md:36-111`
- `research/gerbil-runtime-redefinition-architecture.md:225-300`
- Gerbil binding IDs: `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:710-739`
- import identity: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:535-563`
- `extern`: `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:445-475`
- emitted `block` policy: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:787-804`
- Gambit declaration semantics: `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4886-4939`

No playground application files were inspected for this report.

### Essential mechanisms, not incidental Emacs features

To provide the narrow behavior “evaluate a new definition, then existing ordinary callers see it,” a Gerbil implementation needs:

1. **Stable shared identity**  
   Compiled callers and runtime configuration must identify the same logical binding.

2. **Mutable indirection**  
   The callable implementation must live behind a cell, registry entry, mutable global, or stable forwarding procedure.

3. **Late lookup in compiled callers**  
   Ordinary claimed call paths must dereference the current implementation at execution time. Merely mutating a global is insufficient if the compiler has inlined or directly captured it.

4. **A runtime installation operation**  
   Config evaluation must mutate the existing cell rather than define an unrelated config-local binding.

5. **A collision policy**  
   Large applications need qualified keys or namespaces. Emacs relies largely on name-prefix convention; a Gerbil design can make qualification explicit.

6. **Separate function/value domains if both are promised**  
   Function replacement alone does not emulate Emacs’s distinct function and value cells.

7. **Explicit capture and optimization semantics**  
   The contract must state whether captured procedures remain old, whether stable wrappers remain live, and which optimization modes preserve lookup.

Autoload descriptors, `features`, `require`, load history, advice, documentation, and unload support are useful lifecycle facilities but are not essential to the core replacement mechanism.

### Material implementation options

#### Option A: direct namespaced global mutation

Use a stable Gerbil/Gambit global binding and assign it with `set!` through a statically known qualified binding.

Advantages:

- preserves ordinary `def` and call syntax;
- closest to Emacs’s direct cell replacement.

Constraints:

- affected provider modules need a compiler policy such as `(declare (separate))`;
- optimizers and full-program tree shaking require validation;
- config must know binding namespaces or use a maintained facade;
- there is no supported public arbitrary-symbol global mutation API;
- captured procedure values remain stale.

#### Option B: macro-declared cells and a central registry

Each customizable function owns a private mutable cell and exports a stable forwarding function. Configuration calls one qualified central redefinition API with a qualified key.

Advantages:

- config need not import target modules;
- explicit dereference remains visible under optimization;
- the registry can separate function and value entries;
- a stable wrapper can make ordinary captured references remain live.

Constraints:

- definitions must opt into the framework and callers must be recompiled;
- this is a custom framework, not built-in Gerbil semantics;
- registration, duplicate keys, load ordering, validation, synchronization, and rollback require policies;
- forwarding adds a cell read and call.

#### Option C: Gerbil generic-function dispatch

Use `:std/generic` when the domain genuinely requires runtime method extension. Its dispatch table is mutable and cache invalidation is implemented.

This is appropriate for multimethods, not a general replacement for arbitrary functions and values.

### Recommendation

For a broad “config file imports no target modules” contract, prefer a central qualified registry with macro-created per-binding cells and stable forwarding functions. This reproduces the essential Emacs mechanism—stable identity plus late mutable indirection—without depending on Emacs-specific obarrays, load history, or undocumented Gambit global-table primitives.

Treat direct global `set!` as a narrower alternative only when provider compiler declarations and every supported build mode are tested.

## 10. Findings, severity, and residual gaps

- **High — compiled-call correctness:** A Gerbil design is not Emacs-like if optimized callers capture or inline the old implementation. Validate all claimed `gxc`, `-O`, and full-program optimization modes.
- **High — semantic overclaim:** Function replacement does not establish separate variable-value-cell behavior.
- **High — unsupported internals:** Gambit `##global-var-*` primitives should not be presented as a portable Gerbil API.
- **Medium — ordering:** A later library definition can overwrite an earlier user definition unless replacement is deferred until after load or represented as a pending override.
- **Medium — capture semantics:** Replacing a cell cannot retroactively change an arbitrary captured implementation object.
- **Medium — advice/metadata:** Direct replacement can discard wrapper composition or leave documentation/provenance stale unless the installation API manages them.
- **Medium — reload consistency:** Sequential configuration execution can partially apply changes and repeat side effects.
- **Medium — collision policy:** Emacs-style unqualified global names do not scale safely without prefixes; a Gerbil registry should use qualified keys.
- **Low — feature machinery:** `require`/`provide` and `with-eval-after-load` solve loading and ordering, not binding identity.
- **Unresolved:** Procedure arity validation, concurrent replacement visibility, multi-binding transactions, reset-to-default behavior, and pending overrides are product-level policies.
- **Confidence:** High for GNU Emacs 30.2 symbol-cell, `defun`, byte-code, autoload, feature, advice, and documentation behavior; high for the essential Gerbil mechanism mapping; medium-high across future compiler versions, which require regression tests.

## 11. Evidence-backed validation commands

These commands were derived from the cited Emacs implementation but were not run during this read-only investigation.

### Focused function-cell and byte-code check

```sh
emacs -Q --batch \
  --eval "(progn
            (require 'bytecomp)
            (defun wbg-target () :old)
            (defun wbg-caller () (wbg-target))
            (fset 'wbg-caller
                  (byte-compile (symbol-function 'wbg-caller)))
            (unless (eq (wbg-caller) :old)
              (error \"initial call failed\"))
            (defun wbg-target () :new)
            (unless (eq (wbg-caller) :new)
              (error \"compiled caller retained old definition\"))
            (princ \"ok\n\"))"
```

### Full load, feature, autoload, advice, and redefinition check

```sh
set -eu
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/wbg-feature.el" <<'EOF'
(defun wbg-loaded () :library)
(provide 'wbg-feature)
EOF

cat >"$tmpdir/wbg-auto.el" <<'EOF'
(defun wbg-auto () :autoloaded)
EOF

cat >"$tmpdir/check.el" <<'EOF'
;; -*- lexical-binding: t; -*-
(require 'bytecomp)
(add-to-list 'load-path (getenv "WBG_TEST_DIR"))

(defvar wbg-after-load-ran nil)
(with-eval-after-load 'wbg-feature
  (setq wbg-after-load-ran t))

(require 'wbg-feature)
(unless wbg-after-load-ran
  (error "after-load body did not run"))

(defun wbg-loaded () :configured)
(require 'wbg-feature)
(unless (eq (wbg-loaded) :configured)
  (error "second require unexpectedly reloaded feature"))

(autoload 'wbg-auto "wbg-auto")
(unless (eq (wbg-auto) :autoloaded)
  (error "autoload failed"))

(defun wbg-target () :old)
(defun wbg-caller () (wbg-target))
(fset 'wbg-caller (byte-compile (symbol-function 'wbg-caller)))
(defun wbg-target () :new)
(unless (eq (wbg-caller) :new)
  (error "byte-compiled call was not late-bound"))

(defun wbg-advised () :old)
(advice-add 'wbg-advised :around
            (lambda (original &rest arguments)
              (list :advice (apply original arguments))))
(defun wbg-advised () :new)
(unless (equal (wbg-advised) '(:advice :new))
  (error "defun did not preserve advice"))

(setq wbg-advised :value)
(unless (and (eq wbg-advised :value)
             (equal (wbg-advised) '(:advice :new)))
  (error "function/value cells were not independent"))

(princ "all checks passed\n")
EOF

WBG_TEST_DIR="$tmpdir" emacs -Q --batch -l "$tmpdir/check.el"
```

## Repository scope

The requested output is the only task artifact. No application or playground files were inspected or modified. Git inspection found no staged files; the checkout already contained unrelated unstaged and untracked work.