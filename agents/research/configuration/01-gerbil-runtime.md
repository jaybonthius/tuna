# Gerbil runtime constraints for user configuration (lane 1)

Toolchain: Gerbil v0.19-dev-63-g1cfb032c on Gambit v4.9.8-19 (`/opt/gerbil`). Source checkout: `/home/jay/Code/workbench-gerbil/gerbil/src/gerbil` (cited below as `gerbil/…`). Experiments live in `/tmp/exp1` (exe), `/tmp/exp2`–`/tmp/exp4` (gxi scripts). Labels: **Fact** = I ran it or read the cited source; **Inference** = my reasoning; **Unverified** = not tested.

## Answer

A built Tuna executable can evaluate user Gerbil source at runtime, but only if the Gerbil expander is linked in. Today's `.gerbil/bin/tuna` does not contain it, so `eval` is only Gambit's bare interpreter and cannot handle `def`, `import` or `defstruct`. Adding `(import :gerbil/expander)` and calling `(gerbil-load-expander!)` costs +1.7 MB and about 80 ms at first use. After that, `(import "/abs/path/init")` of a user source module works. It can import Tuna's own modules and shares their live state with the running exe, provided Tuna's `.ssi` files are on the load path.

Recommended approach: treat `init.ss` as a source module, not as a script.
- Load it with `import-module path #t #t` (reload, then evaluate) inside a worker thread with a timeout, under a `parameterize`d plugin context.
- Every failure is an ordinary catchable exception, except a killed load, which leaves the module stuck (finding 7).
- Reloading **source** modules works (finding 3). Reloading **compiled** `.o` modules in-process does not (finding 4).
- Same-named modules at different paths collide, so a "last known good" copy needs a distinct `namespace:` (finding 8).
- User-installed packages are found without rebuilding Tuna, if they are compiled into `$GERBIL_PATH/lib` (finding 9).

## Findings

1. **Today's exe has no expander (Fact).**
   - `tuna__exe.scm` lists no `gerbil/expander*` builtin modules; the exe is 32.4 MB and `tuna --bogus` starts in 16 ms.
   - In the `/tmp/exp1` test exe, `(eval '(+ 1 2))` gave 3, but `gerbil-load-expander!` failed with `Operator is not a PROCEDURE (#!unbound ':gerbil/core)`. The source is `gerbil/runtime/init.ss:15-27` (`__load-gxi`), called from `init.ss:252`. It needs the `gx#` expander symbols linked in.
   - Gambit's plain `load` on a file starting with `(import …)` fails (it takes the file for an R7RS library).

2. **Minimal working setup (Fact).** `/tmp/exp1/ex/main.ss`:
   ```scheme
   (import :ex/lib :gerbil/expander)      ; static link of the expander
   (def (main . args)
     (gerbil-load-expander!)              ; 77-80 ms, once
     (for-each (lambda (f) (for-each eval (call-with-input-file f read-all))) args))
   ```
   Package module `ex/lib` defines `greet`, `counter-inc!` and a `defstruct`. User file:
   ```scheme
   (import :ex/lib "/tmp/exp1/cfg/mymod")  ; package module + source module by absolute path
   (displayln (greet "user") (counter-inc!)) (def (user-fn x) ...)
   ```
   - Run with `GERBIL_LOADPATH=/tmp/exp1/.gerbil/lib`. Output: `hello user counter=2 pt=#<pt #12 x: 1 y: 2>`.
   - `counter=2` shows user code shares the statically linked module's state, because `gerbil-runtime-init!` registers the exe's modules as `builtin`.
   - Without the load path the import fails with `cannot find library module`, because the `.ssi` metadata is not found.
   - A relative path (`"mymod"`) resolves against the current directory, not the file, when forms are `eval`ed one by one. Use absolute paths or `parameterize` `current-directory`.
   - Cost, measured on the exe1 build: 12.5 MB → 14.2 MB (+1.7 MB); 5 ms → about 90 ms start when the expander loads eagerly. Lazy loading in a background thread hides this (Inference).
   - Not tested: `--optimized` full-program optimization. ADR 1 records an earlier failure (`Unbound variable: __eval-import`), and `build.ss` uses plain `gerbil build`.

3. **Source modules are interpreted; compiled ones are about 100× faster (Fact).**
   - A 3M-iteration loop took 223 ms when `import`ed from source, and 2 ms from the same module compiled with `gxc -O -d` and loaded via the load path.
   - Compiling at runtime means running `gxc` as a subprocess; `/opt/gerbil/bin/gxc` took 1.2 s for a tiny module.
   - A compiled user module that imports `:ex/lib` loaded fine in the exe. I did not check state sharing for compiled user modules (Inference: same as for package modules).
   - In-process compilation would need `:gerbil/compiler` linked in, which I did not try (Unverified).

4. **Source-module reload works; compiled-module reload does not re-run (Fact).** Experiments in `/tmp/exp2` and `/tmp/exp3`; reload is `(gx#import-module path #t #t)` (`gerbil/expander/module.ss:93-97`, registry at 197-210).
   - **Source reload** re-evaluates every definition. State is reset: a counter returned to 0, and a hook the user had `set!` reverted to the original.
   - Other modules' calls through an imported name see the new definition (`g` → `(f-v2 1)`). Values captured before reload keep the old closure (`(def h f)` → still `f-v1`).
   - **Compiled reload** (`reload-module! "m/x"` after `gerbil build` produced `x.o4`): the loader's registry points at `x.o4`, but the module body does not re-run. `f` stayed `f-v1` and the counter continued. The cause is probably that Gambit does not re-initialize an already-linked module name (Inference). `loader.ss:75-105` (`reload-module!`) and `107-128` (it picks the highest `.oN`) explain the versioned files, not the missing effect.
   - Consequence: reload user code from source, or compile it under a fresh module name.
   - **Dependents** (Fact): `b` expanded `(pt 1 2)` against the old struct shape. After `a`'s `defstruct` gained a slot and `a` was reloaded, `b`'s `(mk)` raised `arguments don't match object size`. Reload dependents in dependency order.
   - **Class redefinition, hazard** (Fact): old instances still satisfy `pt?` (identity is by type-id symbol `a#pt::t`, not by type object). After redefinition with an extra slot, `(pt-z old)` returned garbage (`1024`) with no error. The same slot layout is safe in practice. A changed layout needs a migration step, or the old instances must be dropped.
   - **`separate` vs `block`:** `##global-var-set!` on `m/x#f` (block) and `m/xs#f` (separate) both changed internal and external callers in my default `gerbil build`. I did not reproduce ADR 1's `-O` finding that block-module internal calls ignore `set!` (Unverified, different flags).

5. **Failures are caught; side effects of a failed load persist (Fact, `/tmp/exp4/run.ss`).**
   - Caught as ordinary exceptions: unbalanced paren (`Incomplete form, EOF reached`), unbound identifier, bad syntax (`invalid match target`, with file and position), a runtime `error`, a missing package (`:no/such/pkg`), and a runtime error in a dependency.
   - A top-level `load` that fails partway keeps earlier forms: `def side 42` before the `error` stayed defined, and forms after it did not run. That is why a staged or transactional load matters.
   - Interpreted `(load f)` only works after the expander is hooked. In the exe, after `gerbil-load-expander!`, `eval` of read forms worked.

6. **Module registry after failures (Fact).**
   - A module that fails at *expansion* leaves no state: after fixing the file, a plain re-import works.
   - A module whose *evaluation* fails caches the error: re-import without reload re-raises (`init.ss:127-176`, the `'error` state). The fix is `import-module path #t #t` on the failed module and its dependent.
   - A dependency that failed at runtime blocks every dependent until it is reloaded the same way.

7. **Infinite loop at load: killable, but the module stays stuck (Fact).**
   - Running `(eval '(import "/tmp/exp4/f/loop"))` in `make-thread` and `thread-join!` with a 1 s timeout returned the timeout. `thread-terminate!` ended it (`abnormally-terminated`), and the main thread kept working.
   - The killed module's state is left as `'forcing` (`init.ss:156-169`). Re-importing the fixed file without reload hung (join timed out again).
   - `import-module path #t #t` (reload) recovered it (returned 5).
   - So: always load with reload, in a worker thread, and the C-g or timeout path must `thread-terminate!` the worker. Loops during macro expansion should be killable the same way (Inference; I tested a runtime loop only).

8. **Coexisting versions (Fact, `/tmp/exp4/run2.ss`).**
   - A source module's global namespace is its **file name** by default. `v1/mod.ss` and `v2/mod.ss` collide: after both were imported, `(a.ver)` returned `v2`, and the type ids were both `mod#pt::t` and `eq?`.
   - With a `namespace: gen1` / `namespace: gen2` first line (`expander/module.ss` `core-read-module/sexp`), both versions coexist with separate state and separate struct types (`a.pt?` of a `b.pt` → `#f`).
   - Swapping back to an older generation is `import` of its path; its state is still there, or reload it for a fresh state.
   - Plan for the loader (Inference): keep `init.ss` snapshots as `generations/N/init.ss` with a generated unique `namespace:`, or load by temporary copy. Compiled modules of two versions can coexist only under different module names.

9. **Staging and abandoning a load (Fact + Inference).**
   - A fresh expander `top-context` is not usable for this (`Unbound variable: def`, no prelude). Evaluating the config as a **module** gives namespace isolation without that.
   - Fact: a module body runs in the loading thread, so `parameterize` of a context parameter around `import-module path #t #t` gives it a *staging* context. Importing under `(parameterize ((current-ctx staging)) …)` put `init-ran` in `staging` only.
   - Re-importing with reload under the real context re-ran the body (the commit step). Without reload the body does not run again.
   - This supports two designs: (a) staging kernel instance: load into a throwaway kernel, discard on failure, then reload into the real one; or (b) load directly under a transaction (Inference).
   - Module-level global variables of a failed load stay in Gambit's global table, namespaced and unreachable. They are garbage in effect, but not reclaimed.

10. **Where packages are found (Fact).**
    - Load path = `[$GERBIL_PATH/lib, $GERBIL_HOME/lib]` plus `GERBIL_LOADPATH` entries (`init.ss:206-228`, `runtime/system.ss:53-58`). Default `GERBIL_PATH` is `~/.gerbil`. `gerbil pkg install` builds into the same root (`tools/gxpkg.ss:343-345`: `pkg` and `lib` under the root; `gerbil build` lib dir at `std/make.ss:91`).
    - This machine's `~/.gerbil/lib` and `pkg/` already hold installed packages.
    - Therefore a running Tuna with the expander linked can `(import :some/pkg)` after `gerbil pkg install`, without a rebuild. `add-load-path!` (`loader.ss:21`) can add more directories at runtime.
    - Tuna's own `.ssi` files live in `tuna/.gerbil/lib` (from `gerbil build`; `make run` uses `gerbil env`). A user config importing `:tuna/...` needs that directory on the load path.
    - A `.ssi` from a different build than the running exe is a hazard: macro-expanded shapes can mismatch the linked code, as in the struct example above (Inference).
    - `gerbil pkg install` needs network and was not run.

11. **What ADR 1 already relies on (Fact where tested).**
    - `import-module path #t #t` re-evaluates a **source** module (confirmed, finding 4).
    - `##global-var-set!` / external `set!` is visible to callers in both modules (confirmed in the default build; the `-O` block-vs-separate distinction is Unverified here).
    - Compiled `.oN` reload does not re-run (contradicts any plan to reload built plugin modules in-process).
    - ADR 2's "reload modules, activate again" therefore needs source-loaded or freshly named modules.
    - Package modules statically linked into the exe cannot be replaced at all except via `set!` on globals or by loading a different source/compiled module under another name (Inference).

## Implications for the configuration design

- **Link the expander** (`:gerbil/expander`, +1.7 MB) and call `gerbil-load-expander!` at startup in a thread, or on first config load.
- **`init.ss` is a source module**, loaded with `import-module path #t #t`, absolute path, from a worker thread with a timeout.
  - On failure: report the exception and fall back, never rely on partial state.
  - On timeout: `thread-terminate!`, then reload the module on next attempt.
- **Failure policy** (owner correction: no standard plugin set to fall back to):
  - (a) Load the new config into a staging context or kernel via a `parameterize`d plugin context; commit only on success by reloading under the real context.
  - (b) Keep numbered snapshots `generations/N/` of the config with distinct `namespace:` lines. On failure, re-import the last known-good generation. Skip-only-what-fails works per plugin entry.
  - Namespaces must be unique per generation and per user module (files with the same basename otherwise collide).
- **User-installed modules:** keep them as source (interpreted) or compile with `gxc` into a versioned lib dir whose module names embed the generation; do not expect `.o` reload to pick up changes.
- **Load path:** add Tuna's installed lib directory, plus the user's, with `add-load-path!`. Record the Tuna build id so a stale `.ssi` can be detected.
- **Dependents must be reloaded in dependency order** after changing a module that exports macros, structs or classes. A class reload with changed slots needs old-instance migration or must be rejected.
- **Avoid:**
  - evaluating config as top-level `eval` forms (partial effects persist);
  - assuming `reload-module!` works for `.o` modules;
  - loading on the editor thread without a kill path;
  - FPO builds (ADR 1);
  - relative paths in `import`.

## Shallow areas

- I did not test: in-process `gxc`/`:gerbil/compiler` linking; `--optimized`; a macro-expansion infinite loop; user modules calling back into Tuna's kernel while the editor thread runs concurrently (the baton, ADR 3); memory growth from abandoned generations; Gambit's `interrupt`/C-g path versus `thread-terminate!` on the editor thread.
- The compiled-reload non-effect is observed, not source-explained in Gambit.
- The `.ssi` and `.ssxi.ss` staleness hazard is inferred from the struct example, not reproduced on a version-mismatched `.ssi`.
- Whether `gerbil env tuna` or a release install changes `GERBIL_PATH` in the final distribution layout was not examined.
