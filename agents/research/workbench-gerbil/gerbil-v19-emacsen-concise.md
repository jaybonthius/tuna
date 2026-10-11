# Gerbil v19 Emacsen runtime — concise recheck

## Answer

### 1. Exact current version

The installed runtime reports:

```text
Gerbil v0.19-dev-31-g4a4d1a30 on Gambit v4.9.7-6-g64f4d369
```

However, `/home/jay/Code/gerbil` is **not that v19 source revision**:

```text
HEAD 0618730d4e30bf3f48538d6b09722ad3b6056414
git describe: v0.18.2-1-g0618730d
```

There is no root `VERSION` file. Version generation instead uses `git describe`: `/home/jay/Code/gerbil/configure:5-25` and `/home/jay/Code/gerbil/src/build/build-version.scm:1-25`.

**High — provenance mismatch:** the installed v19 binary and prescribed source checkout do not correspond. Consequently, source-level claims below are strongly supported for checkout `0618730d`, but cannot be called an attested inspection of installed commit `4a4d1a30`.

### 2. Eval, reload, and FPO changes

No material semantic change can be established from the available evidence:

- Runtime expander initialization remains the relevant eval prerequisite: `src/gerbil/runtime/init.ss:14-31,248-258`.
- Runtime imports still pass through `__eval-import`: `src/gerbil/runtime/eval.ss:85-88` and `src/gerbil/runtime/init.ss:104-188`.
- Expander module import supports explicit reload/evaluation flags: `src/gerbil/expander/module.ss:91-120,140-187`.
- Runtime module reload remains in-place loader behavior: `src/gerbil/runtime/loader.ss:8-105`.
- Interactive reload still re-imports contexts and reloads matching modules in load order: `src/std/interactive.ss:13-64`.
- Gerbil still emits Gambit `(declare (block) ...)` by default: `src/gerbil/compiler/driver.ss:787-804`; FPO aggregation and tree shaking are at `src/gerbil/compiler/driver.ss:343-389`.

The requested bounded v19 `__eval-import` execution check was not run before the tool budget closed. Therefore the prior FPO failure—`Unbound variable: __eval-import`—is **unresolved on installed v0.19-dev**, not confirmed fixed or reproduced.

**Medium — FPO:** continue treating runtime Gerbil expansion under `-full-program-optimization` as unsupported until checked against matching v19 source and binary. Normal compilation and separate-module `-O` remain the defensible targets.

### 3. Idiomatic core: modules and global rebinding, not universal boxes

Yes. Gerbil’s native core is ordinary module/global binding identity plus module load/reload and assignment. It does not require a box behind every binding.

Use explicit indirection only where its semantics are needed:

- a command or hook reference may outlive the module generation;
- an atomic switch between validated implementations is required;
- a stable callback object must continue dispatching to replacement code;
- process-wide registration, validation, or synchronization is required.

A captured procedure remains the old procedure after its global is rebound. Boxes, stable trampolines, or command/hook registries solve that boundary case; they should not replace ordinary internal calls throughout every module.

For multimethod extension, `:std/generic` is a native mutable-dispatch boundary: `src/std/generic/macros.ss:17-53`; replacement, locking, and cache invalidation are implemented in `src/std/generic/dispatch.ss:40-104,119-151`.

### 4. Recommended long-lived Gerbil Emacsen architecture

#### Stable kernel — never reload

Keep these identities stable:

- buffers, documents, windows, editor/event-loop state;
- command and hook registries;
- protocol records/classes and generic definitions;
- persistent parameters, logging, diagnostics, and generation management;
- synchronization and state-migration APIs.

The stable layer must not import reloadable implementations back into itself.

#### Reloadable implementation modules

Reload cohesive source modules through:

```scheme
(import-module canonical-path #t #t)
```

The first flag bypasses the cached module context; the second evaluates the replacement. Reloading reruns module initialization, so reloadable modules should export behavior and registration manifests rather than own irreplaceable state or uncontrolled startup effects.

#### Stable boundaries

- **Commands:** stable command IDs map to current procedures.
- **Hooks:** stable hook collections own registration/removal and generation retirement.
- **Generics:** use `:std/generic` where type-directed extensible dispatch is the domain model.
- **Callbacks:** hand external systems stable trampolines when already-captured callbacks must follow reload.
- **Swap:** validate a module’s manifest before replacing registry entries; serialize the swap on the editor thread.

#### Where `(declare (separate))` is needed

Use it narrowly in a provider module when all of these apply:

1. a module global will be rebound externally or independently of reloading the module’s callers;
2. already-compiled same-provider or optimized callers must observe that rebinding;
3. the compiler otherwise may rely on Gerbil’s default `block` assumption.

The relevant declaration behavior is documented in `src/gambit/doc/gambit.txi:4886-4939`; Gerbil’s generated default is at `src/gerbil/compiler/driver.ss:787-804`.

It is not a blanket requirement for the stable kernel, every reloadable module, registry-backed command dispatch, or generic dispatch. Splitting externally rebindable globals into small provider modules limits the optimization cost. Disable FPO for the source-reload runtime until its eval retention and dynamic binding behavior are attested.

### 5. Concrete comparison with Racket generations

Racket’s recommended architecture in `research/racket-emacsen-runtime.md` is materially stronger for isolated generations:

| Concern | Racket v9.2 | Gerbil evidence reviewed |
|---|---|---|
| Generation isolation | Fresh namespace/module registry | In-place process-global module/global rebinding |
| Stable state sharing | `namespace-attach-module` shares selected module instances | Stable kernel remains loaded and reloadable code calls it |
| Old/new coexistence | Separate registries can retain both generations | Old procedure objects may survive, but no equivalent isolated module registry was identified |
| Failed load | Old namespace generation remains intact | Module evaluation may already have rerun initialization or mutated shared state |
| Resource retirement | Child custodian shutdown | Must be implemented explicitly by generation/registration lifecycle |
| Optimization | Fresh generations permit normal optimized modules | `block`, FPO tree shaking, and runtime eval constrain rebinding |
| Hot boundary | Stable dispatcher still needed | Stable command/hook dispatcher likewise needed |

Thus Gerbil should not copy Racket’s namespace-generation design literally. Its best-supported architecture is **stable state plus controlled in-place module reload**, with explicit command/hook/generic boundaries. Both runtimes still need indirection where captured callbacks must track a new implementation, but Racket supplies native registry isolation and custodian lifecycle that the reviewed Gerbil APIs do not.

## Residual risks and confidence

- **High:** installed v19 and `/home/jay/Code/gerbil` source provenance mismatch.
- **High:** reload executes trusted code and can mutate stable state before validation.
- **Medium:** module initialization may repeat; registrations need generation-aware replacement/removal.
- **Medium:** stale callbacks and objects can retain old procedures or type identities.
- **Medium:** concurrency requires serialized registry and reload operations.
- **Medium:** v19 FPO/`__eval-import` behavior remains untested.
- **Confidence:** high for the architecture and checked-out loader/compiler semantics; medium for applying them unchanged to installed `v0.19-dev-31-g4a4d1a30`.

## Focused validation command

```sh
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/main.ss" <<'EOF'
(import :gerbil/expander)
(export main)
(def (main . _)
  (gerbil-load-expander!)
  (displayln (eval '(+ 20 22))))
EOF
gxc -exe -o "$tmp/main" "$tmp/main.ss"
test "$("$tmp/main")" = 42
```

## Full relevant characterization

Run normal, `-O`, then FPO against a disposable same-path reload fixture. The fixture should load v1, rewrite the source to v2, call `(import-module path #t #t)`, and assert:

- ordinary module calls report v2;
- stable command/hook dispatch reports v2;
- an intentionally captured raw v1 procedure remains v1;
- persistent kernel state retains identity;
- failed replacement does not change the published dispatcher.

FPO should remain characterization-only:

```sh
gxc -O -full-program-optimization -exe -o /tmp/reload-fpo main.ss
/tmp/reload-fpo
```