Turn budget wrap-up was requested after 12 assistant turns (soft limit 12, grace 2). Process-mode live steering is unavailable, so the child was warned at launch to wrap up by this budget. Output may be partial.

# FPO runtime config options

## Answer

**No. FPO is not fundamentally incompatible with the current `#lang` runtime configuration.** The observed `Unbound variable: __eval-import` is caused by FPO dead-definition elimination, not by an inherent conflict with runtime source expansion.

The smallest verified way to preserve source edit-and-reload is to retain the current loader and add this executable build option:

```sh
-prelude '(declare (not optimize-dead-definitions))'
```

The FPO executable then successfully ran **default → v1 → v2** from editable source configuration files. Ahead-of-time configuration compilation is therefore **not** the only fallback.

## Bounded experiment results

Disposable fixture:

```text
/tmp/wbg-fpo-runtime-config-exp1
```

### 1. FPO with broad retention

**Result: passed build and runtime.**

After precompiling the current static dependencies into the disposable build directory, the executable was built with:

```sh
GERBIL_PATH=/tmp/wbg-fpo-runtime-config-exp1/build \
gxc -O -full-program-optimization \
  -prelude '(declare (not optimize-dead-definitions))' \
  -d /tmp/wbg-fpo-runtime-config-exp1/build \
  -exe \
  -o /tmp/wbg-fpo-runtime-config-exp1/build/run \
  playground/main.ss
```

Runtime output:

```text
((default-site default Ada) default Ada default-site default Ada default-site)
((site-one one Ada) one Ada site-one one Ada default-site)
((site-two two Ada) two Ada site-two two Ada default-site)
```

This proves that the FPO host can load and evaluate both editable `#lang` source files without recompiling the executable.

The resulting executable was **13,392,880 bytes**. No baseline size comparison was run because the requested first experiment succeeded and the bounded stop condition applied.

A preliminary one-step FPO build failed with:

```text
Syntax Error: cannot find static module
detail: "runtime.scm"
```

That was a build-layout prerequisite, not the runtime `__eval-import` failure. Precompiling `runtime.ss`, `lib.ss`, and `config-lang.ss` into the disposable `GERBIL_PATH` resolved it.

### 2. Targeted retention/static reference

**Not run.** Experiment 1 succeeded, so targeted retention was not needed under the requested sequence.

Consequently, this research does not establish whether retaining only `__eval-import`, or adding a static reference to it, is transitively sufficient for the complete runtime expander.

### 3. Split non-FPO loader

**Not run.** Experiments 1–2 did not fail, so a split loader was unnecessary.

## Cost and support status

The broad declaration disables dead-top-level-definition removal for **all globals** in each dependency included in the FPO compilation unit. Gerbil’s FPO driver resets declarations and then injects the user prelude before every dependency:

- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:343-380`
- `/home/jay/Code/gerbil/src/gerbil/compiler/driver.ss:392-411`

Gambit documents that unqualified `(not optimize-dead-definitions)` preserves all dead top-level definitions:

- `/home/jay/Code/gerbil/src/gambit/doc/gambit.txi:5100-5111`

Therefore the costs are:

- larger executable/code footprint;
- potentially longer FPO compilation;
- loss of top-level tree-shaking benefits;
- other FPO optimizations remain enabled.

This uses supported public mechanisms:

- `gxc -prelude` and FPO are documented CLI options:  
  `/home/jay/Code/gerbil/doc/reference/dev/bach.md:99-115`
- Whole-program declarations through `-prelude` are documented:  
  `/home/jay/Code/gerbil/doc/guide/intro.md:1300-1312`
- `gerbil-load-expander!` is the documented compiled-eval mechanism:  
  `/home/jay/Code/gerbil/doc/guide/eval.md:62-93`
- `import-module` is explicitly included in the expander user API:  
  `/home/jay/Code/gerbil/src/gerbil/core/expander.ss:38-54`
- Its reload/evaluate arguments implement the current source reload:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:93-100`
- `#lang` reading and prelude loading are implemented at:  
  `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:269-350`

The original failure is consistent with runtime imports compiling to `__eval-import`:

- `/home/jay/Code/gerbil/src/gerbil/runtime/eval.ss:85-88`
- definition and module-evaluation machinery:  
  `/home/jay/Code/gerbil/src/gerbil/runtime/init.ss:123-190`

The retained executable contained a defined `__eval-import` symbol, confirmed with `nm`.

## Current constraints and risks

- The executable must be run where the current relative paths `playground/config.scm` and `playground/config-v2.scm` resolve.
- The language source/compiled phase artifacts must remain deployable through the configured path.
- Broad retention has an unquantified size/performance delta; only the resulting 13.39 MB size was measured.
- Targeted retention remains unresolved and could reduce cost if its transitive requirements are established separately.
- Runtime configuration remains trusted executable code, not sandboxed data.
- Confidence: **high** for Gerbil 18.2/Gambit 4.9.7 on this machine; **medium** across future toolchain releases.