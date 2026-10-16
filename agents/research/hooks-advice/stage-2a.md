# Stage 2a — review follow-ups completed

**Commits:** `464ff89` implements function advice; **`308686773912c42c6f56f5df6b68ecb0c906703c`** fixes retained-owner reordering and removes measured redundant forwarding. Branch `function-advice`, atop documentation clarification `a6a1647`. Worktree/index clean. **Kernel delta: zero.** No owned Tuna process remains. Parent review/merge remains pending.

## Ordering defect: reproduced and fixed

`followup/reorder-red.log` reproduces the exact defect: after reversing retained configuration declarations, inspection reported `(counted/config good/config)` while actual calls still logged `(good counted)`.

- `tuna/lib/advice.ss` now exports **`refresh-function-advice!`**, recomposing only the existing set of advised cells. Each cell retains its installed advice sequence, so inspection describes the actual composition, not uncommitted rank changes.
- `tuna/boot.ss` imports that one operation and calls it after the complete declaration-rank batch, including blocks and user code, **before any activation/deactivation or associated callbacks**. `unwind-protect` also refreshes after a partial unwind of that batch. Later registration/removal/redefinition already refreshes its own target; no second final refresh is necessary.
- The reload regression reverses owners without restarting them, compares actual calls with inspection, then reverses again while replacement user code fails. Both retained owners keep their activation counts and the correct order.
- A unit regression verifies inspection stays with the installed sequence between direct rank mutation and explicit batch refresh.

No hook, epoch, runtime identity, scope map, per-call sorting or kernel API was added.

## Cost attribution and bounded optimization

Evidence is under `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage2/followup/`. `cost-profile.ss` is an isolated compiled diagnostic, not product code. Every timing process used direct `/opt/gerbil/bin/gxi`, explicit local library paths, both `AllowedCPUs=14` and `taskset -c 14`; actual interpreter affinity was printed. A 50 ms sleep advanced elapsed time by 50.09 ms but CPU by only 0.094 ms, verifying real CPU accounting. Hardware: AMD Ryzen 9 7940HS, Linux 6.8.0-136-generic.

Five samples of two million calls, checked sums and warmup. Median CPU nanoseconds/call (`profile-results.log`):

| Diagnostic path | ns/call |
|---|---:|
| Unadvised | 1.97 |
| Generic argument forwarding alone | 118.13 |
| Forwarding + one attribution catch | 247.65 |
| Forwarding + two attribution catches | 432.42 |
| Forwarding + advisor context only | 244.42 |
| Forwarding + advisor/caller contexts | 421.23 |
| Both catches and both contexts | 736.82 |
| Actual ordinary named `before` | 402.63 |
| Actual ordinary named `around` | 773.27 |
| Same `around`, caller already advisor | 582.61 |

**The safety scopes dominate:** catch/continuation handling adds about 314 ns over generic forwarding; context restoration adds about 303 ns separately. These omission experiments are diagnostic, not interchangeable implementations or an exact additive production decomposition. Gambit's documented `time` reports show catches driving most cumulative allocation, with garbage collection accounting for about 54% of actual around-advice CPU in the matched probe. Allocation is cumulative, not live/peak memory, and continuation cost depends on call depth.

One measured redundancy was safely removed in `tuna/prelude.ss`: a named **open** callback already denotes a stable facade whose saved references stay live. Wrapping it in another variadic late-lookup lambda repeated forwarding/allocation. `advise!` now stores that facade directly. Ordinary Gerbil bindings retain the original late-lookup wrapper. Closures, signatures, error/quit attribution and registration/task ownership are unchanged.

Six alternating matched pairs, two million calls/state, compare the new facade path with an explicitly forced copy of the old wrapper in the same executable/process (`profile-pairs.log`):

| Open callback | Old wrapper median | Direct facade median | Median paired saving |
|---|---:|---:|---:|
| Before | 429.57 ns | 410.24 ns | **17.46 ns / 4.09%** |
| Around | 864.28 ns | 835.09 ns | **27.30 ns / 3.16%** |

Every pair improved. Timed allocation sequences also reported less cumulative allocation: approximately 0.30 GB less for before and 0.51 GB less for around over 2.1 million calls (including warmup). Generated code confirms the removed lambda; named callback liveness is tested for both open and ordinary bindings, including a compiled imported open callback redefined after registration.

The dominant catches/context scopes were retained. Replacing a continuation-capturing catch with a non-capturing exception observer is not behavior-preserving: a capped documented-API probe returns **5 versus 15** when an outer handler resumes (`exception-shape.ss`, `exception-shape.log`). No unsafe exception shortcut, arity generator or fictional 1–5 ns target was introduced.

### Final original scalar probe

Freshly recompiled `bench.ss`; five samples of five million calls/state, verified CPU14 affinity and sums (`followup/final-benchmark.log`): **unadvised 2.264 ns, anonymous around-forwarding 706.117 ns, advice removed 2.275 ns** median. The open-callback table above includes additional open-callback forwarding and a different diagnostic stack; it is not directly comparable to this anonymous-callback probe. Unadvised code remains a field read plus indirect call, with no ordering/evaluation/registry work.

## Validation and files

Every Gerbil process ran under `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 2400` (4G for expansion/probes). MCP balance checks bracketed every `.ss` edit; capped contextual module expansion supplied syntax checks.

**This follow-up ran one normal full `make test`, after a local clean: passed first attempt.** It covered 41 Gerbil suites, 12 frontend tests and demo configuration validation (`followup/full-test.log`). No HTTP timing failure or full-suite retry. Focused advice/prelude/reload tests passed (`followup/focused-tests.log`), including exact error/quit identity, owner context/removal, redefinition, compiled private/saved callers, helper recompilation and named callback redefinition. The expected red ordering regression is retained honestly; there were no unexpected failing follow-up verifiers. Earlier implementation failures remain in `logs/advice-test-{1,2}.log` and the original expansion logs.

Follow-up changed files:

| File | Layer / change | Concept contracts / required services |
|---|---|---|
| `tuna/lib/advice.ss` | Library: batch refresh and installed inspection snapshot | None; public kernel facade/Gerbil only |
| `tuna/boot.ss` | Startup: narrow advice refresh import/call at rank boundary | No new contracts/services; existing imports unchanged |
| `tuna/prelude.ss` | Package syntax: reuse live open callback facade | None |
| `tests/integration/reload-test.ss` | Retained reorder/failure regression using existing fixtures | Existing session imports; no new service requirement |
| `tuna/tests/unit/advice-test.ss` | Installed-order snapshot and ordinary callback liveness tests | None; existing test kernel/fixtures |
| `tuna/tests/support/open-functions/recompile.sh` | Compiled named callback liveness proof | Test-only kernel activation |

Follow-up delta: **+112/−15, net +97 lines**. Cumulative stage-2a delta: **8 files, +675/−26, net +649 lines**, including the original build registration and advice-target fixture. No documentation, command/service advice, inspection-command UI, hook or toolchain edits.

## Retained stage-2a contract / remaining gate

`advise!`, `unadvise!`, `function-advice` and `advised-functions` retain their original surfaces. `open-definition` returns the latest **base**, not the effective chain. Ten kinds compose on mutation; lower depth is outermost, then earlier owner declaration, then same-owner name. Filter-args consumes/returns one argument list; filter-return receives every original value and permits any output arity. Conditional predicate positions require exactly one value; selected final returns may have multiple values. Only `#f` is false; after runs only on normal return. Function advice is module-wide, owned and reversible. Replacements do not accumulate receipt inverses; explicit removal leaves two bounded callback-free owner/target receipt notes until deactivation.

**Remaining risk:** real owned around advice still costs about 0.7 µs in the scalar probe; most cost belongs to preserved exception/context guarantees, not redundant forwarding. The existing nullable-return tail-call limit is unchanged. Direct callers that batch `set-plugin-order!` outside configuration must call the explicit library refresh; inspection remains truthful about the installed chain before that call. Stage 2 still needs its separately sequenced inspection command. Recommend parent review of `3086867` and the measured costs before merging.


## Parent acceptance

Merged as `e1c2672`. Parent reviewed placement, public imports, ownership/composition and the retained-owner reorder fix. Independent capped `make test` passed without retry (`followup/parent-make-test.log` in the scratch evidence directory). No kernel changes. The roughly 0.7 µs per advised scalar call is an enabled-advice cost, not an unadvised-call cost; exception/context guarantees were retained. The inspection command and command/service targets remain separate work.
