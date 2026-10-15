# Spike 3: private open functions through a module context

**Verdict: yes, idiomatically.** Tuna can redefine and advise compiled modules' **private** open functions using the documented `enter!` mechanism: parameterize `current-expander-context` with `(import-module module #f #t)`, then ordinary `eval`. Compiled callers observe replacements; new bodies resolve private helpers normally. No private expander access, `##` primitives, generated-name mutation, or prelude changes were needed. Eval-defun should rewrite procedure `def` to explicit `redefine`: plain `def` in this context errors with the spike-2 prelude. This verification is throwaway, never for merging.

## 1. Interactive redefinition

Three libraries were syntax-checked, compiled with `gxc -O -s`, and imported as `:private-target`, `:private-caller`, and `:module-eval`. Runtime ran in an empty directory with compiled library directories on its load path. A separate session evaluator imported `:tuna/config` and evaluated a helper call; the helper entered the defining context only around `eval`:

```scheme
(parameterize ((current-expander-context (import-module module #f #t)))
  (eval form))
;; Evaluated in that context:
(defrule (redefine (name . args) body ...)
  (install-open! name (lambda args body ...)))
(redefine (secret (n : :fixnum)) => :fixnum (fx+ (helper n) 10))
```

Neither `secret` nor `helper` is exported; the session cannot reference `secret` directly. Compiled same-module and second-module callers through the exported operation changed **4/5 → 14/15**. The session's expander context was restored afterward.

## 2. Advice and undo

A separately compiled helper accepts module name, function symbol, and wrapper constructor. It evaluates `(open-definition secret)` and an installer lambda inside the target context, then constructs and installs the wrapper from outside. Callers changed **14/15 → 28/29 → 14/15** after undo: restoration used the **latest interactive definition**, not the source's 4/5. This tests one wrapper; redefinition *while wrapped*, stacking, ownership, and automatic cleanup remain outside scope.

The real compiled layout plugin also passed without source changes or starting Tuna: its compiled `render-fit → container-attributes → container-element-id` chain produced **container-7 → edited-7 → wrapped-edited-7 → edited-7**. Its private `fit-kind` retained identity.

## 3. Plain `def`

Procedure `def` raised **“Bad binding; rebind conflict”** for typed and untyped open targets. It neither replaced nor shadowed them; compiled callers stayed unchanged. Explicit `redefine` still worked after the failed expansion. **Rewrite eval-defun's procedure `def` to `redefine` for an existing open binding; do not rely on the prelude.** Spike 2's session-local shadowing occurred in a different context.

## 4. Loading, repetition, cost, threads

Compiled `.ssi` metadata supplies private bindings to the defining context, although normal imports expose only exports. Across 1,000 repeated lookups/evaluations, context identity and the private state token stayed identical, the counter reached 1,000, and initialization appeared **once** in the runtime log. This does not reload or duplicate state.

Five warm CPU-0 samples, 1,000 trivial-helper evaluations each: **351 µs/eval median** including lookup (344–356); cached context **347 µs** (346–350). These measure expansion/evaluation, not function-call overhead. Concurrency was not stress-tested. Parameterization scopes context selection, not the shared mutable syntax context or open-function cells: serialize edits/advice on Tuna's editor thread.

## 5. Documentation and verdict on hacks

Primary references, read-only checkout `1c6c15385979f0092574fbc2b828f3fb656319b3`: [shell guide, `enter!`](/home/jay/Code/workbench-gerbil/gerbil/doc/guide/shell.md#enter): “Starts a repl using the syntactic context of a given module”; [`src/std/interactive.ss:83–85`](/home/jay/Code/workbench-gerbil/gerbil/src/std/interactive.ss) uses exactly the expression above. The [expander reference](/home/jay/Code/workbench-gerbil/gerbil/doc/reference/gerbil/expander/README.md) lists both APIs, but their entries are placeholders. This is **verified compiled-module behavior supporting the documented shell mechanism**, not an undocumented namespace hack or a claim that the sparse reference guarantees every detail.

Evidence: commit `17eccc1` on `open-def-spike`; `sh spike/open-def/run-private-probes.sh` → **PRIVATE-PROBES-PASS**; logs: `spike3/` beside this report. Gerbil `v0.19-dev-63-g1cfb032c`, Gambit `v4.9.8-19-gea114fc3`. Every Gerbil process ran under 4 GiB, zero swap, and a 2,400-second timeout; none remain from this spike. No production source, installation, or other checkout changed.
