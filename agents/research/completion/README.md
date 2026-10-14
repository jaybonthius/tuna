# Completion: M-x with a Vertico, Orderless, Marginalia and Consult experience

Research, 2026-10-13. Read-only; nothing in Tuna was changed. Question: how
Emacs and these packages divide completion work, which advice and hooks they
rely on, and how Tuna should divide it into contracts and plugins under
ADR 12 so the same parts later serve a file picker, buffer switching and
more.

Supporting files:
- [emacs-core.md](emacs-core.md): question 1 in detail (tables, metadata, styles, history, M-x).
- [packages.md](packages.md): question 2 in detail, with clone commits.
- [hooks-and-advice.md](hooks-and-advice.md): every advice and hook, with the Tuna extension point instead.
- [contract-sketch.md](contract-sketch.md): illustrative Gerbil shapes of the proposed contracts (not compiled).

Labels: **Fact** (with a citation), **Inference** (my reading or proposal),
**Unverified** (not checked). Citations: Emacs `/home/jay/Code/emacs` at
`541f693ca2e8de166cfe52c39bbfc497142215e9`; packages at the commits in
[packages.md](packages.md); Tuna at the working tree of 2026-10-13.

## Summary

Emacs's core already separates the parts the owner wants: completion
**tables** with **metadata** (category, annotation, grouping, sorting), a
**registry of matching styles**, **history** lists, and one **UI slot**
(`completing-read-function`). The packages fill those parts: Orderless is a
style, Vertico a UI, Marginalia annotations, Consult richer tables
(sources, preview, async). The places where they use advice and private
hooks mark three things core lacks: a proper "a completion read starts" hook
for the UI (Vertico advises `completing-read-default`), an annotator registry
and a required category (Marginalia advises `completion-metadata-get`), and a
"completion session" object others can ask for its current candidate and
candidate list (Consult and Embark each define per-UI hooks).

**Recommendation (Inference).** Tuna should make all three explicit: a
`completion` contract with typed candidates, a session object, style and
annotator registries, and a separate `completion-ui` service slot; a small
`commands` contract split out of `keys`; history owned by the minibuffer. Then
Vertico-, Orderless-, Marginalia- and Consult-like plugins, and M-x itself,
need **no advice**. The only general mechanism to build first is
`post-command-hook` (already decided in ADR 8), so the list updates in the
same screen as each keystroke.

## 1. Emacs core

Details and citations: [emacs-core.md](emacs-core.md).

- **Fact.** `completing-read` only calls `completing-read-function`
  (`src/minibuf.c:2051-2053`); the default reads in the minibuffer with the
  table, predicate and require-match as minibuffer-local variables
  (`lisp/minibuffer.el:5157-5207`).
- **Fact.** A table is a list, alist, obarray, hash table or function. A
  function table answers five actions: try, all, test, `(boundaries . suffix)`
  and `metadata` (`minibuffer.el:28-37`). Metadata keys: `category`,
  `annotation-function`, `affixation-function`, `group-function`,
  `display-sort-function`, `cycle-sort-function`, `eager-display`,
  `eager-update` (`minibuffer.el:117-152`).
- **Fact.** Lookup order: category overrides/defaults, then the table's
  metadata, then `completion-extra-properties` (`minibuffer.el:159-181`).
  Emacs 31 adds category parents (`define-completion-category`,
  `minibuffer.el:209-230`) and lets a category override annotation,
  affixation, grouping and sorting (`:1265-1365`).
- **Fact.** Styles: `completion-styles-alist` is a registry of
  `(name try-fn all-fn doc)`; `completion-styles` is the user's ordered list;
  a category may prepend its own; the first style returning a result wins
  (`minibuffer.el:1158-1263`, `:1371-1456`). Lazy highlighting lets styles
  defer highlighting to the shown rows (`:4502-4540`).
- **Fact.** History: a read names a history variable; C adds the answer
  (`minibuf.c:976-980`, `subr.el:2719`); `savehist` persists.
- **Fact.** M-x: `read-extended-command-1` completes over `obarray` with
  `commandp` plus `read-extended-command-predicate`
  (`simple.el:2349-2434`), declares category `command` and a binding
  annotation (`:2397-2400`, `:2509-2527`), uses `extended-command-history`;
  `execute-extended-command` sets `this-command` to the chosen command and
  runs it with `command-execute … 'record` (`:2639-2647`), then may show "You
  can run X with KEY" (`:2593-2690`). A command hides itself from M-x with a
  `completion-predicate` property (`:2450-2461`; Vertico does,
  `vertico.el:711-723`).
- **Mechanism vs UI (Inference).** Mechanism: the table protocol, metadata
  lookup, styles, lazy highlighting, history. UI: `*Completions*`, TAB and
  cycling, display sorting, plus M-x's annotation and after-run hint as
  feature policy. The weak point is the boundary: there is no session object,
  so packages invent per-UI hooks (table in [emacs-core.md](emacs-core.md#8-mechanism-versus-ui)).

## 2. The packages

Details, data structures and all line references: [packages.md](packages.md).
Every advice and hook: [hooks-and-advice.md](hooks-and-advice.md).

| Package | Provides | Needs from core | Official extension points | Advice / hooks |
|---|---|---|---|---|
| Vertico | Vertical list UI and navigation commands | table, predicate, `minibuffer--require-match` (private), metadata, boundaries, `completion-all-completions`, lazy highlighting | `cl-defgeneric` presentation methods for its own extensions | **Advice** on `completing-read-default` and `completing-read-multiple` (`vertico.el:703-709`); scoped `minibuffer-setup-hook` (`:607-613`); local `pre-`/`post-command-hook` (`:604-605`) |
| Orderless | A matching style: space-separated components, any order, per-component dispatch | `completion-styles-alist`, boundaries, `all-completions` + `completion-regexp-list`, lazy highlighting | `completion-styles-alist` (`orderless.el:632-635`) | **None** |
| Marginalia | Annotator registry by category and ~25 annotators | metadata, `this-command` | `marginalia-annotators`, `marginalia-classifiers` (its own) | **Advice** on `completion-metadata-get` (`marginalia.el:1379-1380`) and `completion-all-completions` (`:1382`); `minibuffer-setup-hook` (`:1377`) |
| Consult | Commands over `consult--read`: preview, async pipelines, multi-source, narrowing | `completing-read`, metadata, a UI's current candidate and refresh | its own private hooks for UIs (`consult.el:538-548`) | Temporary **advice** on `run-hooks` during file preview (`:1453`); `cl-letf` during buffer preview (`:4879`); buffer-local style replacement for async split (`:2049-2081`); several local hooks |
| Embark (completion side only) | Act on the current candidate or all candidates | category, current candidate, candidate list, the starting command | `embark-target-finders`, `embark-candidate-collectors` (its own) | `minibuffer-setup-hook` (`embark.el:707-709`); per-UI code reading Vertico internals (`:3625-3666`) |

Package-specific answers:

- **Vertico replaces the UI by advice, not by the slot.** It keeps Emacs's
  read (keymaps, require-match, history, `exit-minibuffer`) and adds
  presentation by adding its setup to `minibuffer-setup-hook` for the length
  of one `completing-read-default` call (Fact, `vertico.el:607-613,703-709`).
  Its pipeline (`vertico--compute`, `:226-293`): all-completions through the
  styles → filter ignored file extensions → sort (override, table's, or
  history+length+alpha) → default and exact match to the front → dedupe →
  group → keep the selection on the same candidate. Annotation and
  highlighting only for visible rows (`:535-537`). Extensions override
  generic methods per mode (flat, grid, reverse, buffer, mouse, indexed,
  multiform; [packages.md](packages.md#vertico)).
- **Marginalia's category** comes from `marginalia-classifiers`
  (`marginalia.el:127-136`): command → category table
  (`marginalia-command-categories`, `:169-175`), the table's own category,
  prompt regexps (`"\\<M-x\\>"` → `command`, `:138-159`), then "is it a
  symbol table". For M-x the table declares `command` itself only while
  `suggest-key-bindings` is on (`simple.el:2397`), so the prompt rule backs it
  up. The command annotator is binding plus first docstring line
  (`marginalia.el:641-647`, `:457-461`).
- **Consult**: preview is a state function called with `setup`,
  `preview CAND`, `exit`, `return CAND` (`consult.el:1855-1890`); async
  sources are composable curried sink pipelines (`:2084-2146`);
  `consult--multi` merges sources described as plists and returns
  `(candidate . source)` (`:3222-3300`); narrowing is a per-source key
  (`:1937-1959`); `consult-buffer` uses eleven sources
  (`consult-buffer-sources`, `:239-255`). Because candidates are strings,
  equal strings from two sources are told apart by appending an invisible
  private-use character ("tofu", `:561-571`, `:3085-3110`). **Inference:**
  typed candidates remove the need for this.
- **Embark** hooks into completion only to learn the current candidate, all
  candidates, their category and the starting command; it has per-UI
  integration code because core has no session object
  ([packages.md](packages.md#embark-only-its-hooks-into-completion)).

## 3. Mapping to Tuna

Tuna today (Fact): the minibuffer contract offers only
`read-from-minibuffer question initial` and `active-prompt`
(`tuna/services/minibuffer.ss:37-43`); a prompt is an internal buffer with a
question node and an answer text node, keys `RET`/`C-g` on its root keymap
(`tuna/plugins/minibuffer.ss:53-74,128-137`). Commands are a struct
`(name procedure doc)` in the **keys** contract (`tuna/services/keys.ss:141-145`)
held in the keys plugin's entry table (`tuna/plugins/keys.ss:24`); `Keys`
has no way to list commands or find a command's keys (`keys.ss:160-189`).
Registries elsewhere are owner-tagged entry tables held by a provider and
reached through its interface (node kinds and renderers,
`tuna/services/buffers.ss:543-568`). `after-change-hook` exists
(`buffers.ss:323`); `pre-`/`post-command` hooks do not (grep finds none).
Jobs are a library with groups, keys, cooperative cancellation and validity
policies (`tuna/lib/jobs.ss:1-60`). Settings have `defsetting` and scopes
(`tuna/services/settings.ss:1-40`); session slots persist plain data
(`tuna/services/session.ss:1-40`).

Each piece below gives the precedent, the proposal (Inference), and how it
replaces advice. Shapes are in [contract-sketch.md](contract-sketch.md).

### 3.1 The completion contract and candidate shape

- **Precedent.** `completing-read` with a string table plus metadata, extra
  properties in dynamic scope, and strings carrying text properties
  (Consult's `multi-category` property and tofu, `consult.el:3116-3131`).
- **Proposal.** `tuna/services/completion.ss` defines vocabulary and two
  service slots:
  - `candidate`: `text` (matched and shown), `value` (returned; a command
    name, a buffer, a path), `key` (identity, so the selection stays put),
    optional `category` (for mixed sources) and `group`.
  - `completion-table`: `category` (required), `items` (list, procedure of the
    input, or async source), optional `sort`, `group`, fallback `annotate`,
    `preview`, `narrow`. These are fields, not dynamic variables
    (replaces `completion-extra-properties`).
  - `completing-read prompt table require-match: initial: history: default:`
    returns the chosen candidate's **value**. It is a yield point (ADR 3).
  - A **session** object for the running read: input, category, candidates
    (filtered, sorted, grouped), selected candidate, select, exit, the
    command that started it, and a revision.
  - `completion-service` (the engine) and `completion-ui-service` (the
    presentation), both live tier.
- **Better than advice.** The session replaces Consult's two private UI
  hooks and Embark's per-UI finders; typed values replace tofu and string
  lookups; a required category replaces Marginalia's classifiers.
- **Owner decision 1** (typed candidates).

### 3.2 Completion styles

- **Precedent.** `completion-styles-alist` registry plus
  `completion-styles` list plus per-category `styles` (official; Orderless
  needs nothing else).
- **Proposal.** A style registry in the engine (owner-tagged entries, so a
  style goes when its plugin goes), registered with
  `context-define-completion-style!`. A style compiles the input to a
  matcher returning `#f` or **match spans**; the UI turns spans into
  `<mark>` elements for shown rows only (Emacs lazy highlighting as data, not
  faces). Which styles run is a setting `completion-styles` (ordered names),
  with a per-category override setting. Built-in `substring` and `basic` live
  in the engine plugin; Orderless-like is its own plugin.
- **Leave room** for `try` (TAB common-prefix expansion) as an optional style
  method; Vertico does not use it.

### 3.3 The UI slot

- **Precedent.** `completing-read-function` (official, unused by Vertico)
  versus Vertico's advice plus scoped `minibuffer-setup-hook` plus local
  `post-command-hook`.
- **Proposal.** `completion-ui-service` with one method, `present session
  prompt`: the engine starts the read (through the minibuffer contract),
  creates the session, then hands it to the UI provider, which adds a
  candidate-list node to the prompt's buffer and a keymap for navigation. No
  UI provider means plain typing with `RET` validation (like Emacs without
  `*Completions*`).
- **Rendering under the immediate-mode rule.** Rows are nodes, one per
  **visible** candidate (Vertico's `vertico-count`, default 10, as a
  setting), rebuilt when the session revision changes; every redisplay
  streams the whole visible UI (ADR 7, owner decision 2026-10-13). Each row
  carries one shared keymap owned by the UI plugin, binding `<mouse-1>` to a
  "choose clicked candidate" command that reads the row through
  `posn-node`, exactly like buttons (`tuna/services/buttons.ss:20-31`).
  Hover is CSS. Annotation columns are CSS grid, so no server-side width
  arithmetic (Marginalia's `space :align-to` and window-width cache,
  `marginalia.el:1279-1327`).
- **Per keystroke** (concrete): typing `buf` in `M-x` (1) inserts into the
  answer text node; (2) `after-change-hook` marks the session dirty;
  (3) `post-command-hook` makes the engine recompute (styles → sort →
  group → keep selection) and bump the session revision; (4) the UI rebuilds
  its ten row nodes with highlights and annotations; (5) the loop renders.
  This needs `post-command-hook`; see 3.11.
- **Leave room** for Vertico-multiform-style per-category layouts (grid,
  flat) as UI settings resolved by category.

### 3.4 Annotator registry

- **Precedent.** `marginalia-annotators` (category → annotators), injected
  through advice on `completion-metadata-get`.
- **Proposal.** An annotator registry in the engine: category → procedure
  `candidate → list of annotation-field` (text plus a class such as `key`,
  `doc`, `size`). Owner-tagged entries with priorities let a richer plugin
  override a simpler one and let `M-x describe-…` show who set it. The engine
  asks the registry first, then the table's own `annotate`. Annotators run
  only for visible rows and are called with the session's origin buffer as
  `current-buffer` (Marginalia runs in the original window,
  `marginalia.el:1319-1327`).
- **Better than advice.** Any UI gets annotations because the engine
  supplies them; no interception.

### 3.5 Categories

- **Precedent.** Symbols; Emacs 31 adds parents and per-category defaults
  (`minibuffer.el:183-230`); Marginalia guesses missing ones.
- **Proposal.** Categories are symbols, and every table states one (`general`
  if nothing better). Leave room for a category registry with parents and
  defaults (`project-file` under `file`), so annotators and style overrides
  fall back to the parent. Not in the first slice.

### 3.6 History

- **Precedent.** History variables, `add-to-history` in C after every read,
  `savehist` to persist; Vertico and `minibuffer-sort-by-history` read it.
- **Proposal.** The minibuffer owns history: `read-from-minibuffer` gains
  `history:`; the minibuffer plugin keeps named lists in one **session slot**
  (ADR 5; savehist built in), trims duplicates, and binds `M-p`/`M-n` in the
  prompt keymap. The contract exposes `minibuffer-history name` so the
  engine's default sort can rank recent answers first. `read-string` gets
  history for free. ("No arbitrary limits": the list length is a setting, not
  a hard cap; Inference about how to honour that preference.)

### 3.7 Async and large sources as jobs

- **Precedent.** Vertico computes inside `while-no-input` (`vertico.el:356-360`);
  Consult builds async sink pipelines with throttling, process sources and
  input splitting (`consult.el:2084-2695`).
- **Proposal.** Keep the pipeline a pure function of plain data: the engine
  extracts `(index . text)` pairs and the input, and the result is a vector
  of indices plus spans. Then it can run inline on the baton or as a job
  (`tuna/lib/jobs.ss`) with key = session, `exact-revision` against the
  input text's revision, and cancellation when the input changes; values that
  are live objects (buffers) never leave the baton. Async sources are
  producers run as jobs that post batches of plain-data candidates; the
  source declares `min-input`, `debounce`, and an input splitter (Consult's
  `#async#filter`). External processes wait for a process service.
- **Owner decision 3** (inline first or jobs from the start).

### 3.8 Consult-style sources and preview

- **Precedent.** `consult--multi` plists; state functions; narrowing keys;
  `consult-buffer-sources` as a user list of symbols; preview suppresses
  `find-file-hook` by advice and blocks tab display by `cl-letf`.
- **Proposal.**
  - A **source** is a table plus `name`, `narrow` key, `hidden?`,
    `history`, `action`, `new`. A contract helper merges sources into one
    table whose candidates carry their source (no tofu). Narrowing is a
    session field the engine applies; the UI shows it.
  - **Source lists as registries**: "buffer switching" is a named list other
    plugins contribute to with owner-tagged priorities (a future files plugin
    adds "recent files"), instead of a user-maintained list of symbols with
    `:enabled` predicates.
  - **Preview** is the table's state procedure, called by the engine when
    the selection changes (`setup`, `preview`, `exit`, `return`), always
    with the origin view. Tuna's layout is an immutable value held by the
    layout plugin (ADR 13), so a preview can restore the exact layout instead
    of juggling buffer histories (`consult.el:4859-4893`). Opening a file for
    preview needs a "visit for preview" option in the future files contract,
    not hook suppression.
  - A Consult-like plugin then provides commands such as `switch-to-buffer`
    over the buffer-switching sources.

### 3.9 Where M-x lives

- **Proposal.** A small `extended-command` plugin: defines
  `execute-extended-command`, binds `M-x`, builds a `command` table from the
  commands contract (hiding commands whose visibility predicate says no:
  `exit-minibuffer` outside a prompt, UI navigation commands; Emacs's
  `completion-predicate`), uses history `extended-command`, and runs the
  choice with `call-command` so it becomes `this-command`/`last-command`
  (Emacs `simple.el:2639-2647`). The "You can run X with KEY" hint is an
  optional later addition in the same plugin.
- **Annotation.** The binding-plus-docstring annotation is an annotator for
  category `command` in the Marginalia-like plugin (owner's request), using
  `where-is` (keys) and the command's doc (commands). The M-x table's own
  fallback `annotate` shows only the binding, as core Emacs does
  (`simple.el:2509-2527`), so M-x is useful without the annotations plugin.

### 3.10 A commands contract separate from keys

- **Evidence.** M-x needs to list commands and read their docs; help needs
  docs and provenance; the M-x annotator needs reverse lookup (`where-is`);
  node activation and Embark-like actions run commands without keys; Vertico
  needs per-command visibility. Today none of this is in `Keys` except
  `command-entry` (`keys.ss:160-189`), and another input provider would have
  to implement `Keys` to host commands (STATUS "Next" 4).
- **Proposal.** `tuna/services/commands.ss`: the `command` record (plus
  `visible?` and later `modes` and argument specs from ADR 8),
  `define-command!`, `command-entry`, `command-names`, `call-command`.
  Provider: a small `commands` plugin; the keys plugin requires it and keeps
  only bindings, resolution and a new `where-is`. `defcommand` keeps its
  syntax. **Owner decision 2.**

### 3.11 What needs hooks or advice first

- **Needed: `post-command-hook`** (and `pre-command-hook` with it, for other
  users). ADR 8 already decides both "for every dispatched command"; the keys
  plugin dispatches commands, so the hook objects belong in the keys (input)
  contract and the plugin runs them around each command. Smallest proper
  version: two `new-hook` values and two `run-hook` calls. **Inference:**
  without it, the engine must recompute inside `after-change-hook`, which
  ADR 3 forbids ("Hooks schedule, they do not compute"), or schedule a task
  that may land a frame late (**Unverified**: whether a task queued from a
  hook finishes before the next render).
- **Needed in the minibuffer contract** (not hooks): a prompt handle the
  caller can extend (add nodes and a keymap to the prompt's buffer), an exit
  check (require-match), exit with a value, and history. The engine is then
  the only caller that touches the prompt's internals.
- **Not needed:** advice. Every advice found
  ([hooks-and-advice.md](hooks-and-advice.md)) maps to a slot, registry or
  session query above. `minibuffer-setup-hook`/`-exit-hook` (ADR 8) are not
  needed for completion either, because the engine calls the UI directly
  and unwinds the session itself; build them in the hooks milestone for
  other packages.
- **ADR 3 prerequisite:** ADR 3 asks for "a test of a task whose text
  changes between its yield points" before minibuffer and completion work.
  `completing-read` suspends the calling command while the origin buffer may
  change; the test belongs in the first slice.

## Recommended plugin and contract map

| Piece | Layer | File (proposed) | Emacs counterpart | First slice? |
|---|---|---|---|---|
| Commands contract | contract | `tuna/services/commands.ss` | `defun`+`interactive`, `commandp`, `completion-predicate` | yes |
| Commands provider | plugin | `tuna/plugins/commands.ss` | obarray of commands | yes |
| Keys: bindings, resolution, `where-is`, `pre`/`post-command-hook` | contract + keys plugin | `tuna/services/keys.ss`, `tuna/plugins/keys.ss` | keymaps, `where-is-internal`, command-loop hooks | yes |
| Minibuffer: prompt handle, history | contract + minibuffer plugin | `tuna/services/minibuffer.ss`, `tuna/plugins/minibuffer.ss` | `read-from-minibuffer`, history, savehist | yes |
| Completion vocabulary, session, two slots, registries' accessors, multi-source helper | contract | `tuna/services/completion.ss` | `minibuffer.el` mechanism, `completing-read-function` | yes (no multi-source yet) |
| Engine: sessions, pipeline, style and annotator registries, `substring`/`basic` styles | plugin (`completion-service`) | `tuna/plugins/completion.ss` | `minibuffer.el` | yes |
| Vertical list UI | plugin (`completion-ui-service`) | `tuna/plugins/completion-vertical.ss` | Vertico | yes |
| Orderless-like style | plugin | `tuna/plugins/orderless.ss` | Orderless | yes (literal + regexp components) |
| Annotations | plugin | `tuna/plugins/annotations.ss` | Marginalia | yes (command only) |
| M-x | plugin | `tuna/plugins/extended-command.ss` | `execute-extended-command` | yes |
| Sources, preview, buffer switching | contract helper + plugin | `completion.ss` + `tuna/plugins/switch-buffer.ss` | Consult | no; leave room |
| Category registry with parents | engine | — | `define-completion-category` | no |
| Async sources as jobs | engine + `tuna/lib/jobs.ss` | — | Consult async | no |
| Act on candidates | plugin | — | Embark | no; session API leaves room |

```
 extended-command ──┐            annotations ──┐   orderless ──┐
 (M-x)              │ completing-read          │ annotator     │ style
                    ▼                          ▼               ▼
              ┌──────────── completion contract (services) ───────────┐
              │ candidate · table · session · styles · annotators     │
              └──────┬─────────────────────────────┬──────────────────┘
          engine plugin (completion-service)   vertical UI (completion-ui-service)
                     │ prompt handle, history         │ row nodes + node keymaps
              minibuffer contract/plugin        renderer (immediate mode)
                     │ post-command-hook, where-is
              keys contract/plugin ── commands contract/plugin
```

No kernel change (Inference): every piece is a contract or a plugin;
registries are owner-tagged entry tables (kernel `context-add-entry!`), and
the new hooks are `new-hook` values in contracts.

## 4. The first slice

**Build now** (smallest extensible base for a good M-x):

1. Commands contract and plugin, with `command-names`, `visible?`,
   `call-command`; keys keeps bindings and gains `where-is`,
   `pre-command-hook` and `post-command-hook`.
2. Minibuffer: prompt handle for callers, exit check, exit with value,
   history with `M-p`/`M-n` in a session slot.
3. Completion contract: `candidate`, `completion-table` (category, items as
   list or procedure, sort, group, annotate), `completing-read`, session
   queries, `completion-service`, `completion-ui-service`, style and
   annotator registration.
4. Engine plugin: one session at a time per prompt (nesting follows the
   minibuffer), the pipeline inline on the baton (styles → sort: history,
   then length, then alphabetical unless the table sorts → keep selection),
   `substring` style as the fallback, `completion-styles` setting.
5. Vertical UI plugin: up to N visible rows as nodes with highlight spans and
   annotation fields; `C-n`/`C-p`/`<down>`/`<up>`, `M-<`/`M->`, `RET`
   (selected candidate), `M-RET` (typed input), `TAB` (insert candidate),
   click to choose; the prompt line shows "index/total".
6. Orderless-like plugin: split on spaces; each component matches as a
   literal substring (smart case) or as a regular expression; all components
   must match in any order; spans for highlighting. Leave room for
   per-component dispatch (`!` negate, `=` literal, `~` flex, `,` initialism).
7. Annotations plugin: the `command` annotator: key binding (first of
   `where-is`) and the first line of the docstring.
8. M-x plugin as in 3.9.
9. Tests: an M-x run end to end; deactivating each of the UI, style and
   annotations plugins leaves M-x working with less (plain prompt, substring
   matching, binding-only annotation); the ADR 3 text-changes-between-yields
   test; a second toy UI provider proving the slot (ADR 12 "proving
   contracts").

**Leave room for, do not build:** multi-source tables and narrowing,
preview, async/job filtering, the category registry with parents, buffer
and file completion and boundaries, TAB common-prefix (`try`), per-category
UI layouts, the after-run key hint, command mode filtering (`M-X`), Embark,
in-buffer completion (Corfu).

## Owner decisions

1. **Typed candidates instead of strings with properties.** Context: Emacs
   tables return strings, so packages hide data in text properties and
   append invisible characters to disambiguate. Options: (a) Emacs strings;
   (b) a `candidate` record with text, value and key. **Recommend (b)**:
   simpler for every source, no tofu, values come back directly. Cost:
   ported Emacs tables need a small adapter (strings become candidates whose
   value is the string). Record as a divergence in
   `docs/emacs-equivalents.md` ("Under consideration" already lists it) and an
   ADR.
2. **Split commands out of keys now.** Options: (a) keep commands in `Keys`
   and add listing and visibility there; (b) a `commands` contract and
   plugin, keys requiring it. **Recommend (b)** before M-x: M-x, help,
   annotations and node actions all need commands without keys, and STATUS
   already asks the question. It is a small, mostly mechanical move.
3. **When the list recomputes, and where filtering runs.** Options: (a)
   build `post-command-hook` now (pulled forward from the hooks and advice
   milestone; ADR 8 decided it) and filter inline on the baton, moving to
   jobs only for async or measured-slow sources; (b) filtering as jobs from
   the start (the "Under consideration" idea), accepting that the list may
   arrive one screen after the keystroke; (c) no new hook, schedule a task
   from `after-change-hook`. **Recommend (a)**: same-screen updates, and the
   pure pipeline keeps (b) a later switch, not a redesign.
4. **What M-x lists.** Options: every command (Emacs default, minus hidden
   ones), or only commands relevant to the current buffer
   (`command-completion-default-include-p`). **Recommend** every command
   whose visibility predicate allows it; mode filtering when modes exist.

## What is shallow

- File completion, boundaries, quoting, and `try-completion`/TAB semantics
  were read only at the signature level.
- Consult's async pipeline internals (`consult--async-process`, throttle,
  merge) and its many sources beyond `consult-buffer` were skimmed.
- Embark was read only for its completion hooks; actions, exporters and
  `embark-collect` were not studied.
- Cape and prescient were not cloned; Corfu only grepped.
- No performance measurement: Gerbil regex speed for Orderless-like matching
  over a few thousand commands, and whether inline filtering fits a frame,
  are **Unverified**.
- **Unverified:** whether a task spawned from a hook completes before the
  next render in Tuna's loop; whether module-level registries would need the
  per-kernel care hooks have (`tuna/kernel/hooks.ss:6-10`) if held outside a
  provider (the proposal keeps them in the engine provider to avoid this);
  how the engine's registries hand over on a live swap.
- The contract sketch was not compiled or checked with the Gerbil MCP tools.
- The Emacs lispref text was not re-read beyond node locations
  (`doc/lispref/minibuf.texi:609, 858, 1805, 1956`); claims rest on the
  source.
- Shallow clones: package history (for example, why Vertico chose advice
  over `completing-read-function`) was not checked; that reason is
  Inference.
