# Command advice

Merged as `df25f44` (2026-10-15), containing `cd8d9ce` and cleanup fix `54cb20c`. Parent reviewed production placement/code and independently ran capped `make test`; it passed without retry (44 Gerbil modules, 12 frontend tests and demo configuration check). Kernel delta zero; production net +99 lines.

## Behavior and API

The commands registry owns advice by name, independently of removable definitions. Advice can precede a definition and survives its owner's removal/re-enable. Mutation rebuilds every live/shadowed definition from its saved base, preserving entry provenance and command metadata; `invoke!` is unchanged. The command owner's task envelope now surrounds the entire combined command, so stopping that owner cancels waits inside another owner's advice. Hooks/activation identity remain outside; self-retirement still ends quietly.

The Commands contract exports canonical `command-advice-target` with the stage-3a keyword protocol, backed by `Commands-add-advice!`, `Commands-remove-advice!`, `Commands-inspect-advice`, plus `Commands-advised-commands` and public `(advised-commands)`. The existing prelude forms now work for `(command NAME)`. Target source is #f because a registry name has no permanent declaration; use `command-entry` for the current declaration. The inspector still lists functions only until its later integration task.

## Cleanup correction

Parent's absent-name probe found receipt growth 0→2→4 across identical add/remove cycles: pruning an empty chain discarded state still owned by pending cleanup notes. The narrow `advice-state-has-owners?` library query now keeps that state until its final owner cleans up. Three-cycle regressions against both providers hold at two notes, then zero after deactivation; inspection-only and invalid names are not cached. Independent parent recheck observed 0→2→2. No new kernel API or broad growth harness.

## Evidence and limits

Focused proofs cover ten shared kinds, order/rank refresh, replacement, two-owner cleanup, definitions/absence/shadowing, metadata, separate registries, named callback liveness, error attribution, compiled routing hygiene, nested hooks/identity, quiet self-restart and cancellation inside advice. Full worker report and failed-attempt history: `/home/jay/Code/workbench-gerbil/scratch/hooks-advice-stage3/commands-report.md`. Parent logs: `parent-commands-make-test.log` and `parent-command-receipt-{probe,fixed}.log` in that directory.

Seven sequential before/after real-task samples measured unadvised command medians 1499.80→1523.77ns (+1.60%). This does not distinguish noise from a small real cost; zero overhead is not established. The pruning correction changes no warm-call code.

Code inspection shows a separate lifetime limit: an unchecked/session registering owner that outlives Commands can retain its old registry through pending advice cleanup until that owner ends. Required advisors normally deactivate with Commands. This is not the fixed repeated add/remove leak; no provider-retirement or kernel receipt changes were made. Replacing Commands creates a fresh registry, not transferred advice.

Service work must preserve the new Commands signatures and reuse shared state/composition. Service views must also preserve richer provider interfaces (Keys extends Input; EchoArea extends Messages), not just wrap the slot's base interface. The earlier seam proposal needs that preservation check before implementation.
