# The packages: what each provides, needs, and hooks into

Supporting file for [README.md](README.md), question 2. Every advice and hook
is listed with its Tuna replacement in [hooks-and-advice.md](hooks-and-advice.md).

Clones in `/home/jay/Code/emacs-packages/` (shallow clones; permalink form
`https://github.com/<owner>/<repo>/blob/<commit>/<file>#L<n>`):

| Package | Repository | Commit | Commit date |
|---|---|---|---|
| vertico | github.com/minad/vertico | `c60d80215d19b4b36c0ba49599b6815ed35f2ac1` | 2026-10-11 |
| orderless | github.com/oantolin/orderless | `e271a8ec938929b726331236cf56d1c44571122e` | 2026-10-13 |
| marginalia | github.com/minad/marginalia | `381af583d2530796b9955ff2fe0cba3ad3119943` | 2026-10-10 |
| consult | github.com/minad/consult | `a64569f377b8bc0f62e1d2ae0f3ee48ba4a7cc1c` | 2026-10-04 |
| embark | github.com/oantolin/embark | `87e53827cf6659dcc4ac4e54be9af34aeca44f6e` | 2026-08-12 |
| corfu (context only) | github.com/minad/corfu | `b468efac023dda39332acc943edc9895c80b5a6f` | 2026-09-13 |

Cape and prescient were not cloned (out of scope for the first slice).

## Vertico

**Provides.** A vertical candidate list under the minibuffer prompt, with
navigation commands (`vertico-next`, `-previous`, `-first`, `-last`,
`-scroll-*`, `-next-group`, `-exit`, `-exit-input`, `-insert`, `-save`;
`vertico.el:615-700`) and a keymap (`vertico-map`, `:127`).

**How it replaces the UI.** It does not replace `completing-read-function`.
`vertico-mode` puts `:around` advice on `completing-read-default` and
`completing-read-multiple` (`vertico.el:703-709`); the advice adds
`vertico--setup` to `minibuffer-setup-hook` only for the duration of that
call and removes it afterwards (`vertico--advice`, `:607-613`, comment "Do
not use `minibuffer-setup-hook' for idempotency"). `vertico--setup` installs
its keymap and two buffer-local hooks: `pre-command-hook` →
`vertico--prepare` and `post-command-hook` → `vertico--exhibit`
(`:594-605`). So Vertico keeps the whole default reading machinery (keymaps,
require-match, history, `exit-minibuffer`) and only adds presentation.
**Inference:** the advice is a workaround for the missing extension point
"a completion read is starting in this minibuffer"; `minibuffer-setup-hook`
fires for every minibuffer read, and `completing-read-function` would require
reimplementing the read.

**What it needs from core.** `minibuffer-completion-table`,
`-predicate`, `minibuffer--require-match` (a private variable),
`minibuffer-default`, `completion-metadata`, `completion-boundaries`,
`completion-all-completions` (so it honours every style), `test-completion`,
`completion-lazy-hilit` (`vertico.el:226-293`).

**Candidate pipeline** (`vertico--compute`, `vertico.el:226-293`), run from
`post-command-hook` via `vertico--exhibit` → `vertico--update`
(`:337-363`, `:479-487`), skipped when the input is unchanged, interruptible
by new input (`while-no-input`):

1. metadata for the text before point; boundaries; the field;
2. `completion-all-completions` with lazy highlighting; the last `cdr` is
   the base;
3. file completion: drop ignored extensions;
4. sort: `vertico-sort-override-function`, else the table's
   `display-sort-function`, else `vertico-sort-function` (default: history,
   then length, then alphabetical; `:95-104`, `:220-224`);
5. move the default, then the exact field (and `field/` for files) to the
   front; drop consecutive duplicates;
6. group by `group-function`;
7. decide whether the prompt itself is selectable, and keep the previously
   selected candidate selected if it is still present ("lock").

Annotation (`vertico--affixate`, `:195-207`) and highlighting run only on the
visible candidates (`vertico--arrange-candidates`, `:527-562`, the calls at
`535-537`). Display is an overlay `before-string` after the input
(`vertico--display-candidates`, `:565-570`).

**Extensions.** Presentation is split into `cl-defgeneric` methods
(`vertico--format-candidate`, `--arrange-candidates`,
`--display-candidates`, `--resize-window`, `--prepare`, `--setup`,
`--advice`; `:520-613`), and the extensions override them with
`cl-defmethod ... &context (MODE (eql t))`: flat (`vertico-flat.el:89,104`),
grid (`vertico-grid.el:116`), reverse (`vertico-reverse.el:75,80`), buffer
(`vertico-buffer.el:210,212`), mouse (`vertico-mouse.el:69,80`), indexed
(`vertico-indexed.el:55,67`), unobtrusive (`vertico-unobtrusive.el:61`),
multiform (`vertico-multiform.el:174`). `vertico-multiform` turns modes on per
command or per category (`vertico-multiform-commands`,
`-categories`, `:62-79`) by reading the category from metadata at setup
(`:110-140`). **Inference:** generic functions with mode-conditioned methods
are Vertico's own, proper extension point; Tuna's analogue is a presentation
registry or settings read by the UI plugin.

**Data structures.** Minibuffer-local variables: `vertico--input` (input
string and point), `--candidates` (list of strings), `--index`,
`--total`, `--base`, `--metadata`, `--groups`, `--lock-candidate`,
`--allow-prompt`, `--hilit` (`vertico.el:147-193`).

## Orderless

**Provides.** One completion style, `orderless`: the input is split into
components (on spaces by default, `orderless-component-separator`, `:96`);
each component is compiled to a regexp or predicate by the matching styles
(`orderless-matching-styles`, default literal then regexp, `:119-135`), with
per-component overrides by style dispatchers (`orderless-style-dispatchers`,
`:185`; the default affix dispatcher maps `!` not, `&` annotation, `,`
initialism, `=` literal, `^` literal prefix, `~` flex, `%` char-fold;
`:137-183`). A candidate matches when every component matches, in any order.
Smart case (`:207`).

**Extension points used.** Only official ones: it registers itself in
`completion-styles-alist` (`orderless.el:632-635`); it uses
`completion-boundaries`, `all-completions` with `completion-regexp-list` for
speed (`:513-557`), and `completion-lazy-hilit-fn` (`:567-580`). The `&`
dispatcher matches against the annotation by calling the table's
`affixation-function`/`annotation-function` from metadata (`:316-344`).
**No advice, no hooks.**

**Data structures.** A compiled pattern is `(predicate . regexps)`
(`orderless-compile`, `:454-490`); matching styles are functions from string
to regexp (or predicate); dispatchers are functions
`(component index total) → styles | string | (styles . string) | nil`
(`orderless--dispatch`, `:392-433`).

## Marginalia

**Provides.** Annotations ("marginalia") for candidates by category: an
annotator registry `marginalia-annotators`, an alist from category to a list
of annotators (the first active; `marginalia-cycle` rotates;
`marginalia.el:91-125`), and a set of annotators (command: binding plus first
docstring line, `:641-647` with `marginalia-annotate-binding` `:457-461`;
buffer `:936`; file `:1004`; and about twenty others). Fields are formatted to
aligned columns with `display (space :align-to …)` text properties, computing
widths from the window (`marginalia--fields` `:429`, `marginalia--align`
`:1279-1303`, `marginalia--affixate` `:1305-1327`). Annotations run in the
original buffer and window (`:1319-1327`) and are cached (`:1255-1277`).

**How it finds a category.** `marginalia-classifiers`
(`:127-136`), tried in order:
1. `marginalia-classify-by-command-name`: `marginalia-command-categories`
   maps the command that opened the minibuffer to a category
   (`:169-175`, `:1219-1225`; it records `this-command` at minibuffer setup,
   `:1345-1350`);
2. `marginalia-classify-original-category`: the table's own `category`,
   except `symbol-help` (`:1227-1233`);
3. `marginalia-classify-by-prompt`: regexps over the prompt text, e.g.
   `"\\<M-x\\>"` → `command`, `"\\<variable\\>"` → `variable`
   (`marginalia-prompt-categories`, `:138-159`; `:1243-1253`);
4. `marginalia-classify-symbol`: the table is an obarray or a list of
   symbols (`:1235-1241`).
For `M-x` the table already declares `command` (`simple.el:2397-2400`), but
only while `suggest-key-bindings` is non-nil, so the prompt rule backs it up.

**Extension points used.** Three advices and a hook
(`marginalia-mode`, `:1371-1386`): `:before-until` advice on
`completion-metadata-get` (twice, for the compat copy) so that every
consumer asking for `affixation-function` gets Marginalia's and every
consumer asking for `category` gets the classifier result
(`marginalia--completion-metadata-get`, `:1329-1343`); `:filter-return`
advice on `completion-all-completions` to record the base position for file
annotations (`:1356-1368`); `minibuffer-setup-hook` to record the command and
reset the cache (`:1345-1354`); plus buffer-local `window-state-change-hook`
and `context-menu-functions` (`:1352-1353`).
**Inference:** the advice on `completion-metadata-get` is the heart of it: it
lets Marginalia annotate for every UI (default, Vertico, Icomplete, Embark)
without each UI knowing about it, because core has no annotator registry and
no "classify this read" step.

## Consult

**Provides.** Commands (`consult-buffer`, `consult-line`, `consult-grep`,
`consult-history`, …) built on an internal API:

- `consult--read` (`consult.el:2926-2985`, implementation `consult--read-1`
  `:2864-2924`): a keyword wrapper over `completing-read` that adds
  `:category`, `:group`, `:annotate`, `:sort`, `:lookup` (map the chosen
  string back to an object), `:state` (preview), `:preview-key`,
  `:narrow`, `:history`, `:add-history`, and async tables. It builds the
  metadata itself and merges it with the table's (`:2895-2903`).
- **Preview** through a *state function* called with
  `setup`, `preview CAND` (repeatedly, `nil` to reset), `exit`, `return CAND`
  (`consult--with-preview`, documentation `:1855-1890`, implementation
  `consult--with-preview-f` `:1764-1853`). Per-type state functions such as
  `consult--buffer-preview` (`:4859-4893`) switch the original window to the
  candidate and restore the window's buffer history afterwards.
- **Async sources**: curried functions `(sink) → (action) → …` composed with
  `consult--async-pipeline` (`:2084-2146`); actions are `setup`, `destroy`,
  `flush`, `refresh`, `cancel`, `nil` (get candidates), a list (append), a
  string (new input). Stages include `consult--async-min-input`,
  `-throttle`, `-process` (external commands), `-dynamic` (a function of the
  input), `-transform`, `-highlight`, `-split` (split input like
  `#async#filter`), `-merge` (`:2207-2695`).
- **Multi-source** `consult--multi` (`:3222-3300`): sources are plists with
  `:items` or `:async`, `:name`, `:narrow`, `:category`, `:enabled`,
  `:hidden`, `:face`, `:annotate`, `:history`, `:default`, `:action`, `:new`,
  `:state` (`:3233-3275`). It returns `(candidate . source-plist)`.
  Candidates from different sources carry their category in a
  `multi-category` text property (`consult--multi-format`, `:3116-3131`), and
  to keep equal strings from different sources apart Consult appends an
  invisible Unicode private-use character, "tofu", encoding the source index
  (`consult--tofu-char`, `:561-571`; lookup by tofu, `:3085-3110`).
- **Narrowing**: a source's `:narrow` key; `consult-narrow` sets
  `consult--narrow` and the predicate, shows an indicator overlay, and
  refreshes (`:1937-1959`; setup `:1998-2008`).
- **`consult-buffer` sources** (`consult-buffer-sources`, `:239-255`): buffer,
  hidden buffer, modified buffer, other buffer, recent file, buffer and file
  registers, bookmark, and hidden project variants. Example:
  `consult-source-buffer` (`:5027-5039`) has `:narrow ?b`, `:category buffer`,
  `:history buffer-name-history`, `:state consult--buffer-state`, `:default t`.
- **Per-command customization** by `this-command`
  (`consult-customize`, `:3313`; `consult--customize-args`, `:3329-3339`).

**What it needs from a completion UI.** The current candidate and a way to
refresh the display. Core provides neither, so Consult defines two private
hooks that each UI integration fills: `consult--completion-candidate-hook`
and `consult--completion-refresh-hook` (`:538-548`), with integrations for
the default UI, Vertico (`:5708-5727`), Mct (`:5729-5732`) and Icomplete
(`:5734-5761`).

**Advice and hooks.** See [hooks-and-advice.md](hooks-and-advice.md). The
notable ones: temporary `:around` advice on `run-hooks` to filter
`find-file-hook` while opening a file for preview (`:1381-1391`,
`:1453`); `cl-letf` over `display-buffer-in-tab` during buffer preview
(`:4879`); a buffer-local replacement of `completion-styles` and
`completion-styles-alist` to split async input from filter input
(`consult--split-setup`, `:2049-2081`).

## Embark (only its hooks into completion)

- **Targets.** `embark-target-finders` (`embark.el:166-200`), a list of
  functions returning `(type . target)`. For completion the type is the
  category from metadata: `embark-target-top-minibuffer-candidate`
  (`:1037-1060`) recomputes the top candidate itself because core has no
  "selected candidate".
- **Candidates.** `embark-candidate-collectors` (`:2714-2730`), e.g.
  `embark-minibuffer-candidates` (`:2803-2815`), which reruns
  `completion-all-completions`.
- **Per-UI integration.** For Vertico it adds its own finder and collector
  that read `vertico--candidate` and `vertico--candidates` (`:3625-3642`),
  and a `cl-defmethod` on `vertico--format-candidate` to mark selected
  candidates (`:3653-3666`). Similar code exists for Ivy (`:3702-3705`).
- **Global hooks**: `minibuffer-setup-hook` to record `this-command` as the
  default action (`:707-709`); `completion-setup-hook` for the
  `*Completions*` buffer (`:700`).
- **embark-consult**: fills Consult's candidate hook
  (`embark-consult.el:55`) and advises `embark-collect--metadatum`
  (`:474-475`).
- **Inference.** Everything Embark needs from completion is: the current
  candidate with its type, the full candidate list with its type, the
  command that opened the read, and a way to quit the read and run an action
  afterwards. A Tuna completion session that exposes those as typed data
  needs no per-UI integration code.

## Corfu (context only)

In-buffer completion (`completion-at-point`) replaces
`completion-in-region-function` buffer-locally (`corfu.el:1373`), uses
`pre-command-hook`/`post-command-hook` (`:910-913`), and advises
`completion--capf-wrapper` and `eldoc-display-message-no-interference-p`
(`:1428-1431`). Out of scope for the first slice; the same session and
pipeline should serve it later.
