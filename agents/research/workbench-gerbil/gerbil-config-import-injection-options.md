# Gerbil runtime config import-injection options

## Answer

Yes. A Gerbil application can evaluate a config **as though a central import were prepended**:

```scheme
(gerbil-load-expander!)
(eval `(begin
         (import :app/customize)
         (include ,config-path)))
```

This is a custom loader composition built from public Gerbil facilities, not a dedicated loader option. A `/tmp` prototype confirmed zero-import user configs with:

```scheme
(redefine (greeting who) ...)
(set! site-name ...)
```

under `gxi`, normal `gxc`, and separate-module `gxc -O`, including two successive reloads. It fails under FPO on this toolchain with `Unbound variable: __eval-import`.

There is no public `load(path, environment)` facility. Gambit `load` accepts only a path, and Gambit `eval` ignores its optional environment. Therefore removing both qualified globals and user imports requires one of:

1. Gerbil runtime-expander import/alias injection;
2. a custom Gerbil prelude or module reader;
3. a source wrapper/rewriter using Gambit `##namespace`;
4. an ahead-of-time compiled config plugin.

The existing repository’s plain Gambit `load` plus qualified central runtime globals remains the smallest tested option supporting FPO.

## Baseline

Research used:

- Gerbil `v18.2-20260722T1909420700`
- Gambit `v4.9.7-6-g64f4d369`
- authoritative Gerbil source snapshot `/home/jay/Code/gerbil`, commit `0618730d4e30bf3f48538d6b09722ad3b6056414`
- disposable fixtures only under `/tmp`

No checkout application file was modified.

## Current repository behavior

The current implementation uses custom cells and one registry:

- `playground/runtime.ss:3-11` retains dynamically named entry points and creates the registry.
- `playground/runtime.ss:17-48` registers typed cells and performs redefinition.
- `playground/runtime.ss:50-51` reloads plain source using Gambit `load`.
- `playground/runtime.ss:53-77` defines stable function wrappers and value identifier macros.
- `playground/lib.ss:7-14` declares `greeting`, `site-name`, and ordinary internal reads/calls.
- `playground/main.ss:8-30` loads two configs and proves repeated changes and capture behavior.
- `playground/config.scm:1-8` and `playground/config-v2.scm:1-8` use qualified globals only in `playground/runtime`, not target-library globals.

Current behavior passed `gxi`, normal `gxc`, `gxc -O`, and FPO. Its limitation is config spelling:

```scheme
(playground/runtime#redefine-function! ...)
(playground/runtime#redefine-value! ...)
```

## Authoritative findings

### 1. Gerbil imports can be synthetically prepended

Gerbil imports bind identifiers in the current top or module syntactic context:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1098-1115`
- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:19-48`

`include` splices the included forms into the surrounding block. Expansion proceeds in order, so an earlier import affects later included forms:

- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:94-99`
- `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:250-304`

Runtime imports compile to `__eval-import`:

- `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:75-88`
- `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:485-510`

Thus this works:

```scheme
(def (load-config path)
  (gerbil-load-expander!)
  (eval `(begin
           (import :app/customize)
           (include ,path))))
```

The application can instead inject only central runtime aliases, avoiding target-module imports:

```scheme
(eval `(begin
         (extern
           (redefine-function! app/runtime#redefine-function!)
           (redefine-value! app/runtime#redefine-value!))
         (include ,path)))
```

`extern` publicly maps local identifiers to runtime binding IDs:

- `/home/jay/Code/gerbil/doc/guide/eval.md:19-93`
- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:445-472`
- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:687-693`

The `extern` variant avoids evaluating a customization façade, but it can inject runtime procedures only—not imported syntax such as a `redefine` macro.

### 2. Runtime Gerbil expansion has a hard FPO problem

Compiled applications must call `gerbil-load-expander!` before evaluating imports, macros, `extern`, or `include`:

- `/home/jay/Code/gerbil/doc/guide/eval.md:38-93`
- `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:14-34`
- `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:248-258`

On this toolchain, all Gerbil runtime-expander fixtures failed under FPO before loading the config:

```text
Unbound variable: __eval-import
```

FPO enables dead-definition elimination, and Gerbil’s driver explicitly warns that complete compiled modules cannot be assumed present:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:343-388`

The compiler’s `-prelude` flag is a Gambit compiler-declaration prelude, not a Gerbil config-language prelude:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1300-1312`
- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:392-410`

### 3. Runtime imports may execute module initialization again

Gerbil reconstructs source module contexts and delays their evaluation:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:140-178`

Runtime import then evaluates dependency contexts and caches them by reconstructed context:

- `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:123-188`

This cache is separate from the compiled executable’s already-run module initialization.

A compiled custom-prelude fixture initially imported the registry module normally. Runtime evaluation recreated its registry hash table without re-running the provider registration, causing:

```text
(cdr #f)
```

Using hygienically captured `extern` declarations in the prelude instead of importing the runtime module avoided this reset and passed `gxi`, normal `gxc`, and `gxc -O`.

Therefore a runtime-imported façade must not casually re-evaluate stateful application modules. Suitable mitigations include:

- a façade containing syntax only and using `extern` for runtime entry points;
- explicitly idempotent initialization;
- importing only modules proven safe to evaluate again.

### 4. Imports, re-exports, aliases, and namespaces are expansion-time mappings

Gerbil imports retain the source binding ID:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:535-563`

Re-exporting imported identifiers builds exports from those imported bindings rather than creating façade-owned globals:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:945-1001`

Consequences:

- a re-export façade can expose `greeting` and `site-name`;
- `(set! greeting ...)` can target the original provider global;
- no new `app/customize#greeting` global is created;
- `extern namespace: app/customize greeting` does not resolve a re-export originally owned by `app/lib`.

`defalias` similarly creates an expander alias, not a mutable runtime alias cell:

- `/home/jay/Code/gerbil/doc/reference/gerbil/prelude/macros.md:82-86`
- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:253-264`
- `/home/jay/Code/gerbil/src/gerbil/expander/top.ss:709-717`

### 5. Ordinary `def` does not mean redefine

A fixture evaluated:

```scheme
(begin
  (import "/tmp/.../customize")
  (include "config-def.scm"))
```

where `config-def.scm` contained:

```scheme
(def (greeting who) ...)
(def site-name ...)
```

Both `gxi` and compiled execution left the provider values unchanged.

Top contexts permit expander rebinding while module/prelude contexts do not:

- `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:670-674`

Thus ordinary `def` can create/rebind config-top syntax without mutating the imported provider binding. Same-form `def` requires a custom macro or source transformation.

### 6. Direct `set!` is possible but changes the optimization contract

A static façade can re-export ordinary globals:

```scheme
(import :app/a :app/b)
(export (import: :app/a)
        (import: :app/b))
```

Then an injected import permits:

```scheme
(set! greeting (lambda (who) ...))
(set! site-name "configured")
```

However Gerbil emits Gambit `(block)` by default:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:787-797`

Gambit documents that `block` permits globals defined and apparently unmutated in a file to be treated as permanent; `separate` withholds that assumption:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4886-4910`
- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4921-4939`

Every provider containing calls or reads that must observe external `set!` therefore needs `(declare (separate))`. The current cell-backed value is an identifier macro, so direct `(set! site-name ...)` is not naturally compatible with the current architecture.

### 7. `##namespace` is documented, but lexical

Gambit publicly documents `##namespace` as a lexical identifier mapping:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6290-6314`

For example:

```scheme
(##namespace ("app/runtime#" redefine-function! redefine-value!))
```

maps subsequent unqualified identifiers in the same file/body. It is not a runtime namespace object.

Gambit `load` has only a path argument:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6063-6083`

Gambit `eval` evaluates in the global interaction environment and ignores its optional environment:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4626-4643`

Macros loaded from another file remain local to that file:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6132-6135`

Therefore an application cannot call `load` with a namespace mapping. It must:

- put the mapping in the user file;
- load an application-owned wrapper that `include`s the user file;
- read and rewrite/wrap the forms before evaluation.

A raw Gambit wrapper prototype mapped central registry calls, defined a `def` macro, and included user files containing:

```scheme
(def (greeting who) ...)
(def site-name ...)
```

It passed normal compiled, `-O`, FPO, and repeated `v1 → v2 → v1`. It failed under `gxi` because the active Gerbil expander interpreted the raw Gambit macro forms differently. This is viable only as a deliberately Gambit-specific config language.

### 8. Custom preludes support same-form `def`

Gerbil officially supports alternate prelude modules:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1334-1356`

A prelude can be selected by:

- a `prelude:` directive;
- an implicit `prelude:` property in `gerbil.pkg`;
- `#lang` for a custom reader.

Evidence:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1358-1372`
- `/home/jay/Code/gerbil/doc/guide/intro.md:1378-1399`
- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:221-267`
- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:352-382`

A tested prelude re-exported core except `def`, then exported a custom macro as `def`. User modules contained:

```scheme
(def (greeting who)
  (string-append "one " who))

(def site-name "site-one")
```

The macro expanded these to central registry calls. With runtime APIs captured through `extern`, repeated `v1 → v2 → v1` passed `gxi`, normal `gxc`, and `gxc -O`.

Constraints:

- the config must be treated as a Gerbil module, not ordinary `load` source;
- the prelude or its compile-time metadata must centrally map each unqualified name to a qualified registry key;
- duplicate names across libraries need an explicit policy;
- runtime source-module evaluation still requires the Gerbil expander and fails under FPO here.

An implicit `gerbil.pkg` can remove the visible `prelude:` line if the application controls the config directory.

### 9. Reader hooks do not provide an ambient load environment

Custom readers are official module-language facilities. A prelude may export `read-module-body` at syntax phase, and `#lang` selects it:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1358-1372`
- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:269-350`
- `/home/jay/Code/gerbil/src/lang/gerbil/polydactyl.ss:19-31`

A reader can inject imports or rewrite `def`, but this is a custom language frontend. It is invoked when sourcing a module, not as a parameter to Gambit `load`.

Gambit readtables control lexical parsing such as case, keyword recognition, sharing, and prefix/infix syntax:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:17220-17340`
- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:17711-17738`

They do not supply module imports or runtime binding environments.

### 10. Compiled config modules/plugins avoid runtime Gerbil expansion

Gambit `load` supports compiled objects:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6063-6097`

Gerbil `load-module` locates and caches dynamic objects, while `reload-module!` reloads source modules or a newly discovered object version:

- `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:32-73`
- `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:75-118`

A compiled plugin prototype used the same custom-prelude `def` syntax:

- normal compiled host loaded config modules v1 and v2 successfully;
- loading the same module ID again was cached and did not rerun it;
- recompilation generated `.o2`, matching Gambit’s documented versioned-object reload model;
- default FPO failed because plugin-generated code referenced dynamically stripped loader globals;
- FPO passed when the host was built with:

```sh
-prelude '(declare (not optimize-dead-definitions))'
```

This broad retention disables FPO tree shaking for top-level definitions and is materially heavier than the current small-module retention declaration.

Gambit also explicitly forbids loading the same `.oN` twice; a newer `.oM` is required:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6093-6097`

## Syntax prototype matrix

| User syntax | Mechanism | Result |
|---|---|---|
| `(redefine (greeting who) ...)` | Injected import of façade-specific macro | Passed `gxi`, normal, `-O`; FPO expander failure |
| `(set! site-name ...)` | Injected re-export façade over ordinary globals | Passed `gxi`, normal, `-O`; requires provider `separate` |
| `(def (greeting who) ...)` | Ordinary `def` after import | Did **not** redefine provider |
| Same-form `(def ...)` | Custom Gerbil prelude mapping names to registry keys | Passed `gxi`, normal, `-O`; FPO expander failure |
| Same-form `(def ...)` | Raw Gambit wrapper with `##namespace` and `define-macro` | Passed compiled normal, `-O`, FPO; failed in `gxi` |
| Same-form `(def ...)` | Ahead-of-time compiled plugin using custom prelude | Passed normal; FPO required broad retention |
| Unqualified central procedures | Synthetic `extern` aliases | Public and avoids module import evaluation; still needs runtime expander |

## Materially different options

### A. Keep plain `load`, add no language layer

```scheme
(load path)
```

Config uses qualified central runtime entry points, as today.

- **Classification:** public Gambit loader; current registry is custom.
- **Strengths:** smallest, repeated source reload, current FPO passes, no target imports.
- **Cost:** qualified central globals remain visible.

### B. One central import written in the config

```scheme
(import :app/customize)
(redefine ...)
```

- **Classification:** public Gerbil import; custom façade.
- **Strengths:** simple and explicit; façade can export macros and runtime bindings.
- **Cost:** user writes one import; runtime expander required; module re-evaluation risks; FPO fails.

### C. Loader-injected central import

```scheme
(eval `(begin
         (import :app/customize)
         (include ,path)))
```

- **Classification:** custom loader built from public Gerbil forms.
- **Strengths:** zero user imports; supports custom macros such as `redefine`.
- **Cost:** same runtime-expander, module-initialization, and FPO constraints as option B.

### D. Loader-injected `extern` aliases

```scheme
(eval `(begin
         (extern
           (redefine-function! app/runtime#redefine-function!)
           (redefine-value! app/runtime#redefine-value!))
         (include ,path)))
```

- **Classification:** custom loader built from documented `extern`.
- **Strengths:** zero imports and no façade evaluation.
- **Cost:** only runtime procedures are injected; config still needs symbolic keys; FPO fails when loading the expander.

### E. Custom Gerbil prelude/module reader

- **Classification:** officially supported extension point; resulting config language is custom.
- **Strengths:** can provide same-form `def`, `redefine`, validation, and name metadata.
- **Cost:** requires module sourcing, a directive/controlled `gerbil.pkg`, or `#lang`; central name map; runtime expander; FPO failure.

### F. Raw Gambit namespace wrapper

- **Classification:** public Gambit `##namespace`/`include`; custom wrapper language.
- **Strengths:** can avoid Gerbil expander and pass FPO.
- **Cost:** lexical wrapper required; mode divergence with `gxi`; poor fit for Gerbil macros/modules.

### G. Compiled config plugin

- **Classification:** public compiler/dynamic loader; custom plugin protocol.
- **Strengths:** full Gerbil syntax resolved ahead of time; no runtime compiler.
- **Cost:** compiler deployment/build step, object-version reload policy, ABI compatibility, loader caching, and broad FPO retention.

## Review findings

- **High:** `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:343-388` — FPO tree shaking breaks `gerbil-load-expander!`; injected imports, `extern`, custom-prelude source loading, and readers are not FPO-compatible on this snapshot.
- **High:** `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:123-188` — runtime imports evaluate reconstructed module contexts; a stateful registry module was reset in a compiled prototype.
- **High:** `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4886-4939` — direct imported-global `set!` requires a provider `separate` contract for same-module optimized references.
- **Medium:** `/home/jay/Code/gerbil/src/gerbil/expander/core.ss:670-674` — ordinary config-side `def` does not reliably redefine imported providers.
- **Medium:** `/home/jay/Code/gerbil/src/gerbil/runtime/loader.ss:32-118` — compiled plugins are cached; same-object reload does not rerun configuration.
- **Medium:** `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:6063-6097` — compiled plugin reload requires a newly versioned object.
- **Medium:** `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:4626-4643` — no first-class evaluation environment exists for supplying imports or aliases.
- **Low:** `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:535-563` — static re-export façades require central name enumeration and conflict handling.

## Residual risks and unresolved gaps

- Runtime configuration remains arbitrary trusted code; none of these options sandbox it.
- Plain source reload and imported/prelude module evaluation are sequential and nontransactional.
- Unqualified names require a central uniqueness/mapping policy across libraries.
- Direct `set!` is incompatible with the current value identifier-macro contract without another syntax layer.
- Runtime import initialization must be audited module by module.
- Compiled plugins need a supported compiler/runtime compatibility policy.
- Broad FPO retention may materially increase binary size and reduce optimization.
- `load-scheme` in this installed snapshot produced an internal `##load` arity error during a raw-wrapper probe; it should not be relied upon without a separate toolchain fix.
- Confidence is **high** for normal and separate-module optimized behavior on the installed snapshot, and **medium** for portability across future Gerbil/Gambit releases.

## Evidence-backed validation commands

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

gxi -e '(begin (import "playground/main") (main))' >"$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual"
```

### Full compiled and optimized matrix

```sh
set -eu
cd /home/jay/Code/workbench-gerbil

for mode in normal O FPO; do
  tmpdir=$(mktemp -d)
  mkdir "$tmpdir/build"

  case "$mode" in
    normal) opts="" ;;
    O)      opts="-O" ;;
    FPO)    opts="-O -full-program-optimization" ;;
  esac

  gxc -O -d "$tmpdir/build" playground/runtime.ss
  gxc -O -d "$tmpdir/build" playground/lib.ss
  gxc $opts -d "$tmpdir/build" -exe \
    -o "$tmpdir/build/run" playground/main.ss

  "$tmpdir/build/run" >"$tmpdir/actual"
  cat >"$tmpdir/expected" <<'EOF'
((default-site default Ada) default Ada default-site default Ada default-site)
((site-one one Ada) one Ada site-one one Ada default-site)
((site-two two Ada) two Ada site-two two Ada default-site)
EOF
  cmp "$tmpdir/expected" "$tmpdir/actual"
  rm -rf "$tmpdir"
done
```

### Scope and staging

```sh
cd /home/jay/Code/workbench-gerbil
git status --short --untracked-files=all -- playground \
  research/gerbil-config-import-injection-options.md
test -z "$(git diff --cached --name-only)"
```