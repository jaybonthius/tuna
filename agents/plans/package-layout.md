# Plan: one package per concept

Owner-approved brief: [`docs/briefs/2026-10-package-layout.md`](../../docs/briefs/2026-10-package-layout.md) (2026-10-14). Evidence and the file-by-file move map: [`agents/research/package-layout/refresh-2026-10-14.md`](../research/package-layout/refresh-2026-10-14.md).

## Invariants (every stage)

- Behavior unchanged: `make test` green, starter and demo checked in a real browser on an isolated run (temporary `XDG_*` directories), with screenshots.
- No compatibility: no aliases, forwarders or re-exports; every caller updated in the same change (AGENTS.md).
- The kernel does not change unless a stage names why; Tuna (`tuna/`) ends importing no concept and no plugin.
- Implementation by `openai-codex/gpt-6.1-sol` in its own worktree per stage; review, browser check and merge by the primary agent.

## Stages

1. **Untangle, no files moved** (**Done 2026-10-14**, merged `6b78b55`; report `/home/jay/Code/workbench-gerbil/scratch/tuna-layout/stage1-report.md`) (brief, "What has to change before files move", items 1–6): drop main.ss's empty plugin imports; `#lang :tuna/config` and `:tuna/prelude` stop bundling `defcommand`/`keymap-set`/`defsetting` (files import them from the commands/keys/settings contracts; the evaluation environment starts with what init.ss imported); click lookup registered by layout through the keys contract (keys drops its layout use); configuration contract lifecycle moments (after start-up, around swap/restart, before shutdown) joined by the session plugin, so start-up stops importing the session contract; the echo-area start-up summary moves into reload-config; the configuration contract moves to `tuna/configuration.ss`. The boundary test gains: `tuna/` imports nothing from `tuna/services/` except the configuration contract's new home, and nothing from `tuna/plugins/`.
2. **Move and rename** (one change): the move map; `tuna/gerbil.pkg` `(package: tuna)` and one `gerbil.pkg` per concept package; root `build.ss` with one `make` call per package; Makefile test paths and web assets; plugin bindings drop the `-plugin` suffix (report clashes); tests into `tests/{unit,integration,support}` beside their owners and `tests/integration/` at the top; `starter/`, `demo/`, docs' import examples updated.
3. **Check:** boundary test rewritten for packages (Tuna imports no package; a plugin imports Tuna, contracts and its own files only; no package cycle; only tests and the demo use test support). Then the primary agent updates `docs/overview.md`, ADR 12's layer description, `docs/emacs-equivalents.md` where names changed, and AGENTS.md command paths.
