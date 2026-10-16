# Plan: hooks and advice

Owner-approved brief: [`docs/briefs/2026-10-hooks-and-advice.md`](../../docs/briefs/2026-10-hooks-and-advice.md) (2026-10-15): open functions by default, one `advise!` with function, command and service targets, `redefine`, `describe-advice`, three hook fixes. Evidence: [`agents/research/hooks-advice/`](../research/hooks-advice/) (Emacs, prior art, Gerbil audit, spikes 1–3). Spike code: commit `7d2c5ed` (open-function prelude) and `17eccc1` (private-function probes) on branch `open-def-spike`. Read it; never merge it.

**Complete (2026-10-16).** All four stages are merged locally through source endpoint `f5a3cc5`. Combined capped `make deps test`: 50 Gerbil modules and 12 frontend tests pass. The isolated browser proved hungry deletion, one Undo, plain deletion with the plugin off, re-enable and inspection with owner/source. Final evidence/limits: `agents/research/hooks-advice/stage-4.md`. The owner requested later Opus review, not a gate; no further implementation is authorized by this completed plan.

## Invariants (every stage)

- **No hacks (owner rule).** Documented Gerbil only: macros, the prelude, `identifier-rules`, `stx-identifier`, the read-only `module-context?` check, and module-context evaluation as `enter!` does it (`import-module` and `current-expander-context`, then `eval`). No `##` primitives, no reading or changing expander or module internals, no mutation of compiler-generated names. If something needs more, stop and report.
- **Fallback (owner, 2026-10-15):** if open-by-default turns out complicated or hacky, or starts breaking Gerbil idioms, stop and report. The owner may switch to option (a).
- Kernel changes only where the brief names them (the service advised view, the hook fixes), each reported with its line delta. ADR 12 is amended in the same merge.
- `make test` green under the memory cap. Each stage reports the measurements its brief claims depend on. The final stage is checked in a real browser on an isolated run.
- Implementation by `openai-codex/gpt-6.1-sol` in its own worktree per stage; review, merge and owner report by the primary agent.

## Stages

1. **Open functions. Done (2026-10-15), merged `3c64f87`.** Parent `make test` passed. Evidence: `agents/research/hooks-advice/stage-1.md`. Clean build +10.4%; controlled pairs measured +0.95 µs/self-insert and +0.34 µs/movement key, not zero overhead; unchanged-redraw ranges overlap. These costs are below the prior spike's accepted key overhead. Go-to-definition remains unverified because the available language server cannot build; no tool changes. Implemented scope:
   - Read an open function's current definition through a plain mechanism, not marker tokens passed through the function's name (spike-2 `install-query`/`definition-query`).
   - Cover `def*` and any other `def`-like core forms used in packages, or record why one stays closed.
   - Shrink interface (`.ssi`) growth: re-export the core prelude as one entry instead of enumerating it.
   - `def/closed`; `redefine` (keeps advice once stage 2 exists); `rope-for-each-chunk` and `rope-line-count` become `def/closed`.
   - Tooling check: backtraces, `describe-function`-style lookups, and go-to-definition in `gerbil-lsp` (`/home/jay/Code/workbench-gerbil/gerbil-lsp`) on an open function. Report what breaks; fixing tools is out of scope.
   - Tests: callers in the same module and in other modules see `redefine`; a private function redefined through its module context; tail calls in a 10-million-step loop; recompiling one module keeps its compiled callers working.
   - Measure against `main`: clean build, `make test`, the 5k and 50k redraw cases, ms per key. Target: build at most +16%, the rest within noise.
2. **Done (2026-10-15): library `e1c2672`, inspection command `e7deaad`.** `advice-help` adds `M-x describe-advice` through public commands/completion/help contracts; six behavior tests and independent parent `make test` pass. Evidence: `agents/research/hooks-advice/stage-2b.md`. Evidence: `agents/research/hooks-advice/stage-2a.md`. Parent review and capped `make test` passed; kernel delta zero. Actual owned around-advice costs about 0.7 µs/scalar call with exception/context guarantees retained; unadvised path unchanged. Retained-owner reorder is regression-tested through configuration reload. Library/prelude and inspection UI were separate bounded tasks:
   - One composition model for the ten kinds. Combine when advice changes, not per call.
   - Owner, name, kind, depth. Same owner and name replaces. Order by depth, then the owners' `init.ss` order. Removal goes through the owner's receipt.
   - `redefine` while advised keeps the advice. Removing the last piece reveals the newest definition.
   - `advise!` with an imported name or `(function module name)`, private functions included. Named-function advice follows the shared module definition, like `redefine` and Emacs's `advice-add`; ownership controls removal, not per-editor copies. No runtime-membership API or scope-dispatch layer. See `agents/research/hooks-advice/advice-scope.md`.
   - Errors propagate with the advice and its owner named.
   - `describe-advice` command and its query.
   - Tests for each kind, stacking and ordering, a reload not reordering, owner removal, redefinition under advice.
3. **Done (2026-10-16): command and service targets, including inspection. Shared seam `af16541`, commands `df25f44`.** Command proof, cleanup correction and measured unadvised +1.60% (noise versus small real cost unresolved): `agents/research/hooks-advice/stage-3b.md`. Complete-interface declaration/wrapper producer merged `e7a39d0`; proof/API: `agents/research/hooks-advice/stage-3c1.md`. It preserves richer interfaces and distinct qualified implementations. Provider registration/cache merged `50d457a`; API/proof: `agents/research/hooks-advice/stage-3c2.md`. Library service advice/routing merged `f6c6f58`; proof/query API: `agents/research/hooks-advice/stage-3c3.md`. All targets work; inspector integration is merged as `d9e61a3`. Shared API, routing hygiene fix and independent parent test: `agents/research/hooks-advice/stage-3a.md`. Source-backed seam note: `agents/research/hooks-advice/target-seams.md` (proposals, not authority). Implementation proceeded serially through shared target state/routing, command registry, service declarations/cache/library, and inspector integration; contract conversions did not overlap commands work. Preserve the approved one-form surface and boundary rules; no kernel identity query or undocumented interface reflection.
   - `(command name)`: the commands plugin keeps a command's advice; keys and `call-command` run the combined command; turning off the command's own plugin and back on keeps other owners' advice.
   - `(service svc operation)`: the kernel's advised view of a provider, handed out while advice exists; advice is not a provider and restarts nothing; it survives a provider swap. Amend ADR 12.
   - When function and service advice both apply, service advice is outermost.
   - Measure: an unadvised command or service call costs what it does today.
4. **Done (2026-10-16): hook fixes `4c039f9`, hungry-delete demo `f5a3cc5`, final records/diagrams.** Browser walkthrough, full combined tests and the overview's executable plugin example pass. Kernel source delta: hooks net +9; whole effort net +288. See stage-4 evidence.
   - Hooks: a callback removed for failing takes its receipt note with it; equal-depth ties go by the owners' `init.ss` order (closes the `TODO.md` item).
   - Records: amend ADR 1 (open by default, the closed kernel, module-context evaluation) and ADR 2 (advice ownership, ordering, error policy). Update `docs/emacs-equivalents.md` (advice, `defsubst` ↔ `def/closed`, `add-function` ↔ service advice, the hook divergences), `docs/overview.md` and its diagrams, `TODO.md`, and the roadmap.
   - Demo: a `hungry-delete` plugin in `demo/init.ss` advising `delete-backward-char`; in the browser, Backspace deletes runs of spaces and `M-x describe-advice` shows the advice; turning the plugin off restores plain Backspace.

## Not in this plan

`eval-defun`/`C-M-x` and `M-:` commands (REPL milestone; this plan provides `redefine` and module-context evaluation they will use); the profiler and per-callback hook timing; hooks that stop at the first answer; per-buffer hooks; the Gerbil `(Maybe T)` tail-call issue (`TODO.md`).
