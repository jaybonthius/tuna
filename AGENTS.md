# AGENTS.md

## Orientation

- **Start with `agents/STATUS.md`**: current state, owner decisions, and the ordered next steps.
- `docs/` is for the owner (Jay); `agents/` is for agents. If the owner is expected to read it, it belongs in `docs/`; if it exists so an agent gets things right, it belongs in `agents/`.
- Architecture decisions are in `agents/adr/`; read the relevant ones before designing or changing a subsystem. They override everything in `agents/research/`.
- `docs/overview.md` explains the architecture in plain language; `docs/roadmap.md` names the current milestone; `docs/ideas/` describes desired features that are not yet scheduled in detail.
- `docs/emacs-equivalents.md` maps Tuna concepts to Emacs. Divergence from Emacs is welcome when it is an improvement, but every divergence must be recorded both there and in an ADR. When you introduce a concept with an Emacs counterpart, add it to the equivalents table.
- Before designing a subsystem, check `agents/research/capability-audit/` for the Emacs capabilities and packages it must eventually support.
- Datastar documentation is vendored in `agents/reference/datastar/`.
- `agents/research/README.md` indexes prior research from earlier attempts. Treat it as evidence, not as decisions, and re-verify version-sensitive Gerbil claims.
- The previous attempt is preserved at `/home/jay/Code/workbench-gerbil/tuna-old-2026-10` (including `stash@{0}`). Do not copy its customization macros, application-state framework, or buffer spec back in.

## Documents for the owner

The owner must understand the architecture and every plan. Earlier attempts failed partly because he did not.

- **Before any effort that touches architecture**, write a brief in `docs/briefs/YYYY-MM-name.md` and get the owner's approval before writing ADRs or code. A brief is one or two screens: (1) what we're building and why, with no jargon; (2) one or two diagrams; (3) a walkthrough of one concrete scenario through the diagram; (4) a small code sample from a package author's point of view; (5) decisions for the owner, each with context, options, a recommendation, and why (ideally none); (6) definitions of new terms only.
- **After the work lands**, update `docs/overview.md` and its diagrams to match what was actually built. Briefs are historical; the overview is current.
- **Update the docs as each stage merges, not in a wave at the end** (owner, 2026-10-23): the merging agent updates the overview, `docs/emacs-equivalents.md` (rows and divergences), affected ADRs, the roadmap, and the brief's and plan's status for what that stage built, in the same change or right after it.
- **Diagrams** are D2 (use the `d2-diagrams` skill), stored as `.d2` source plus rendered `.svg` in `docs/diagrams/`. One question per diagram; at most about ten boxes, otherwise split into an overview and zoom-ins; plain-English labels, not identifiers; flows follow a concrete numbered example; every diagram, or its caption in the document, marks what exists today versus what is planned, in text, not by color alone. Use the same terms as `docs/overview.md`'s glossary. Render, then look at the result before linking it.
- Write plainly: short sentences, define acronyms, name concrete things, and explain why before how.

## How to work

- `tuna/` is Tuna itself (kernel, libraries, start-up program, `init.ss` language) and imports no concept or plugin. Each concept is a package `plugins/<concept>/` with `contract.ss`, its default `plugin.ss`, private files and `tests/{unit,integration,support}`; cross-plugin tests and shared fixtures live in `tests/integration/` and `tests/support/`; demos live in `demo/`; `starter/init.ss` declares only real plugins. Plugin bindings have no `-plugin` suffix.
- Build working vertical slices. Every milestone must run in the browser; specify interfaces and invariants, not the internals behind them.
- Keep plans to a page, in `agents/plans/`. Write an ADR only for a hard-to-reverse choice with real alternatives.
- Do not add review, oracle, or acceptance-report loops unless the owner asks. Validate with tests and by running the program.
- Prefer deleting an abstraction to defending it. Add a framework only when a second concrete user needs it.
- **No backward compatibility, ever, until the owner says Tuna is in use.** There is no old code, no old data, and no users. Never keep forwarders, aliases, re-exports, deprecated names, migrations, or fallbacks for earlier versions of Tuna's own code or saved state. When something moves or is renamed, update every caller in the same change and delete the old name.

## Keep boundaries clean

- A plugin imports only Tuna's public modules (kernel facade, libraries, configuration), other packages' `contract.ss`, and its own files; never another package's plugin or private files. No two packages import each other.
- A contract imports only the kernel facade, libraries, and the contracts its own vocabulary needs. It never re-exports another module. Dependencies between contracts point one way, with no cycles: if two contracts need each other, a concept is in the wrong one.
- A plugin declares in `requires:` every service it calls. Use what you were handed (a session, a prompt handle) instead of reaching for another service's global "current" state.
- Put each hook, record, and operation in the contract whose concept it is, not in whichever module was convenient.
- Every merge review lists, for each changed module, which contracts it imports and which services it requires, and checks them against these rules. `make test` checks the mechanical parts.

## Keep the kernel small

This is the project's central rule (ADR 12). The kernel is only the plugin runtime, the execution rules, and shared vocabulary; it contains no features. Every feature, policy, measurement, demo, and test aid lives in a plugin, and each plugin does one job.

- Before adding anything to `tuna/kernel/` or changing a kernel interface, ask: could a plugin own this, given a general-purpose hook or service? If yes, it goes in a plugin. A kernel interface must never be shaped around one consumer (for example, passing data to the display "so it can measure latency").
- Default plugins do one job. Diagnostics, profiling, logging, and demos never live inside the transport, renderer, buffers, or other default plugins; they observe them through hooks, advice, or services.
- Before designing a subsystem, search `agents/research/` for earlier attempts; several mistakes have already been made once (the Racket attempt entangled its profiler in the core; see `agents/research/profiling/racket-profiler-extraction-research.md`).
- **Every merge review checks placement, not only tests:** for each new or changed module, which layer owns it (kernel, service contract, which plugin), whether the kernel grew, and whether any contract serves a single consumer. Task briefs for implementers name the plugin that owns each piece of work.

## Delegation and worktrees

The owner talks to one primary agent in this checkout (`/home/jay/Code/workbench-gerbil/tuna`, branch `main`).

- **Delegate substantial implementation.** When a stage or task is large enough to be worth handing off, the primary agent writes a bounded task (scope, relevant ADRs and plan, acceptance checks) and gives it to an implementing agent, then reviews the result and reports to the owner.
- **Implementers work in their own worktree, never in the primary checkout.** Create one per task with `git worktree add /home/jay/Code/workbench-gerbil/tuna__<task> -b <task>` from a clean `main`, and run the implementer with that directory as its working directory. Each worktree has exactly one writer. The implementer runs `make deps` there, commits its work on the task branch with the repository's commit-message rules, and reports what it validated.
- **Merge when complete.** The primary agent reviews the branch, runs the tests in the worktree, merges it into `main` locally (`git merge --no-ff <task>` from the primary checkout), then removes the worktree and branch. Never push.
- Read-only research or review agents may run in parallel anywhere; they write only to the output path they are given.
- Small changes, documentation, and planning are done directly in the primary checkout.

## Gerbil

- Read `agents/guides/gerbil.md` before writing Gerbil. It covers the required editing protocol (Gerbil MCP balance and syntax checks around every edit), which MCP tools to use when, coding conventions, performance rules, and tests.
- Core modules use `prelude: :gerbil/core`, typed signatures, and `:std/interface` for replaceable services.
- Use the `gerbil-reference` skill before relying on an unfamiliar API, the `emacs-reference` skill for Emacs behavior, and the `datastar-guidance` skill for browser transport.

## Commands

Agents run every build, test and Gerbil process under a hard memory cap and a timeout, because a runaway test once took 31 GiB and froze the owner's machine (2026-10-15): `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0 timeout 1800 make test`. Raise the cap only with a reason.
Stop every Tuna process you start (by its exact PID) before you finish; 11 orphaned test instances once held 4 GB for a day.

```sh
make deps          # install Gerbil package dependencies into .gerbil/
make               # build the browser asset and the Gerbil package
make test          # Gerbil tests, the keyboard-plugin test, and a check that demo/init.ss loads
make run           # build, then run .gerbil/bin/tuna with starter/init.ss
.gerbil/bin/tuna --port N --config demo/init.ss   # after make: the development demo
```

`gerbil build` needs at least one commit, because it records `git describe` in the package manifest. A Racket-era `tuna` binary may be on `PATH`; run this checkout's binary through `make run` or `gerbil env tuna`.

## HTML and CSS

Follow `agents/guides/html-css.md`: each plugin styles its own HTML in its own `tokens.css` and `rules.css`, registered with `add-stylesheet`; semantic tokens are named after the plugin's classes and defined with the design-token subset (`agents/guides/design-tokens.md`) and a fallback. No colours or styles in Gerbil.

## README scope

- Keep `README.md` brief: project introduction and essential install, build, and run instructions.
- Keep individual settings, API reference, implementation details, and behavioral caveats out of the README. Configuration examples belong in example config files.
- Update the README only when requested or when its essential setup instructions change. Routine feature changes do not require README additions or new documentation.
