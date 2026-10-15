# Open-by-default spike — never merge

**Verdict: no-go for option d as specified.** A documented macro, typed facade (stable entry point), and private procedure record do support live replacement, wrapping, saved function values, and optimized callers. But 34 nullable-returning functions cannot be opened with the requested tail-call guarantee using the documented forms tested; imported macros can also retain closed definitions. The restricted prototype builds and passes every test without consumer or kernel changes. It costs substantially more compilation time, worsens backtrace names, breaks old compiled callers when private facade names shift on recompilation, and does not automatically make session `def` replace package definitions. Prefer explicit open points unless those requirements change.

| Workload | Baseline | Restricted open* | + two closed helpers |
|---|---:|---:|---:|
| 5k lines: unchanged, ms/redraw | 1.56 | 2.35 | 1.72 |
| 5k: point moved | 60.86 | 70.24 | 62.97 |
| 5k: character inserted | 64.29 | 77.49 | 67.70 |
| 5k: text reads alone, ms/pass | 19.49 | 27.02 | 20.45 |
| 50k lines: unchanged, ms/redraw | 16.00 | 18.43 | 16.17 |
| 50k: point moved | 570.99 | 659.39 | 580.25 |
| 50k: character inserted | 567.85 | 628.11 | 580.93 |
| 50k: text reads alone, ms/pass | 201.95 | 215.65 | 203.16 |
| Self-insert, ms/key | 0.01379 | 0.01503 | 0.04935 |
| Next/previous line, ms/key | 0.02427 | 0.03232 | 0.01235 |
| Clean `make`, seconds | 238.64 | 432.22 (+81%) | — |
| Built-tree `make test`, seconds | 112.64 | 123.68 (+9.8%) | — |

All table entries are **five-sample CPU-0 medians**, Ryzen 9 7940HS, Gerbil `v0.19-dev-63-g1cfb032c`, Gambit `v4.9.8-19-gea114fc3`. Baseline is `a7173864`; builds remove this workspace's artifacts, not dependencies. All runs used the required memory caps and 2400-second timeout. The adapted benchmark uses 79 characters plus newline per line and 40 repetitions per redraw/read case. Keys use the real input/command pipeline with an editor-loop barrier per key, on 5k lines; no redraw, browser or network is timed. Samples ran sequentially, not interleaved. Key wall times vary sharply; these do not establish a per-call cost or a universal latency improvement.

\* All **22 actual package-language modules** were rebuilt: **219 functions open, 34 `Maybe` returns closed**. The supposed 25 modules include three comment/fixture-string matches. The last column/final branch additionally closes `rope-for-each-chunk` and `rope-line-count` (217 open). A call-count probe of the earlier installer-export prototype found 6.17M and 2.42M calls respectively in the 5k workload. Closing them brings changed-redraw medians within 1.6–5.3% of baseline, **not all hot paths**: self-insert worsened. Final opt-out `make test` passed once (114.18 s); its incremental build was 26.73 s, not comparable to clean-build medians.

## Coverage

| Form / behavior | Result |
|---|---|
| Plain/typed positional arguments; `=> Type` | **Handled.** Original signature retained; documented `:-` asserts the dynamic result. Installations must honor that signature. |
| Optional/keyword/rest arguments; curry | **Handled.** Explicit/default arguments, keyword plus rest, and curried calls pass; defaults run once. Only rest forwarding uses `apply`. |
| Value `def`; literal `lambda` value | **Left alone / handled.** Non-procedures unchanged; literal lambdas open. Arbitrary expressions returning procedures are not recognized. |
| Forward references; mutual/self recursion | **Handled.** Forward typed caller and 10M self/mutual iterations pass. Continuation traces at depth 1 and 1M are identical: four frames. A wrapper sees all 10,001 recursive entries. |
| Same-module / cross-module `-O` calls | **Handled.** Replacement changes both; typed arithmetic caller still uses the facade's unchecked typed entry, then reads the record. |
| First-class references | **Handled.** Saved facade, table entry, `map`, and `apply` see the new definition and wrapper. `open-definition` retrieves the effective procedure, not the facade. |
| Package `defrule`; imported core-bound macros / `def*` | **Handled / problem.** Hygiene preserves the defining macro's `def` binding. A foreign core-bound generator stays closed. |
| `defcommand`; `defplugin` bodies | **Left alone.** Commands register lambdas; plugin-body/local definitions retain lexical Gerbil behavior. Full command/plugin tests pass. |
| `defmethod` / `defclass` / `defstruct` | **Left alone.** Existing tests and explicit struct/method probe pass. |
| Docstrings; source locations; backtraces | **Body string retained; argument error still names the correct file/line.** Procedure names become generated private names such as `probe#_%$%typed...%_`; backtraces are worse. |
| `(declare (separate))`; block compilation | **Handled.** Both compiled probes observe installation; record mutation does not depend on foreign global rebinding. |
| `=> (Maybe T)` | **Problem; automatically closed.** See proof and complete inventory below. |

**Nullable proof:** at recursion depths 1 / 10,000, documented continuation inspection counts **11 / 10,011** frames for ordinary closed Gerbil, **15 / 30,013** with a checked nullable facade, and **12 / 20,011** when the facade keeps typed arguments but drops its return type. Thus the existing nullable adapter already prevents tail recursion; opening adds frames, and dropping the facade return does not repair it. `:-` accepts a type identifier, not `(Maybe T)`; `:?` checks after the call. No documented check-free nullable assertion was found. The application measurements exclude these functions rather than run that nonconforming facade.

**All 34 exclusions** (each path is `plugins/NAME/plugin.ss`):
- buffers: `changes-since`, `first-text`, `find-buffer`; buttons: `button-at`.
- command-annotations: `annotate-command`; commands: `registry-activation`; completion: `exact-candidate`; help: `live-help-buffer`.
- keys: `key-description`, `focused-node`, `clicked-node`, `command-task`, `resolve-key!`, `bound-command-task`, `resolve-pointer!`.
- layout: `normal-part`, `shown-node`, `find-node`, `repair-part`, `leaf-showing`, `selected-container-id`, `enclosing-tabs`, `rearranging-refusal`, `selected-container`, `nearest`.
- reload-config: `startup-report-summary`; session: `session-entries`; settings: `scope-value`; text-store: `replace-within-leaf`.
- web: `web-transport-url`, `header`, `parse-key-event`, `parse-part`, `parse-pointer-event`.

## Caveats and evidence

- **Installation works; ordinary interactive `def` still shadows.** `install-open!` and `open-definition` are generic public macros dispatching through documented `identifier-rules` to private module-owned operations. `set!` on an imported open name also routes to that installer. A new evaluator-owned top-context probe, matching `config.ss`/`boot.ss`, proves that evaluating `(def (f ...) ...)` creates a session-local `f`; a prefixed imported name still reaches the package installer. Only already-exported names are targetable from outside; private functions remain private. Options: explicit `install-open!`, an explicit `redefine-open` form, or an `eval-defun` command given an explicit source/package target. Automatic target selection needs design, not evaluation inside another module.
- **Two expansion failures were repaired idiomatically.** Moving bodies into typed lambdas broke `count-newlines` return inference; a hygienically named private ordinary `def` preserves the original inference. Auto-exporting named installers/getters made `demo/init.ss` fail with an `ask!-definition` import collision. Generic identifier dispatch removed all per-function exports; no consumer imports changed.
- **Types still optimize the facade, not through the mutable body.** Indirection blocks body inlining and the private checked implementation repeats argument checks. Generated Scheme grew 8.8%, `.ssi` metadata 49.8%; expansion is a fixed-size scaffold per function, but compile time is appreciably worse. Full-program optimization was not tested (already unsupported by ADR 1).
- **Unstable compiled-module interface.** `recompile-probe.sh` adds one unrelated private helper, recompiles only the defining module, and keeps its caller compiled. The caller fails: its old generated facade binding is undefined. In-process installation still works; module recompilation/reload needs a separate stable-identity design or caller rebuilds. No repair was folded into this spike.
- **Not an advice engine.** Wrapping the effective definition is demonstrated; ownership, removal, ordering and preserving advice under later redefinition are not built. Wrapping a saved facade instead of `open-definition` would recurse into the wrapper. No undocumented primitives, generated-name mutation, foreign-namespace evaluation or binding inspection are used. The only macro-context query is the approved documented `module-context?` predicate; session probes create their own top context.
- **Validation / ownership:** baseline and restricted-open `make test` pass 5/5; final opt-out branch passes again; compiled probes end `PROBES-PASS`. Kernel and consumers are unchanged. `tuna/prelude.ss` still imports only core/kernel; text-store still imports its contract and kernel/interface library, provides `text-store-service`, and adds no service requirement. No Tuna process remains running.

Spike commit: `bd3752eac11d88eafd83325c3fcd8802cdca53fc` on `open-def-spike`. Reproduce with `spike/open-def/README.md` and `run-probes.sh`. Raw evidence in this directory: `summary.json` (all samples/ranges), `{baseline,open}-{build,test}*.log`, `{baseline,open,closed}-work.log`, `final-probes.log`, `nullable-inventory.json`, `source-diagnostic.log`, `recompile-checked.log`, and the archived earlier installer prototype/call-count probe. The worktree is throwaway; do not merge it.
