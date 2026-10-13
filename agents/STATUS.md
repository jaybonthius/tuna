# Status and handoff

Read this first when resuming work. Last updated 2026-10-12. It records where the project stands, what the owner has decided, and what comes next. Keep it current at every milestone boundary.

## Where things stand

- **Architecture skeleton: done** (four stages merged; see `docs/briefs/2026-10-architecture-skeleton.md`, `agents/plans/architecture-skeleton.md`). Working: plugins with receipts and live swaps, the editor thread with `C-g`, the token-protected browser connection, keys, tree buffers with a text node, rope and plain-string text stores, basic editing and undo, minibuffer and `read-string`, `with-settings`, timers, hooks, jobs, HTML and plain-text renderers, one-window and two-window window managers, session and autosave.
- **The skeleton let the kernel drift** (about 1,050 to 1,800 non-test lines). The owner caught latency instrumentation in the kernel's display contract; it was reverted (`380fdc0`). An independent audit (`agents/research/kernel-audit-2026-10-12.md`) and three research lanes (`agents/research/kernel-contract/`) followed.
- **Kernel contract: approved** 2026-10-12 (`docs/briefs/2026-10-kernel-contract.md`), recorded in ADR 12's "Kernel contract" section. **Kernel cleanup: done** 2026-10-12 (all nine steps of `agents/plans/kernel-cleanup.md`, merged through `817f95f` plus the docs merge): the kernel holds only ADR 12's four items, exports 79 names, has 3 permanent forbidden-word exceptions, and `make test` enforces the layer boundaries. Implementer and review reports: `/home/jay/Code/workbench-gerbil/scratch/tuna-kernel-cleanup/`.

## Next, in order

1. **Configuration** (owner request 2026-10-12): brief `docs/briefs/2026-10-configuration.md` decided 2026-10-12 (one `init.ss` with a declarative `use-plugin`; no automatic copying, `tuna init` copies the starter on request, `--config PATH` and `TUNA_CONFIG` choose the file; start-up report to terminal, a log file replaced each start, and Tuna's display when available; a settings screen like `M-x customize` is wanted later (roadmap), and what it saves overrides `init.ss`; configuration is not a kernel feature: start-up code in `main` plus an ordinary configuration plugin); next: a one-page build plan; research in `agents/research/configuration/`. Owner decisions already given: ship a starter configuration (a file the user copies and owns, never a fallback); no stored history such as a last-known-good config; recovery comes from the user's own configuration. Approved to plan and build.
2. **Brief: making buffers replaceable** (audit P1-1: `services/buffers.ss` is the implementation, not a contract), with a toy second buffers provider. Owner approval before work.
3. **Brief: demo out of default startup**, `describe-services` into a help plugin, and the smaller audit items (P2-3, P2-5, P2-7).
3a. **Jobs hardening: done** 2026-10-12 (merged `092e4d3`): cooperative cancellation, spans mapped instead of dropped, result tasks built on the loop thread, stale exact-revision runs cancelled; ADR 3 records the settle-by items (edit results exact-revision only, re-run is the starting plugin's job, inline fast path before syntax highlighting, ordered deltas before out-of-process workers, a yield-point edit test before minibuffer/completion work, empty-span policy before the first diagnostics producer, no CRDT/OT).
4. **Brief: hooks and advice milestone.** Open design question to settle in it: whether the command registry (moved in cleanup step 3 into the keys contract and keys plugin) should become its own small service, since `M-x`, help, advice, and node activation need commands independently of keys, and any other input provider would otherwise have to implement `Keys` to host commands. Command-loop hooks (`pre-command`, `post-command`, ADR 8) in the input plugin; advice on commands (wrap the registry entry), service methods (wrap the provider), and package functions (probably a small macro that wraps the current definition with `set!`; Gerbil needs the name at compile time; runtime lookup through Gambit internals was advised against). Include a spike proving: redefining a command while Tuna runs, advising and un-advising a package function, and plugin deactivation removing its advice. No REPL or `init.ss` loading exists yet; redefinition was verified only in a one-off experiment (`(declare (separate))` makes `set!` reach a module's own calls; the prelude emits it).
5. **Profiler plugin** (`docs/briefs/2026-10-profiler.md`): optional, outside the core, built on general hooks, advice, and sampling. Since cleanup step 5 the kernel cannot announce job events: job started/finished must come from hooks that `tuna/lib/jobs.ss` defines with `new-hook` (the kernel sees only the `job-result` task through `task-started-hook`/`task-finished-hook`); `docs/diagrams/profiler.d2` and the brief's kernel row are out of date on this point. Decided: sampling may use Gambit `##` primitives with a loud test; build after the hooks and advice milestone. Decided 2026-10-12: reports appear in a `*profile*` buffer. Split it into two plugins: the profiler (measurement; needs only hooks, advice and sampling) and the profile report (needs the buffers contract), so measurement works even without buffers. Both depend on contracts, never on a particular plugin.
6. Then the roadmap's feature milestones (commands and completion, or files), and the layout-facts research before windows and scrolling.

## Owner decisions and preferences (do not relitigate)

- Everything is a plugin; the kernel is scaffolding only (ADR 12 and its contract). Tuna's own plugins get no privileged access.
- No arbitrary limits such as line-count caps. Make every kernel addition deliberate and justified instead.
- Buffer positions are 1-based. Ordinary browser tabs are first-class; reserved keys are simply rebound. Layout belongs to the browser; mixed monospace and proportional text must be possible (no cell grid).
- Buttons and clickable UI resolve through node keymaps via the input plugin; the client never names a command. Hooks stay in the kernel.
- Window management is a replaceable plugin; the default is the owner's recursive layout tree (ADR 11, `docs/ideas/window-management.md`).
- Divergence from Emacs is welcome when better, but must be recorded in an ADR and `docs/emacs-equivalents.md`.
- Owner-facing documents follow AGENTS.md "Documents for the owner": briefs before architecture work, plain language, rendered and checked D2 diagrams, a walkthrough, a code sample, decisions with recommendations, new terms.
- Delegate substantial implementation to agents in their own worktrees (`tuna__<task>`), merge locally with `--no-ff`, never push. The owner talks only to the primary agent.
- Commit work as it lands; the owner wants things committed.
- Tuna has no "standard" setup (2026-10-12). The plugins in this repository are ordinary plugins; users need not use any of them and may use completely different keybindings and input models. Recovery from a broken configuration comes from the user's own configuration (skip only what fails, or return to the last known-good one), never from a built-in default plugin set; the exact design is being researched for the configuration brief.
- No magic (2026-10-12): Tuna never creates, copies or edits the user's configuration on its own; explicit commands only.

## Lessons recorded from this attempt

- Task briefs named what to build but not where; reviews checked tests, not placement; agents' reports of kernel additions were accepted. AGENTS.md "Keep the kernel small" now requires naming the owning layer in every task and checking placement at every merge.
- Demo features (the digit highlighter, latency counter) shaped general layers. The same pattern sank earlier attempts (`agents/research/editor-corpus/prior-attempts-audit.md`, `agents/research/profiling/racket-profiler-extraction-research.md`).

## Loose ends

- An old `tuna` build may still be running on port 8001 from the primary checkout; it predates stage 4's merge. Restarting with `make run` uses the real `~/.local/state/tuna/`.
- `.vscode/` is untracked and was left alone on purpose.
- `TODO.md` lists upstream Gerbil/Gambit issues and Tuna follow-ups.
