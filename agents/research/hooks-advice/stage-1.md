# Hooks and advice — stage 1

**Implemented; performance acceptance is incomplete.** Branch `open-functions`, commits `95106e2`, `db09673`, based on `e40a66f`. Working tree and index are clean. No kernel changes, advice library, service/command targets, hook changes, or documentation edits.

## Changes and plan checklist

- `tuna/prelude.ss`: **168 lines (main: 20)**. Open procedures retain typed implementation and facade signatures. **Plain definition lookup done:** an `open-binding` syntax object holds quoted facade/cell identifiers; `syntax-local-value` supplies them to `open-definition` and `install-open!`. Both expand to typed operations. No marker arguments or runtime registry.
- **Core forms done:** procedure `def`, literal `lambda`/`case-lambda`, curried definitions, and `def*`. Variables, local definitions, structs/classes/methods and syntax definitions retain Gerbil behavior. Other procedure-definition core forms are not used in production packages. Imported macros bound to core `def` deliberately remain closed; rewriting those lexical bindings would violate hygiene. Command advice belongs to stage 3.
- **Compact interfaces done:** one core-prelude re-export, ordered so the open forms win in both normal imports and `#lang`. Prelude `.ssi`: 8,744 bytes; all Tuna `.ssi` files: 1,410,862 → 1,610,140 bytes (+14.1%), instead of enumerating core exports. The built packages contain **251 open procedures**.
- **Opt-out/redefinition done:** `def/closed`, `redefine`, and `plugins/text-store/plugin.ss`'s two measured rope opt-outs. No advice exists yet; stage 2 must make cell updates preserve advice.
- **Tests done:** `tuna/tests/unit/prelude-test.ss`; helpers in `tuna/tests/support/open-functions/{target.ss,caller.ss,foreign-macro.ss,recompile.sh}`. Helpers are not build targets.
- **Tooling check partly blocked:** findings below; no tool patches.
- **Measurements done:** table below. Build meets its target; the remaining within-noise target is **not established**, particularly line motion and total test time. No extra opt-outs were added to hide this.

Placement: prelude imports the kernel, no service contracts; rope imports only its own text-store contract and declares no required services (it provides text-store). Tests import their own helpers and public Tuna modules. Kernel line delta: **0**.

## Validation

Normal `make test` discovers seven new cases: same-module/imported/saved callers and `set!`; signatures/defaults/rest/keywords/local definitions/closed forms; `def*` and literal procedures; nullable return checking; private module-context redefinition with private helpers and unchanged state; bounded-depth tail calls; optimized compiled callers and target-only recompilation. The latter checks **10,000,000 self and mutual calls**, unchanged caller checksums, and byte-identical `.ssi` after a body-only edit. Duplicate interpreted self/mutual checks use **10,000**, not ten million; source and compiled trace-depth assertions remain.

Clean full build/test passed. **Final timed test sampling required six attempts on each variant: five passes and one failure, not five clean passes.** Each passing open attempt included 40 Gerbil suites, 12 frontend tests and demo configuration loading. Both variants failed the identical unchanged HTTP ordering assertion (`tests/integration/web-test.ss:134`: expected `"126"`, received `"12"`):
- Baseline: `main-test-4.log` failed (114.63 s); `main-test-4-retry.log` passed (114.26 s).
- Open: `open-test-2.log` failed (152.77 s); `open-test-2-retry.log` passed (155.02 s).

The table uses five successful samples per variant, substituting those retries; every failed log is retained. Earlier passing open samples with duplicate interpreted ten-million-step loops were superseded, not failures: `open-test-1-long-source.log` (154.44 s), `open-test-2-long-source.log` (168.79 s). An early incremental development run also failed on stale constructor-arity artifacts (`initial-full-test.log`); a clean rebuild resolved it without a compatibility shim. No unchanged web test was edited.

Every build/test/interpreter/compiler command used `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 2400` (4G for single-file/probe runs). MCP balance checks bracketed edits; capped source imports in module context supplied syntax checks because the MCP syntax API cannot request a memory cap. No running Tuna process remains.

## Measurements against main

Five-sample medians; same toolchain, `taskset -c 0`, spike workload harness, 40 redraw/read repetitions, 79 characters plus newline per line. Line-motion time is divided by two keys per iteration. Baseline is an isolated archive of `e40a66f`, not the primary checkout. Commands/raw samples: `measure.sh`, `resume*.sh`, `finish-open.sh`, `*-build-*.log`, `*-test-*.log`, `*-work.log`, `collect.py`, `summary.json` beside this report.

| Workload | Main | Open | Change |
|---|---:|---:|---:|
| Clean make, seconds | 306.36 | 338.14 | +10.4% |
| Built-tree make test, seconds | 117.74 | 218.21 | +85.3% |
| 5k unchanged, ms/redraw | 1.884 | 2.049 | +8.8% |
| 5k point moved | 70.719 | 69.090 | −2.3% |
| 5k character inserted | 70.954 | 76.442 | +7.7% |
| 5k reads, ms/pass | 21.440 | 23.012 | +7.3% |
| 50k unchanged, ms/redraw | 16.845 | 21.205 | +25.9% |
| 50k point moved | 625.826 | 647.941 | +3.5% |
| 50k character inserted | 659.476 | 658.958 | −0.1% |
| 50k reads, ms/pass | 213.314 | 226.355 | +6.1% |
| Self-insert, ms/key | .01518 | .01667 | +9.8% |
| Next/previous line, ms/key | .01337 | .03291 | +146.0% |

The new regression suite alone took **24.06 s** in a separate diagnostic sample; this is added test cost, not production latency, and does not explain the entire test-time increase. Main test range: 108.78–180.29 s; open: 145.46–221.34 s. Other users' CPU-heavy jobs were present; these sequential runs cannot separate production cost from changing host load. **Do not call the line-motion increase noise:** its ranges are disjoint (.01277–.01625 vs .01783–.04196 ms/key). A controlled paired rerun/profile is warranted before accepting the performance gaps.

## Tooling, idioms, later work

- `tooling/lookup.log`: ordinary value lookup remains callable and prints `typed::open-entry`; `open-definition` prints `typed::open-body`. Syntax-based inspectors see `open-binding` metadata, not a plain procedure binding. Dynamic argument backtraces retain the original source location and readable entry name; inline guards may report the call site. Freshly evaluated replacement lambdas can appear anonymous in body-error traces (`tooling/backtrace*.log`).
- **gerbil-lsp go-to-definition could not run:** an isolated, unchanged copy of checkout `35a83af` fails to build because `lsp/transport.ss` imports unavailable `:std/text/json` (`lsp-build.log`). No go-to-definition result is certified; no tool/installation/checkout was patched.
- Macro metadata uses the documented `setq-macro` role (Gerbil `doc/guide/intro.md:180`, `doc/reference/gerbil/prelude/macros.md:156`), `syntax-local-value` (expander reference), and the same subclass pattern as `src/gerbil/core/match.ss:19`. `quote-syntax` captures the defining context. Avoided marker queries, raw primitives, expander internals/mutation, compiler-name mutation, global registries and tool fixes. Stable `::open-*` names follow the spike's generated-name convention.
- Stage 2 still owns advice-preserving redefinition/composition; stage 3 owns commands/services; stage 4 owns hooks and all records. Later docs must amend ADR 1's now-stale closed-`def` claim, explain lookup/macro metadata and `def/closed`, update overview/equivalents, and retain the known nullable-tail-call limitation. **Review performance gaps and the unavailable language-server check before merging.**

## Addendum — controlled performance diagnosis

**No production changes or new opt-outs.** Baseline remains `e40a66f`; open remains `db09673`. The old +146% motion/+25.9% unchanged-redraw figures are not reproduced by controlled paired runs. Smaller, real typing/motion costs remain; they are not being called noise. No application rebuild series, toolchain/LSP changes, merges or stage-2 work were performed.

**Controls and provenance.** Core 14 was allowed and 99.4% idle in the five-second preflight. Every workload ran inside both `AllowedCPUs=14` and `taskset -c14`; all **48 timed workload processes** reported `Cpus_allowed_list: 14`. Concurrent processor load and thread/process snapshots are retained. Crucially, replaying the earlier `taskset -c14 gerbil env gxi …` launcher produced **CPU 8 inside gxi**. The historical taskset-only launch did not guarantee its requested child affinity. New runs invoke gxi directly with explicit, variant-local library paths.

For each helper mode, six fresh-process A/B–B/A pairs alternate order with identical warmup: five cached redraws; 100 self-insert/down/up triples. Primary runs retain the spike's **1,000 self-inserts, 1,000 down/up cycles = 2,000 motion keys, and 40 unchanged 50k redraws**. Another six pairs per mode use 10,000/20,000 keys as a longer-repeat check. Both variants produce the same screen length. `process-times` supplies user, system and elapsed seconds; CPU = user + system (Gambit manual, `gambit.txi:13563–13589`). Every process's 50 ms sleep consumes approximately 0.1 ms CPU, verifying that the installed CPU clock is not a wall-clock fallback.

The three helpers have identical source hashes across variants. `strace` confirms production plugins load their respective compiled libraries, while the original harness loads helper `.ss` files. The compiled-helper control changes **only those three import specifications**, compiling the unchanged helpers into isolated scratch libraries. Its baseline/open harness files are byte-identical. No production library was recompiled for this control.

### Matched workload results

Primary, original-count runs with compiled helpers; ranges include all six samples. Per-key figures are microseconds (µs), redraw figures milliseconds (ms). Paired deltas/percentages are medians of matched differences/ratios, not differences/ratios of marginal medians.

| Case | Wall median A → B | CPU median [range], A → B | Paired CPU delta; percentage [pair range] |
|---|---:|---|---|
| Unchanged 50k | 19.1199 → 19.1448 ms | 19.1179 [19.0362–19.3681] → 19.1434 [19.0250–19.2641] ms | +0.0158 ms; +0.08% [−1.05%, +0.59%] |
| Self-insert | 13.586 → 14.638 µs/key | 13.585 [13.425–14.012] → 14.638 [14.376–14.677] µs/key | **+0.949 µs/key; +6.96% [+4.43%, +9.12%]** |
| Line motion | 11.102 → 11.454 µs/key | 11.102 [10.936–11.289] → 11.454 [11.343–11.672] µs/key | **+0.341 µs/key; +3.05% [+1.61%, +5.81%]** |

Typing and motion increased in every original-count compiled-helper pair; these increases are measurable despite their small absolute size. Unchanged redraw ranges overlap closely. With source helpers, paired CPU deltas were +0.479 ms/redraw (+2.47%), +1.246 µs/self-insert (+8.39%), and +0.576 µs/motion key (+4.65%). The longer-repeat compiled-helper check gave −0.98%, +6.29%, +2.09%, respectively; redraw/motion pair ranges included zero there. Both helper modes and both repetition counts remain in the evidence, not selectively discarded.

**Mechanism and limits.** Optimized output shows the new entry performing a cell-field read followed by an indirect call into the checked implementation. The compiler already removes the cell's type check; there is no runtime registry, name lookup or syntax-metadata query on this path. The indirect checked boundary replaces the old known-procedure call and prevents that call's direct optimization. A compiled, alternating body-versus-facade scalar probe measured approximately **11.46 → 12.87 ns/call**, about **1.4 ns extra**. That demonstrates a fundamental boundary cost, not the complete accounting of each command's microsecond delta. The exact contribution of downstream optimization/contract/garbage-collection effects to the full key cost is not isolated.

Garbage collection materially affects source-helper redraw comparisons: both diagnostic pairs collected ten times over 40 redraws; open used an extra **31–40 ms of collection CPU**, or 0.78–0.99 ms/redraw, with almost identical redraw allocation totals. Compiled-helper redraw pairs show no consistent increase. This is evidence of interpreter/retained-heap sensitivity in the harness, not evidence that serialization itself gained a 25.9% trampoline cost. The diagnostic timer's byte-allocation figures for key loops were implausible and were not used; CPU and elapsed measurements use the separately verified clocks. No avoidable per-call lookup/check was found to remove safely. Bypassing declared implementation contracts or adding opt-outs would change the approved safety/scope, so no speculative speed patch was made.

### Test time, separately

Only `prelude-test.ss` was excluded from the diagnostic: the remaining **39 source-identical suites**, preserving normal discovery order, ran A/B then B/A. All four attempts passed:

| Order | Main wall / CPU seconds | Open wall / CPU seconds | Open minus main CPU |
|---|---:|---:|---:|
| A/B | 93.44 / 83.51 | 99.64 / 89.71 | +6.20 s (+7.42%) |
| B/A | 86.10 / 76.17 | 101.46 / 91.53 | +15.36 s (+20.17%) |

The new prelude suite alone passed in **19.82 s wall / 19.85 s aggregate CPU**, including its existing self-capped fixture compiler processes. Loading the 39 suites without executing them took 13.75–15.65 s on main and 13.43–16.81 s open. Timestamped module execution localizes most extra test time to repeated configuration/reload/evaluation work: median wall differences were reload +5.16 s, options +4.12 s, session evaluation +2.63 s, boot +1.51 s. They are not editor-command latency measurements. These localizations do not precisely partition expansion versus execution/collection cost. The excluded-suite comparison still shows a real cost; neither the original +85.3% nor “all overhead is the new suite” is justified as a production slowdown estimate.

The **normal, unchanged `make test` final gate passed once**, including the prelude suite, 40 Gerbil suites, 12 frontend tests and demo loading: 156.17 s wall, 146.31 s aggregate CPU. No HTTP-test failure or retry occurred in this follow-up; the earlier failures/retries remain documented above. An exploratory alphabetical 39-suite diagnostic was superseded by the normal-order comparison, not silently pooled. A setup-only load probe rejected a keyword used as an import prefix; its failed log is retained and excluded from timing results.

**Raw evidence:** all under `paired/` beside this report: `idle-cores.txt`, `old-launcher-affinity.log`, `*load*.txt`; `bench-*.ss`, `compiled-*.ss`, `short-*.ss`, `*pair-*.log`, `paired-summary.json`, `summarize.py`; `resolve-{source,compiled}-*.txt`, `dispatch.{ss,log}`, `compiled-forwarding.txt`, `gc-*.log`; `normal-order-test-files.json`, `ordered-tests-*.log`, `ordered-module-times-*.json`, `ordered-module-summary.json`, `load-only-*.log`, `prelude-only.log`, `final-make-test.log`. Driver scripts retain exact invocations. `provenance-status.txt` records revisions and helper hashes.

**Final git status:** branch `open-functions`, HEAD `db09673`; worktree clean, index empty; no new commit, no source/test changes. All owned benchmark/monitor/test processes finished; no Tuna process remains. Acceptance decision: the severe historical gaps are replaced by controlled bounds, but **approximately +0.95 µs/self-insert and +0.34 µs/motion key remain measurable costs**, plus configuration/test overhead. Review those costs explicitly rather than declaring every “within noise” target satisfied.
