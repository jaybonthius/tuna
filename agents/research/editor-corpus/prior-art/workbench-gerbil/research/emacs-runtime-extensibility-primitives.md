# GNU Emacs 30.2 runtime extensibility primitives

## Conclusion

Emacs’s live extensibility is primarily a language/runtime property, not an accumulation of editor features:

1. **Names normally read as shared interned symbol objects.**
2. **Each symbol has independently mutable value, function, and property-list cells.**
3. **Ordinary interpreted and byte-compiled calls retain a symbol and resolve its current function cell at execution time.**
4. **Dynamic and buffer-local value lookup adds context-sensitive indirection.**
5. **Macros, hooks, advice, commands, keymaps, and loading conventions build on those cells.**

The decisive question for Gerbil is whether compiled application code can preserve deliberate mutable indirection under supported optimization modes. Reproducing Emacs surface forms without that property would not reproduce live extensibility.

**Research baseline**

- GNU Emacs 30.2 installed at  
  `/nix/store/m8rvbsn5h1nx27wvk9ch9gxr8l2m8avx-emacs-nox-30.2`
- GNU Emacs source tag: `emacs-30.2`
- Tag commit used by existing repository research: `29f3f150af5c5b065c3a9f39969429e5bb3285da`
- Local manuals:
  - `/nix/store/m8rvbsn5h1nx27wvk9ch9gxr8l2m8avx-emacs-nox-30.2/share/info/elisp.info.gz`
  - `/nix/store/m8rvbsn5h1nx27wvk9ch9gxr8l2m8avx-emacs-nox-30.2/share/info/emacs.info.gz`

No playground application files were inspected.

---

## 1. Language/compiler, runtime, and convention layers

| Layer | High-leverage behavior |
|---|---|
| **Language/compiler** | Lisp-2 name resolution; special versus lexical variables; macro expansion; interpreted versus compiled late binding; interactive declarations; source lexical-binding cookie. |
| **Runtime representation** | Interned symbols; separate function/value/property cells; symbol and variable indirection; buffer-local value records; closure and byte-code objects; autoload descriptors; keymap objects; unwind stack. |
| **Library convention** | Name prefixes; hooks stored in variables; advice wrappers; Customize metadata; feature loading; after-load callbacks; load-history-based unloading; command and keymap conventions. |

Hooks, advice, Customize, and features are important ergonomics, but none substitutes for stable identity plus mutable late-bound cells.

---

## 2. Interned symbols and separate cells

### Representation and operation

The ordinary reader interns symbol names in `obarray`. Re-reading the same name normally returns the same symbol object. Alternative obarrays and uninterned symbols from `make-symbol` are exceptions.

A symbol carries distinct:

- print name;
- variable value/indirection state;
- function definition;
- property list.

Evidence:

- interning implementation: GNU Emacs `src/lread.c:4900-5047`
- cell introspection: `src/data.c:714-818`
- GNU ELisp Manual nodes:
  - `Symbol Components`
  - `Creating and Interning Symbols`
  - `Symbol Forms`
  - `Function Names`

### User-facing property enabled

The same printed name can simultaneously denote a variable, function, command, macro, and metadata owner:

```elisp
(setq example :value)
(defun example () :function)
(put 'example 'category :metadata)
```

This gives Emacs its Lisp-2 behavior and lets independently loaded code rendezvous through a shared process-wide identity without importing a binding copy.

### Limitations

- The global namespace is collision-prone; packages conventionally prefix names.
- Uninterned symbols and separate obarrays do not share identity merely because names print alike.
- Property cells are metadata, not automatically transactional or lifecycle-safe.
- A Gerbil registry with separate function/value tables can reproduce the behavior without reproducing Emacs’s exact object layout.

---

## 3. Functions: `defun`, `defalias`, `fset`, removal, and introspection

### Representation and operation

`defun` is a macro that constructs a lambda/function object and expands to `defalias`:

- `lisp/emacs-lisp/byte-run.el:402-443`

`defalias` records load/function history, consults the `defalias-fset-function` property used by advice, and otherwise delegates to `fset`:

- `src/data.c:924-1021`

`fset` directly changes the symbol’s function cell after checking for circular symbolic indirection:

- `src/data.c:889-921`

Core introspection/removal operations are:

- `fboundp`: whether the cell is non-`nil`;
- `symbol-function`: raw cell contents;
- `indirect-function`: follow symbol aliases;
- `functionp`, `subrp`, `byte-code-function-p`, `commandp`;
- `fmakunbound`: set the function definition to `nil`.

Evidence: `src/data.c:758-810`.

### User-facing property enabled

Re-evaluating a named function definition mutates one shared cell. Future ordinary calls can observe it immediately:

```elisp
(defun greeting () :old)
(defun greeting () :new)
```

Existing callers need not be reloaded or re-imported.

### Redefinition and compiled-code limitations

Ordinary interpreted and byte-compiled named calls normally look up the symbol’s current function at execution time:

- evaluator lookup: `src/eval.c:2512-2535`
- `funcall`: `src/eval.c:3031-3067`
- byte-code lookup/call: `src/bytecode.c:608-633,740-815`

Late redefinition does **not** update:

- an invocation already executing;
- a procedure object previously extracted with `symbol-function`;
- closures that captured that object;
- inlined `defsubst`/`define-inline` bodies;
- compiler-macro rewrites;
- already-expanded macros;
- direct C calls;
- native speed-3 intra-unit direct/inlined calls.

The native compiler explicitly warns about speed-3 redefinition safety at `lisp/emacs-lisp/comp.el:2805-2818,2865-2881`.

Direct `fset` is intentionally lower-level than `defalias`: it bypasses load-history association and can discard advice wrappers.

---

## 4. Values: `defvar`, `defconst`, `setq`, `set`, and `defcustom`

### Representation and operation

- `setq` assigns the currently resolved binding of a syntactically named variable.
- `set` takes a symbol value at runtime and assigns that symbol’s current dynamic/value-cell binding.
- `symbol-value`, `boundp`, `makunbound` inspect or remove the value-cell binding.
- `defvar` initializes only when void and declares the variable special.
- `defconst` installs its value unconditionally and documents constant intent; it is not general immutable storage.
- `defcustom` uses `defvar` and attaches Customize metadata and initialization/setter policy.

Evidence:

- `set`: `src/data.c:1628-1647`
- `boundp`/`makunbound`: `src/data.c:714-782`
- `defcustom`: installed `lisp/custom.el.gz:249-302`
- GNU ELisp Manual nodes:
  - `Global Variables`
  - `Defining Variables`
  - `Setting Variables`
  - `Variable Definitions`

### User-facing property enabled

`defvar` supports configuration-before-library-loading:

```elisp
(setq package-option :user-value)
;; Later:
(defvar package-option :library-default)
```

The library does not overwrite the existing user value.

`defcustom` makes the same variable discoverable and editable through Customize by adding type, group, setter, safety, and standard-value metadata. `setopt`, unlike plain `setq`, validates the option and invokes its Customize setter.

### Redefinition and compiled-code limitations

- Plain loading another `defvar` normally does not reset an existing value.
- `defconst` does reset and is unsuitable for user-overridable state.
- `eval-defun` and related interactive evaluation commands can specially force a top-level `defvar`/`defcustom` initializer; ordinary `load` and `eval-buffer` do not.
- A lexical local with the same name is not the global value cell.
- Compiler-visible special declarations matter: code should declare special variables before compiling uses that depend on dynamic binding.
- Captured lexical values remain captured; changing the symbol’s global value does not rewrite closures.

---

## 5. Dynamic versus lexical binding

### Representation and operation

With lexical binding enabled, ordinary local `let` bindings reside in lexical environments or closure storage. Variables declared special by `defvar`, `defconst`, or `defcustom` remain dynamically bound through the runtime binding stack.

`set` and `symbol-value` address dynamic/value-cell state; they cannot reach an arbitrary lexical binding. `setq` updates a lexical binding when lexical resolution finds one.

A source file selects lexical behavior using its first-line `lexical-binding` file variable. The loader reads that cookie before evaluating forms:

- `src/lread.c:980-1100,1697-1746`
- GNU ELisp Manual nodes `Lexical Binding`, `Dynamic Binding`, and `Selecting Lisp Dialect`

### User-facing property enabled

Dynamic variables provide call-chain context without threading explicit parameters through every function:

```elisp
(let ((case-fold-search nil))
  (call-arbitrary-library-code))
```

Library code reading the special variable sees the temporary binding during that dynamic extent.

### Limitations

- Dynamic binding is invisible to functions using a same-named lexical binding.
- Mutation inside a dynamic `let` normally changes the temporary binding, not the process-wide default.
- Dynamic variables complicate concurrency and reasoning; a new editor should test thread/task semantics explicitly rather than assume process-global behavior.

---

## 6. Buffer-local variables

### Representation and operation

A variable can have a default value plus a value associated with the current buffer.

Runtime support uses localized symbol-value records and per-buffer local-variable storage:

- default lookup/set: `src/data.c:1986-2130`
- automatic localization on set: `src/data.c:2145-2209`
- explicit current-buffer localization: `src/data.c:2212-2315`
- removal and inspection: `src/data.c:2317-2415`

Relevant operations:

- `make-local-variable`;
- `make-variable-buffer-local`;
- `defvar-local`;
- `default-value` / `set-default`;
- `local-variable-p`;
- `kill-local-variable`.

### User-facing property enabled

Modes can use the same variable name while each buffer retains independent state, falling back to a shared default where no local binding exists.

### Limitations

- A normal `setq` can target the current buffer’s local value rather than the default.
- `let` binding and buffer localization interact subtly; creating a local value while `let`-bound can be surprising.
- Major-mode setup normally clears local variables unless marked permanent.
- Buffer-local state is a context overlay on variable lookup, not a separate lexical namespace.
- Gerbil suitability depends on whether similarly cheap context-sensitive cells can be implemented, not on adopting Emacs’s exact C representation.

---

## 7. Macros and redefinition

### Representation and operation

`defmacro` installs `(macro . EXPANDER)` in the symbol’s function cell through `defalias`:

- `lisp/emacs-lisp/byte-run.el:343-400`

`macroexpand-1` reads the current function definition, follows macro aliases/autoloads, and calls the expander:

- `lisp/emacs-lisp/macroexp.el:216-237`

### User-facing property enabled

An interpreted form that reaches macro expansion after a macro is redefined normally uses the new expander. This supports interactive language extension while developing configuration and libraries.

### Compiled-code limitation

Macro expansion produces ordinary code before execution. Already byte-compiled or native-compiled callers retain the old expansion until recompiled. Advice or redefinition of the macro name cannot intercept code that no longer contains that macro call.

The same limitation applies to:

- `defsubst`;
- `define-inline`;
- compiler macros;
- optimizer substitutions;
- explicit earlier `macroexpand`.

This is one of the most important boundaries when evaluating Gerbil: runtime procedure rebinding does not imply runtime macro rebinding.

---

## 8. Interactive commands and `call-interactively`

### Representation and operation

A command is a callable object with interactive argument metadata. For interpreted lambdas the metadata originates from a top-level `(interactive SPEC)` form; byte-code closures have a dedicated interactive slot; primitives carry a C-level interactive specification; autoload descriptors can declare interactivity.

`commandp` recognizes these representations:

- `src/eval.c:2195-2260`

`call-interactively` obtains the interactive form, computes arguments from either an interactive-code string or evaluated Lisp form, handles prefix/key/event context, optionally records command history, then calls the function interactively:

- `src/callint.c:253-430`

### User-facing property enabled

The same function can be:

- called programmatically with explicit arguments;
- invoked by keys with arguments read from editor state;
- discovered as a command;
- recorded in command history.

This cleanly separates command dispatch from UI argument acquisition.

### Redefinition limitations

- A keymap entry containing a command **symbol** follows the current function cell.
- A keymap or variable containing an extracted closure retains the old object.
- Re-evaluating `defun` replaces its interactive declaration along with its body.
- Inlined or direct compiled calls bypass `call-interactively` and its metadata.
- Advice may alter the callable while preserving or synthesizing interactive metadata; low-level replacement can lose it.

For a new Emacsen, command metadata should be treated as runtime callable metadata, not encoded solely in keymap entries.

---

## 9. Hooks

### Representation and operation

Hooks are primarily a library convention over variables:

- a hook variable contains a function, list of functions, or `nil`;
- hook runners call the entries;
- named hook entries remain late-bound because the list stores symbols;
- local hooks use a buffer-local value containing `t` to include the default/global hook.

`add-hook` and `remove-hook` manipulate this representation and optional ordering depth:

- installed `lisp/subr.el.gz:2096-2250`

### User-facing property enabled

Libraries expose stable extension points without callers replacing entire functions. Configuration can add, remove, order, and localize behavior.

### Limitations

- A symbol entry observes later `defun`; a lambda entry is a captured object.
- Anonymous functions are harder to identify, remove, and unload.
- Hook execution is sequential and normally not transactional.
- One failing hook can abort later entries unless the hook runner explicitly isolates errors.
- Hook naming and argument contracts are conventions, not enforced by the base cell mechanism.

Hooks are preferable to advice when the library owns an explicit extension point.

---

## 10. Advice

### Representation and operation

Modern named advice composes wrappers around a symbol’s current function. It records pending advice for undefined/autoloaded functions and installs `defalias-fset-function` metadata so later `defun`/`defalias` replaces the inner definition while preserving advice:

- `lisp/emacs-lisp/nadvice.el:454-532`
- `src/data.c:984-990`

### User-facing property enabled

Users can add `:before`, `:after`, `:around`, filtering, or overriding behavior even where no hook was designed.

### Limitations

- Direct `fset` can replace the entire advised definition.
- Advice cannot affect already-expanded macros, inlined calls, direct C calls, or native direct calls.
- Wrapper order and argument/return transformations make composition harder to reason about than hooks.
- Advice attached by anonymous closures is harder to remove and unload.
- Advice is a library-level composition protocol relying on mutable function cells; it is not a necessary primitive for an initial Gerbil spike.

---

## 11. Keymaps and command remapping

### Representation and operation

Keymaps are mutable map objects, represented in full or sparse forms, with optional parent maps. `define-key`/`keymap-set` mutate a mapping from event sequences to definitions.

A definition can be a command symbol, closure, keyboard macro, prefix keymap, menu item, or indirection. Symbol definitions are resolved through their function definitions at lookup/execution time.

Command remapping is stored under the special key form:

```elisp
[remap ORIGINAL-COMMAND]
```

Evidence:

- keymap creation/parents: `src/keymap.c:94-320`
- mutation and definition representation: `src/keymap.c:1085-1218`
- remapping: `src/keymap.c:1224-1248`
- lookup applying remapping: `src/keymap.c:1792-1852`

### User-facing property enabled

- Keys can change without redefining commands.
- Commands can change without rebinding every key.
- A mode can remap the semantic command while inheriting whichever keys currently invoke it.
- Parent and active-map precedence provide contextual behavior.

### Limitations

- A symbol binding remains live; a stored closure remains stale after function redefinition.
- Remapping is contextual and generally nonrecursive.
- Mutating a shared keymap affects every context referencing that object.
- Keymaps are an editor/runtime data structure and dispatch convention, not evidence that the underlying language supports live definition replacement.

---

## 12. Autoload, features, after-load behavior, history, and unloading

### Autoload

`autoload` installs an autoload descriptor in the function cell. The descriptor carries the file plus optional documentation, interactivity, and type information. First use loads the file, verifies that loading replaced the descriptor, and retries the call:

- installation: `src/eval.c:2305-2343`
- rollback/load/verification: `src/eval.c:2346-2442`
- retry: `src/eval.c:3054-3060`

An existing non-autoload definition is not overwritten by `autoload`. Explicit later loading can still overwrite it.

Failed autoloading specially rolls back function definitions and feature provisions made through the autoload queue; ordinary explicit loading is not generally transactional.

### `provide` and `require`

- `provide` adds a symbol to global `features`.
- `require` loads only when the feature is absent and verifies that loading provided it.

Evidence: `src/fns.c:3650-3796`.

These are load coordination, not module imports or namespace isolation.

### After-load behavior

`with-eval-after-load` expands to `eval-after-load` with a closure. It runs immediately if the file/feature is already loaded or records a callback otherwise:

- installed `lisp/subr.el.gz:5950-6026`
- after-file dispatch: `lisp/subr.el.gz:6028-6062`
- loader invocation: `src/lread.c:1697-1750`

This solves definition ordering, such as ensuring a user replacement happens after a library’s own `defun`.

### Load history and unloading

`load` evaluates forms sequentially and records definitions, `provide`, and `require` entries in `load-history`:

- `src/lread.c:1278-1322,1697-1746`

`unload-feature` uses that history and function history to:

- restore prior definitions/autoloads where possible;
- unbind recorded variables;
- remove named functions from recognizable hooks;
- remove provided features;
- invoke package-specific unload cleanup.

Evidence:

- `lisp/loadhist.el:145-226`
- `lisp/loadhist.el:229-322`

### Limitations

- Reload is sequential execution, not atomic module replacement.
- Definitions removed from an edited source file remain live until explicitly removed or unloaded.
- Repeated registrations and other side effects may duplicate.
- Failure halfway through loading leaves earlier ordinary mutations applied.
- Unloading cannot reliably discover arbitrary side effects or anonymous closures.
- `require` does not reload an already provided feature.
- Ordinary `load` may choose `.elc`/`.eln` instead of edited source; `load-prefer-newer` or an exact source filename changes that policy.

---

## 13. `read`, `eval`, `load`, source metadata, and introspection

### Representation and operation

- `read` converts textual Lisp into ordinary runtime objects.
- Symbols are interned during reading unless syntax explicitly requests otherwise.
- `read-from-string` returns the object and ending index.
- `eval` evaluates an object, optionally with a lexical environment.
- `eval-buffer` and `eval-region` repeatedly read and evaluate forms.
- `load` locates a source/compiled artifact, establishes load variables and lexical mode, evaluates sequentially, records history, and runs after-load callbacks.

The first-line lexical cookie is parsed at `src/lread.c:980-1100`; loading and history behavior are at `src/lread.c:1278-1322,1697-1750`.

Emacs 30 can attach source positions to read symbols using “symbol with position” wrapper objects. Accessors are implemented at:

- `src/data.c:828-883`

Definition provenance is also exposed indirectly through:

- `load-file-name` / `load-history`;
- `function-history`;
- function documentation and argument-list inspection;
- `find-function`/`find-variable` library conventions;
- macro expansion APIs;
- backtraces and error data.

### User-facing property enabled

A user can evaluate one form, region, buffer, or file in the running process and immediately inspect or invoke the changed definitions. The reader and evaluator are available as runtime services rather than only as ahead-of-time build tools.

### Limitations

- Source position wrappers are not universal retained source maps for every runtime object.
- Compiled objects may retain documentation/source references differently from interpreted definitions.
- Evaluating source mutates the live process incrementally.
- Runtime `eval` suitability must be tested in the exact compiled Gerbil deployment; availability only in a development interpreter is insufficient for an Emacs-like configuration contract.

---

## 14. Aliases

### Function aliases

A function cell can contain another symbol:

```elisp
(defalias 'live-alias 'target)
```

Calls follow symbolic function indirection, so redefining `target` remains visible.

This differs from:

```elisp
(defalias 'snapshot (symbol-function 'target))
```

which stores the current function object and remains attached to it.

`fset` rejects a newly introduced circular alias chain: `src/data.c:889-921`.

### Variable aliases

`defvaralias` redirects variable operations so two symbols share value bindings. Runtime variable lookup follows `SYMBOL_VARALIAS`, visible throughout `src/data.c:714-750,1986-2094,2145-2415`.

### User-facing property enabled

Aliases support compatibility names, renaming, and API migration while preserving live behavior when alias indirection is retained.

### Limitations

- Aliasing a symbol is live; copying its current object/value is not.
- Function and variable aliases are separate mechanisms.
- Aliases can complicate provenance, watchers, unloading, and cycle detection.
- Compiler inlining or constant propagation can remove the intended indirection.

---

## 15. Errors, nonlocal exits, and cleanup

### Representation and operation

- `catch` establishes a tagged nonlocal-exit target.
- `throw` exits to a matching catch.
- `signal` raises an error condition with data.
- `condition-case` selects handlers by condition hierarchy.
- `unwind-protect` records cleanup forms on Emacs’s dynamic binding/unwind stack.

Evidence:

- catch/throw: `src/eval.c:1245-1381`
- `unwind-protect`: `src/eval.c:1384-1398`
- `condition-case`: `src/eval.c:1400-1490`
- `signal`: `src/eval.c:1798-1960`
- runtime cleanup records: `src/eval.c:3594-3810`

### User-facing property enabled

Live configuration and extensions can:

- report structured failures;
- recover at a chosen boundary;
- abort deeply nested work without explicit return propagation;
- guarantee restoration of temporary state, resources, buffers, or bindings.

### Limitations

- `unwind-protect` guarantees cleanup, not rollback of arbitrary cell mutations.
- A cleanup error can replace the original exit.
- Ordinary file evaluation remains partially applied after an error.
- A configuration transaction, if desired, requires an explicit staging/commit or undo protocol.
- Dynamic bindings and cleanup must unwind correctly across all supported Gerbil exceptions, continuations, and threads; this is a must-test runtime property.

---

## 16. Separate editor data structures

These structures matter to an editor but are a separate evaluation axis from language/runtime extensibility:

- **buffers:** mutable text plus buffer identity and per-buffer state;
- **markers:** positions that adjust as text changes;
- **text properties:** interval-associated metadata embedded in text;
- **overlays:** independent ranges carrying properties and display behavior.

They interact with hooks, commands, and buffer-local variables, but implementing them does not establish live definition semantics. Conversely, a successful cell/dispatch spike does not establish that Gerbil is suitable for their performance or garbage-collection demands.

---

## 17. Material implementation options for Gerbil

### Option A — Emacs-like runtime symbol objects

Create interned runtime symbols with separate function, value, and property cells; compile designated global calls and reads into cell lookup.

**Advantages**

- Closest semantic match.
- Natural aliases and introspection.
- One representation can support commands, macros, properties, and loading.

**Constraints**

- Broad custom language/runtime work.
- Every compiler mode must preserve designated late lookup.
- Requires collision, synchronization, namespace, and garbage-collection policies.

### Option B — Qualified registry plus stable per-binding cells

Macros declare customizable definitions, allocate mutable cells, register qualified keys, and expose stable forwarding procedures/accessors.

**Advantages**

- Smaller and more idiomatic for Gerbil.
- Explicitly limits late binding to intended extension points.
- Stable wrappers can remain live even when captured.

**Constraints**

- Not automatic for ordinary Gerbil `def`.
- Existing callers must use/recompile against the generated seam.
- Stable captured wrappers are stronger than Emacs’s captured-function-object behavior.
- Separate function/value domains and compiler retention must be deliberately implemented.

### Option C — Dynamic parameters for values

Use parameters for dynamically scoped configuration while using cells/registries for functions.

**Advantages**

- Natural dynamic extent and restoration.
- Potentially good task/thread-local semantics.

**Constraints**

- Does not implement ordinary process-global or buffer-local variables by itself.
- Parameter procedure capture and thread inheritance require explicit contracts.
- Still needs a function-dispatch solution.

### Option D — Runtime module reload

Reload implementation modules and keep stable public dispatch modules.

**Advantages**

- Useful development/plugin mechanism.

**Constraints**

- Initializers rerun; removed definitions and captured objects remain problematic.
- Type identity and optimization can make replacement unsafe.
- Not a substitute for mutable binding cells.

---

## 18. Ranked runtime semantics to spike

### Must-test now

1. **Stable identity and distinct function/value cells**  
   Demonstrate the same public name in both domains, independent mutation, introspection, aliasing, and removal.

2. **Late lookup from real compiled callers**  
   An already-compiled ordinary caller must observe function and global-value replacement in every claimed `gxi`, normal `gxc`, `-O`, and full-program optimization mode. Explicitly test extracted procedures and inlining as negative cases.

3. **Runtime read/eval/load in one process**  
   Load edited configuration repeatedly without restarting. Confirm lexical mode, source diagnostics, unknown-name errors, and definition provenance.

4. **Macro phase boundary**  
   Show that interpreted callers can observe a changed macro where applicable and that compiled callers retain old expansion until recompiled. Do not advertise macro hot-swapping beyond this boundary.

5. **Dynamic binding and reliable unwinding**  
   Test nested special bindings across calls and guaranteed restoration after exceptions/nonlocal exits.

6. **Context-local value overlay**  
   Prototype a minimal buffer/context-local variable with default fallback, local mutation, local removal, and dynamic-binding interaction. This tests a core Emacsen pattern without building buffers themselves.

7. **Callable command metadata**  
   Attach interactive metadata to a replaceable callable; discover it, replace it, and invoke it through a `call-interactively`-like dispatcher.

### Later-test

1. Symbol-valued hooks with ordering, removal, local/global composition, and failure policy.
2. Advice wrapper composition and preservation across ordinary redefinition.
3. Keymap mutation, parent lookup, symbol bindings, and command remapping.
4. Autoload descriptors, pending overrides, feature gates, and after-load ordering.
5. Customize-style typed metadata, setters, validation, defaults, and provenance.
6. Load history, explicit unload hooks, and best-effort restoration.
7. Concurrency visibility, synchronization, and multi-binding configuration transactions.
8. Native/plugin reload and compatibility of runtime type identities.

These can mostly be built as libraries once the must-test indirection, metadata, and unwinding semantics are proven.

### Not yet relevant to the language/runtime decision

- rendering and display engines;
- redisplay scheduling;
- windows and frames;
- input decoding;
- buffer storage algorithms;
- marker-update algorithms;
- text-property interval structures;
- overlays;
- process/network APIs;
- package user interfaces.

They are important later editor-engine investigations but do not answer whether Gerbil can support Emacs-like live extensibility.

---

## 19. Findings and risks

- **High — compiler correctness:** Mutable cells are insufficient if optimized callers inline, direct-call, or capture implementations.
- **High — runtime evaluator availability:** Development-time `eval` is insufficient if deployed compiled executables cannot safely read and apply configuration.
- **High — phase conflation:** Function redefinition must not be presented as macro or inline redefinition.
- **High — dynamic cleanup:** Incorrect exception unwinding would corrupt temporary configuration and editor context.
- **Medium — context model:** Buffer-local semantics need an explicit task/thread/buffer interaction contract.
- **Medium — captured-object semantics:** Decide whether Gerbil stable wrappers remain live or emulate Emacs’s stale extracted procedure objects.
- **Medium — load consistency:** Sequential reload can duplicate effects and partially apply changes unless a transaction protocol is added.
- **Medium — metadata lifecycle:** Direct low-level mutation can leave advice, command, documentation, and provenance metadata stale.
- **Medium — unloading:** History-based best-effort unloading cannot discover arbitrary side effects.
- **Low — exact Emacs representation:** Obarrays and C symbol layouts need not be copied if observable semantics are preserved.
- **Confidence:** High for GNU Emacs 30.2 symbol, binding, command, macro, advice, keymap, loading, and unwind behavior; medium-high for how closely Gerbil can preserve these semantics under every optimizer until the proposed spikes are run.

---

## 20. Evidence-backed validation commands

### Focused Emacs 30.2 runtime probe

```sh
emacs -Q --batch --eval '
(progn
  (require (quote bytecomp))

  ;; Separate cells and compiled late function lookup.
  (setq wbg-target :value)
  (defun wbg-target () :old)
  (defun wbg-caller () (wbg-target))
  (fset (quote wbg-caller)
        (byte-compile (symbol-function (quote wbg-caller))))
  (defun wbg-target () :new)
  (unless (and (eq wbg-target :value)
               (eq (wbg-target) :new)
               (eq (wbg-caller) :new))
    (error "cell or compiled-call failure"))

  ;; Live alias versus captured object.
  (defalias (quote wbg-live) (quote wbg-target))
  (defalias (quote wbg-snapshot)
    (symbol-function (quote wbg-target)))
  (defun wbg-target () :newer)
  (unless (and (eq (wbg-live) :newer)
               (eq (wbg-snapshot) :new))
    (error "alias/capture failure"))

  ;; Dynamic restoration.
  (defvar wbg-special :global)
  (condition-case nil
      (let ((wbg-special :temporary))
        (error "leave"))
    (error nil))
  (unless (eq wbg-special :global)
    (error "dynamic unwind failure"))

  (princ "focused checks passed\n"))'
```

### Fuller convention-layer probe

```sh
emacs -Q --batch --eval '
(progn
  ;; Buffer-local fallback.
  (defvar wbg-local :default)
  (with-temp-buffer
    (make-local-variable (quote wbg-local))
    (setq wbg-local :buffer)
    (unless (and (eq wbg-local :buffer)
                 (eq (default-value (quote wbg-local)) :default))
      (error "buffer-local failure")))

  ;; Hook symbol remains late-bound.
  (defvar wbg-hook nil)
  (defvar wbg-result nil)
  (defun wbg-hook-function () (setq wbg-result :old))
  (add-hook (quote wbg-hook) (quote wbg-hook-function))
  (defun wbg-hook-function () (setq wbg-result :new))
  (run-hooks (quote wbg-hook))
  (unless (eq wbg-result :new)
    (error "hook late-binding failure"))

  ;; Advice survives defun/defalias redefinition.
  (defun wbg-advised () :old)
  (advice-add
   (quote wbg-advised) :around
   (lambda (original &rest args)
     (list :advice (apply original args))))
  (defun wbg-advised () :new)
  (unless (equal (wbg-advised) (quote (:advice :new)))
    (error "advice preservation failure"))

  ;; Key binding stores a live command symbol.
  (defvar wbg-map (make-sparse-keymap))
  (defun wbg-command () (interactive) :old)
  (define-key wbg-map (kbd "C-c w") (quote wbg-command))
  (defun wbg-command () (interactive) :new)
  (unless (and (commandp (lookup-key wbg-map (kbd "C-c w")))
               (eq (call-interactively
                    (lookup-key wbg-map (kbd "C-c w")))
                   :new))
    (error "command/keymap failure"))

  (princ "full checks passed\n"))'
```

Recommended Gerbil validation should reproduce the must-test matrix in interpreted, normal compiled, optimized, and full-program modes rather than relying on a single REPL demonstration.