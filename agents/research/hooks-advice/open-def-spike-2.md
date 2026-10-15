# Open-by-default spike 2 — never merge

**1. Readable backtraces: fixed** for the generated function names. **2. Recompilation stability: fixed** in the unchanged-caller and body-only probes. **3. Compile time: partly fixed:** clean-build median falls from 432.22 to **289.08 s**, still **15.7% above the rerun baseline**. **4. Interactive redefinition: partly fixed:** an explicit `redefine` works; ordinary session `def` still shadows. All **251 eligible functions are open**, including all 34 nullable returns; the two rope opt-outs stay closed. No kernel, contract, consumer, or toolchain changes.

| Workload | Baseline rerun | Spike 1* | Spike 2 |
|---|---:|---:|---:|
| 5k lines: unchanged, ms/redraw | 1.95 | 1.72 | 2.28 |
| 5k: point moved | 82.28 | 62.97 | 75.07 |
| 5k: character inserted | 90.92 | 67.70 | 85.22 |
| 5k: text reads alone, ms/pass | 27.85 | 20.45 | 26.02 |
| 50k lines: unchanged, ms/redraw | 20.78 | 16.17 | 20.99 |
| 50k: point moved | 744.51 | 580.25 | 637.84 |
| 50k: character inserted | 619.46 | 580.93 | 604.70 |
| 50k: text reads alone, ms/pass | 205.14 | 203.16 | 220.66 |
| Self-insert, ms/key | .01491 | .04935 | .02969 |
| Next/previous line, ms/key | .01567 | .01235 | .01443 |
| Clean `make`, seconds | 249.84 | 432.22* | 289.08 |
| Built-tree `make test`, seconds | 115.71 | 123.68* | 120.75 |

Five-sample CPU-0 medians; same benchmark/toolchain/machine as spike 1, baseline `a717386` isolated in scratch. Redraw/reads: 40 repetitions, 79 characters plus newline per line. Keys: real command pipeline plus barrier, no redraw/network. Sequential wall times are noisy; faster redraw medians do not prove opening helps. Self-insert still costs more. *Spike-1 workloads use its final rope opt-outs; build/test use its published 219-open series before those opt-outs.*

## What changed and what remains

- **Names/recompilation.** Documented `stx-identifier` creates private `f::open-body`, `f::open-entry`, `f::open-cell` names. An untouched compiled caller survives adding an unrelated private helper, then returns 102 instead of 2 after a body-only edit. Caller checksums remain unchanged; the entire `.ssi` module-interface file is byte-identical after the body edit. Real backtrace excerpts:

  ```text
  BEFORE: *** ERROR IN "probe.ss"@31.14-31.15 [ContractViolation]: contract violation
  [0] __raise-contract-violation-error__%
  [1] probe#_%$%typed47915046%_
  [2] (interaction) (apply probe#_%$%typed47915046%_ (list "bad"))
  AFTER:  *** ERROR IN "probe.ss"@31.14-31.15 [ContractViolation]: contract violation
  [0] __raise-contract-violation-error__%
  [1] probe#typed::open-entry
  [2] (interaction) (apply probe#typed::open-entry (list "bad"))
  ```

  Body-error frames likewise become `probe#__fail-middle::open-body`. Ordinary compiler-generated local names are not rewritten.
- **Compile cost.** Sharing one `identifier-rules` constructor removes per-function matcher compilation. Dropping installer/getter procedures helps less; stable names alone do not solve it. Most diagnostic time is Gambit plus C compilation: spike 1 → final seconds are **13.39→5.35** (text store), **113.10→29.46** (layout), **11.01→5.31** (keys). Layout's macro-stage Scheme shrinks **6.04→2.01 MB**; sharing runtime operations alone left 5.91 MB / 100.46 compiler seconds. These are single diagnostic samples. Built-tree runtime Scheme remains **+6.5%**, macro-stage Scheme **+17.9%**, `.ssi` **+40.8%** versus baseline (previously +49.8%). Two-thirds of interface-size excess is the prelude enumerating filtered core exports instead of retaining one re-export entry.
- **Nullable calls.** Ordinary checked return contracts reject invalid replacement results; no unchecked nullable assertion. At depths 1 / 10,000, closed traces have **11 / 10,011** frames, actual open traces **13 / 30,011**: **two extra frames per recursion level**. Non-nullable ten-million-step recursion and constant-depth traces pass.
- **Interactive designs.** Recommend explicit `redefine` of an imported name, prefixed if ambiguous. This evaluator-owned-context proof updates compiled callers:

  ```scheme
  (defrule (redefine (name . args) body ...)
    (install-open! name (lambda args body ...)))
  (redefine (package-typed (x : :fixnum)) => :fixnum (fx+ x 20))
  ```

  Alternatively, source-aware `eval-defun` imports a module/name alias into the session and emits this operation. That needs target-selection policy. Both designs reach exported names only; replacement bodies resolve in the session, without package-private access or foreign-namespace evaluation. Ordinary `def` still shadows.

**Evidence:** baseline/spike-2 `make test` **5/5** each; compiled replacement, tail, nullable, session, block/separate, recompilation probes pass. Imported core-bound macros still generate closed functions. All runs capped/timed as required; no Tuna server started or remains. Raw samples/ranges: `spike2/summary.json`; compiler/nullable evidence: `spike2/compiler.json`; traces: `spike2/backtrace-{spike1,final}/`; probes: `spike2/factory-probes.log`. Reproduce: `spike/open-def/README.md`; commit `7d2c5ed` on `open-def-spike`. Never merge.
