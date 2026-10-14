# Emacs core completion: what is mechanism, what is UI

Supporting file for [README.md](README.md), question 1. Citations are to the
local checkout `/home/jay/Code/emacs` at commit
`541f693ca2e8de166cfe52c39bbfc497142215e9` (master, 2026-07-16; it carries
Emacs 31 features). Permalink form:
`https://github.com/emacs-mirror/emacs/blob/541f693ca2e8de166cfe52c39bbfc497142215e9/<file>#L<n>`.
The installed Emacs may be older; claims target that commit.

Labels: **Fact** (cited), **Inference** (my reading), **Unverified**.

## 1. `completing-read` and `completing-read-function`

- **Fact.** `completing-read` is a C function whose whole body calls the
  function in `completing-read-function` with its eight arguments
  (`src/minibuf.c:1981-2054`, the call at `2051-2053`).
- **Fact.** The default, `completing-read-default`
  (`lisp/minibuffer.el:5157-5207`), picks a keymap from `require-match`,
  binds minibuffer-local `minibuffer-completion-table`,
  `minibuffer-completion-predicate`, `minibuffer--require-match`,
  `minibuffer--original-buffer` in a `minibuffer-with-setup-hook` lambda, then
  calls `read-from-minibuffer` with the history variable and default.
- **Fact.** Other code calls `completing-read-default` directly, bypassing the
  variable (`lisp/tmm.el:231`, `lisp/net/tramp-cmds.el:474`).
- **Inference.** `completing-read-function` is the official UI slot, but it
  is all-or-nothing (a replacement must reimplement reading, keymaps,
  require-match and history) and it misses direct callers. That is why
  Vertico advises `completing-read-default` instead (see
  [packages.md](packages.md#vertico)).

## 2. Completion tables

- **Fact.** A table (`COLLECTION`) is a list of strings, an alist, an
  obarray, a hash table, or a function (`src/minibuf.c:1987-1990`, docstring
  of `completing-read`; lispref "Basic Completion", `doc/lispref/minibuf.texi:858`).
- **Fact.** A function table is called as `(fun STRING PRED ACTION)`, where
  ACTION is `nil` (try-completion), `t` (all-completions), `lambda`
  (test-completion), `(boundaries . SUFFIX)`, or `metadata`
  (`lisp/minibuffer.el:28-37`; lispref "Programmed Completion",
  `minibuf.texi:1956`). `complete-with-action` adapts a static collection to
  that protocol (`minibuffer.el:232`).
- **Fact.** The three primitives `try-completion`, `all-completions`,
  `test-completion` are C (`src/minibuf.c:1610`, `1841`, `2057`).
  `all-completions` filters by prefix plus `completion-regexp-list`; Orderless
  uses that to filter fast (`orderless.el:545-557`).
- **Fact.** Boundaries: `completion-boundaries` asks a function table which
  part of the input it completes, `(START . END)`; plain tables complete the
  whole string (`minibuffer.el:96-112`). Files are the main user (completing
  one path component at a time).
- **Fact.** Combinators: `completion-table-dynamic` (`:256`),
  `completion-table-with-cache` (`:288`), `completion-table-with-metadata`
  (`:335`), `completion-table-in-turn` (`:495`), `completion-table-merge`
  (`:505`).

### Metadata

- **Fact.** `completion-metadata` (`minibuffer.el:117-152`) asks a function table for
  `(metadata . ALIST)`. Documented keys: `category`, `annotation-function`
  (one string in, suffix out), `affixation-function` (list in, list of
  `(cand prefix suffix)` out, wins over annotation), `group-function`
  (`(cand transform)` → title, or transformed candidate),
  `display-sort-function`, `cycle-sort-function`, `eager-display`,
  `eager-update`. "The metadata of a completion table should be constant
  between two boundaries" (`minibuffer.el:117-152`).
- **Fact.** `completion-metadata-get` looks a property up in this order:
  category overrides and defaults (unless the property is `category`
  itself), then the table's metadata, then `completion-extra-properties`
  (`minibuffer.el:159-181`).
- **Fact.** Emacs 31 adds category inheritance: `completion-category-get`
  walks a category's parents (`minibuffer.el:183-207`), and
  `define-completion-category` declares parents and per-category defaults
  such as `:group-function` (`minibuffer.el:209-230`).

## 3. `completion-category-defaults` and `-overrides`

- **Fact.** `completion-category-defaults` (`minibuffer.el:1265-1291`) and the
  user option `completion-category-overrides` (`:1293-1365`) map a category
  to `styles`, `cycle`, `cycle-sort-function`, `display-sort-function`,
  `group-function`, `annotation-function`, `affixation-function`,
  `eager-display`, `eager-update`. Overrides win over defaults
  (`completion--category-override`, `:1367-1369`). Defaults ship for
  `buffer`, `unicode-name`, `project-file`, `xref-location`, `info-menu`,
  `symbol-help` (`:1266-1272`).
- **Inference.** Since Emacs 31 lets a category override
  `annotation-function` and `affixation-function`, the category system now
  does part of what Marginalia's advice does, but only when the table states
  its category; Marginalia's classifiers (guessing a category from the
  prompt or command) still have no core equivalent.

## 4. `completion-styles` and `completion-styles-alist`

- **Fact.** `completion-styles-alist` is a registry: each entry is
  `(NAME TRY-FUNCTION ALL-FUNCTION DOC)` (`minibuffer.el:1158-1234`).
  `completion-styles` is the user's ordered list, default
  `(basic partial-completion emacs22)`; an element may be
  `(STYLE ((VAR VAL) ...))` to rebind variables while it runs
  (`:1236-1263`).
- **Fact.** `completion--styles` puts a category's `styles` override before
  the global list (`:1371-1376`). `completion--nth-completion` tries each
  style in turn and returns the first non-nil result (`:1378-1436`);
  `completion-try-completion` and `completion-all-completions` are its two
  entry points (`:1438-1456`). The all-completions result is a list whose
  final `cdr` is the base position (`:1448-1456`).
- **Fact.** Lazy highlighting: a front end binds `completion-lazy-hilit`; a
  style then sets `completion-lazy-hilit-fn` instead of propertizing every
  candidate, and the front end calls `completion-lazy-hilit` only on the
  candidates it shows (`minibuffer.el:4502-4540`).

## 5. `completion-extra-properties`

- **Fact.** A dynamically bound plist giving `:category`,
  `:annotation-function`, `:affixation-function`, `:group-function`,
  `:display-sort-function`, `:cycle-sort-function`, `:eager-display`, and
  `:exit-function` for "the current completion job"
  (`minibuffer.el:2652-2694`). It is how a caller with a plain list table
  attaches metadata.
- **Inference.** It is dynamic scope used as an argument channel; in Tuna
  these are simply fields of the table object passed to `completing-read`.

## 6. Minibuffer history

- **Fact.** The `HIST` argument names a variable holding a list; after a
  read, C code calls `add-to-history` unless `history-add-new-input` is nil
  (`src/minibuf.c:976-980`). `add-to-history` trims to `history-length`
  (default 100, `minibuf.c:2567-2576`) and removes duplicates when
  `history-delete-duplicates` is set (`lisp/subr.el:2719-2750`).
- **Fact.** `minibuffer-sort-by-history` sorts alphabetically and then
  moves history items to the front, only when the history variable is
  specific to this read (`minibuffer.el:1873-1891`). Vertico's default sorter
  does the same, plus length (`vertico.el:95-104`; `extensions/vertico-sort.el`).
- **Fact.** Persistence across sessions is the separate `savehist` package
  (lispref "Minibuffer History", `minibuf.texi:609`).

## 7. `M-x`: `execute-extended-command` and `read-extended-command`

- **Fact.** `execute-extended-command` reads a name with
  `read-extended-command`, then sets `this-command` and
  `real-this-command` to the chosen function and runs it with
  `command-execute ... 'record` (`lisp/simple.el:2601-2647`, the assignment
  at `2639`), so `last-command` and `repeat` see the real command.
- **Fact.** `read-extended-command-1` calls `completing-read` with a function
  table over `obarray` whose `metadata` action returns
  `(affixation-function . read-extended-command--affixation)` and
  `(category . command)`, but only when `suggest-key-bindings` is non-nil
  (`simple.el:2349-2434`, metadata at `2397-2400`). The predicate is
  `commandp` plus `read-extended-command-predicate` called with the symbol
  and the original buffer (`:2424-2433`). History is
  `extended-command-history` (`:2248`, `:2434`).
- **Fact.** `read-extended-command-predicate` (`:2251-2290`) chooses which
  commands appear: nil (all), `command-completion-default-include-p` (honour
  a command's `completion-predicate` property, else its declared modes;
  `:2450-2461`), `command-completion-using-modes-p`, or
  `command-completion-using-modes-and-keymaps-p` (`:2474-2501`). `M-X`
  cycles between "all" and "this buffer" variants via
  `extended-command-versions` (`:2292-2311`).
- **Fact.** Core M-x annotation: `read-extended-command--affixation` adds
  " (alias)", " (obsolete-replacement)", or " (KEY)" from
  `where-is-internal` (`simple.el:2509-2527`). After running, if the command
  has a binding (or a shorter `M-x` abbreviation), a timer shows "You can
  run the command X with KEY" (`suggest-key-bindings`, `:2529`; message at
  `:2593-2599`; timer at `:2648-2690`).
- **Fact.** A package hides its commands from `M-x` by putting a
  `completion-predicate` property on the symbol; Vertico does so for its
  navigation commands (`vertico.el:711-723`).
- **Fact.** `current-minibuffer-command` exists (`src/keyboard.c:13819`), but
  Marginalia and Embark still record `this-command` in
  `minibuffer-setup-hook`, citing Emacs bug#80815
  (`marginalia.el:1345-1350`; `embark.el:707-709`).

## 8. Mechanism versus UI

| Part | Kind | Where |
|---|---|---|
| Table protocol (try/all/test/boundaries/metadata) | Mechanism | `minibuf.c`, `minibuffer.el:28-345` |
| Metadata lookup with category overrides and extra properties | Mechanism | `minibuffer.el:117-226`, `:1265-1369`, `:2652` |
| Styles registry and dispatch | Mechanism | `minibuffer.el:1158-1456` |
| Lazy highlighting protocol | Mechanism (front-end contract) | `minibuffer.el:4502-4540` |
| History lists and `add-to-history` | Mechanism | `minibuf.c:976-980`, `subr.el:2719` |
| Minibuffer reading, keymaps, require-match, `exit-minibuffer` | Mechanism with UI policy | `completing-read-default`, `minibuffer.el:5161` |
| `*Completions*` buffer, TAB completion, cycling, sorting for display | UI | `minibuffer-completion-help` (`minibuffer.el:2830`) and friends |
| `completing-read-function` | The UI slot | `minibuffer.el:5157` |
| `M-x` command collection, predicate, history | Feature on top of the mechanism | `simple.el:2248-2501` |
| `M-x` binding annotation and after-run hint | UI policy of the feature | `simple.el:2509-2690` |

**Inference.** The split is clean for tables, styles and metadata, and weak
at the UI boundary: there is no core notion of "the current completion
session" (current candidate, candidate list, refresh), so each package that
needs one (Consult, Embark) defines private hooks that each UI must fill
(see [hooks-and-advice.md](hooks-and-advice.md)).
