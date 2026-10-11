# Emacs runtime redefinition semantics

## Concise answer

Emacs makes runtime redefinition ergonomic because loaded Lisp libraries share interned symbol objects in a process-wide namespace, and each symbol has independent **function** and **variable-value** cells. Ordinary, non-inlined calls retain the callee symbol and resolve its current function cell at call time; ordinary global/special variable references resolve the current dynamic/value-cell binding at read time. Updating one shared cell is therefore visible to already-loaded callers without re-importing libraries or installing setters at every call site.

This is late binding, not file replacement. Evaluating a new `defun`, `setq`, or `set` changes selected live bindings. It does not rewrite active stack frames, captured function objects, lexical closures, already-expanded macros/inlines, arbitrary top-level side effects, or definitions removed from a reloaded file.

The installed GNU Emacs 30.2 manual and the `emacs-30.2` source tag were used below.

## 1. Shared symbols and separate cells

An Emacs symbol has distinct value, function, property-list, and print-name components. A symbol used as a variable reads its value binding; the same symbol in function position follows its function cell. Thus Emacs Lisp is effectively Lisp-2: a function and variable can have the same name without conflict.

Authoritative references:

- GNU ELisp Manual §9.1, [Symbol Components](https://www.gnu.org/software/emacs/manual/html_node/elisp/Symbol-Components.html)
- §10.2.2, [Symbol Forms](https://www.gnu.org/software/emacs/manual/html_node/elisp/Symbol-Forms.html)
- §10.2.4, [Symbol Function Indirection](https://www.gnu.org/software/emacs/manual/html_node/elisp/Function-Indirection.html)
- §13.3, [Naming a Function](https://www.gnu.org/software/emacs/manual/html_node/elisp/Function-Names.html)

The Lisp reader interns names, so separately loaded files normally refer to the same symbol object. Emacs libraries are not isolated lexical modules requiring imports at each use. `require` ensures definitions have executed; it does not create private imported copies.

### Consequence

Given a symbol `foo`:

- `(foo ...)` uses `foo`’s function cell.
- `foo` as an expression uses its value binding.
- `(defun foo ...)` does not change variable `foo`.
- `(setq foo ...)` does not change function `foo`.

That separation is essential to any claim of Emacs-equivalent function **and** variable redefinition.

## 2. Function redefinition

### `defun`

`defun` creates a function object and installs it under the named symbol. Re-evaluating the form replaces that symbol’s definition without warning, including definitions that were previously primitives.

The implementation is explicit: the `defun` macro expands to `defalias` with a function/lambda object:

- [`lisp/emacs-lisp/byte-run.el`, lines 402–443](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/byte-run.el?h=emacs-30.2#n402)
- Manual §13.4, [Defining Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Defining-Functions.html)

A future interpreted call reads the current function cell. The evaluator’s fast path obtains the symbol’s function field and follows symbol indirection:

- [`src/eval.c`, lines 2512–2535](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?h=emacs-30.2#n2512)
- `funcall` likewise resolves a symbol and retries after autoloading: [`src/eval.c`, lines 3031–3060](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?h=emacs-30.2#n3031)

### `fset`

`fset` directly stores an arbitrary object in a symbol’s function cell. It checks for circular symbol indirection but does not require the value to be a valid function:

- Manual §13.9, [Accessing Function Cell Contents](https://www.gnu.org/software/emacs/manual/html_node/elisp/Function-Cells.html)
- [`src/data.c`, lines 889–921](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?h=emacs-30.2#n889)

`fset` is the low-level mutation primitive. Unlike `defalias`, it does not associate the definition with the current load file or cooperate with `defalias`’s advice hook. Direct `fset` can therefore discard advice already wrapping the function.

### `defalias`

`defalias` records load/function history and normally delegates the actual installation to `fset`. If the symbol has a `defalias-fset-function` property, it invokes that hook instead; modern advice uses this to preserve advice across later `defun`/`defalias` redefinitions:

- [`src/data.c`, lines 961–1021](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?h=emacs-30.2#n961)

The distinction is behavioral:

```elisp
(defalias 'live 'base)                  ; stores symbol base
(defalias 'copy (symbol-function 'base)) ; stores current function object
```

After redefining `base`, `live` follows the alias chain to the new function, while `copy` still invokes the captured old object. A batch Emacs 30.2 probe confirmed `live=:new`, `copy=:old`.

Function aliases are live only when the cell contains another symbol. Circular alias chains signal `cyclic-function-indirection`.

## 3. Variable redefinition is different

### Global/value-cell behavior

A global variable’s value persists until changed. `setq` changes the **current binding** of the statically named symbol. `set` evaluates its symbol argument and changes that symbol’s current dynamic/value-cell binding:

- Manual §12.1, [Global Variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Global-Variables.html)
- §12.8, [Setting Variable Values](https://www.gnu.org/software/emacs/manual/html_node/elisp/Setting-Variables.html)
- [`src/data.c`, lines 1613–1647](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?h=emacs-30.2#n1613)

For ordinary global reads, existing interpreted, byte-compiled, and normally native-compiled code observes a later top-level `setq`/`set`.

### `defvar` is deliberately not a reset

`defvar` initializes only a void variable and otherwise preserves its existing value. It also marks the variable special/dynamically bound. This supports a major Emacs customization idiom:

1. user configuration sets a variable;
2. the defining library later loads;
3. its `defvar` does not overwrite the user value.

`defconst` initializes unconditionally, although its “constant” status is advisory. `defcustom` is built on `defvar`; `setopt` additionally invokes Customize validation/setter behavior.

Manual §12.5, [Defining Global Variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Defining-Variables.html).

Interactive `eval-defun` and `eval-last-sexp` specially force a top-level `defvar`/`defcustom` initial value to be reapplied. Plain `load` and `eval-buffer` do not gain that special reset behavior.

### Lexical versus special/dynamic bindings

Under lexical binding:

- a lexical local is stored in its lexical environment or closure, not in the symbol value cell;
- `setq` changes the current lexical binding when one exists;
- `set` and `symbol-value` address the dynamic/value-cell binding and cannot reach an arbitrary lexical binding.

Manual:

- §12.10.1, [Lexical Binding](https://www.gnu.org/software/emacs/manual/html_node/elisp/Lexical-Binding.html)
- §12.10.2, [Dynamic Binding](https://www.gnu.org/software/emacs/manual/html_node/elisp/Dynamic-Binding.html)
- §12.10.4, [Selecting Lisp Dialect](https://www.gnu.org/software/emacs/manual/html_node/elisp/Selecting-Lisp-Dialect.html)

Variables declared with `defvar`, `defcustom`, or `defconst` are special. A dynamic `let` temporarily replaces the symbol’s current dynamic binding, and ordinary calls made within that dynamic extent observe the temporary value. A `setq` or `set` there changes that temporary binding, not necessarily the process-wide default.

Other exceptions include buffer-local values and variable aliases. `defvaralias` makes two variable names share values and bindings; this is distinct from function-cell indirection.

## 4. Advice

`advice-add` composes behavior around a named function rather than merely copying the old definition. Existing ordinary calls observe the wrapper because the named symbol’s function definition is changed.

It additionally:

- handles macros and autoloads;
- permits advice before the target is defined;
- records advice so it can be listed and removed;
- arranges for later `defun`/`defalias` to replace the innermost original while preserving advice.

Implementation:

- pending/autoload advice and preservation hook: [`lisp/emacs-lisp/nadvice.el`, lines 454–532](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/nadvice.el?h=emacs-30.2#n454)
- Manual §13.12.2, [Advising Named Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Advising-Named-Functions.html)

An Emacs 30.2 probe confirmed:

- redefining an advised function with `defun` retained the advice and wrapped the new body;
- direct `fset` replaced the entire advised definition and removed the advice.

Advice is intentionally not the preferred general extension mechanism: hooks are cleaner where available. It also cannot affect already-expanded macros, direct C calls to primitives, or compiled calls optimized away from the named function.

## 5. Loading, autoloads, features, and interactive evaluation

### Autoload

`autoload` installs an autoload object in the function cell. The first call loads the designated file, which should replace that cell with the real definition, and then retries the call:

- Manual §16.5, [Autoload](https://www.gnu.org/software/emacs/manual/html_node/elisp/Autoload.html)
- installation/no-overwrite rule: [`src/eval.c`, lines 2305–2343](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?h=emacs-30.2#n2305)
- load, verify replacement, and retry: [`src/eval.c`, lines 2394–2442](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/eval.c?h=emacs-30.2#n2394)

If the name already has a non-autoload definition, `autoload` does nothing. Consequently, manually defining an autoloaded name suppresses call-triggered loading for that name. Explicitly loading/requiring the library later may redefine it again.

Autoload failures receive special rollback: function definitions and `provide` calls made during the failed autoload are undone. Ordinary explicit `load` is not generally transactional.

### `provide` and `require`

`provide` adds a feature symbol to global `features`. `require` checks that list and loads only when the feature is absent:

- Manual §16.7, [Features](https://www.gnu.org/software/emacs/manual/html_node/elisp/Named-Features.html)
- [`src/fns.c`, lines 3650–3674](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/fns.c?h=emacs-30.2#n3650)
- [`src/fns.c`, lines 3689–3796](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/fns.c?h=emacs-30.2#n3689)

Therefore:

- redefining a live cell does not require another `require`;
- calling `require` again normally does not reload or undo the redefinition;
- direct `load` can execute the file again regardless of `features`;
- user function changes made before a later library load can be overwritten by that library’s `defun`;
- `advice-add` before definition or an after-load hook avoids that ordering problem.

### `load`, reload, `eval-buffer`, and `eval-defun`

`load` finds a file, evaluates its forms sequentially, and records definitions/features in `load-history`:

- Manual §16.1, [How Programs Do Loading](https://www.gnu.org/software/emacs/manual/html_node/elisp/How-Programs-Do-Loading.html)
- [`src/lread.c`, lines 1278–1322 and 1697–1746](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/lread.c?h=emacs-30.2#n1278)

`eval-buffer` reads and evaluates the accessible buffer using the file’s lexical-binding cookie:

- Manual §10.5, [Eval](https://www.gnu.org/software/emacs/manual/html_node/elisp/Eval.html)
- [`src/lread.c`, lines 2580–2618](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/lread.c?h=emacs-30.2#n2580)

`eval-defun` evaluates one surrounding top-level form and has the special variable-reset behavior described above:

- [`lisp/progmodes/elisp-mode.el`, lines 1756–1796](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/elisp-mode.el?h=emacs-30.2#n1756)
- GNU Emacs Manual §29.9, [Evaluating Emacs Lisp Expressions](https://www.gnu.org/software/emacs/manual/html_node/emacs/Lisp-Eval.html)

### What “redefine a file” actually means

Emacs does not atomically replace a file/module abstraction. It executes new top-level forms:

- repeated `defun` forms replace named function cells;
- `setq`, `set`, `defconst`, and forced interactive evaluation can replace values;
- normal `defvar` retains an existing value;
- forms removed from the edited file remain live unless explicitly unbound or the feature is unloaded;
- registration and mutation side effects may run twice;
- an error can leave a partially updated process;
- active invocations continue executing their already-selected old function object;
- old objects survive wherever closures, variables, hooks, keymaps, or other data structures captured them.

`unload-feature` uses `load-history` to undefine recorded definitions, restore prior autoloads, remove some hook references, and unprovide features, but it is a separate operation—not implicit reload semantics. See Manual §16.9, [Unloading](https://www.gnu.org/software/emacs/manual/html_node/elisp/Unloading.html).

Reload also has artifact-selection hazards: normal `load` prefers `.elc`, and then a matching `.eln`, over `.el`. Editing source and calling `load` can therefore reload older compiled code unless recompilation, an exact source filename, or `load-prefer-newer` is used. Manual §16.6, [Repeated Loading](https://www.gnu.org/software/emacs/manual/html_node/elisp/Repeated-Loading.html).

## 6. Byte-compiled and native-compiled behavior

### Ordinary byte-code calls remain late-bound

Byte-code constants retain symbols used as function and variable names. At a call instruction, the interpreter retrieves the current symbol function definition; at a variable-reference instruction, it retrieves the current value:

- closure constant-vector semantics: Manual §17.6, [Closure Function Objects](https://www.gnu.org/software/emacs/manual/html_node/elisp/Closure-Objects.html)
- variable lookup: [`src/bytecode.c`, lines 608–633](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/bytecode.c?h=emacs-30.2#n608)
- function call lookup: [`src/bytecode.c`, lines 748–815](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/bytecode.c?h=emacs-30.2#n748)

An Emacs 30.2 probe byte-compiled a caller, replaced its callee with `fset`, and observed `:old` before and `:new` afterward. Its constant vector was `[rr-target]`, confirming that the caller retained the symbol rather than the old closure. A corresponding variable probe observed a later global `setq`, including temporary dynamic `let` binding.

### Inlining and compiler transformations defeat late redefinition

The guarantee does not apply where compilation removes the named call:

- `defsubst` inlines the old body into compiled callers.
- `define-inline` supplies a compiler macro.
- ordinary macros are expanded before execution.
- `byte-compile`, `byte-optimize`, and `compiler-macro` properties can rewrite calls into different operations.

Already-compiled callers then keep the expansion until recompiled. Advice/redefinition of the original name cannot intercept code that no longer calls it.

Manual:

- §13.14, [Inline Functions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Inline-Functions.html)
- §13.12.5, [Advice and Byte Code](https://www.gnu.org/software/emacs/manual/html_node/elisp/Advice-and-Byte-Code.html)
- §14.3, [Macros and Byte Compilation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Compiling-Macros.html)

### Native compilation

Native compilation inherits byte-compilation’s expansion and optimization caveats. At the default optimization level 2, an Emacs 30.2 probe showed a normally named Lisp-function caller observing a subsequent `fset`.

There are two important exceptions:

1. At native compilation speed 3, calls within the same compilation unit may become direct calls and may even be inlined by GCC. Emacs source explicitly states that this makes functions in that unit unsafe to redefine without recompiling the whole unit:
   - [`lisp/emacs-lisp/comp.el`, lines 2805–2818 and 2865–2881](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/lisp/emacs-lisp/comp.el?h=emacs-30.2#n2805)

2. At speed 2 or greater, primitive calls may be optimized. Emacs installs native trampolines when primitives are advised or redefined:
   - trampoline installation trigger in `fset`: [`src/data.c`, lines 910–917](https://cgit.git.savannah.gnu.org/cgit/emacs.git/tree/src/data.c?h=emacs-30.2#n910)
   - Manual §18.2, [Native-Compilation Variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Native_002dCompilation-Variables.html)

If required primitive trampolines are disabled or unavailable, natively compiled Lisp calls can ignore primitive redefinitions/advice. Direct calls made from Emacs C code always bypass the Lisp symbol cell.

## 7. Minimal semantics a Gerbil MWE must emulate

For the narrow claim “Emacs-like ordinary runtime redefinition,” the minimum observable requirements are:

1. **Stable shared binding identity:** separately loaded/compiled callers and runtime configuration identify the same live binding.
2. **Late function lookup:** a normal, non-inlined call made after redefinition observes the replacement without recompiling or rewiring the caller.
3. **Runtime installation:** evaluating configuration mutates the existing binding rather than creating a new config-local binding.
4. **Before/after evidence in one process:** an ordinary caller returns the default, configuration runs, and the same ordinary caller returns the replacement.
5. **Compiled evidence:** the property holds for the normal compiled mode being claimed, not only interpretation.
6. **Function/variable distinction:** if variable parity is claimed, a separate shared mutable value binding must be demonstrated. Function rebinding alone does not establish Emacs variable semantics.
7. **Explicit exclusions:** captured procedure values, lexical locals/closures, macro or inline expansions, direct native calls, and unsupported optimization modes must not be presented as late-bound.

Advice composition, autoload rollback, feature/load history, interactive evaluation commands, buffer-local values, and unloading are important Emacs ergonomics but are not necessary for the minimal function-redefinition MWE.

## 8. Current repository behavior

The current Gerbil playground satisfies the narrow function path:

- `playground/lib.ss:1–5` defines and exports ordinary `greeting`.
- `playground/main.ss:1–12` imports that library once, calls `greeting`, evaluates runtime configuration, then calls it normally again.
- `playground/config.scm:1–6` resolves the same `playground/lib` runtime binding with `extern` and replaces it with `set!`.
- Expected output is `default\nconfigured\n`.

Supporting repository evidence:

- `research/runtime-redefinition-library-module.md:1–194`
- `plans/runtime-redefinition-library-module/spec.md:1–177`
- Earlier same-module constraints: `research/runtime-redefinable-config.md:1–197` and `plans/emacs-like-runtime-redefinition/spec.md:1–146`

Unlike Emacs’s shared global symbol namespace, the Gerbil config must explicitly name the target namespace. No current file demonstrates an independent variable-value-cell path, lexical/dynamic variation, advice, aliases, or autoload semantics. Those omissions do not invalidate the approved narrow function MWE.

## Findings and residual risks

- **High — optimization:** `lisp/emacs-lisp/comp.el:2805–2818` says native speed-3 intra-unit calls are not safely redefinable without recompiling the unit. Inline/compiler-macro expansions have the same stale-call-site effect.
- **High — semantic conflation:** `playground/lib.ss:1–5` and `playground/config.scm:1–6` establish function rebinding only. They do not demonstrate Emacs variable value-cell semantics.
- **Medium — captured values:** storing `(symbol-function 'f)` or a closure captures an object, so later cell replacement does not update it. A live symbol alias behaves differently.
- **Medium — load ordering:** a later library `defun` can overwrite an earlier user replacement. `require` is a one-time feature gate, not a redefinition propagation mechanism.
- **Medium — reload:** `load`/`eval-buffer` execute forms and side effects; removed definitions linger and `defvar` normally retains values. Reload is not atomic module replacement.
- **Medium — compiled artifact selection:** ordinary `load` can choose stale `.elc`/`.eln` instead of edited `.el`.
- **Medium — primitives:** C direct calls ignore Lisp redefinition; optimized native primitive calls require available trampolines.
- **Low — global namespace:** Emacs gains ergonomics by sacrificing isolation; package-wide naming prefixes are conventionally needed to avoid collisions.
- **Confidence:** High for function/value-cell, load, advice, byte-code, and default native behavior; high for the documented native speed-3 limitation; medium-high for cross-version native optimizer details beyond Emacs 30.2.

## Evidence-backed validation commands

### Focused interpreted Gerbil check

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

### Full normal compiled Gerbil check

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

These commands are established in `plans/runtime-redefinition-library-module/spec.md:93–131`. They were not rerun during this read-only Emacs investigation.