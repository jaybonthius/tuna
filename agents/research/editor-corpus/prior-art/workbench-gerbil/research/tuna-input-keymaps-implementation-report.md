# Tuna input keymaps implementation report

## Outcome

The current uncommitted Tuna input-keymap implementation satisfies the owner-approved contract at `/home/jay/Code/workbench-gerbil/plans/tuna-input-keymaps/spec.md`. This corrected report supersedes the prior implementation report.

Approval gates verified before editing:

- Plan status: `Status: owner-approved`.
- Read-only Oracle approval: `/home/jay/Code/workbench-gerbil/research/tuna-input-keymaps-modifiers-oracle-review.md` — **APPROVED**.
- Owner approval: explicit conversation statement, “this is approved! go ahead and begin implementing”.
- No ticket was selected; the exact absolute approved plan path is the complete contract.

The post-review **Important** benchmark defect reported in `/home/jay/Code/workbench-gerbil/research/tuna-input-keymaps-architecture-review.md` is corrected. No production API, resolver, runtime, ordinary test, documentation, build, or matrix-harness behavior was changed in this correction.

## Review-driven benchmark correction

`/home/jay/Code/workbench-gerbil/tuna/tuna/test/keymap-benchmark.ss:45-133` now has an explicit prepared workload:

- `prepare-workload` constructs the representative map and all its bindings, all exact/absent/continuation/undefined query sequences, the higher-precedence binding and map, and both ordered-map lists.
- The complete setup is measured by the separate construction timer.
- Workload fields are extracted before the lookup garbage collection.
- Only then does the benchmark collect garbage and enter the timed lookup call.
- `checked-lookups` performs repeated calls to the public `resolve-key-sequence` interface, deterministic public-result checks, and checksum consumption. It does not construct maps, bindings, query sequences, or ordered-map lists.

This directly resolves the architecture review’s setup-contamination finding and makes the reported lookup timing/allocation figures resolver-lookup measurements rather than mixed setup-and-lookup measurements.

## Delivered implementation

### `:tuna/lib/keymap`

The implementation provides the approved public API for opaque key strokes, key sequences, transition bindings, immutable-by-contract keymaps, and exact/continuation/undefined/absent resolution. It includes canonical modifiers ordered `(control meta shift super hyper alt)`, defensive modifier publication, logical stroke/sequence equality, checked sequence access, defensive entry handling, constructor validation, and a private sorted-vector backing with binary lower-bound lookup.

### `:tuna/lib/runtime`

The implementation adds exactly the approved read-only outcome observers:

- `state-changed?`
- `state-unchanged?`
- `state-changed-value`
- `state-outcome-result`

Runtime request handling, transition invocation, state installation, lifecycle, root ownership, and installation authority remain unchanged.

### Scope boundary

No command domain, runtime input request, production dispatcher, root envelope, command registry, key-string parser, declaration macro, translation, remapping, browser mapping, trie, or public installation capability was added. Dispatcher and argument-acquisition behavior remain application/test-local.

## Current uncommitted implementation paths

Within `/home/jay/Code/workbench-gerbil/tuna`:

- `tuna/lib/keymap.ss`
- `tuna/lib/runtime.ss`
- `tuna/test/keymap-test.ss`
- `tuna/test/state-outcome-test.ss`
- `tuna/test/input-dispatch-test.ss`
- `tuna/test/keymap-benchmark.ss`
- `tuna/test/run-keymap-benchmark-matrix.sh`
- `tuna/test/command-runtime-suite-main.ss`
- `tuna/test/run-command-runtime-matrix.sh`
- `tuna/build.ss`
- `tuna/README.md`

This correction modified only:

- `/home/jay/Code/workbench-gerbil/tuna/tuna/test/keymap-benchmark.ss`
- `/home/jay/Code/workbench-gerbil/research/tuna-input-keymaps-implementation-report.md`

## Test and benchmark coverage

The existing public resolver tests cover modifier normalization and alias safety, sequence behavior and bounds, binding validation, malformed/duplicate/prefix-conflicting map rejection, caller collection mutation, all four resolution variants, and layered precedence.

The existing public runtime/dispatcher coverage exercises outcome observers, continuation and terminal behavior, original-root acquisition, argument propagation, target outcome propagation, dequeue-time maps, live target replacement, per-runtime maps, undefined/absent behavior, rollback on all approved failure modes, later recovery, and single-installation behavior.

The corrected benchmark deterministically checks exact, absent, continuation, undefined, and layered-precedence resolution for map sizes 16, 64, and 256; sequence lengths 2, 3, and 4; and 5,000 iterations per combination.

## Validation and observed results

### Corrected benchmark matrix

Command:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna && test/run-keymap-benchmark-matrix.sh
```

Result: passed under source `gxi`, normal `gxc`, and `gxc -O`. Construction and lookup were reported separately after the review-driven setup separation.

Observed construction ranges:

| Mode | Construction real time | Allocated bytes |
|---|---:|---:|
| source `gxi` | 0.000192–0.002677 s | 394,272–9,218,544 |
| normal `gxc` | 0.000042–0.000594 s | 116,352–2,496,592 |
| `gxc -O` | 0.000007–0.000093 s | 17,520–359,296 |

Observed lookup ranges for 5,000 checked iterations:

| Mode | Lookup real time | Allocated bytes |
|---|---:|---:|
| source `gxi` | 0.241943–0.430429 s | 465,041,888–806,482,016 |
| normal `gxc` | 0.023792–0.036585 s | 17,920,304–17,920,384 |
| `gxc -O` | 0.003628–0.005646 s | 2,800,064 |

No speculative pass threshold was applied.

### Build and full runtime matrix

Commands:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna && gerbil build
cd /home/jay/Code/workbench-gerbil/tuna/tuna && test/run-command-runtime-matrix.sh
```

Results:

- Package build passed; the existing `std/net/request` deprecation warning remained non-blocking.
- Source `gxi`: pass.
- Normal `gxc`: pass.
- `gxc -O`: pass.
- Matrix harness: `worktree status: unchanged`.

### Diff, status, and staging checks

Commands:

```sh
git -C /home/jay/Code/workbench-gerbil/tuna diff --check
git -C /home/jay/Code/workbench-gerbil/tuna status --short --untracked-files=all
git -C /home/jay/Code/workbench-gerbil/tuna diff --cached --name-only
git -C /home/jay/Code/workbench-gerbil status --short --untracked-files=all
git -C /home/jay/Code/workbench-gerbil diff --cached --name-only
```

Results:

- `git diff --check` passed with no whitespace errors.
- Tuna status before and after validation was identical: the same five tracked modifications and six intended untracked implementation paths listed above; no generated or unexpected Tuna path appeared.
- The Tuna and outer checkout staged-file queries were empty.
- No file was staged or committed, and no mutating Git command was run.

## Findings and residual risks

- **Resolved — Important:** `/home/jay/Code/workbench-gerbil/tuna/tuna/test/keymap-benchmark.ss:45-133` previously included setup in lookup measurements. All maps, bindings, query sequences, and ordered-map lists are now prepared before lookup garbage collection and timing.
- **No Blockers:** build, full three-mode runtime validation, and the corrected three-mode benchmark matrix passed.
- Gerbil transitive immutability remains contractual rather than enforced.
- The synthetic benchmark uses distinct first strokes and does not characterize heavily shared prefixes or establish a product performance budget.
- Source-mode allocation remains materially higher than compiled modes; no optimization change is justified without a representative product budget.
- Host/browser normalization, capture behavior, Input Method Editor behavior, accessibility, and external-effect rollback remain explicitly out of scope.

Conventional Commit suggestion: `test(keymap): isolate benchmark lookup timing`

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Resolved the Important setup-contamination finding at /home/jay/Code/workbench-gerbil/tuna/tuna/test/keymap-benchmark.ss:45-133; source gxi, normal gxc, and gxc -O benchmark and runtime matrices passed."
    }
  ],
  "changedFiles": [
    "tuna/tuna/test/keymap-benchmark.ss",
    "research/tuna-input-keymaps-implementation-report.md"
  ],
  "testsAddedOrUpdated": [
    "tuna/tuna/test/keymap-benchmark.ss"
  ],
  "commandsRun": [
    {
      "command": "cd /home/jay/Code/workbench-gerbil/tuna/tuna && test/run-keymap-benchmark-matrix.sh",
      "result": "passed",
      "summary": "Corrected checked benchmark passed under source gxi, normal gxc, and gxc -O for all 9 size/length combinations."
    },
    {
      "command": "cd /home/jay/Code/workbench-gerbil/tuna/tuna && gerbil build",
      "result": "passed",
      "summary": "Normal package build passed; only the established non-blocking std/net/request deprecation warning appeared."
    },
    {
      "command": "cd /home/jay/Code/workbench-gerbil/tuna/tuna && test/run-command-runtime-matrix.sh",
      "result": "passed",
      "summary": "Source gxi, normal gxc, and gxc -O suites passed; harness reported worktree status unchanged."
    },
    {
      "command": "git -C /home/jay/Code/workbench-gerbil/tuna diff --check",
      "result": "passed",
      "summary": "No whitespace errors."
    },
    {
      "command": "git -C /home/jay/Code/workbench-gerbil/tuna status --short --untracked-files=all; git -C /home/jay/Code/workbench-gerbil/tuna diff --cached --name-only",
      "result": "passed",
      "summary": "Before/after Tuna status matched exactly and the staged-file query was empty."
    },
    {
      "command": "git -C /home/jay/Code/workbench-gerbil status --short --untracked-files=all; git -C /home/jay/Code/workbench-gerbil diff --cached --name-only",
      "result": "passed",
      "summary": "Outer checkout was inspected and its staged-file query was empty; pre-existing unrelated untracked content was not modified."
    }
  ],
  "validationOutput": [
    "Benchmark matrix: source gxi pass; normal gxc pass; gxc -O pass.",
    "Corrected lookup ranges: gxi 0.241943-0.430429 s and 465,041,888-806,482,016 bytes; gxc 0.023792-0.036585 s and 17,920,304-17,920,384 bytes; gxc -O 0.003628-0.005646 s and 2,800,064 bytes.",
    "Package build passed.",
    "Runtime matrix: gxi pass; gxc pass; gxc -O pass; worktree status unchanged.",
    "git diff --check passed; Tuna before/after status matched; no staged files."
  ],
  "residualRisks": [
    "Gerbil transitive immutability remains contractual rather than enforced.",
    "The synthetic benchmark does not characterize heavily shared-prefix workloads or define a product performance budget.",
    "Host/browser behavior and external-effect rollback remain explicitly out of scope."
  ],
  "noStagedFiles": true,
  "diffSummary": "Moved all benchmark workload construction into separately timed preparation before lookup garbage collection; the timed lookup function now performs only public resolution calls, deterministic result checks, and checksum consumption.",
  "reviewFindings": [
    "resolved Important: tuna/tuna/test/keymap-benchmark.ss:45-133 - construction/setup no longer contaminates lookup timing",
    "no blockers"
  ],
  "manualNotes": "No ticket was selected. No production API, resolver, runtime, ordinary tests, documentation, or harness scope changed. No mutating Git command, staging, or commit was performed."
}
```
