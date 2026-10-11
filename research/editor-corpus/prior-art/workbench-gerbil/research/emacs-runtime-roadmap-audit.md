# GNU Emacs 30.2 runtime roadmap audit

## Conclusion

The checklist identifies most relevant Emacs capabilities, but its order and one central representation claim need correction.

### Roadmap-critical findings

1. **High — metadata conflation**  
   `plans/emacsen-runtime/checklist.md:9` says “Property table for documentation and source metadata.” Emacs does not have one unified definition-metadata record:
   - arbitrary symbol properties live in the symbol property-list cell;
   - normal function documentation is normally embedded in the function object;
   - variable documentation is the symbol’s `variable-documentation` property;
   - positioned symbols are temporary compiler-oriented wrapper objects, not persistent definition source records;
   - current file provenance comes primarily from `load-history`;
   - prior function definitions are held separately in the symbol’s `function-history` property;
   - source line discovery is generally reconstructed by tooling rather than retained as a universal definition position.

2. **High — compiled lookup is the immediate decision gate**  
   `plans/emacsen-runtime/checklist.md:12` should precede documentation/property work. A mutable Gerbil cell is insufficient if supported compilation modes inline, direct-call, capture, or eliminate its lookup.

3. **High — cleanup and concurrency are ordered too late**  
   Dynamic binding and cleanup belong together. `plans/emacsen-runtime/checklist.md:13` and the concurrency part of line 20 must be evaluated before higher-level hooks, advice, or keymaps.

4. **Medium — aliases, capture, inspection, and removal are one core milestone**  
   `plans/emacsen-runtime/checklist.md:10-11` should be evaluated with the cell kernel, not as separate later editor features. They distinguish live indirection from copied procedure objects and establish whether runtime state can be diagnosed and repaired.

5. **Medium — runtime loading is essential, but Emacs’s exact loading conventions are not**  
   Repeatedly reading/evaluating/loading configuration in the deployed process is a decision gate. Exact `autoload`, feature, after-load, history, and best-effort unload behavior can follow after Gerbil passes the binding/compiler/runtime tests.

The two existing reports are broadly accurate. Their principal weakness is wording that can make all documentation and provenance appear to be ordinary symbol-property metadata. The exact distinctions are documented below.

## Authoritative baseline

- Installed manual/runtime: GNU Emacs 30.2.
- Official tag: `emacs-30.2`, commit `29f3f150af5c5b065c3a9f39969429e5bb3285da`.
- Source inspected through `/home/jay/Code/emacs` using `git show emacs-30.2:PATH`.
- Manual: GNU Emacs Lisp Reference Manual 30.2.
- No playground application files were inspected.

Priority labels:

- **Essential** — needed before deciding whether Gerbil can support a new Emacsen’s language/runtime contract.
- **Later** — valuable editor/runtime library behavior, but not a Gerbil suitability gate.
- **Split** — a small foundational subset is essential; exact Emacs compatibility can wait.

---

## 1. Symbols and separate function/value/property cells

**User-facing forms**

```elisp
(intern "name")
(intern-soft "name")
(make-symbol "name")
(symbol-name 'name)
(symbol-value 'name)
(symbol-function 'name)
(symbol-plist 'name)
```

Ordinary variable and function use demonstrates Lisp-2 separation:

```elisp
(setq example :value)
(defun example () :function)
(list example (example))
```

**Representation and operation**

An interned symbol has print name, value, function, and property-list components. Reading the same ordinary name in the same obarray normally returns the same symbol. Other obarrays and uninterned `make-symbol` objects are exceptions.

- Source: `src/lread.c:4941-5047` at `emacs-30.2` implements interning and canonical lookup.
- Source: `src/data.c:714-816` independently accesses value-boundness, function cell, and property list.
- Manual: `(elisp) Symbol Components`, `(elisp) Creating Symbols`, `(elisp) Symbol Forms`, `(elisp) Function Names`.

**Observable semantics and caveats**

- Value-cell changes do not replace the function definition, and vice versa.
- Function cells can contain functions, macros, aliases, autoload descriptors, keymaps, or keyboard macros.
- A property list is a generic association list, not a complete definition record.
- The ordinary global obarray is collision-prone; Emacs packages rely heavily on name prefixes.
- A Gerbil implementation can preserve these semantics with qualified registry keys and separate cells without copying Emacs’s symbol layout.

**Priority: Essential.** Stable shared identity and distinct mutable function/value domains are fundamental. An exact Emacs property-list cell is later.

---

## 2. `defun`, `defalias`, and `fset`

**User-facing forms**

```elisp
(defun name (args...) [doc] [declare] [interactive] body...)
(defalias 'alias definition [docstring])
(fset 'name definition)
(symbol-function 'name)
```

**Representation and operation**

`defun` parses documentation, declarations, and an interactive form, constructs a lambda/function object, and expands to `defalias`:

- `lisp/emacs-lisp/byte-run.el:402-443`.

`defalias`:

1. associates `(defun . SYMBOL)` with the current load history;
2. records the old non-`nil` definition in `function-history`;
3. invokes the symbol’s `defalias-fset-function` property when present;
4. otherwise calls `fset`;
5. writes `function-documentation` only when its explicit third argument is non-`nil`.

- `src/data.c:924-991` — load/function history and advice interception.
- `src/data.c:993-1021` — Lisp-visible `defalias`.
- `src/data.c:889-921` — cycle checking and direct function-cell replacement by `fset`.
- Manual: `(elisp) Defining Functions`, `(elisp) Function Cells`, `(elisp) Function Indirection`.

**Observable semantics and caveats**

- Re-evaluating `defun` changes the shared function cell. Future ordinary late-bound calls see the new object.
- An invocation already executing continues with the old function object.
- `fset` is lower-level than `defalias`: it does not perform the latter’s load-history, prior-definition-history, or advice-preservation protocol.
- If an old `function-documentation` property exists, an ordinary later `defun` does not necessarily clear it: `defalias` writes that property only for a non-`nil` explicit third argument. Such a property can continue to override embedded documentation.
- A low-level cell mutation is not equivalent to reloading or atomically replacing a module.

**Priority: Essential.** Gerbil needs an installation operation with stable identity and explicit low-level versus lifecycle-aware semantics.

---

## 3. `defvar`, `defconst`, `setq`, `set`, and `defcustom`

**User-facing forms**

```elisp
(defvar option [initial-value] [docstring])
(defconst constant initial-value [docstring])
(setq variable value ...)
(set 'variable value)
(symbol-value 'variable)
(defcustom option standard doc :type type ...)
(setopt option value ...)
```

**Representation and operation**

- `setq` assigns a lexical binding when one is present; otherwise it delegates to dynamic/value-cell assignment: `src/eval.c:465-499`.
- `set` invokes the variable-value machinery for a symbol: `src/data.c:1628-1647`.
- `defvar` marks a variable special and initializes its default only when void: `src/eval.c:828-918`.
- `defconst` marks the symbol special but unconditionally sets its default; Lisp-level immutability is not generally enforced: `src/eval.c:929-974`.
- Variable declarations attach their docstring as `variable-documentation` and enter load history: `src/eval.c:798-825`.
- `defcustom` expands to `custom-declare-variable`: `lisp/custom.el:249-405`.
- Customize stores the standard expression and metadata such as `custom-set`, `custom-get`, `custom-type`, safety, requests, and locality as symbol properties: `lisp/custom.el:161-247`.
- Manual: `(elisp) Defining Variables`, `(elisp) Setting Variables`, `(elisp) Variable Definitions`.

**Observable semantics and caveats**

- A prior user `setq` normally survives a later `defvar` initializer.
- `defconst` resets the value and expresses programmer intent, not general immutable storage.
- `setq` can update a lexical local; `set` and `symbol-value` cannot address arbitrary lexical bindings.
- For buffer-local variables, `defvar` and `defconst` generally operate on the default rather than existing per-buffer values.
- A bare `(defvar name)` has special declaration behavior but deliberately does not count as a normal unloadable value definition (`src/eval.c:904-916`).
- `setopt`, unlike `setq`, invokes Customize validation/setter policy.
- Captured lexical values are unaffected by later global value-cell changes.

**Priority: Split.** Global value mutation, `defvar`-style initialization, and special-variable declarations are essential. Full `defcustom`/Customize policy can wait.

---

## 4. `get`, `put`, and symbol property lists

**User-facing forms**

```elisp
(get 'symbol 'property)
(put 'symbol 'property value)
(symbol-plist 'symbol)
(setplist 'symbol plist)
(plist-get plist property)
(plist-put plist property value)
(plist-member plist property)
```

**Representation and operation**

The symbol’s property-list field is a flat list of alternating property names and values. `put` mutates/replaces the property and stores the resulting list in the symbol. `get` first consults `overriding-plist-environment`, then the actual symbol plist.

- `src/data.c:810-816,1024-1030`.
- `src/fns.c:2606-2634` — `get`.
- `src/fns.c:2636-2701` — plist update.
- `src/fns.c:2703-2712` — `put`.
- Manual: `(elisp) Symbol Properties`, `(elisp) Property Lists`.

**Observable semantics and caveats**

- `get` returning `nil` does not distinguish a missing property from a property explicitly containing `nil`; inspect the plist or use membership operations when that distinction matters.
- Symbol properties are process-visible metadata attached to symbol identity.
- Property mutation has no automatic versioning, validation, synchronization, rollback, or unload semantics.
- Some definition-related data uses properties, but that does not make all definition metadata one homogeneous table.

**Priority: Later.** A general metadata facility will be useful, but it does not establish Gerbil live-binding viability.

---

## 5. Function and variable documentation

### Function documentation

**Forms**

```elisp
(defun f (...) "Documentation." ...)
(defalias 'f definition "Documentation.")
(documentation 'f)
(documentation function-object)
(documentation-property 'f 'function-documentation)
(describe-function 'f)
```

**Representation**

Normal `defun` documentation is normally embedded in the lambda/closure/function object. A symbol’s `function-documentation` property is an optional override/alternate source, used by explicit `defalias` documentation and advice.

- Closure construction separates docstring and interactive slots: `src/eval.c:535-552`.
- `defalias` optional property write: `src/data.c:993-1017`.
- `documentation` checks the symbol property first and otherwise follows the function definition: `src/doc.c:321-387`.
- Manual: `(elisp) Function Documentation`, `(elisp) Documentation Basics`, `(elisp) Accessing Documentation`.

Compiled/preloaded documentation may be represented by file/offset references rather than an in-memory string.

### Variable documentation

**Forms**

```elisp
(defvar v nil "Documentation.")
(defconst v value "Documentation.")
(defcustom v value "Documentation." :type ...)
(documentation-property 'v 'variable-documentation)
(describe-variable 'v)
```

**Representation**

Variable documentation is stored on the symbol’s `variable-documentation` property. During dumping, the value may be a DOC-file position rather than a string.

- `src/eval.c:798-825`.
- `src/doc.c:616-627`.
- Manual: `(elisp) Variable Documentation`, `(elisp) Documentation Basics`.

**Observable semantics and caveats**

- Function and variable documentation for the same symbol are independent.
- Function documentation is not normally “the documentation property”; variable documentation normally is.
- Documentation values can be strings, dynamic forms, or external references.
- Direct low-level replacement can leave an explicit function-documentation override stale.

**Priority: Later.** Useful for an editor’s discoverability, but not a Gerbil language/compiler decision gate.

---

## 6. Source position, definition provenance, `load-history`, and `function-history`

These are five distinct concepts.

### Positioned symbols

**Forms**

```elisp
(read-positioning-symbols ...)
(position-symbol 'name position)
(symbol-with-pos-p object)
(symbol-with-pos-pos object)
(bare-symbol object)
```

**Representation and semantics**

A symbol-with-position is a wrapper containing a bare symbol and an occurrence position. It is not itself an interned symbol and has no value/function/property cells. The byte and native compilers use these wrappers for diagnostics; most code should not retain them.

- `src/data.c:832-887`.
- `doc/lispref/symbols.texi:785-864`.
- Manual: `(elisp) Symbols with Position`.

This is **not** persistent definition provenance or a universal source map.

### Current definition file

**Forms**

```elisp
(symbol-file 'name)
(symbol-file 'name 'defun)
(symbol-file 'name 'defvar)
(find-function 'name)
(find-variable 'name)
```

`symbol-file` is based mainly on `load-history`, not on a source-position property.

- `doc/lispref/loading.texi:1103-1125`.
- Manual: `(elisp) Where Defined`.

`find-function`/`find-variable` locate a likely source file and search it; the exact source line is generally reconstructed rather than stored with every live definition.

### `load-history`

**Form and representation**

```elisp
load-history
```

It is a global alist keyed by loaded filename. Entries record variables, `(defun . FUN)`, `(provide . FEATURE)`, `(require . FEATURE)`, and other recognized definition forms.

- `src/lread.c:1278-1322,1697-1746`.
- `doc/lispref/loading.texi:1127-1164`.
- Manual: `(elisp) Where Defined`.

### `function-history`

**Form and representation**

```elisp
(get 'function-name 'function-history)
```

This particular history is a symbol property, but it is not the same thing as the generic property mechanism or `load-history`. It is an alternating list approximately:

```elisp
(file1 old-definition file2 still-older-definition ...)
```

- Population: `src/data.c:924-980`.
- Documented shape: `doc/lispref/loading.texi:1166-1181`.
- Restoration: `lisp/loadhist.el:169-196`.

**Caveats**

- Definitions made outside a file can have `nil` provenance.
- History records recognized defining operations, not arbitrary side effects.
- Direct `fset` does not perform `defalias` history bookkeeping.
- `function-history` stores previous objects and associated files, not definition line numbers.
- `load-history` is global library history, not a per-symbol source record.
- Evaluating a region may append definitions to the visited file’s history rather than replacing its entry.

**Priority: Split.** Source-aware errors and enough provenance to diagnose runtime configuration are essential. Exact Emacs history and source-navigation reconstruction can wait.

---

## 7. `boundp`, `fboundp`, `makunbound`, and `fmakunbound`

**User-facing forms**

```elisp
(boundp 'name)
(fboundp 'name)
(symbol-value 'name)
(symbol-function 'name)
(makunbound 'name)
(fmakunbound 'name)
```

**Representation and operation**

- `boundp` follows variable aliases and buffer-local/default machinery and tests against the internal unbound marker: `src/data.c:714-752`.
- `fboundp` tests whether the raw function cell is non-`nil`: `src/data.c:758-764`.
- `makunbound` installs the internal unbound value: `src/data.c:766-782`.
- `fmakunbound` sets the function definition to `nil`: `src/data.c:784-800`.
- Manual: `(elisp) Void Variables`, `(elisp) Function Cells`.

**Observable semantics and caveats**

- Reading a void variable signals `void-variable`; calling an unbound function name signals `void-function`.
- `boundp` under lexical binding refers to global/dynamic state, not an arbitrary lexical local.
- `fboundp` does not prove that the cell contains a valid callable.
- Low-level removal does not undo arbitrary registrations or metadata.

**Priority: Essential.** Inspection/removal is needed to test, recover, and distinguish absent from present bindings.

---

## 8. Function and variable aliases

### Function aliases

**Forms**

```elisp
(defalias 'alias 'target)
(defalias 'snapshot (symbol-function 'target))
(indirect-function 'alias)
```

A symbol-valued function cell is live indirection. A copied function object is a snapshot.

```elisp
(defalias 'live 'target)
(defalias 'snapshot (symbol-function 'target))
(defun target () :replacement)
```

`live` observes the replacement; `snapshot` retains the earlier object.

- Alias cycle prevention: `src/data.c:889-921`.
- Lookup: `src/eval.c:2512-2535,3031-3064`.
- Manual: `(elisp) Function Indirection`, `(elisp) Defining Functions`.

### Variable aliases

**Forms**

```elisp
(defvaralias 'alias 'base [docstring])
(indirect-variable 'alias)
```

The alias symbol’s value representation redirects to the base variable, so reads, writes, and dynamic operations share state.

- `src/eval.c:626-720`.
- Value lookup follows `SYMBOL_VARALIAS`: `src/data.c:1586-1611`.
- Manual: `(elisp) Variable Aliases`.

**Caveats**

- Copying a value or function object is not aliasing.
- Function and variable aliases are separate mechanisms.
- Variable aliases mark both variables special.
- Emacs rejects cycles and rejects some alias conversions involving built-in, localized, or currently `let`-bound variables.
- Optimizers can defeat intended live indirection if the Gerbil contract does not preserve lookup.

**Priority: Essential.** This is the sharpest user-visible test of live identity versus captured implementation behavior.

---

## 9. Interpreted, byte-compiled, and native-compiled late lookup

**User-facing forms**

```elisp
(name args...)
(funcall 'name args...)
(byte-compile function)
(native-compile file-or-function)
```

**Representation and operation**

- Interpreted function position reads the symbol’s current function field and follows symbolic indirection: `src/eval.c:2512-2535`.
- `funcall` performs the same symbolic lookup and retries after autoload: `src/eval.c:3031-3064`.
- Byte-code global variable instructions retain a symbol and read its current value machinery: `src/bytecode.c:608-633`.
- Byte-code calls retain a symbol in the constants and resolve its current function definition: `src/bytecode.c:740-815`.

Native compilation introduces important exceptions:

- native speed 2 can optimize recursive calls and built-in subroutine trampolines;
- native speed 3 can turn intra-compilation-unit calls into direct calls, explicitly making those functions unsafe to redefine without recompiling the unit.

Source: `lisp/emacs-lisp/comp.el:2805-2818,2828-2883`.  
Manual: `(elisp) Native-Compilation Variables`, `(elisp) Inline Functions`, `(elisp) Compiling Macros`, `(elisp) Advice and Byte Code`.

**Observable semantics and caveats**

Ordinary interpreted and byte-compiled named calls are normally late-bound. Lookup disappears when code:

- stores `(symbol-function 'name)` instead of the symbol;
- expands a macro;
- inlines `defsubst`/`define-inline`;
- applies a compiler macro;
- substitutes a primitive operation;
- uses native direct calls;
- performs full-program optimization that assumes a closed world.

Native speed-2 direct recursion also means an old invocation may continue recursive calls directly to its own compiled implementation even after the symbol is replaced.

**Priority: Essential and immediate.** This must be the next checklist gate and must cover every Gerbil deployment/optimization mode the project intends to support.

---

## 10. Dynamic and buffer-local variables

### Dynamic variables

**Forms**

```elisp
(defvar context :global)
(let ((context :temporary))
  (call-library-code))
(symbol-value 'context)
```

`defvar`, `defconst`, and `defcustom` mark variables special. A dynamic `let` binding is maintained on the runtime binding/unwind stack and is visible down the call chain.

- Special declaration: `src/eval.c:798-918`.
- Variable lookup: `src/data.c:1586-1626`.
- Binding restoration: `src/eval.c:3682-3761`.
- Manual: `(elisp) Dynamic Binding`, `(elisp) Lexical Binding`.

**Caveats**

- `setq` updates a same-named lexical local when lexical resolution finds one.
- Dynamic mutation ordinarily changes the innermost current binding.
- Dynamic bindings are thread-local even though global values are shared.

### Buffer-local variables

**Forms**

```elisp
(make-local-variable 'name)
(make-variable-buffer-local 'name)
(defvar-local name value [doc])
(default-value 'name)
(set-default 'name value)
(local-variable-p 'name)
(kill-local-variable 'name)
```

A localized value representation selects a value associated with the current buffer or falls back to a default.

- Lookup: `src/data.c:1594-1609`.
- Default/local operations: `src/data.c:1986-2415`.
- Manual: `(elisp) Buffer-Local Variables`, `(elisp) Creating Buffer-Local`.

**Caveats**

- `setq` may update the current buffer’s local value rather than the default.
- The current buffer is thread-local, but threads that select the same buffer share that buffer’s state.
- Dynamic `let` and localization interact through specialized unwind records; a hand-built parameter scheme must test equivalent cases.
- Major-mode changes normally clear non-permanent local values.

**Priority: Essential.** Dynamic extent, reliable restoration, and a minimal context-local overlay are core Emacsen patterns. Exact buffer C structures are not required.

---

## 11. Interactive commands

**User-facing forms**

```elisp
(defun command (arg)
  (interactive "p")
  ...)

(commandp 'command)
(interactive-form 'command)
(call-interactively 'command)
(command-execute 'command)
```

**Representation and operation**

- Interpreted closures have a dedicated interactive-form slot separate from their docstring: `src/eval.c:535-552`.
- `commandp` recognizes primitive interactive specs, closure slots, interpreted lambda forms, keyboard macros, modules, and autoload metadata: `src/eval.c:2195-2303`.
- `call-interactively` reads/evaluates the interactive specification, derives editor-context arguments, optionally records history, and invokes the callable: `src/callint.c:253-430`.
- Manual: `(elisp) Defining Commands`, `(elisp) Interactive Call`.

**Observable semantics and caveats**

- Programmatic calls pass ordinary explicit arguments; interactive calls acquire them from editor state.
- Replacing a function normally replaces its embedded interactive declaration.
- A keymap storing the command symbol remains live; one storing an extracted closure does not.
- Direct/inlined calls bypass interactive argument acquisition.
- Advice can synthesize/preserve command metadata; raw replacement can lose it.

**Priority: Essential.** A minimal replaceable callable with inspectable command metadata and a dispatcher should be proven before adopting Gerbil for an Emacsen.

---

## 12. Macro redefinition phase boundary

**User-facing forms**

```elisp
(defmacro name (args...) body...)
(macroexpand-1 form)
(macroexpand form)
```

**Representation and operation**

`defmacro` installs `(macro . EXPANDER)` in the function cell through `defalias`:

- `lisp/emacs-lisp/byte-run.el:363-399`.

Macro expansion consults the current function definition, follows aliases/autoloads, and calls the expander:

- `lisp/emacs-lisp/macroexp.el:216-237`.
- The evaluator’s expansion path is also visible at `src/eval.c:1220-1242`.
- Manual: `(elisp) Defining Macros`, `(elisp) Expansion`, `(elisp) Compiling Macros`.

**Observable semantics and caveats**

- A form expanded after macro redefinition can use the new expander.
- Already byte/native-compiled callers retain their prior expansion.
- Previously explicit `macroexpand`, compiler macros, inline substitutions, and generated code have the same phase boundary.
- Runtime function rebinding does not imply compiled macro hot-swapping.

**Priority: Essential.** Gerbil’s macro phase differs significantly from runtime procedure lookup; the supported boundary must be demonstrated and documented early.

---

## 13. Hooks

**User-facing forms**

```elisp
(defvar package-hook nil)
(add-hook 'package-hook #'function)
(remove-hook 'package-hook #'function)
(run-hooks 'package-hook)
(run-hook-with-args 'package-hook args...)
```

**Representation and operation**

Hooks are chiefly a convention over variables containing `nil`, a function, or a list of functions. Buffer-local hooks can include `t` to splice in the default/global hook. `add-hook` supports local installation and ordering depth.

- `lisp/subr.el:2096-2250`.
- Manual: `(elisp) Hooks`, `(elisp) Setting Hooks`, `(elisp) Running Hooks`.

**Observable semantics and caveats**

- A stored function symbol observes later redefinition; a stored closure is captured.
- Anonymous functions are harder to remove and unload.
- Execution is sequential and usually nontransactional.
- A failure normally prevents later hook functions unless the runner isolates errors.
- Hook arguments and naming are library contracts rather than runtime type enforcement.

**Priority: Later.** Build after cells, symbols, context values, and cleanup are proven.

---

## 14. Advice

**User-facing forms**

```elisp
(advice-add 'target :around #'wrapper)
(advice-add 'target :before #'observer)
(advice-remove 'target #'wrapper)
(advice-member-p #'wrapper 'target)
```

**Representation and operation**

Named advice wraps the current function representation, records pending advice for undefined/autoloaded targets, and installs a `defalias-fset-function` property. A later `defun`/`defalias` then replaces the inner definition while retaining advice.

- `lisp/emacs-lisp/nadvice.el:454-532`.
- `src/data.c:984-990`.
- Manual: `(elisp) Advising Named Functions`, `(elisp) Advice Combinators`.

**Observable semantics and caveats**

- Direct `fset` bypasses the `defalias` advice protocol and can discard the wrapper.
- Advice does not intercept already-expanded macros, inlined calls, direct native calls, or direct C operations.
- Wrapper order and argument/result filters complicate composition.
- Anonymous advice is difficult to remove or unload reliably.

**Priority: Later.** Advice validates metadata lifecycle and wrapper composition, not basic Gerbil suitability.

---

## 15. Keymaps and command remapping

**User-facing forms**

```elisp
(make-sparse-keymap)
(define-key map (kbd "C-c x") 'command)
(keymap-set map "C-c x" #'command)
(lookup-key map (kbd "C-c x"))
(key-binding (kbd "C-c x"))
(set-keymap-parent map parent)

(define-key map [remap original-command] 'replacement-command)
(keymap-set map "<remap> <original-command>" 'replacement-command)
```

**Representation and operation**

Keymaps are mutable full or sparse map objects with optional parents. Definitions can be symbols, closures, keyboard macros, prefix maps, menu items, or indirections. Remapping uses the special `[remap ORIGINAL]` key.

- Creation/parents: `src/keymap.c:94-320`.
- Mutation/definitions: `src/keymap.c:1085-1218`.
- Remapping: `src/keymap.c:1224-1248`.
- Lookup/remap application: `src/keymap.c:1792-1852`.
- Manual: `(elisp) Keymaps`, `(elisp) Changing Key Bindings`, `(elisp) Remapping Commands`.

**Observable semantics and caveats**

- A command symbol remains late-bound; a closure stored directly remains captured.
- Mutating a shared keymap affects every owner of that object.
- Parent and active-map precedence make lookup contextual.
- Command remapping changes semantic command dispatch without enumerating every key.
- Remapping is generally nonrecursive.

**Priority: Later.** This is an editor dispatch structure layered on callable identity.

---

## 16. Autoloads, features, and after-load configuration

### Autoload

**Forms**

```elisp
(autoload 'function "file" [doc] [interactive] [type])
```

An autoload descriptor is installed in the function cell. It includes file, documentation, interactivity, and kind.

- Installation/no-overwrite rule: `src/eval.c:2305-2343`.
- Targeted failed-autoload rollback: `src/eval.c:2346-2387`.
- Load and replacement verification: `src/eval.c:2394-2442`.

An existing non-autoload definition is not overwritten by `autoload`. A later explicit file load can still execute a real `defun` and replace it.

### Features

**Forms**

```elisp
(provide 'feature)
(require 'feature [filename] [noerror])
(featurep 'feature)
```

`provide` adds to global `features`; `require` avoids loading when already present and verifies that loading provides the requested feature.

- `src/fns.c:3650-3796`.
- Manual: `(elisp) Named Features`.

These are load coordination, not imports or namespace isolation.

### Deferred configuration

**Forms**

```elisp
(with-eval-after-load 'feature body...)
(eval-after-load 'feature form)
```

The body runs immediately if the target is already loaded or is stored for execution after the relevant file/feature loads.

- `lisp/subr.el:5950-6062`.
- Loader callback: `src/lread.c:1744-1746`.
- Manual: `(elisp) Hooks for Loading`.

**Caveats**

- Repeated `require` normally does not reload a provided feature.
- Failed autoload has special rollback, unlike ordinary explicit loading.
- Ordering tools solve “library definition overwrote user configuration”; they do not create live binding identity.

**Priority: Split.** Deployed runtime read/eval/load is essential. Exact descriptors, feature lists, and after-load conventions can wait.

---

## 17. Load history and unloading

**User-facing forms**

```elisp
(load "file")
(load-file "/path/file.el")
(require 'feature)
(unload-feature 'feature [force])
(symbol-file 'name)
```

**Representation and operation**

`load` chooses a source/byte/native artifact, binds load state, detects lexical binding, evaluates forms, builds `load-history`, then runs after-load callbacks.

- `src/lread.c:1278-1322,1697-1746`.

`unload-feature` uses `load-history` and `function-history` to restore or remove recognized definitions, remove named hook registrations, cancel certain timers, remove provided features, and invoke package-specific cleanup.

- `lisp/loadhist.el:169-226,229-322`.
- Manual: `(elisp) Where Defined`, `(elisp) Unloading`.

**Observable semantics and caveats**

- Ordinary load is sequential, not atomic.
- An error leaves earlier top-level mutations applied.
- Reloading does not remove definitions deleted from the source.
- Repeated top-level registrations can duplicate side effects.
- `unload-feature` is best effort: it cannot discover arbitrary side effects or anonymous closures.
- History only covers operations participating in its protocols.
- File selection can load `.elc`/`.eln` instead of edited source depending on suffix and freshness policy.

**Priority: Later**, except for a minimal repeated-load and provenance test. Full unload is not needed to decide Gerbil suitability.

---

## 18. Errors, cleanup, and concurrency

**User-facing forms**

```elisp
(signal 'error-symbol data)
(error "message")
(condition-case err body handlers...)
(handler-bind body-function conditions handler ...)
(catch 'tag body...)
(throw 'tag value)
(unwind-protect body cleanup...)
```

Concurrency forms include:

```elisp
(make-thread function)
(thread-yield)
(thread-join thread)
(make-mutex)
(with-mutex mutex body...)
(make-condition-variable mutex)
(condition-wait condition)
(condition-notify condition)
```

**Representation and operation**

- Catch/throw and nonlocal unwinding: `src/eval.c:1245-1381`.
- `unwind-protect`: `src/eval.c:1384-1398`.
- `condition-case`: `src/eval.c:1400-1439`.
- Error signaling/handler selection: `src/eval.c:1798-1960`.
- Cleanup and dynamic-binding records: `src/eval.c:3594-3830`.
- Manual: `(elisp) Errors`, `(elisp) Handling Errors`, `(elisp) Cleanups`, `(elisp) Threads`, `(elisp) Mutexes`.

**Observable semantics and caveats**

- Dynamic bindings and registered cleanups unwind on error and `throw`.
- `unwind-protect` guarantees cleanup execution, not rollback of arbitrary earlier cell mutations.
- If a cleanup itself exits nonlocally, remaining cleanup forms are not automatically guaranteed.
- Ordinary load/configuration remains partially applied unless a separate transaction protocol exists.
- Emacs threading is currently “mostly cooperative,” but correct code must not rely on that remaining true.
- Globals are shared; dynamic `let` bindings, current buffer, and match data are thread-local.
- Multi-cell invariants require mutexes or immutable snapshot/commit designs.
- A single cell replacement can be visible as one operation, but a sequence of replacements is not a transaction.

**Priority: Essential.** Exception-safe dynamic restoration, the deployment failure boundary, and concurrent visibility must be proven before building hooks or advice. Multi-binding transactions can be postponed if explicitly excluded from the initial contract.

---

## Corrected interpretation of the checklist

| Existing item | Audit disposition |
|---|---|
| Live function cell | Keep, but provisional until compiled modes pass. |
| Independent value cell | Keep; add `defvar` initialization and special-variable behavior. |
| Property table for documentation and source metadata | Split and rewrite. Generic properties, function docs, variable docs, positioned symbols, provenance, load history, and function history are distinct. Defer most of it. |
| Function/value inspection and removal | Move into the cell-kernel milestone. |
| Live aliases and captured implementation | Move into the cell-kernel milestone. |
| Compiled behavior | Move immediately after the cell kernel; make it a stop/go gate. |
| Dynamic/context-local values with cleanup | Split into dynamic/unwind/thread semantics, then context-local overlay. Move concurrency here. |
| Interactive metadata | Keep as the final pre-decision Emacsen-specific runtime spike. |
| Macro boundary | Move beside runtime evaluation/compiler testing. |
| Hooks/advice/keymaps | Keep for after the core decision. |
| Features/autoload/deferred configuration | Split deployed runtime load from exact Emacs coordination conventions. |
| Load history/unload/concurrency/deployment | Split: deployment and concurrency are early; history/unload are later. |

---

## Minimal milestone sequence for evaluating Gerbil

Do not begin the next milestone unless the preceding one passes.

### M0 — Freeze the executable contract and test matrix

Define:

- qualified public binding identity;
- supported interpreted, separately compiled, optimized, and full-program modes;
- whether captured procedures are snapshots or stable live wrappers;
- whether runtime configuration is available in the deployed executable;
- excluded semantics, especially transactions and unload.

This prevents a REPL-only success from being mistaken for an Emacsen runtime result.

### M1 — Implement and test the binding kernel

In one running process demonstrate:

- stable shared function and value identities;
- independent function/value mutation;
- inspection, absent-state distinction, and removal;
- live symbolic aliases versus captured implementation objects;
- cycle rejection;
- a lifecycle-aware install operation distinct from raw cell mutation.

No documentation, hooks, advice, keymaps, or unload yet.

### M2 — Run the compiled late-lookup gate

An already-compiled caller must observe replacements in every supported mode. Include negative controls for:

- extracted procedures;
- explicit inlining;
- same-unit direct calls;
- compiler macros or equivalent rewrites;
- global-value reads.

If the contract cannot be maintained under a claimed production mode, either redesign the seam or remove that mode from the contract before continuing.

### M3 — Prove deployed runtime evaluation and the macro boundary

In the real deployment shape:

- read/evaluate/load a configuration form repeatedly without restart;
- report source-aware syntax, expansion, and runtime errors;
- preserve enough file/form provenance for diagnosis;
- show new macro expansion for forms expanded after redefinition;
- show that already-compiled expansions remain old until recompilation;
- confirm partial-load behavior or implement an explicitly scoped transaction.

Exact Emacs `load-history` is unnecessary here.

### M4 — Prove dynamic extent, cleanup, and concurrency semantics

Test:

- nested special bindings through arbitrary call chains;
- restoration after normal return, exception, and nonlocal exit;
- task/thread isolation of dynamic bindings;
- shared global visibility;
- replacement while another task is calling or waiting;
- synchronization for any multi-cell invariant.

This is a stop/go runtime-safety gate.

### M5 — Add one minimal context-local value overlay

Demonstrate:

- default fallback;
- context-local set/read/remove;
- switching contexts;
- dynamic binding interaction;
- exception restoration;
- task/thread behavior.

The context can be a lightweight editor-context token; buffers need not yet exist.

### M6 — Add replaceable command metadata and dispatch

Demonstrate:

- callable metadata identifying an interactive command;
- introspection/discovery;
- runtime replacement of body and interactive specification;
- programmatic versus interactive invocation;
- symbol-backed dispatch remaining live while captured closures remain captured.

After M6, Gerbil has supplied enough evidence for the language/runtime decision. Only then proceed to generic property metadata, documentation, Customize-like policy, hooks, advice, keymaps, autoload/features, full provenance/history, unloading, and configuration transactions.

---

## Validation commands

### Focused authoritative Emacs 30.2 probe

```sh
emacs -Q --batch --eval '
(progn
  (require (quote bytecomp))
  (setq wbg-target :value)
  (defun wbg-target () :old)
  (defun wbg-caller () (wbg-target))
  (fset (quote wbg-caller)
        (byte-compile (symbol-function (quote wbg-caller))))
  (defalias (quote wbg-live) (quote wbg-target))
  (defalias (quote wbg-snapshot)
    (symbol-function (quote wbg-target)))
  (defun wbg-target () :new)
  (unless (and (eq wbg-target :value)
               (eq (wbg-target) :new)
               (eq (wbg-caller) :new)
               (eq (wbg-live) :new)
               (eq (wbg-snapshot) :old))
    (error "cell, alias, capture, or byte-code lookup failure"))
  (princ "focused Emacs checks passed\n"))'
```

### Full convention-layer probe

```sh
emacs -Q --batch --eval '
(progn
  (defvar wbg-special :global "Variable documentation.")
  (condition-case nil
      (let ((wbg-special :temporary))
        (error "force unwind"))
    (error nil))
  (unless (eq wbg-special :global)
    (error "dynamic restoration failed"))

  (with-temp-buffer
    (make-local-variable (quote wbg-special))
    (setq wbg-special :local)
    (unless (and (eq wbg-special :local)
                 (eq (default-value (quote wbg-special)) :global))
      (error "buffer-local fallback failed")))

  (defvar wbg-hook nil)
  (defvar wbg-result nil)
  (defun wbg-hook-function () (setq wbg-result :old))
  (add-hook (quote wbg-hook) (quote wbg-hook-function))
  (defun wbg-hook-function () (setq wbg-result :new))
  (run-hooks (quote wbg-hook))
  (unless (eq wbg-result :new)
    (error "hook symbol was not late-bound"))

  (defun wbg-advised () :old)
  (advice-add
   (quote wbg-advised) :around
   (lambda (original &rest args)
     (list :advice (apply original args))))
  (defun wbg-advised () :new)
  (unless (equal (wbg-advised) (quote (:advice :new)))
    (error "defalias did not preserve named advice"))

  (defvar wbg-map (make-sparse-keymap))
  (defun wbg-command () (interactive) :old)
  (define-key wbg-map (kbd "C-c w") (quote wbg-command))
  (defun wbg-command () (interactive) :new)
  (unless (and (commandp (lookup-key wbg-map (kbd "C-c w")))
               (eq (call-interactively
                    (lookup-key wbg-map (kbd "C-c w")))
                   :new))
    (error "command/keymap late lookup failed"))

  (princ "full Emacs checks passed\n"))'
```

These probes were not run during this read-only audit. Gerbil validation commands must be derived from the eventual spike’s supported `gxi`/`gxc` and deployment harness rather than guessed. The mandatory matrix is M2 above.

## Residual risks and confidence

- **High:** No Gerbil result is conclusive until optimized and deployed compiled callers are tested.
- **High:** Runtime evaluation available only in a development interpreter would not satisfy the proposed Emacsen contract.
- **High:** Dynamic cleanup must be tested across Gerbil exceptions, continuations, and threads/tasks.
- **Medium:** A stable forwarding wrapper would make captured references remain live, which is stronger than Emacs’s extracted-function snapshot behavior; this must be intentional.
- **Medium:** Source provenance and unload policy remain product decisions after the core language evaluation.
- **Medium:** Emacs native speed-2 recursion and speed-3 intra-unit calls show why “native compiled” cannot be treated as one uniform lookup mode.
- **Confidence:** High for the GNU Emacs 30.2 behavior and source distinctions documented here; medium-high for the eventual Gerbil mapping until the milestone matrix is executed.