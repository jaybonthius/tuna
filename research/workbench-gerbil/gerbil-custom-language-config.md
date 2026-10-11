# Gerbil custom languages for a runtime configuration DSL

## Conclusion

Yes. A runtime configuration file can ergonomically contain only:

```scheme
#lang :workbench/config-lang

(def (greeting who)
  (string-append "Hello, " who))

(def site-name "Workbench")
```

The strongest design is:

1. A custom language prelude re-exports the desired Gerbil expression language.
2. It overrides `%%begin-module`, not necessarily `def`, so only top-level `def` forms are treated as configuration entries while nested ordinary `def` retains normal semantics.
3. The body expander rewrites all entries into one transactional call to a pre-registered customization API.
4. The runtime executable imports `:gerbil/expander`, calls `gerbil-load-expander!`, then loads and evaluates the source module with:

   ```scheme
   (import-module config-path #t #t)
   ```

5. Unknown names and expected kinds are validated by the central runtime registry before any update is committed. Compile-time validation is possible only if the language and runtime share a generated/static schema.

This is feasible with supported Gerbil language facilities. The principal unresolved area is deployment under full-program optimization: the source strongly suggests it can load external language artifacts, but an end-to-end FPO executable test is still required, especially to ensure the central registry is not reinitialized by a dynamically loaded second copy of its module.

## 1. Language and expansion model

### Root, prelude, and module contexts

Gerbil separates:

- the **root context**, containing primitive core expanders;
- the **prelude context**, an ordinary module whose exports become a module’s initial bindings;
- the **module context**, where the source body is expanded.

This is documented at:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1334-1356`
- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:1-12`

When a prelude context is constructed, every export of the language module is converted into an import and bound **weakly**:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:51-66`
- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:535-563`

Consequences:

- Language bindings are implicit initial bindings, not textual imports added to the user file.
- User/module bindings can override them.
- A language may re-export `:gerbil/core` and add stronger replacements under names such as `def` or `%%begin-module`.
- Compiler dependency discovery traverses a module’s prelude and prelude imports, so runtime bindings re-exported by the language participate in normal dependency collection:  
  `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:491-580`.

The tutorial’s supported pattern is to import and re-export core, then export a replacement under the hook’s public name:

- `/home/jay/Code/gerbil/doc/tutorials/languages.md:97-108`
- `/home/jay/Code/gerbil/src/tutorial/lang/dot-app.ss:4-7`

### Expander hooks

The supported hook names are:

- `%%ref`: ordinary identifier references;
- `%%app`: ordinary applications;
- `%%begin-module`: complete or partial module-body expansion.

Documentation:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1351-1356`
- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:186-192`
- `/home/jay/Code/gerbil/doc/tutorials/languages.md:59-120`
- `/home/jay/Code/gerbil/doc/tutorials/languages.md:161-181`

The root bindings map these names to primitive expansion forms:

- `/home/jay/Code/gerbil/src/gerbil/expander/root.ss:145-160`

Ordinary applications and references are redirected through `%%app` and `%%ref` when they are not already core forms:

- `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:175-201`

A module body is initially wrapped in `%%begin-module`; a custom prelude can transform it and delegate to the root hook:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:627-680`
- `/home/jay/Code/gerbil/src/tutorial/lang/auto-export.ss:4-11`

### Why `%%begin-module` is preferable for this DSL

A replacement `def` macro is possible. Core `def` itself is just a macro over `define-values` and `lambda`:

- `/home/jay/Code/gerbil/src/gerbil/core/sugar.ss:449-459`

However, globally replacing `def` also changes nested `def` inside configured procedure bodies. A `%%begin-module` hook can instead:

1. inspect raw top-level forms;
2. accept only the two desired shapes;
3. rewrite them to updater calls;
4. delegate nested expressions and procedure bodies to ordinary Gerbil expansion.

This also enables duplicate checking and transactional aggregation across the whole file.

A plausible expansion is:

```scheme
(def (greeting who) body ...)
=>
(config-entry 'greeting 'procedure
              (lambda (who) body ...)
              source-metadata)

(def site-name expr)
=>
(config-entry 'site-name 'value expr source-metadata)
```

The body hook can finally produce one call such as:

```scheme
(apply-configuration-transaction!
  (list entry ...))
```

No exports or ordinary module definitions are required in the configuration module.

## 2. `#lang` and custom readers

### Exact `#lang` behavior

Supported syntax is:

```scheme
#lang prelude [package: pkg-id] [namespace: namespace-id]
```

Documentation:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1358-1372`

Implementation details:

- The regular s-expression reader is tried first; a datum parsing failure at file position zero triggers the `#lang` path:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:210-219`.
- The first line must begin with `#lang` and contain a space before its arguments:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:328-350`.
- The remaining first-line arguments are read as Scheme datums.
- The first datum is the prelude module; `package:` and `namespace:` are extracted from the rest:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:317-326`.
- The language prelude is imported before the body is read:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:277-306`.
- Reader parameters expose the source path and complete argument list while the reader runs:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:35-39,303-306`.

Practical constraint: `#lang` should be at the first byte of the file. Leading comments, a shebang, or other data will not follow the `#lang` fallback path.

### Reader phase

A custom reader must be a procedure exported at phase `+1` under `read-module-body`. The tutorial implementation uses:

```scheme
(export (phi: +1 read-module-body))
(begin-syntax
  (def (read-module-body port) ...))
```

Evidence:

- `/home/jay/Code/gerbil/doc/tutorials/languages.md:205-242`
- `/home/jay/Code/gerbil/src/tutorial/lang/sexp.ss:4-14`

The modern `for-syntax` spelling is equivalent to `phi: +1`:

- `/home/jay/Code/gerbil/src/gerbil/core/module-sugar.ss:47-56`
- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:1076-1087`
- `/home/jay/Code/gerbil/src/lang/gerbil/polydactyl.ss:6-31`

The reader receives the port positioned after the `#lang` line and must return a list of syntax objects. `read-syntax` preserves source locations; arbitrary readers should similarly return located syntax objects.

### A custom reader is not required for this DSL

The current expander implementation falls back to a built-in s-expression reader if the prelude has no phase-1 `read-module-body` export:

- default reader: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:269-275`
- phase-1 export lookup and fallback: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:282-298`

Therefore a current Gerbil 18.2 language can use:

```scheme
#lang :workbench/config-lang
```

without defining a reader at all. The tutorial’s statement that its identity reader is needed “in contrast to the gerbil core prelude” at `/home/jay/Code/gerbil/doc/tutorials/languages.md:225-227` appears stale relative to the current implementation. This should be verified against the exact production Gerbil release before relying on the fallback.

### `prelude:` and `gerbil.pkg`

For s-expression modules, alternatives are:

```scheme
prelude: :workbench/config-lang
```

or a nearest `gerbil.pkg` containing:

```scheme
(prelude: :workbench/config-lang)
```

Evidence:

- source directive processing: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:221-267`
- package inheritance: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:352-390`
- documentation: `/home/jay/Code/gerbil/doc/guide/intro.md:1378-1399`

For a user-owned runtime configuration file, explicit `#lang` is more predictable than depending on the nearest filesystem `gerbil.pkg`.

## 3. Automatically exposing the customization API

A language can automatically expose a central API by importing it and re-exporting its imports. Public import/export support includes:

- phase imports;
- runtime-only dependencies;
- renaming;
- re-exporting imported modules.

See:

- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:34-85`
- `/home/jay/Code/gerbil/doc/guide/intro.md:1098-1146`

For example:

```scheme
(import :gerbil/core
        :workbench/customization-api)

(export
  (except-out (import: :gerbil/core) def)
  (import: :workbench/customization-api)
  (rename: config-def def))
```

`except-out`, renaming, and phase shorthands are supported public macros:

- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:1076-1125`
- implementation: `/home/jay/Code/gerbil/src/gerbil/core/module-sugar.ss:194-230`

Materially different options are:

1. **Import and re-export the whole API**  
   Simplest, but unnecessarily enlarges the configuration language.

2. **Export a narrow dispatcher defined by the language module**  
   The configuration sees only one updater. This adds a runtime language-module dependency.

3. **Use an `extern` binding to the executable-owned dispatcher** — preferred for FPO  
   The language declares an external procedure in the central API’s namespace and generated code calls it directly. `extern` is public core syntax:  
   `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:140-147`.

4. **Have `%%begin-module` insert an explicit import**  
   Supported, but more expansion machinery than needed and may dynamically reload the central API under FPO.

For a singleton registry owned by an already compiled executable, option 3 best avoids loading or initializing a second API module during runtime expansion.

## 4. Validation of names and kinds

### Recommended split

The language should validate syntax and the runtime registry should validate live registration state.

At expansion time:

- require an identifier as the configuration name;
- distinguish function shape from value shape;
- reject malformed top-level forms;
- optionally reject duplicate names;
- optionally validate names/kinds against a generated static schema;
- raise `raise-syntax-error` against the offending syntax object for source-local errors.

At runtime, before committing:

- confirm the name is currently registered;
- confirm expected kind (`procedure` versus `value`);
- optionally validate formal shape or an application contract;
- validate every entry first, then commit all updates atomically.

This addresses the fact that “pre-registered runtime cells” may vary by executable startup state. A phase-1 macro runs in the expander environment, not automatically against the phase-0 live registry.

### Validation alternatives

1. **Runtime registry only**  
   No schema duplication; unknown names/kinds are detected while evaluating the configuration. Best fit for truly dynamic registration.

2. **Generated shared schema**  
   Generate both language phase-1 validators and runtime cell descriptors from one source. Gives early syntax errors without drift.

3. **Hard-coded macro table**  
   Easy but risks divergence from runtime registration.

4. **Specific generated setter per name**  
   Unknown names fail during expansion, but this is less extensible and produces more bindings.

### Atomicity

A one-form-at-a-time custom `def` macro can partially update state before a later error. A whole-body transaction avoids that failure mode. The transaction API should preserve old values until all names, kinds, and evaluated values pass validation.

## 5. Loading and evaluating a language file at runtime

### Supported executable setup

The documented compiled-executable pattern is:

```scheme
(import :gerbil/expander)

(gerbil-load-expander!)
```

Evidence:

- `/home/jay/Code/gerbil/doc/guide/eval.md:19-93`
- runtime configuration example: `/home/jay/Code/gerbil/doc/guide/eval.md:95-118`
- idempotent expander loader: `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:248-258`
- expander initialization: `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:14-33`

To honor `#lang`, load the file as a module:

```scheme
(gerbil-load-expander!)
(import-module config-path #t #t)
```

`import-module` has optional `reload?` and `eval?` arguments:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:93-100`

For configuration reloads, `#t #t` is important:

- `reload? = #t` bypasses the prior expander module-context cache;
- `eval? = #t` evaluates the newly expanded module immediately.

The module importer reads, expands, creates the module context, stores delayed evaluation code, and registers the context:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:139-178`
- cache/reload dispatch: `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:195-208`

`import-module` is exported in Gerbil’s expander “user api” surface:

- `/home/jay/Code/gerbil/src/gerbil/core/expander.ss:36-58`

Its optional runtime behavior is source-supported but sparsely documented in the reference, so it should receive an integration test.

### Why `eval '(include ...)` is insufficient for `#lang`

The Eval guide documents:

```scheme
(eval '(include "/path/config.scm"))
```

But `include` directly uses `read-syntax-from-file` and splices the resulting forms into the current expansion context:

- `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:250-274`
- `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:367-382`

It does not invoke module `#lang` processing. Use `import-module` for the custom-language file.

### `load-module` is not the source loader

Runtime `load-module` searches for generated `.oN` or `.scm` module artifacts:

- `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:32-73`
- artifact lookup: `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:107-128`

It does not read a `.ss` custom-language configuration file. Runtime source loading requires the expander-level `import-module`.

## 6. Required artifacts by execution mode

| Mode | Expander | Required language/config artifacts | Notes |
|---|---|---|---|
| `gxi` | Already loaded by the universal interpreter, but the calling context still must import `:gerbil/expander` to bind `import-module` | Configuration `.ss`; language source `.ss`, or compiled `.ssi` plus phase/runtime module artifacts | `gxi --lang` only changes initial REPL bindings; it is not the configuration file loader. |
| Normal `gxc -exe` | Main imports `:gerbil/expander`; call `gerbil-load-expander!` | Configuration `.ss`; language `.ssi`; language `~1.o1` for macros/reader; language loader/runtime objects as generated; central API compiled into executable or available dynamically | Normal executable links against `libgerbil`: `/home/jay/Code/gerbil/doc/guide/intro.md:1290-1299`. |
| `gxc -O -exe` | Same as normal | Same runtime artifacts | `-O` optimizes Gerbil source; it does not change the runtime expansion architecture. `.ssxi.ss` is optimizer metadata, not the runtime language interface. |
| FPO | Must be explicitly retained through imports/direct calls | Same external `.ssi` and dynamic phase artifacts unless language source is shipped; central dispatcher should preferably be an executable-owned `extern` | FPO initializes runtime with an empty builtin-module list because tree shaking means compiled modules may be incomplete: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:366-390`. End-to-end testing is mandatory. |

### What `gxc` generates

Compilation generates:

- a runtime loader/module;
- optional runtime section;
- `.ssi` expander/module metadata;
- phase modules such as `~1`;
- optional `.ssxi.ss` optimization metadata under `-O`.

Evidence:

- runtime generation: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:645-704`
- `.ssi` and phase generation: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:706-746`
- `.ssxi.ss`: `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:748-755`

Installed Polydactyl artifacts observed on this machine were:

```text
polydactyl.o1
polydactyl.scm
polydactyl.ssi
polydactyl.ssxi.ss
polydactyl~1.o1
polydactyl~1.scm
polydactyl~_extern_.o1
polydactyl~_extern_.scm
```

The `.ssi` records the phase-1 `read-module-body` export and loads the `~1` module. This directly confirms that phase code must be deployable when a runtime expander imports a compiled language.

Library resolution prefers `.ssi`, then source `.ss`, `.sld`, or `.scm`:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:406-446`

### FPO-specific singleton risk

FPO’s generated startup calls:

```scheme
(gerbil-runtime-init! '())
```

because tree shaking prevents treating included modules as complete builtins:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:382-388`

Therefore a runtime-imported `.ssi` may cause `load-module` to load external objects even when similarly named code was included in the executable. A dynamically reloaded customization API could overwrite or reinitialize registry globals.

Mitigations:

- keep the registry and dispatcher statically referenced by the executable;
- have the language use an `extern` dispatcher rather than dynamically import the registry module;
- load/initialize the expander and language before registering cells, if dynamic module initialization cannot be avoided;
- test identity and state visibility in the FPO executable.

## 7. `gxi --lang`

The tutorial documents `gxi --lang` for s-expression custom languages:

- `/home/jay/Code/gerbil/doc/tutorials/languages.md:16-29`

It imports the language prelude as the REPL’s initial bindings. The universal binary’s implementation imports the selected language and installs its prelude context:

- `/home/jay/Code/gerbil/src/gerbil/main.ss:131-170`

It does not generally install a user language’s custom reader/readtable; the implementation explicitly has a TODO for user-language readtables. Thus `--lang` is useful for interactive macro testing, but `import-module` of a `#lang` source file is the authoritative runtime configuration path.

## 8. Public APIs versus internals

### Public/documented or intentionally exported

- Custom prelude modules and hook names.
- `#lang`, `read-module-body`, phase exports.
- `begin-syntax`, `defsyntax`, `defrules`.
- Import/export/re-export and `extern`.
- `gerbil-load-expander!`.
- `import-module` is exported in the expander’s marked user API, though its reference documentation is incomplete.

### Internal implementation evidence

- `core-read-module/lang`.
- Expander module/prelude context structures and caches.
- Compiler `.ssi`/phase generation details.
- FPO builtin-list behavior.
- Loader artifact search order.

These internals are useful evidence but should not be called directly from application code.

## 9. Validation commands

### Focused language/runtime test

Given a temporary fixture containing `config-lang.ss`, `customization-api.ss`, `main.ss`, and `site.ss`:

```bash
gxc -O -d /tmp/wb-config/lib \
  /tmp/wb-config/customization-api.ss \
  /tmp/wb-config/config-lang.ss

GERBIL_PATH=/tmp/wb-config \
gxi -e '(begin
          (import :gerbil/expander :workbench/customization-api)
          (import-module "/tmp/wb-config/site.ss" #t #t)
          (assert (equal? (site-name) "Workbench"))
          (assert (equal? (greeting "Gerbil") "Hello, Gerbil")))'
```

Also test malformed, unknown, wrong-kind, duplicate, and rollback cases and assert source paths/lines occur in exceptions.

### Full executable matrix

```bash
gxc -exe -o /tmp/wb-config/main-normal /tmp/wb-config/main.ss
/tmp/wb-config/main-normal /tmp/wb-config/site.ss

gxc -O -exe -o /tmp/wb-config/main-O /tmp/wb-config/main.ss
/tmp/wb-config/main-O /tmp/wb-config/site.ss

gxc -O -full-program-optimization -exe \
  -o /tmp/wb-config/main-fpo /tmp/wb-config/main.ss
/tmp/wb-config/main-fpo /tmp/wb-config/site.ss
```

For FPO, additionally assert that:

- the registry object before and after language loading is the same;
- pre-registered cells remain present;
- updates are visible through statically compiled application accessors;
- removing the external language `~1.o1` produces the expected controlled deployment failure;
- removing a dynamically loaded API object does not matter when the dispatcher is `extern`-bound.

## 10. Review findings and residual risks

- **high — FPO deployment:** dynamic source expansion and the executable-owned registry have not been tested together in an FPO binary. Empty builtin registration can trigger external module loading and state reinitialization.
- **high — security:** re-exporting full `:gerbil/core` makes configuration trusted code, not a sandbox. A top-level whitelist does not prevent dangerous operations inside configured procedure bodies.
- **medium — atomicity:** direct per-form updater calls can leave partial configuration after a later failure. Use whole-body validation and commit.
- **medium — schema drift:** compile-time hard-coded name/kind validation can diverge from runtime registration. Generate both from one schema or validate dynamically.
- **medium — version compatibility:** the current implementation provides a default reader for `#lang` preludes without `read-module-body`, while the tutorial implies otherwise. Verify the exact deployed Gerbil release.
- **low — module naming:** arbitrary configuration paths derive module identity from basename plus package/namespace information. Always use normalized paths and reload explicitly.

Confidence: **high** for language/prelude/reader mechanics and runtime loading under `gxi` and normal executables; **medium** for FPO until the executable matrix is run.