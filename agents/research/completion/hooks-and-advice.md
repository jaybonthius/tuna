# Every advice and hook, and the Tuna extension point instead

Supporting file for [README.md](README.md). Commits are listed in
[packages.md](packages.md). Found with
`grep -n "advice-add\|add-hook\|cl-defmethod\|cl-letf"` over each package,
then read in context. "Why" is the package's stated reason where it gives one
(Fact) or my reading (Inference). "Tuna instead" is a proposal.

Kinds: **A** advice; **H** standard hook; **PH** package-private hook (a
proper extension point the package defines); **G** generic-function method
(proper, package-defined); **L** `cl-letf` / variable rebinding.

## Vertico

| Where | Kind | What | Why | Tuna instead |
|---|---|---|---|---|
| `vertico.el:703-709` | A | `:around` on `completing-read-default` and `completing-read-multiple` | Inference: no hook for "a completion read starts"; `completing-read-function` would mean reimplementing the read and misses direct callers (`tmm.el:231`) | The completion UI is a **service** (`completion-ui`); `completing-read` calls its provider. No advice. |
| `vertico.el:607-613` | H | adds/removes `vertico--setup` on `minibuffer-setup-hook` around the read | Fact: comment "Do not use `minibuffer-setup-hook' for idempotency" — scoped to this one read | The UI provider receives the session and prompt handle as arguments. |
| `vertico.el:604` | H (local) | `pre-command-hook` → `vertico--prepare` | Fact: make sure candidates are computed before a `vertico-*` command runs (`:587-592`) | Navigation commands call the session's `update` themselves. |
| `vertico.el:605` | H (local) | `post-command-hook` → `vertico--exhibit` | Recompute and redraw after every command typed in the minibuffer | The session marks itself dirty from `after-change-hook` on its input text (exists, `tuna/services/buffers.ss:323`) and recomputes in **`post-command-hook`** (ADR 8; not built yet; the one hook the first slice needs). Drawing is the renderer's job (immediate mode). |
| `vertico.el:711-723` | (symbol property) | `completion-predicate` hides Vertico commands from `M-x` outside Vertico | Fact: "Do not show Vertico commands in M-X" | A **visibility predicate field on the command record** in a commands contract. |
| `vertico.el:520-613` | G | `cl-defgeneric` presentation methods | Vertico's own extension point for its extensions | UI plugin settings, or a small presentation registry inside the UI plugin. |
| `vertico-flat.el:89,104`, `vertico-grid.el:116`, `vertico-reverse.el:75,80`, `vertico-buffer.el:210,212`, `vertico-mouse.el:69,80`, `vertico-indexed.el:55,67`, `vertico-unobtrusive.el:61`, `vertico-multiform.el:174` | G | mode-conditioned methods | Extensions change layout per mode | Layouts are CSS and node shapes chosen by a UI setting resolved per category (settings scopes, ADR 9). Mouse is free: rows are nodes with node keymaps. |
| `vertico-buffer.el:192-193` | H (local) | `minibuffer-exit-hook`, `pre-redisplay-functions` | Restore the window, track it | Not needed: in Tuna the prompt is already a buffer in a view (ADR 13); showing the list elsewhere is a layout choice. |
| `vertico-directory.el:55` | H | `rfn-eshadow-update-overlay-hook` | Tidy shadowed file names | Later, with file completion. |
| `vertico-multiform.el:121-122,178` | H | `minibuffer-exit-hook`, `context-menu-functions`, `minibuffer-setup-hook` | Turn modes on per command or category, off at exit | Per-category settings scope read by the UI when the session starts. |
| `vertico-repeat.el:160-161` | H (local) | `post-command-hook`, `minibuffer-exit-hook` | Remember input and selection to repeat a session | A **session-end hook** in the completion contract carrying the finished session (plain data). |
| `vertico-suspend.el:63,69` | A, H | `:around` on `set-minibuffer-message`; `pre-redisplay-functions` | Suspend and resume a session | Not needed: prompts already wait without blocking the editor (ADR 3); leave a prompt and come back. |

## Orderless

None. It registers in `completion-styles-alist` (`orderless.el:632-635`) and
uses `completion-lazy-hilit-fn` (`:575-577`). **Tuna instead:** a style
registry entry in the completion contract.

## Marginalia

| Where | Kind | What | Why | Tuna instead |
|---|---|---|---|---|
| `marginalia.el:1379-1380` | A | `:before-until` on `completion-metadata-get` (and its compat copy) | Inference: inject `affixation-function` and `category` for every UI, since core has no annotator registry and many tables have no category | An **annotator registry by category** in the completion contract, consulted by the engine; every table **declares a category**, so no classifier is needed. |
| `marginalia.el:1382` | A | `:filter-return` on `completion-all-completions` | Fact: record the base position for file annotations (`:1356-1368`) | The session carries boundaries and base as data. |
| `marginalia.el:1377` | H | `minibuffer-setup-hook` → record `this-command`, reset cache | Fact: TODO comment cites bug#80815 about `current-minibuffer-command` (`:1348-1349`) | The session records the command that started it (ADR 8 activation context). |
| `marginalia.el:1352` | H (local) | `window-state-change-hook` → reset cache | Recompute alignment on resize | Alignment is CSS grid in the browser; no server-side widths. |
| `marginalia.el:1353` | H (local) | `context-menu-functions` | Menu to cycle annotators | Later; a command plus owner-tagged priorities. |

## Consult

| Where | Kind | What | Why | Tuna instead |
|---|---|---|---|---|
| `consult.el:538-548`; filled at `:5725-5726`, `:5732`, `:5761` | PH | `consult--completion-candidate-hook`, `consult--completion-refresh-hook` | Core has no "current candidate" or "refresh"; each UI must supply them | **Session queries in the completion contract**: `session-selected`, `session-candidates`, `session-refresh!`. Any UI must implement them; no per-UI glue. |
| `consult.el:1453` (removed `:1458`) | A (temporary) | `:around` on `run-hooks` during preview file opening | Fact: filter `find-file-hook` to `consult-preview-allowed-hooks` (`:1381-1391`) | Later: the files contract offers "visit for preview" (no mode hooks, no recording), instead of suppressing hooks. |
| `consult.el:4879` | L | `cl-letf` over `display-buffer-in-tab`, `-in-new-tab` during buffer preview | Fact: comment "Prevent opening the preview in another tab" | Preview receives the origin view and sets that view's buffer directly; the layout is a value, so restoring it is exact. |
| `consult.el:2049-2081` | L (buffer-local) | replaces `completion-styles` and `-alist` with a splitting style | Separate async input from filter input (`#grep#filter`) | Async sources declare an input splitter; the engine passes the filter part to the styles. |
| `consult.el:1521`, `:1539`, `:1701` | H | `window-selection-change-functions`, `pre-command-hook` | Buffer and location preview bookkeeping (when the user leaves the minibuffer window) | Later, with the preview protocol. |
| `consult.el:1780` | H (local) | `minibuffer-exit-hook` | Run state `exit` | The session's own unwind (`completing-read` returns through `dynamic-wind`). |
| `consult.el:1750-1762` | H (local, by `setq-local`) | appends to `post-command-hook` | Trigger preview after each command | Engine calls the table's preview procedure when the selection changes. |
| `consult.el:2197` | H (local) | `after-change-functions` | Async input changed | Same mechanism as the session's input change. |
| `consult.el:2873` | H (local) | `after-change-functions` | Hide tofu characters in the minibuffer | Not needed: candidates are typed; no tofu. |
| `consult.el:5665-5666` | H | `post-command-hook`, `completion-list-mode-hook` | Preview in `*Completions*` | Not needed. |

## Embark (completion-related only)

| Where | Kind | What | Why | Tuna instead |
|---|---|---|---|---|
| `embark.el:707-709` | H | `minibuffer-setup-hook` → record `this-command` | Default action is the command that opened the read | Session records it. |
| `embark.el:700` | H | `completion-setup-hook` | Cache info for `*Completions*` | Not needed. |
| `embark.el:3653-3666` | G, PH | method on `vertico--format-candidate`; adds Vertico finders/collectors to `embark-target-finders`, `embark-candidate-collectors` | Read Vertico's private state | Session queries return typed candidates with categories; a "marked" set could be a session field. |
| `embark.el:3702-3705` | PH | Ivy finders/collectors | Same | Same. |
| `embark.el:1975`, `:2002`, `:2018`, `:2140-2141`, `:4230-4231` | H | `minibuffer-exit-hook`, `post-command-hook` | Quit the minibuffer, then run the action after it | The session's exit returns a value and a continuation; ADR 3 tasks make "exit, then run" direct. |
| `embark-consult.el:55` | PH | fills Consult's candidate hook | Collect buffer integration | Not needed. |
| `embark-consult.el:474-475` | A | `:after-until` on `embark-collect--metadatum` | Add imenu grouping | Category defaults registry (group function per category). |

## What Tuna needs before completion

**Inference.** Of all the above, only one general mechanism is needed for a
first slice that Tuna lacks: `post-command-hook` (ADR 8 already decides it;
the keys plugin, which is the input service, runs commands, so it is the
place). Everything else becomes an explicit slot, registry, or session query
in a completion contract. Advice is not needed for completion. Advice
matters later only for porting Emacs packages that advise core functions.
