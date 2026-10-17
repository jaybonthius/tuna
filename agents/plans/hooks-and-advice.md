# Plan: hooks and advice

Owner-approved brief: [`docs/briefs/2026-10-hooks-and-advice.md`](../../docs/briefs/2026-10-hooks-and-advice.md) (2026-10-15). Evidence: [`agents/research/hooks-advice/`](../research/hooks-advice/).

**Done (2026-10-16).**

## What was built

1. **Open functions** (merged `3c64f87`): top-level `def`/`def*` in Tuna-prelude modules are open; `def/closed`, `redefine`, private functions through module-context evaluation. Evidence: `stage-1.md`.
2. **Function advice and `describe-advice`** (merged `e1c2672`, `e7deaad`): ten kinds, owner cleanup, redefinition under advice, ordering by depth then `init.ss` order. Evidence: `stage-2a.md`, `stage-2b.md`. Owned around-advice costs about 0.7 µs per call (error attribution and context restoration); unadvised calls are unchanged.
3. **Rework after the audit** (owner-approved 2026-10-16). A first implementation of the remaining stages (`5aaf7fc` through `643e25d`) added a parallel service-interface system to the kernel, changed every contract, and made the prelude look up a macro from the commands contract at each use site. `4a324ed` restored the stage-2 tree; the rest was redone smaller:
   - One `advice-target` type in `tuna/lib/advice.ss`; `advise!` takes an open function, `(function module name)`, or any expression yielding a target. The commands contract adds `command-target`; the commands plugin composes advice over the current definition and caches it.
   - Hook fixes: a failed callback releases its receipt note; equal-depth ties follow the owners' declaration order (kernel +9 lines).
   - The `hungry-delete` demo (`C-c h` toggles it in the demo).
   - Service-operation advice is deferred to the profiler milestone.

## Not in this plan

`eval-defun`/`C-M-x` and `M-:` (REPL milestone); service-operation advice and per-callback hook timing (profiler); hooks that stop at the first answer; per-buffer hooks; the Gerbil `(Maybe T)` tail-call issue (`TODO.md`).
