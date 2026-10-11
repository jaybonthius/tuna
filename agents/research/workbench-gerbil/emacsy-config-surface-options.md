# Emacsy configuration surface options

## Concise answer

The current cell-and-registry architecture is a sound semantic base, but its user surface is not yet Emacs-like:

```scheme
(playground/runtime#redefine-function!
 'playground/lib/greeting
 (lambda (who) ...))
```

A concrete ergonomic target is:

- **Library author:** mark a definition customizable with one familiar declaration, ideally with its public key inferred:

  ```scheme
  (defcustom (greeting who)
    (string-append "default " who))

  (defcustom site-name
    "default-site")
  ```

- **User:** write short definition/assignment forms, import no target library, and reload repeatedly:

  ```scheme
  (defun playground-greeting (who)
    (string-append "configured " who))

  (setq playground-site-name "configured-site")
  ```

- **Runtime meaning:** these forms replace registered, existing bindings only; they never create config-local application bindings.
- **Naming:** customization names are public API, distinct from Gambit’s internal `module#binding` globals.
- **Lisp-2:** function and value registries are separate domains, so the same public name can occupy both.
- **Errors:** unknown names, ambiguous short names, wrong kind, duplicate declarations, invalid values, and detectable arity mismatch fail with config path/location and declaration provenance.
- **Reload:** repeated evaluation is idempotent for definitions; advice requires stable IDs; reset needs immutable defaults and source-layer provenance.

The Emacs-style typed surface above most faithfully preserves Emacs ergonomics. Qualified `def`, scoped module forms, and alias blocks can improve Gerbil usability, but mainly compress or hide qualification.

## Current repository behavior

### Implemented semantics

The live playground is newer than the supplied research artifacts’ “current prototype” descriptions:

- `playground/runtime.ss:11-21` holds one symbol-keyed registry and rejects duplicate keys.
- `playground/runtime.ss:23-48` distinguishes function and value entries, rejects unknown keys and kind mismatches, and validates only `procedure?` for functions.
- `playground/runtime.ss:50-51` reloads configuration with plain Gambit `load`.
- `playground/runtime.ss:53-63` generates a stable function forwarder around a boxed implementation.
- `playground/runtime.ss:65-77` exports customizable values through an identifier macro reading a box.
- `playground/lib.ss:7-11` declares one function and one value, but repeats explicit qualified keys.
- `playground/lib.ss:13-14` demonstrates same-library late reads and calls.
- `playground/main.ss:9-30` captures the function and value, loads two configurations, and observes both changes.
- `playground/config.scm:1-8` and `playground/config-v2.scm:1-8` import no libraries but use verbose fully qualified runtime calls, quoted qualified keys, and explicit lambdas.

Expected behavior is recorded in `plans/emacsy-runtime-customization-mwe/spec.md:194-204`: ordinary and same-library calls/reads change; the captured stable function forwarder remains live; the captured value remains stale.

### Current ergonomic and semantic gaps

1. **Medium — one registry key blocks true Lisp-2 coexistence.**  
   `playground/runtime.ss:17-21` rejects a duplicate key before considering kind. A function and value named by the same key therefore cannot coexist, unlike Emacs’s independent function and value cells.

2. **Medium — diagnostics lack provenance and expected contracts.**  
   `playground/runtime.ss:13-48` reports a message and key, but not config path/line, declaration location, expected value predicate, expected signature, or nearby-name suggestions.

3. **Medium — explicit key duplication can drift.**  
   `playground/lib.ss:7-11` repeats `greeting`/`site-name` inside quoted keys. Renaming either side can silently change or break the customization API.

4. **Medium — reload is sequential and nontransactional.**  
   `playground/runtime.ss:50-51` delegates directly to `load`. Earlier mutations survive if a later form fails, and a form removed from a later config remains in effect. This matches ordinary Emacs load closely but is not necessarily the most useful production behavior.

5. **Low — current examples load two files, not the same edited path twice.**  
   `playground/main.ss:17-24` proves repeated loads in one process, and Gambit permits repeated source loading, but the example uses `config.scm` followed by `config-v2.scm`.

The older statement at `research/emacsy-runtime-customization-design.md:423-429` that the playground demonstrates only one function and no values/repeated reload is now stale.

## Authoritative constraints

- Gerbil’s ordinary `def` is a definition form that expands to `define-values`, not a replace-existing customization operation: `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:17-32`.
- The expander permits rebinding in non-module top contexts: `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:670-674`. Therefore native config-side `def` cannot enforce “registered existing customization only.”
- Compiled `eval` uses the top-level namespace rather than the enclosing module namespace: `/home/jay/Code/gerbil/doc/guide/eval.md:19-62`.
- `extern` is expansion-time namespace mapping and requires the Gerbil expander in compiled programs: `/home/jay/Code/gerbil/doc/guide/eval.md:62-93`; implementation at `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:445-475`.
- Gerbil derives runtime IDs from module namespace and identifier: `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:719-738`.
- Module imports preserve the source binding identity: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:535-563`.
- Gambit `load` rereads and executes source, while loaded-file macro definitions are local to that file: `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6063-6097,6132-6135`.
- Gerbil syntax objects can carry file, line, and column locations through `stx-source`: `/home/jay/Code/gerbil/doc/reference/gerbil/expander/utilities.md:182-197`.
- Gerbil errors can carry message, irritants, origin, and stack traces: `/home/jay/Code/gerbil/doc/reference/std/errors.md:9-21,54-87,129-137`.

Consequently, richer definition-shaped config syntax needs one of:

1. a custom reader/lowering loader;
2. a config-local included macro prelude;
3. the Gerbil runtime expander, with its already researched FPO problem;
4. or a less expressive procedure-call surface valid under plain Gambit `load`.

Syntax should not be selected solely because option 4 is easiest.

## Naming and Lisp-2 model

### Recommended model for evaluating surfaces

Registry identity should be:

```text
(kind, public-customization-name)
```

rather than one untyped symbol key.

This gives:

- duplicate detection within each kind;
- legal coexistence of function and value names;
- deterministic `defun` versus `setq`;
- public names independent of Gambit’s `module#binding` implementation symbol;
- declaration metadata attached to each cell.

A public name may default to a qualified logical key such as `playground/lib/greeting`, with an explicit stable-name override for API stability. Automatic module-derived keys minimize author syntax but couple user configuration to module moves.

Gerbil itself remains Lisp-1. Under the current implementation, a stable function procedure and an identifier-macro value cannot both be exported under the same Gerbil identifier. Exact same-name Lisp-2 behavior inside library source would require either:

- distinct Gerbil source identifiers mapping to the same external public name; or
- one identifier macro that expands application position through the function cell and bare identifier position through the value cell.

The latter changes higher-order capture semantics and should not be implied by merely splitting the registry.

## Can user `def` safely mean replace-existing-only?

**Yes, but only as a customization-language form—not as native Gerbil `def`.**

Safe semantics require:

1. target libraries register before config loading;
2. lookup occurs before evaluating or committing replacement;
3. an unknown key is an error, not a new definition or implicit pending override;
4. the form selects function versus value deterministically;
5. mutations are recorded against the current config load for diagnostics/reset.

With structured forms:

```scheme
(def (playground/lib/greeting who) ...)
(def playground/lib/site-name "site")
```

the first can mean function replacement and the second value replacement. However:

- setting a function from an existing procedure expression needs a typed escape such as `fset`;
- setting a value to a procedure is otherwise ambiguous;
- the same public name in both Lisp-2 domains cannot be selected by a generic expression-form `def`.

Thus a generic `def` is safe only with either globally unique cross-kind keys—which gives up Lisp-2 coexistence—or typed companion forms.

## Candidate surfaces

### 1. Gerbil-shaped qualified `def`

Library:

```scheme
(defcustom (greeting who)
  (string-append "default " who))

(defcustom site-name "default-site")
```

Config:

```scheme
(def (playground/lib/greeting who)
  (string-append "configured " who))

(def playground/lib/site-name "configured-site")
```

**Advantages**

- Minimal author syntax.
- Familiar to Gerbil users.
- No quotes, explicit lambda, runtime namespace call, or imports.
- Definition-shaped form can record declared arity.
- Clearly means replacement if handled by a dedicated config loader.

**Tradeoffs**

- Qualification remains on every form.
- Overloaded `def` is ambiguous for procedure-valued values and procedure-expression function replacement.
- It is not native Gerbil `def`; presenting it without that distinction would be misleading.
- Needs `fset`/`vset` escapes for complete Lisp-2 behavior.

**Classification:** Substantive ergonomic improvement and Gerbil-familiar, but only partly Emacs-like. It preserves live redefinition semantics while retaining explicit module identity.

### 2. Emacs-style typed, globally prefixed names

Library:

```scheme
(defcustom (greeting who)
  name: playground-greeting
  (string-append "default " who))

(defcustom site-name
  name: playground-site-name
  "default-site")
```

Config:

```scheme
(defun playground-greeting (who)
  (string-append "configured " who))

(setq playground-site-name "configured-site")
```

Low-level escapes:

```scheme
(fset playground-greeting replacement-procedure)
(setv playground-site-name replacement-value)
```

**Advantages**

- Closest to Emacs’s actual ergonomics: flat shared names, conventional package prefixes, and distinct function/value operations.
- Same public name can legally have both cells.
- `defun` can validate syntactic formals; `setq` cannot accidentally replace a function.
- Public names remain stable across internal module moves.

**Tradeoffs**

- Global prefix discipline replaces module isolation.
- Library authors either repeat a public name or accept a project-specific derivation convention.
- Elisp vocabulary may be less natural to Gerbil users.
- Requires a DSL/macro loader rather than plain current `load`.

**Classification:** The strongest preservation of Emacs-like ergonomics, not merely hidden qualification.

### 3. Typed, qualified compact forms

```scheme
(defun playground/lib/greeting (who)
  (string-append "configured " who))

(setv playground/lib/site-name "configured-site")
```

or expression-oriented:

```scheme
(fset playground/lib/greeting replacement)
(vset playground/lib/site-name value)
```

**Advantages**

- Unambiguous kind selection and Lisp-2 registry support.
- Good errors and arity metadata are straightforward.
- Still far shorter than the current API.
- Qualified keys scale without global prefix conventions.

**Tradeoffs**

- Every form still names a module-qualified key.
- `fset` with a lambda is only a compressed registry API.
- Less familiar than ordinary Gerbil `def`.

**Classification:** Semantically strong, but mostly an ergonomic wrapper around qualification rather than Emacs-like namespace ergonomics.

### 4. Module-scoped Gerbil forms

```scheme
(in-customization playground/lib
  (def (greeting who)
    (string-append "configured " who))
  (def site-name "configured-site"))
```

Typed variant:

```scheme
(in-customization playground/lib
  (defun greeting (who) ...)
  (setq site-name "configured-site"))
```

**Advantages**

- Qualification appears once for a group.
- Short familiar names inside the group.
- Ambiguities and typo suggestions can be scoped to one library.
- Logical module names remain explicit.

**Tradeoffs**

- Nested groups complicate source locations and partial evaluation.
- Moving one definition between modules changes config structure.
- The apparent lexical environment is only key prefixing; it is not a target-library import or module namespace.

**Classification:** Useful Gerbil configuration ergonomics, but primarily qualification compression rather than Emacs-like global symbol access.

### 5. Automatically resolved short names

```scheme
(def (greeting who)
  (string-append "configured " who))

(def site-name "configured-site")
```

The registry accepts an unqualified leaf only when exactly one matching customization exists; otherwise it reports all candidates and requires qualification.

**Advantages**

- Smallest, most familiar user surface.
- No module declarations or prefix boilerplate.
- Imports remain unnecessary.

**Tradeoffs**

- Adding an unrelated library with the same leaf can break an existing config.
- Resolution depends on the set and order of registered libraries.
- Function/value ambiguity still requires typed forms.
- It resembles Emacs only superficially: Emacs relies on globally interned, conventionally prefixed names rather than “currently unique leaf” lookup.

**Classification:** Convenient but fragile. It hides qualification rather than reproducing Emacs’s stable shared-name model.

## Error contract

A useful config error should resemble:

```text
~/.config/workbench/config.scm:12:3:
unknown function customization `playground/lib/greting`
did you mean `playground/lib/greeting`?
declared at playground/lib.ss:7:1
no changes from this reload were committed
```

Minimum diagnostics:

- config path, line, column, and offending form;
- public key and requested kind;
- unknown versus ambiguous versus wrong-kind distinction;
- nearby-name suggestions;
- declaration source and existing duplicate source;
- expected function signature or value predicate;
- whether earlier forms committed;
- cause/backtrace for exceptions while evaluating replacement expressions.

Declaration macros can capture source locations using `stx-source`. Function shorthand can compare its syntactic formals to declaration metadata. Arbitrary `fset` procedure expressions may only permit `procedure?` validation unless a supported arity-introspection contract is established; invoking a replacement speculatively is unsafe.

Unknown names should fail immediately by default. Supporting configuration before library registration should use an explicit `defer`/pending form, because treating all unknown names as pending turns typos into delayed failures.

## Advice, reload, and reset evolution

### Advice

Do not implement advice as repeated destructive wrapping of the effective box value. Store per function:

- immutable library default;
- current configured base implementation;
- ordered advice records;
- recomputed effective implementation used by the stable forwarder.

Each advice needs a stable ID:

```scheme
(advice-add playground-greeting
  around: log-greeting
  (lambda (next who) ...))
```

Reloading the same `(target, advice-id)` should replace that advice entry, not append another wrapper. Function redefinition should replace the base while preserving advice, matching Emacs `defalias`/modern advice behavior described in `research/emacs-runtime-redefinition-semantics.md:51-75,119-139`.

### Reload

Two materially different contracts are defensible:

1. **Emacs-like sequential reload**
   - execute forms in order;
   - earlier changes survive a later error;
   - removed forms remain active;
   - repeated named definitions overwrite;
   - named advice must still avoid duplication.

   This matches `research/emacs-runtime-redefinition-semantics.md:191-204` and current `playground/runtime.ss:50-51`.

2. **Declarative source-layer reload**
   - evaluate and validate into a staging layer;
   - commit all operations atomically;
   - replace the previous layer associated with that canonical path;
   - forms removed from the file cease to apply;
   - failure preserves the previously committed layer.

   This is less literally Emacs-like but usually more predictable for application configuration.

The surface should expose which contract is in force rather than silently mixing them.

### Reset

Reset requires preserving defaults and provenance:

```scheme
(reset playground-greeting)       ; restore library default/base
(reset-config! config-path)        ; remove one source layer
(reset-all-customizations!)        ; restore all defaults
```

Advice reset should be separate from base reset unless explicitly documented. Library re-registration must preserve existing cell identity so compiled callers are not stranded; policy must decide whether a new library declaration updates the saved default while retaining active user layers.

## Material implementation options

1. **Custom reader/lowering loader**  
   Best syntax control, diagnostics, staging, and advice IDs. Highest risk: arbitrary Scheme expression evaluation and FPO behavior need new proof.

2. **Config-local included macro prelude**  
   Keeps Gambit source loading and permits definition-shaped forms, but requires an `include` line or generated wrapper. Gambit documents loaded-file macros as file-local.

3. **Unqualified top-level procedures with quoted keys**  
   Works with plain `load`, but cannot support `(def (name args) body ...)` without macro/reader transformation and risks top-level name collisions.

4. **Keep current fully qualified procedures**  
   Already tested through FPO and remains the low-level escape/API, but fails the requested ergonomic target.

A higher-level surface should lower to the current typed registry operations rather than replace the stable-cell architecture.

## Risks and unresolved gaps

- **High — loader/FPO compatibility:** Rich config syntax requires a loader path not yet validated under normal, optimized, and full-program compilation.
- **High — sandboxing:** All options that evaluate arbitrary Scheme remain trusted-code configuration.
- **Medium — Lisp-2 scope:** Splitting registry domains does not itself make Gerbil library source Lisp-2.
- **Medium — public-name stability:** Automatically inferred module-derived keys make module moves user-visible; explicit names add author syntax.
- **Medium — transactions and concurrency:** Staging, multi-binding atomicity, and synchronization are absent.
- **Medium — arity validation:** Current code checks only `procedure?`; arbitrary procedure expressions lack an established public arity-introspection path.
- **Medium — advice ordering:** Stable IDs, ordering constraints, and behavior when advice evaluation fails remain unspecified.
- **Medium — stale research:** `research/emacsy-runtime-customization-design.md:423-429` no longer describes the current playground.
- **Low — overhead:** Stable forwarders add a box read and call to customizable functions.
- **Confidence:** High for current behavior, naming/Lisp-2 conclusions, and native `def` constraints; medium for richer loader feasibility until tested under FPO.

## Evidence-backed validation commands

These are established by `plans/emacsy-runtime-customization-mwe/spec.md:216-352`. They were not run during this read-only investigation.

### Focused current behavior

```sh
set -eu
cd /home/jay/Code/workbench-gerbil
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/expected" <<'EOF'
((default-site default Ada) default Ada default-site default Ada default-site)
((site-one one Ada) one Ada site-one one Ada default-site)
((site-two two Ada) two Ada site-two two Ada default-site)
EOF
/opt/gerbil/bin/gxi \
  -e '(begin (import "playground/main") (main))' \
  >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

### Full optimization matrix

Run the normal, `-O`, and FPO commands at:

- `plans/emacsy-runtime-customization-mwe/spec.md:235-258`
- `plans/emacsy-runtime-customization-mwe/spec.md:260-281`
- `plans/emacsy-runtime-customization-mwe/spec.md:283-301`

Then run registry diagnostics and config-boundary checks at:

- `plans/emacsy-runtime-customization-mwe/spec.md:303-337`
- `plans/emacsy-runtime-customization-mwe/spec.md:339-352`

Any new surface additionally needs the same matrix for:

- repeated loading of the same path;
- unknown and ambiguous names;
- same public function/value name;
- procedure-valued values;
- duplicate advice IDs;
- syntax/runtime errors before and after staged mutations;
- reset of one binding, one config layer, and all defaults.