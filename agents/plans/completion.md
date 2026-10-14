# Plan: completion and M-x

Owner-approved brief: [`docs/briefs/2026-10-completion.md`](../../docs/briefs/2026-10-completion.md) (2026-10-13). Decision: [ADR 14](../adr/0014-completion.md). Research and contract sketch: [`agents/research/completion/`](../research/completion/README.md).

## Invariants

- Placement: contracts in `tuna/services/`, defaults in `tuna/plugins/`, doubles in `tuna/test-support/`; the kernel is unchanged; no advice.
- Every plugin is optional: M-x works without the UI, style and annotation plugins, with less.
- Immediate mode (ADR 7): the list is nodes rebuilt from the session; the whole visible screen is sent each redraw.
- Typed candidates; no strings with hidden properties.
- Owner preference: where Emacs carries a legacy smell, prefer a clean, idiomatic Gerbil design and record the divergence.
- `make test` green; each stage checked in a real browser on an isolated run with screenshots.
- Implementation by `openai-codex/gpt-6.1-sol`; review by the primary agent.

## Stages

1. **Foundations.** **Done 2026-10-13** (merged; report `/home/jay/Code/workbench-gerbil/scratch/tuna-completion/stage1-report.md`: commands contract and plugin with toy provider, `where-is`, hooks run through `Keys.dispatch-command`, history setting `minibuffer-history-length`, prompt handle via `setup:`). `tuna/services/commands.ss` and a commands plugin (records with doc and visibility, `command-names`, `command-entry`, `call-command` setting `this-command`/`last-command`), keys requiring it, `defcommand` unchanged for package authors; `where-is` in keys; `pre-command-hook` and `post-command-hook` in the keys contract, run by the keys plugin around each dispatched command; minibuffer history (`history:` on reads, `M-p`/`M-n`, a session slot, a length setting) and the prompt handle the engine needs (add nodes and a keymap to the prompt buffer, an exit check, exit with a value); the ADR 3 test of a buffer changing while a command waits at a prompt.
2. **Engine, vertical list, M-x.** `tuna/services/completion.ss` (candidate, table, session, the two slots, style and annotator registration); the engine plugin (one session per prompt, nesting with the minibuffer; pipeline inline: style match, sort by history then length then name unless the table sorts, keep the selection by identity; `substring` style; `completion-styles` setting with per-category override); the vertical list plugin (N rows as nodes with highlight spans and annotation fields in a CSS grid; `C-n`/`C-p`/`<down>`/`<up>`, `M-<`/`M->`, `RET`, `M-RET`, `TAB`, click; "index/total" by the prompt); the M-x plugin (`M-x`, hidden commands excluded, history `extended-command`, fallback annotation: the key binding); a toy UI provider in `tuna/test-support/` proving the slot.
3. **Orderless-like style and annotations.** A style plugin (space-separated components, any order, literal with smart case or regular expression, spans); an annotations plugin with the `command` annotator (first key, first docstring line). Tests that turning each plugin off leaves M-x working.

After stage 3: update `docs/overview.md`, `docs/emacs-equivalents.md`, and the status.

## Not in this plan

Multi-source tables, narrowing and preview (Consult); async sources and jobs; category parents; file completion and boundaries; TAB common-prefix; per-category layouts; the after-run key hint; mode filtering; Embark; in-buffer completion.
