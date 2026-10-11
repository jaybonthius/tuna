# Lane 4: Real-package stress tests against Tuna's ADRs 1–7

Method: read `tuna/docs/overview.md` and ADRs 1–7, then grepped the installed sources under `/home/jay/.config/emacs/var/elpaca/sources/` (magit, transient, vertico, consult, corfu, cape, embark, marginalia, orderless, avy, meow, hel, yasnippet, eat, gptel, undo-fu) and the Emacs 30 tree `/home/jay/Code/emacs/lisp/` (org, dired, wdired, eglot, flymake, eldoc, treesit, comint, eshell, tramp, compile, xref, project, ediff, smerge, repeat, which-key). Line numbers below refer to those files (checked in this run).

**Not installed locally, so characterised from general knowledge and marked "(unverified)":** Evil, vterm, multiple-cursors, undo-tree, vundo, popper, tempel. `hel` (a Helix-style modal package) is installed and substitutes for Evil on emulation maps.

**Shallow areas:** Org babel/export/capture internals, TRAMP internals and Eshell were checked only at the entry-point level. Evil, vterm, multiple-cursors, vundo, popper and tempel were not read. Nothing was run or prototyped; all verdicts are design review.

Tuna ↔ Emacs terms used below: *text node* ≈ a buffer's text with properties; *rich node* ≈ no Emacs equivalent (nearest: text with `display`/`invisible`/widget overlays); *job* ≈ no equivalent (nearest: `make-thread`/async processes); *baton* ≈ the Lisp global lock; *receipt* ≈ none (`unload-feature`).

---

## Summary

- **Corner risk 1 (CR1):** ADR 6 gives text nodes "text properties" but never defines properties, overlays or property-carrying strings. Nearly every package below (vertico, corfu, consult, embark, marginalia, orderless, avy, flymake, eglot, yasnippet, magit, org, dired, wdired) depends on them. Strings must be able to carry properties, and decorations need their own revision counter so a decoration change doesn't invalidate jobs.
- **CR2:** ADR 6 defers "moving past the end of one text node into the next". Point, region, markers, undo positions, isearch, kill and `next-error` have no defined meaning in multi-node buffers. Rich Magit, Dired, agenda and xref buffers all depend on that meaning. Fix: decide the coordinate model now. Do not design the traversal yet.
- **CR3:** ADR 4 says settings are "ordinary data in owning objects, not dynamic variables". Real packages `let`-bind `default-directory`, `case-fold-search`, `inhibit-read-only` and `completion-extra-properties` around calls (e.g. project.el, wdired.el:444). A dynamically scoped override layer is needed.
- **CR4:** ADR 3 has only interactive commands (suspendable, baton-holding) and jobs (no live objects). Packages need a third thing: a non-interactive, baton-holding, suspendable task started by timers, process events, hooks and capf callers (Eglot completion, Consult preview, gptel, Magit refresh). Direct-style I/O that suspends (TRAMP-style `file-exists-p`) also conflicts with ADR 4's "no yield mid-edit".
- **CR5:** ADR 3 gates every job result on revision equality and otherwise discards it. This is wrong for append-only streams (gptel, terminals, grep) and causes flicker for highlights and diagnostics. Needs a per-job validity policy plus "rebase through changes".
- **CR6:** There is no interrupt path. C-g, `while-no-input` (used by corfu.el:709 and consult.el:2266, 3835, 3928) and `input-pending-p` cannot work if input is only seen when the loop dequeues it. One reserved side channel is needed.
- **CR7:** Keymap layering (transient, emulation, minor, per-node/per-range, global), pending-prefix state, the command-loop hook set (pre/post-command etc.), `read-key`/`unread-command-events` and prompt-answer injection are unspecified. Modal editing, which-key, hydra, transient, repeat, vertico, corfu and embark all depend on them.
- **CR8:** ADR 7's "server knows all, browser holds no state" breaks for visual-line motion, `posn-at-point` popups, variable-height lines and high-throughput terminals. Needs a geometry report from the browser, CSS-anchored popups, and an opt-in client-owned widget node (Datastar's `ignore-morph`, `patchElements.ts:164`).
- **Best opportunities:** (a) node-identity reconciliation makes Magit/Dired/agenda refresh preserve point and folds for free; (b) typed candidates replace string+text-property candidates in completion; (c) persistent text turns undo into a native version tree and job highlights into cheap snapshots; (d) multi-selection as first-class focus; (e) real browser popovers, tables and images instead of posframe/child-frame hacks.
- **Text vs rich nodes: both.** Text the user edits, searches, yanks or regex-parses stays in text nodes with properties and overlays. Structure, chrome, selection state and widgets are rich nodes. Each rich node needs an optional text projection so search, copy and region work across both (section "Text nodes vs rich nodes").

---

## Text nodes vs rich nodes (the question asked)

Emacs builds UIs by writing text and attaching properties because the buffer is the only structure it has. Evidence from the sources:

- Magit sets `keymap` and `invisible` on text and hides sections with `make-overlay` + `(overlay-put o 'invisible t)` (`magit-section.el:972-975`); it also pushes `keymap` into `text-property-default-nonsticky` (line 501).
- Dired stores marks and flags as characters in column 0 and filenames behind `dired-filename`/`invisible` properties (`dired.el:1933, 2074-2090`).
- Wdired makes only the filename editable by setting `read-only` on everything else (`wdired.el:332-348`).
- Org folds by setting `invisible` to fold-specific values (`org-fold-core.el:140-169`).

Each of those buffers is simultaneously (1) data, (2) a view, and (3) an editable, searchable, copyable text. In Tuna the three can be separated, but only some of them should be.

Proposed mapping:

| Emacs-as-text pattern | Tuna mapping | Why |
|---|---|---|
| Hierarchy/containers (Magit sections, org outline, Dired subdirs, xref file groups, agenda blocks) | rich nodes with stable identity, `collapsed` as view state | Identity gives point/fold preservation across refresh; no `invisible` + `magit-section-ident` workaround |
| Leaf content the user reads as lines (diff hunks, git log lines, file text, compile output, terminal scrollback) | text nodes with properties/overlays | Region, isearch, regexp, `kill-ring`, `occur` all expect text; hunk-region staging needs partial selection inside a hunk |
| Tabular data (Dired rows, agenda rows, candidate lists, org tables) | rich table/row nodes whose editable cells are text nodes | Alignment by CSS, columns, sort/filter by data; wdired becomes "edit name cells, diff by row identity" |
| Chrome (minibuffer prompt, headings' fold indicators, buttons, checkboxes, tabs) | rich nodes, non-focusable or focus-as-widget | Replaces `read-only`+`cursor-intangible`+`display` hacks |
| Marks, flags, selection, current-item highlight | node state (attribute), not characters | Removes regex-over-buffer to find marked files |
| Inline images, tables inside prose, inline widgets in an editable file (org, markdown) | decorations on a text range that *replace its rendering* (Emacs `display` property) with an inline rich node, text stays underneath | Keeps file text authoritative; needs the CR1/CR8 decision |

Conclusion (inference): both. The glue that must exist is a **text projection** on every rich node (what a user would search/copy/yank) and a defined **linear order** over the buffer so cross-node operations work (CR2). Without that glue, rich buffers lose every text command Emacs users rely on.

---

## Inventory

Status values: covered, later, corner-risk, divergence. "ADR" = where the current design bears on it.

### Org mode

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 1 | Folding headings/drawers/blocks | `invisible` text property with fold-specific values + `buffer-invisibility-spec` (`org-fold-core.el:140-169`); Emacs folds are buffer-wide, so per-window folds need indirect buffers | Org, outline-mode, `hs-minor-mode` | ADR 6 nodes; no invisibility concept | divergence | Fold = view state per window/node attribute on an outline overlay or rich node, not a text property. Cost: `org-fold-*` API and `search-forward` skipping folded text must be re-implemented; `isearch` must know folded ranges. Per-window folds are a win |
| 2 | Org element parse + cache | `org-element-parse-buffer`, incremental `org-element-cache` keyed on change (`org-element.el:302,624`) | Org everything | ADR 3 jobs on snapshots; ADR 6 revisions | covered | Parse in a job per revision; result is an immutable tree. Commands needing a fresh tree for the current revision must wait (suspend) for it, see CR4. Org cache invalidation via change records maps to ADR 6 change records |
| 3 | Links, buttons, clickable text | `keymap`/`mouse-face`/`help-echo` text properties, `button-map` | Org, Help, Magit, Embark | ADR 7 stable node IDs for clicks; no ranged property API | corner-risk | CR1: per-range keymap/click action must be a defined property family |
| 4 | Babel execution | `org-babel-execute-src-block`, `call-process`/comint sessions (`ob-core.el:330,799-810`), results inserted as text | Org | ADR 3 jobs/subprocesses | later | Run as subprocess job; insert result on editor thread at a marker (CR5 policy: validate marker alive, not revision). Scheme blocks can `eval` in-process (ADR 2 trust). `:session` = a terminal/comint node |
| 5 | Agenda over many files | Visits each file with `find-file-noselect`, `org-element`/regexp scan, builds agenda buffer with `org-marker`/`org-hd-marker` text properties (`org-agenda.el`, finalize hook line 1025) | Org agenda | ADR 3 jobs; ADR 6 markers are buffer-owned | divergence | Index files off-thread without opening buffers (location = file + offset + revision); rows are rich nodes referencing a `location` value. Markers into unvisited files do not exist in ADR 6, so a `location` value type is needed (cheap) |
| 6 | Agenda refresh/filter, bulk actions | Rebuild whole buffer (`org-agenda-redo`); filters as text-property hiding; `B` bulk marks | Agenda | ADR 6 stable identity | divergence | Reconcile by row identity: point, marks, filters survive. Needs CR2 for marks/region-on-rows |
| 7 | Capture | Temp indirect/narrowed buffer + `org-capture-mode` minor mode (`org-capture.el:593`), refile uses markers into other buffers | Org | ADR 6: buffer owns its node tree; no indirect buffers/narrowing | later | Needs narrowing and indirect/shared-text buffers (CR12). Natural in Tuna: second buffer view over the same persistent text version |
| 8 | Export (ox) | Pure element-tree → backend transform, output to buffer/file | Org | ADR 3 jobs | covered | Perfect job fit on a snapshot. Tuna can preview in the browser as a rich node (HTML export is native) |
| 9 | Inline images / LaTeX preview | `display` text property + `create-image`, image overlays | Org, Markdown, eww | ADR 7 browser renders HTML | divergence | Inline rich node replacing a text range at render time; needs CR1 (replace-rendering decoration) and CR8 (variable line height) |
| 10 | Tables | Text with `\|` alignment, formulas, `org-table-align` (`org-table.el:236`), column widths via spaces | Org, table.el, markdown tables | ADR 6 rich nodes | divergence | File remains pipe text; editor shows a table decoration (grid via CSS) with cells editable; formulas run as jobs. Do not make the table a separate node tree that must round-trip to text on every edit (open question) |
| 11 | Persistent caches | `org-persist` (`org-persist.el:842-877`) | Org | ADR 5 session slots / SQLite plugins | covered | Plugin-owned cache; SQLite allowed |

### Magit and transient

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 12 | Section tree in a text buffer | EIEIO `magit-section` objects with markers; `magit-section` text property on every char; hide/show via overlay `invisible` (`magit-section.el:954-975`, `post-command-hook` highlight at 503, 1736) | Magit, forge, many | ADR 6 node tree, stable identity | divergence | Rich section node (type, identity key, `collapsed`) containing text nodes. `magit-section-at` becomes focus→ancestor lookup. Must keep an Emacs-compat `section-at` function. Cost: hunk-region staging needs region within a text node only (fine); region across sections needs CR2 |
| 13 | Refresh preserving point | Erase and rebuild; restore by `magit-section-ident` + relative position (`magit-mode.el` refresh) | Magit | Stable node identity (ADR 6) | divergence | Reconcile new tree against old by identity key; keep focus, fold state, scroll. Better than Emacs, less code. Needs the identity key to be author-supplied, not auto-generated |
| 14 | Async git processes + filter + sentinel | `make-process`, `set-process-sentinel` (`magit-process.el:647`), ANSI handling (`magit-process.el:277`) | Magit | ADR 3 subprocess reader threads post messages | later | Process output arrives as loop messages (good). CR13: need coalescing/backpressure |
| 15 | Many synchronous git calls per refresh (`magit-git-lines`) | `process-file`/`call-process` blocking | Magit | Single baton thread | corner-risk | A command doing blocking process calls with the baton held freezes the editor (Emacs freezes too). Tuna should make these suspend (CR4) so keys keep flowing, or run the status gather as a job and build the tree on the editor thread |
| 16 | Building a tree off-thread | n/a (Emacs can't) | — | ADR 3: jobs "must not touch live editor objects" | later | Clarify: a job may construct fresh, unpublished nodes and hand ownership over; otherwise a large Magit tree is built on the editor thread |
| 17 | `with-editor` (git commit message) | `GIT_EDITOR=emacsclient` + server | Magit, forge | Web server exists (ADR 7) | later | Tuna needs an "edit this file for an external process" endpoint (Unix socket/HTTP), exit by finishing a buffer. A plugin, no ADR change |
| 18 | Diff display: word-level refine, syntax in hunks | `diff-refine-hunk` overlays, font-lock | Magit | Highlight jobs (ADR 3) | later | Job on snapshot returns spans; overlays only (CR1) |
| 19 | Blame, margins, line annotations | overlays with `before-string`/margin `display` | Magit blame, git-gutter | ADR 7 browser | divergence | Annotation columns as real rich gutters; needs overlay model (CR1) |
| 20 | Transient popups | Prefix command; `transient--pre-command` on `pre-command-hook` (`transient.el:2058-2061`), side window via `display-buffer-in-side-window` (247-266), infix arg EIEIO objects, `transient--emergency-exit` (126-135), saved values/history | Magit, Casual (`casual` installed), many | ADR 3 suspension for input; keymaps | later | A transient is naturally a suspended command that owns a modal keymap and renders a rich popup. Needs CR7 (modal keymap layer, key peek, command classification) and CR10 (window placement). Values/history go in session slots (ADR 5) |
| 21 | Auto-revert on file/ref change | `file-notify`, `auto-revert-mode` (`autorevert.el:296`) | Magit, all buffers | ADR 3 subprocess/job messages; ADR 5 | later | A watcher job posts a message |

### Dired and wdired

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 22 | Listing as text parsed with regexps | `ls` output; `dired-move-to-filename`, `dired-get-filename` (`dired.el`) | Dired and dozens of extensions | ADR 6 | divergence | Table of row nodes (identity = path), columns as cells. Directory read as a job. Cost: extensions that parse the buffer text (dired-subtree, dired-narrow, `dired-map-over-marks`) must use the node API |
| 23 | Marks/flags | Characters in column 0, scanned by regex (`dired-marker-char`, line 567) | Dired | — | divergence | Row attribute. Region-based marking (`m` over an active region) needs CR2 |
| 24 | Multiple subdirectories in one buffer | `dired-subdir-alist` (line 632) | Dired `i` | ADR 6 tree | covered | Natural as nested container nodes |
| 25 | wdired (edit filenames in place) | Toggle `read-only` text property on everything but filenames, diff on finish, `dired-rename-file` (`wdired.el:253-348`) | wdired, `wgrep`-like | Text nodes inside cells | divergence | The name cell is a text node; editing is ordinary; commit diffs by row identity. Undo, `query-replace`, multi-cursor work for free once cells are real text nodes. Requires CR2 so a command like `replace-regexp` can span cells |
| 26 | Hide details | `invisible` text/overlays (`dired.el:1933,2074-2090`) | Dired | — | divergence | Column visibility toggle |
| 27 | Remote dired (TRAMP) | `file-name-handler-alist`, `ls` over ssh | Dired, Magit remote | ADR 5 Files plugin only | later | See TRAMP rows |
| 28 | Async copy/delete with progress | `dired-async`, `make-process` | Dired | ADR 3 jobs | covered | Job with progress rows (rich node) |

### TRAMP

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 29 | Transparent remote file names | Every file primitive dispatches through `file-name-handler-alist`/`tramp-file-name-handler` (`tramp.el:1357,1572`); `default-directory` is buffer-local; `process-file`/`start-file-process` run remote | Dired, Magit, Eglot, compile, project | ADR 5 "files plugin"; no filesystem abstraction | later | Decide early that file access goes through a `FileSystem`/`Vfs` service (ADR 2 service) and `default-directory` is a scoped value (ADR 4). Paths must be a value type, not a bare string. Cost to add later: every package calls file primitives |
| 30 | Blocking I/O with timeouts and C-g | Synchronous; freezes UI | TRAMP | ADR 3 | corner-risk | CR4/CR6: remote primitives should suspend the calling command (editor stays live) and be interruptible. Implicit yielding conflicts with ADR 4's "no yield mid-edit"; must be named (e.g. `await` primitives) or forbidden inside atomic regions |
| 31 | Remote editing alternative | n/a | — | ADR 7 browser UI | divergence | Run a headless Tuna on the remote host and point a tab at it (no TRAMP for the common case). Cost: needs install on remote; keep Vfs for sudo/docker/ssh zero-install |

### Evil, Meow (modal editing)

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 32 | Modal states as keymap layers | `emulation-mode-map-alists` (meow: `meow-core.el:167-171`; hel: `hel-core.el:32-65`), minor-mode maps, `overriding-*` maps | Meow, hel, Evil (unverified), god-mode | ADR 3 "resolves keys through the active keymaps"; ADR 2 keymaps via `defkeymap` | corner-risk | CR7: no keymap layer order or per-buffer/per-node/per-range layer defined. Modal plugins need a documented priority stack with at least one layer above minor modes and below transient |
| 33 | Cursor shape per state | `cursor-type` buffer-local, `set-cursor-color` (`meow--update-cursor`) | Meow, Evil | ADR 7 server renders cursor | covered | Cursor style = scoped setting (ADR 4) read by renderer. Browser can render block/bar/underline natively, even per-cursor |
| 34 | Operator-pending, count prefix, text objects | `read-key`/`read-event` inside a command, `prefix-arg`, `evil-define-operator` (unverified) | Evil, Meow (`meow-keypad`) | ADR 3 suspension for input | later | `read-key` needs listing as a suspension point alongside `read-string`. Counts need `prefix-arg` state. Fits, if `read-key` returns a structured event (not a string) |
| 35 | `.` repeat / repeat-mode | Record keys via `pre/post-command-hook`, `this-command-keys`, `last-repeatable-command`; `repeat.el:285` uses `set-transient-map` | Evil, Meow, repeat-mode, hydra | ADR 3 queue of events | corner-risk | CR7: need command-loop hooks, `this-command-keys`, `last-command`, `unread-command-events` as defined surface. Commands in separate threads must not make these thread-local by accident |
| 36 | Selection/region semantics, mark ring | `mark`, `transient-mark-mode`, `use-region-p`, `deactivate-mark` | Meow, Evil visual, Embark, all | ADR 6 focus = node + point; no mark | corner-risk | CR2/CR9: mark/region/selection must be defined, ideally as a list of selections |
| 37 | Keypad / leader key translation | `read-key-sequence`, key-translation maps (meow keypad) | Meow, Doom | ADR 3 | later | Fits if there is a key-translation stage before keymap lookup |
| 38 | Beacon / multiple cursors | Fake cursors as overlays, replay command per cursor with saved state (`mc/execute-command-for-all-cursors`, unverified); meow beacon uses kmacro | multiple-cursors, Meow beacon, Evil-mc | ADR 6: "focus is a node plus … a point" | divergence | CR9: first-class multi-selection (list of selections, one primary); `(point)` = primary head. Edits applied atomically across selections in one change/undo group. Cost: porting commands that assume one point means wrapping them in `for-each-selection` |

### Completion stack (Vertico, Consult, Orderless, Marginalia, Embark, Corfu, Cape)

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 39 | Completion table protocol | Function `(string pred action)` returning candidates/metadata/boundaries; `completion-metadata-get` (`minibuffer.el:167`), `completion-category-defaults` | Everything in this section | ADR 3 mentions `completing-read` only | later | Replicate the protocol (metadata: category, group, annotation, affixation, display-sort, cycle-sort). Tables are closures that may read live state: call on the editor thread, never in a job |
| 40 | Candidates as strings with text properties | Consult tags candidates with text props; Embark reads them; orderless/vertico add face props | Consult, Embark, Marginalia, Orderless | Strings have no properties in Gerbil | corner-risk | CR1: need a property-carrying string value (`propertize`, `get-text-property`, `buffer-substring` with props, `format`/`concat` preserving them) |
| 41 | Typed candidates | n/a | — | — | divergence | Candidate = struct (value, display text, annotations as rich nodes, group, category, extra data). Keep a string adapter so Emacs-style tables work. Better because identity survives sorting/filtering and `embark` gets the real object, no text-prop smuggling |
| 42 | Completion UI as minibuffer overlay | Vertico: overlay `before-string` at end of minibuffer (`vertico.el:587-619`), `pre/post-command-hook` local (622-623), recursion via `recursive-edit`/`abort-recursive-edit` (380) | Vertico, Mct, Ivy-like | ADR 3: minibuffer is a buffer, keys go there | covered | Tuna UI = a candidates rich node next to the input text node; prompt is a non-editable rich node (replaces `read-only`+`minibuffer-prompt-properties`). Requires the minibuffer to be a multi-node buffer (CR2 for minibuffer only: input node is the sole editable node, so low risk) and that `post-command-hook` runs for keys dispatched to the minibuffer (CR7) |
| 43 | Completion styles / filtering / highlighting | `completion-styles-alist`, orderless (`orderless.el`), `completion-lazy-hilit` (`vertico.el:220-244`) | Orderless, flex, partial-completion | ADR 3 jobs | divergence | Filtering of a realized candidate vector runs as a keyed job, streaming first-N, so 100k candidates never freeze typing (Emacs filters synchronously). Styles are pure functions of strings: fine as jobs. Table realization stays on editor thread |
| 44 | Async candidate streams | `consult--async-process` (`consult.el:2490`), throttle/refresh pipeline, `consult--async-split` | consult-grep/ripgrep/find/man | ADR 3: job posts one result, applied if revision current | corner-risk | CR5: needs repeated partial results to a long-lived consumer, keyed cancel, backpressure. The consumer is the candidate list, whose "revision" is the input text; cancel-by-key already covers input change |
| 45 | Live preview while selecting | Consult `:state` callbacks `(funcall state 'preview cand)`, restores window config on exit; temporary file buffers | consult-line/buffer/theme/goto-line | ADR 3, ADR 4 mutable windows | later | Preview runs on editor thread when selection changes. Needs `window-configuration` snapshot/restore as a value (CR10) and tasks for blocking opens (CR4) |
| 46 | `while-no-input` for interruptible computation | corfu.el:709, consult.el:2266,3835,3928 | Corfu, Consult, eglot | ADR 3 says long Scheme work "delays subsequent commands" | corner-risk | CR6 |
| 47 | Per-category annotation | Marginalia registry keyed by category, `annotation-function`/`affixation-function` (`marginalia.el:479-482,1334-1396`) | Marginalia | Rich nodes | divergence | Annotations are rich cells, aligned by CSS, lazy per visible row. Port cost: annotators returning propertized strings need an adapter |
| 48 | Embark: targets and actions | `embark-target-finders`, `embark-keymap-alist` (`embark.el:130-166`), runs action by injecting the target as the answer to the action's prompt, exports/collects candidates to buffers (`embark.el:94-99`) | Embark | ADR 3: prompts are suspension inside command bodies (overview example reads inside body) | corner-risk | CR7: prompt-answer injection needs commands to separate argument acquisition from body, or a dynamic prompt-handler. Recommended: `defcommand` accepts interactive-spec parameters (like Emacs `interactive`) so actions are called with explicit args. Also needs the completion session (table, input, selected candidate) as public state |
| 49 | Embark collect/export/live | Persistent buffer of candidates; export to Dired/grep/ibuffer | Embark, wgrep | ADR 6 | divergence | A "result list" rich node kind with live update; export = convert to specialised node kind (dired rows, location list) |
| 50 | In-buffer completion popup | Corfu: `completion-in-region-function`, `completion--capf-wrapper`, preview overlay (`corfu.el:278-301`), child frame positioned by pixel point (425-474), `emulation-mode-map-alists`-style local map, `pre/post-command-hook` quit rule, idle/`post-self-insert` auto trigger | Corfu, Company | ADR 7 browser DOM | divergence | Popup is a browser popover anchored by CSS to the cursor element id (no pixel round-trip, no child frame). Needs CR1 (inline preview decoration), CR7 (modal keymap + hooks) and cursor element identity (ADR 7 already requires stable ids) |
| 51 | Capf protocol and combinators | `(start end table . props)` with `:exit-function`, `:annotation-function`, `:company-*`; Cape `cape-capf-super`, buster, wrappers (`cape.el`) | Cape, Eglot, all modes | ADR 1 names | covered | Port mechanically if functions are called on the editor thread. Cape dabbrev scans buffers: runs on editor thread or as a job over snapshots (better) |
| 52 | Candidate docs/resolve lazily | `:company-doc-buffer`, `completionItem/resolve` | corfu-popupinfo, Eglot | Jobs | later | Task/job per selected candidate; popup content as rich node |
| 53 | Histories and recent-first sorting | `minibuffer-history`, savehist | Vertico, Consult | ADR 5 session slots | covered | Per-prompt-kind history slots |

### which-key, hydra, repeat

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 54 | Popup of next-key options | Idle timer + current partial key sequence + keymap enumeration (`which-key.el`, echo-keystrokes handling at 75-80) | which-key, Embark indicators | ADR 3 key resolution; ADR 2 timers | corner-risk | CR7: key resolution must expose pending prefix and enumerable bindings with docstrings. Keymaps built by `defkeymap` are data, so enumeration is easy if resolution is a visible state machine |
| 55 | Transient keymaps with exit predicate | `set-transient-map` (`subr.el:7009`), `repeat.el:285`; `overriding-terminal-local-map` | Hydra, repeat-mode, transient, avy-ish | ADR 3 | later | Same keymap stack (CR7) |
| 56 | Hydra hints with colored heads | `hydra--clearfun` on `pre-command-hook`, `lv`/posframe hint | Hydra | — | later | Hint = popover rich node. Little extra beyond transient |

### Eglot, flymake, eldoc

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 57 | JSON-RPC over process | `jsonrpc-process-connection` (`eglot.el:1202`), reader via filter | Eglot, dape | ADR 3 subprocess reader threads | covered | Reader parses off-thread, posts decoded messages |
| 58 | didChange tracking | `after-change-functions`, document version bumped (`eglot.el:1429`) | Eglot | ADR 4 revision per buffer; ADR 3 change hooks sync | covered | Revision = LSP document version. Incremental sync needs the change record (offset, deleted, inserted) in the hook |
| 59 | UTF-16 positions | `eglot-move-to-linepos-function` utf-16 | Eglot | ADR 6 code-point coordinates, store converts | later | Ask the `TextStore` interface for UTF-16 column conversion (cheap in a rope with cached counts) |
| 60 | Diagnostics as overlays | `flymake` overlays with `flymake-overlay-control` property alist (`flymake.el:76-103`), eol overlays, next/prev error via properties | Flymake, Eglot, flycheck | ADR 6 text properties; no overlays | corner-risk | CR1: overlay model. Diagnostics must survive edits by relocating (overlay = markers pair), not by being discarded (CR5) |
| 61 | Diagnostics arrive for an older revision | Flymake `report-fn` with `:region`; Emacs just drops stale | Flymake | ADR 3: discard stale | divergence | "Rebase through change records since revision R" helper for job results, otherwise highlights/diagnostics flicker every keystroke. Cost: keep a bounded change journal |
| 62 | Eldoc | `eldoc-documentation-functions` composition (`eldoc.el:46,145`), idle timer (298), echo area/posframe | Eldoc, eglot, eldoc-box | ADR 2 hooks, timers | covered | Docs as markdown rich nodes in hover/side panel; composition protocol kept |
| 63 | Code actions, rename, format, workspace edits | Applies edits across files, one undo group each; formatting as minimal diff to keep markers | Eglot | ADR 4 undo group helper | later | Needs multi-file edit transaction helper and minimal-diff apply |
| 64 | Inlay hints, semantic tokens | Overlays with `before-string` / face props | Eglot | — | later | Zero-width inline decorations (CR1) |
| 65 | Blocking requests inside capf | `jsonrpc-request` with `while-no-input` | Eglot completion | ADR 3 | corner-risk | CR4/CR6: capf must be callable from a suspendable task, not inside a "cheap" hook |

### Tree-sitter modes

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 66 | Incremental parse with edit notification | Parser per buffer updated on change; `treesit-parser-notifiers`, `treesit-range-settings` for injections (`treesit.el:706,1351`) | All `*-ts-mode` | ADR 3/6 snapshot jobs, change records, chunk iteration | covered | FFI to tree-sitter; the parser reads chunks from the immutable snapshot. Needs byte offset and row/column conversion from the store (ADR 6 lists conversions) |
| 67 | Font-lock via queries | `treesit-font-lock-rules` → `face` props, jit-lock on visible region | ts modes | ADR 3 highlight job example | covered | Spans keyed to a revision |
| 68 | Highlights don't blank while typing | Properties travel with text; jit-lock refontifies edited region | All | ADR 3: stale colors thrown away | corner-risk | CR5: if properties are tied to a revision and discarded, every keystroke flashes unstyled text. Properties must be relocated by edits (stored with the text, sticky by rule) with the job later overwriting the span |
| 69 | Indent/navigation need a *current* tree | `treesit-simple-indent-rules`, `treesit-node-at`, thing-settings | RET/TAB, symex, combobulate | ADR 3: command can't wait on a job | later | A command suspends until the parse for the current revision completes, or the parser is kept incremental on the editor thread (ms). Decide per language; needs CR4 |

### Terminals and high-throughput output (eat, vterm, comint, eshell, ghostel)

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 70 | VT emulation in-process | Eat is pure Elisp: process filter parses escapes, writes text + props, scrollback 128K (`eat.el:159`), Kitty graphics (`kitty-graphics` installed), shell integration; vterm uses a native module (unverified) | Eat, vterm, ghostel | ADR 3 process reader → message; ADR 7 whole-frame morph | corner-risk | CR8/CR13: a grid node kind is fine; whole-frame morph per output chunk and one queue message per chunk will not scale. Coalesce chunks, run the emulator in a job that returns grid deltas, cap frame rate (ADR 3 already caps) |
| 71 | Client-side terminal widget | n/a | — | ADR 7 "no `contenteditable`… browser holds no editor state" | divergence | Allow an opt-in client-owned widget node (xterm.js-style) fed by a separate byte channel, with Datastar `ignore-morph` so morphs skip it (`patchElements.ts:164,462`). Cost: scrollback search/copy needs the projection API; focus handoff chord. Keep a server-side grid node for the fallback |
| 72 | Raw key passthrough | `eat-semi-char-mode` map, vterm key vectors | Eat, vterm | ADR 3 key resolution | later | A per-buffer "forward all keys except escape prefix" layer (CR7). Browser-reserved keys (C-w, C-t) limit this regardless |
| 73 | comint output at process mark | `comint-output-filter`, `comint-preoutput-filter-functions`, `comint-last-prompt`, input ring (`comint.el:117-130`) | shell, REPLs, cider/geiser/sesman (installed), agent-shell | ADR 6 markers, text node | covered | Text node appended at a marker; editable input region after the prompt marker. Prompt/input boundary as a property or sub-node. Better: output as stream nodes, prompt as a rich node |
| 74 | Eshell objects pipeline | `eshell-output-object` (`esh-io.el:769`), commands = Lisp functions or processes | Eshell | ADR 6 rich nodes | divergence | Command results can be rich nodes (tables, images) rather than text only; strong fit |
| 75 | Compile/grep error buffers | `compilation-filter` hook (`compile.el:88`), regexps in `compilation-error-regexp-alist`, `next-error-function` | compile, grep, Embark, xref, flymake | ADR 3 | covered | Incremental parse job over appended chunks produces `location` attributes; rows are text lines with a clickable property or row nodes |

### Navigation and search (avy, project, xref, next-error, undo)

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 76 | Jump hints across windows | Overlays in every visible window; `avy-all-windows` (`avy.el:216`), `read-char`, `avy-dispatch-alist` (188), `overlay-put` hints | Avy, ace-window (installed), flash, vertico-quick | ADR 7 server viewport; windows are server objects | divergence | Server knows each window's viewport, so hints are a transient annotation layer per window. Overlays must not touch the buffer revision (CR1) and need per-window scope |
| 77 | Window selection hints | `ace-window` labels | ace-window | ADR 4 windows | later | Per-window label decoration |
| 78 | project.el | `project-find-functions` hook (`project.el:192`), `project-root`, files via VC/find, binds `default-directory` dynamically for `project-compile` | project, Magit, Consult | ADR 4 scopes | corner-risk | CR3: `let`-binding `default-directory`. Project list persisted in session slot (ADR 5) |
| 79 | xref backends | `xref-backend-functions` + cl-generic backends (`xref.el:237-251`), results buffer `xref--show-xref-buffer` (1252) | Eglot, etags, dumb-jump (installed) | ADR 2 services/hooks | covered | Backend as a service (interface with identifier-at-point/definitions/references/apropos). Results = location-list rich node |
| 80 | Editing result lists (wgrep, `xref-query-replace-in-results`, `occur-edit`) | Marker-based edits written back to source buffers | wgrep, xref, Embark export | ADR 6: text node owns its store | corner-risk (low) | CR12: result rows that are live excerpts of source text need a text node whose content is a view onto another store. Keep the door open: "content provider" interface, don't hard-code ownership. This is the multibuffer idea earlier attempts failed to finish; do not specify now |
| 81 | `next-error` protocol | Buffer-local `next-error-function`, `next-error-last-buffer`, highlight overlay | compile, grep, occur, xref, flymake, Embark | ADR 2 services | covered | A "locatable list" generic protocol |
| 82 | Undo/redo trees | `buffer-undo-list`, `primitive-undo` (vundo/undo-tree unverified); undo-fu(-session) installed | undo-fu, vundo, undo-tree | ADR 4 list of change records, memory-only; ADR 6 persistent versions | divergence | With persistent text, keep a version DAG: jump to any version in O(1), branching undo native, no `undo-equiv-table` hack. Records must be public data. Session undo persistence is a later slot. Properties/markers/node-tree restoration on jump must be specified |
| 83 | Undo grouping / amalgamation | `undo-boundary`, change groups | gptel, multi-edit commands | ADR 4 amalgamation group | covered | |

### Diff, merge, snippets, streaming, popups

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 84 | ediff | Control buffer, 2–3 windows synced via scroll hooks, overlays for diff regions and refinement, `recursive-edit`, window-config restore (`ediff-util.el`) | ediff, vc-diff | ADR 6 rich nodes, ADR 3 jobs | divergence | Side-by-side / three-way rich node with aligned rows (CSS grid), diff computed in a job on two snapshots, result pane an editable text node. Scroll sync is layout, not hooks |
| 85 | smerge | Regex conflict markers, overlays, refine (`smerge-mode.el:203-330`) | VC, Magit | CR1 overlays | later | Conflict regions as decorations; actions as commands |
| 86 | Snippet expansion with fields and mirrors | Overlays per field with `keymap` property so TAB works only inside (`yasnippet.el:3689-3694`), modification hooks to update mirrors, embedded Lisp | yasnippet, tempel (unverified), abbrev | ADR 3 sync change hooks must be cheap | corner-risk | CR1/CR7: overlay-attached keymaps and range modification hooks; reentrant edit from a change hook needs rules (`inhibit-modification-hooks` equivalent). Mirrors are cheap enough to update synchronously |
| 87 | Streaming insertion (LLM) | Process/curl filter inserts at a tracked marker; `gptel` text property marks response ranges (`gptel.el` hooks at 237-256); user keeps typing | gptel, gptel-agent, agent-shell, shell-maker | ADR 3 job result gated by revision | corner-risk | CR5: append-only stream targets a marker/node, not a revision. Rich alternative below (divergence row) |
| 88 | Chat as structured buffer | n/a | — | ADR 6 | divergence | Message nodes (user prompt editable text node; assistant message streams into a text node; tool calls, reasoning, code blocks with copy button as rich nodes); Markdown parsed incrementally in a job. Cost: Org/markdown-based chat packages that expect a flat file need a flat serialisation |
| 89 | Popup window management | `display-buffer-alist` actions, side windows, `window-parameter`, `window-dedicated-p`, `quit-restore` (`window.el:272-294`) | popper (unverified), shackle, transient, Magit, Help, compile | ADR 4 windows are mutable objects; ADR 7 | corner-risk (low) | CR10: nothing in ADRs defines `display-buffer` as a rule-driven protocol, window parameters, side/dedicated windows or window-configuration values. Every package funnels through it. Browser enables drawers and floating panes |
| 90 | Child frames / posframe | `make-frame` child frame (`corfu.el:425-474`), posframe (installed) | Corfu, eldoc-box, which-key-posframe, company-box | ADR 7 "per-tab frames later" | divergence | Popovers are in-page elements; "frame" as OS-window concept can stay unimplemented |

### Cross-cutting mechanisms

| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
|---|---|---|---|---|---|---|
| 91 | Timers (run, idle, repeat) | `run-with-timer`, `run-with-idle-timer` (`eldoc.el:298`, `flymake.el:1517`) | which-key, eldoc, flymake, corfu-auto, auto-revert, autosave | ADR 2 lists timers; ADR 3 loop | later | Idle = no queued input for N ms. Callbacks run as tasks (CR4), cancelled with the plugin |
| 92 | Command-loop hooks | `pre-command-hook`, `post-command-hook`, `post-self-insert-hook`, `before/after-change-functions`, `window-selection-change-functions`, `minibuffer-setup-hook` | Vertico, Corfu, Magit, Meow, Evil, eldoc, hl-line | ADR 2 hooks general; ADR 3 only mentions change hooks | corner-risk | CR7: name the set and its reentrancy (hooks run for keys dispatched to the minibuffer while another command is suspended) |
| 93 | Dynamic binding of config | `let`-bind variables around calls | project.el, wdired.el:444 (`inhibit-read-only`), consult, embark | ADR 4 "not dynamic variables" | corner-risk | CR3 |
| 94 | Current buffer / window context | Global `current-buffer`, `with-current-buffer`, `save-excursion`, `save-window-excursion` | Everything | ADR 3/4: several suspended commands | later (decide) | Make `current-buffer` per command-thread (Gerbil parameter). A suspended command keeps its own context; avoids Emacs's "recursive edit changed my buffer" class of bugs. Process callbacks bind buffer explicitly |
| 95 | `unread-command-events`, keyboard macros | Push synthetic events | Embark, vertico-quick, kmacro, evil | ADR 3 queue | later | Events must be structured values with modifiers and text, not strings |
| 96 | Narrowing / indirect buffers | `narrow-to-region`, `make-indirect-buffer` | Org capture/edit-src/tree-to-indirect, Calc | ADR 6 | later | Narrowing = accessible range on buffer; indirect = second buffer sharing a text version/store with separate point/markers/modes. Decide revision/undo sharing (CR12) |
| 97 | Inline/variable-height rendering | `display` property, `line-spacing`, `:height` faces (org-modern, olivetti, ultra-scroll installed) | Org, markdown, olivetti | ADR 7 server viewport slice by lines | corner-risk | CR8: viewport by logical lines assumes uniform height; scroll-by-window, `recenter`, `pos-visible-in-window-p` need browser geometry |
| 98 | Visual-line motion | `line-move-visual`, `vertical-motion`, `move-to-column` pixel/display aware | Every C-n/C-p on wrapped text | ADR 7 server has no layout | corner-risk | CR8: the browser wraps; the server needs cols/rows and char metrics, or the browser reports wrap points on demand |
| 99 | Clipboard / paste / IME | `interprogram-cut-function`, `yank` | All | ADR 7 paste/composition later | later | Out of lane; noted because kill-ring/yank-handler need property-carrying strings (CR1) |
| 100 | Plugin lifecycle for all of the above | Hooks/overlays/timers/processes created by packages | All | ADR 2 receipt | covered | Overlays, text-property registrations, keymap layers, tasks and client widgets must all be context-registered so deactivation reverts them. A visible tax: every new effect type needs an inverse |

---

## Corner risks

Severity: **H** = blocks a whole family of packages or forces a rewrite; **M** = blocks several packages; **L** = narrow.

### CR1 (H): Text properties, overlays, property-carrying strings and decoration revisions are undefined
- **Where:** ADR 6 "A text node holds a `TextStore` value plus text properties"; `TextStore` interface covers only text (length, slicing, conversions, chunks, edit); ADR 4 "Each buffer … has a monotonically increasing revision, incremented on every change".
- **Break scenario:**
  - (a) `buffer-substring` returns plain text, so `kill-ring`, Consult candidates and Embark targets lose properties.
  - (b) Avy or flymake adds an overlay; if that counts as a "change", the revision bumps and every in-flight highlight/diagnostic job is discarded, which restarts the job, which adds overlays, and so on.
  - (c) There is no way to say "replace this range's rendering with an image/table" (Org images/tables) or "show this at the end of the line" (flymake eol, inlay hints, Vertico candidates).
  - (d) yasnippet/tempel need a keymap attached to a range (`yasnippet.el:3694`); Magit/Org need per-range keymaps and `invisible`.
- **Smallest change:** ADR 6 adds: (1) a `PropString` (text + intervals) is the value that `buffer-substring`, `insert`, kill ring and completion candidates exchange; the `TextStore` interface does not need to change, properties live in an interval structure beside it; (2) properties are relocated by edits and have stickiness rules; (3) overlays are marker-bounded ranges with priority, optional window scope and a defined open set of render-affecting keys (face, invisible, display/replace, before/after-string, keymap, field/read-only, modification hooks); (4) ADR 4 splits `text-revision` from `decoration-revision`; jobs gate on the former, rendering on both.

### CR2 (H): Positions, point, region, markers and undo in multi-node buffers
- **Where:** ADR 6 "Moving past the end of one text node into the next focusable node is a later, separate feature" and "Public positions are zero-based Unicode code-point offsets"; "Markers are buffer-owned positions".
- **Break scenario:** A Dired buffer of row nodes. `C-x h`, `isearch`, `query-replace`, `kill-region` from the first row to the third, `m` on an active region, and `next-error` all need an answer to "what is a position in a buffer with several text nodes". Markers owned by the buffer need an offset space; undo records need coordinates. If later definitions differ, every package that stored positions breaks.
- **Smallest change:** Decide the coordinate model now, without designing traversal: either (a) a buffer-level linear order (pre-order concatenation of text-node text, rich nodes contribute their text projection or a separator), with positions = offsets into it and node-qualified `(node, offset)` as the primitive, or (b) all position APIs are node-qualified. The choice affects only names and signatures today. Single-text-node buffers are unaffected.

### CR3 (M): No dynamic-scope layer for settings
- **Where:** ADR 4 "Settings resolve … (node, buffer, mode, global), implemented as ordinary data in owning objects, not as dynamic variables."
- **Break scenario:** `project-compile` does `(let ((default-directory root)) (compile …))`; wdired binds `inhibit-read-only` (`wdired.el:444`); Consult/Embark bind completion settings around a prompt. With data-only scopes you must mutate and restore a buffer value, which breaks under suspension and errors.
- **Smallest change:** Add a topmost "dynamic" scope: Gerbil parameters per command/task thread consulted before node scope, with a `with-setting` form. Because each suspended command is its own thread, bindings survive suspension without leaking to other commands (better than Emacs).

### CR4 (H): No suspendable non-interactive task, and unnamed implicit yielding
- **Where:** ADR 3 "Each interactive command runs in its own Gambit thread"; "A command that needs input … suspends"; "Hooks schedule, they do not compute"; "Jobs … must not touch live editor objects". ADR 4 "commands do not yield the baton mid-edit except at explicit suspension points".
- **Break scenario:**
  - Corfu calls a capf on every keystroke; Eglot's capf waits for a language-server reply. That cannot be a command (not interactive), a hook (must be cheap), or a job (needs live buffer access to build the request and apply it).
  - Idle-timer callbacks that open files (Consult preview, org-agenda follow) have the same shape.
  - TRAMP-style `file-exists-p` or Magit `git-lines` that block the baton freeze the editor; if they suspend implicitly, ADR 4's atomicity guarantee silently weakens.
- **Smallest change:** Name a **task**: a baton-holding thread started from timers, process events, hooks or other tasks. It may suspend on awaitables (job results, process output, input, I/O) exactly like a command, is cancelled with its plugin, and is the only caller context for capfs and callbacks. Declare which primitives may yield (documented, `await`-prefixed or listed) and provide an `atomic` region in which yielding is an error.

### CR5 (M): Revision-only validity policy for job results
- **Where:** ADR 3 "applied on the editor thread only if the revisions it was computed from are still current; otherwise it is discarded or restarted"; overview: "the stale colors are thrown away".
- **Break scenario:** (a) A terminal or gptel stream targets a marker; revision changes whenever the user types, so output would be dropped. (b) Highlight and diagnostic results are discarded on each keystroke if latency exceeds the frame time, flashing unstyled text. (c) A grep stream posts many partial results.
- **Smallest change:** Each job declares a validity policy: `exact-revision` (default), `target-alive` (marker/node still exists; append-only streams), or `rebase` (apply after relocating spans through the change records since revision R; requires a bounded change journal). Jobs may post multiple messages. Keyed cancel stays.

### CR6 (M): No interrupt path
- **Where:** ADR 3 "Browser events are acknowledged … and enqueued. The loop dequeues events…"; "Long-running Scheme computation … does delay subsequent commands".
- **Break scenario:** A runaway command or blocking call never returns to the loop, so C-g sits in the queue. Corfu/Consult rely on `while-no-input` (`corfu.el:709`, `consult.el:2266,3835,3928`), which polls for pending input from inside a computation.
- **Smallest change:** The input receiver (web handler thread) recognises the configured quit key(s) on arrival and signals the running command/task thread directly (mechanism to verify in Gambit); expose `input-pending-p` as a cheap check of the queue. Everything else stays in order.

### CR7 (H): Keymap layering, pending-prefix, command-loop hooks, `read-key`, prompt injection
- **Where:** ADR 3 "resolves keys through the active keymaps" (layers unspecified); ADR 2 "Hooks and advice" (set of command-loop hooks unspecified); ADR 3 prompts are suspensions inside command bodies (overview example reads inside the body).
- **Break scenario:**
  - Meow/hel need a layer above minor modes and below transient (`meow-core.el:167-171`, `hel-core.el:63-65`); transient/hydra need a layer above that; yasnippet/tempel need per-range keymaps (`yasnippet.el:3694`); Magit uses per-text `keymap`.
  - Which-key needs the pending prefix and bindings.
  - Vertico runs from `post-command-hook` on every key typed into the minibuffer (`vertico.el:622-623`); if hooks only run for top-level commands it never updates.
  - Embark injects the target as the answer to an action's prompt; with inline `read-string` in the body there is nothing to inject into.
- **Smallest change:** Specify (not design) four things: (1) an ordered keymap stack with named layers and per-node/per-range keymaps; (2) pending-prefix as observable state; (3) the hook set `pre-command`, `post-command`, `post-self-insert`, `before/after-change`, `minibuffer-setup/exit`, `window-selection-change`, run for every dispatched command including minibuffer keys; (4) `defcommand` parameters carry an interactive spec so arguments can be supplied programmatically, and prompts go through a replaceable prompt service so a dynamic handler can answer them.

### CR8 (M): Browser layout, geometry and throughput vs "browser holds no editor state"
- **Where:** ADR 7 "Viewport. Text nodes render only the lines visible in their window"; "The browser holds no editor state"; "Whole-frame morphs are simple but cost bandwidth and render time proportional to visible content"; "Browser-owned editing widgets … are not used".
- **Break scenario:** Wrapped text: `C-n` must move by visual lines and needs the wrap width. `recenter`, `scroll-up`, `pos-visible-in-window-p` and avy need the true visible range; variable-height lines (images, org headings, variable-pitch) make line-count slicing inexact. Corfu/eldoc popups need cursor position (Emacs uses pixels). A terminal printing 100 MB/s cannot go through per-chunk whole-frame morph.
- **Smallest change:** (1) Browser reports window geometry (cols, rows, cell size) on resize and optionally on-demand layout facts; server assumes a monospace cell model for motion, variable height is display-only. (2) Popups anchor to node ids with CSS anchor positioning, no pixel round-trip. (3) ADR 7 reserves a class of client-owned widget nodes (terminal, canvas, PDF) with their own data channel, excluded from morph via Datastar's `ignore-morph` attribute (`datastar/library/src/plugins/backend/watchers/patchElements.ts:164,462`).

### CR9 (M): Focus is a single point
- **Where:** ADR 6 "A buffer's focus is a node plus, for a text node, a point".
- **Break scenario:** Multiple-cursors and Meow beacon (and any Kakoune/VS Code-style editing) need N cursors with per-cursor mark and state; retrofitting changes every command's idea of `point`.
- **Smallest change:** State that focus holds a non-empty ordered list of selections (node, anchor, head), one primary; `point`/`mark` refer to the primary. Single selection is the default and costs nothing.

### CR10 (L): Window protocol not specified
- **Where:** ADR 4 lists windows and frames as mutable objects; nothing defines how a buffer is displayed.
- **Break scenario:** Magit, compile, Help, Embark, xref, transient all call a `display-buffer`-like API with action rules; popper/shackle rewrite those rules; Consult/ediff save and restore window configuration.
- **Smallest change:** Reserve in a window ADR: rule-driven display action alist (as data + functions), window parameters, side/dedicated windows, and `window-configuration` as a restorable value.

### CR11 (L): File access abstraction
- **Where:** ADR 5 "File contents | The visited file | Files plugin".
- **Break scenario:** Remote and virtual paths added after packages call plain file functions require touching every package.
- **Smallest change:** Files plugin exposes a `Vfs` service and a path value type from the start; `default-directory` is a scoped value.

### CR12 (L): Text node always owns its store
- **Where:** ADR 6 "A text node holds a `TextStore` value".
- **Break scenario:** Narrowing, indirect buffers (Org capture/edit-src) and editable result excerpts (wgrep, xref replace) need content that is a view onto another buffer's text.
- **Smallest change:** Describe the text node's content as supplied by a provider (owned store, or a range view over another buffer); don't implement the second now.

### CR13 (L): Process-output backpressure and coalescing
- **Where:** ADR 3 "External processes … reader threads post messages into the loop"; "User input is processed before job results and process output".
- **Break scenario:** `cat huge.log` in a terminal or compile buffer floods the queue; priority rule starves output forever while the user is typing, or memory grows unbounded.
- **Smallest change:** Reader threads coalesce chunks into one pending message per process and stop reading when the pending size exceeds a bound (Emacs analog: `read-process-output-max`).

---

## Proposed divergences (improvements over Emacs)

| # | Emacs does | Tuna could do | Why better | Cost | Porting impact |
|---|---|---|---|---|---|
| D1 | Sections, rows and menus are text + `invisible` + `keymap` properties (Magit `magit-section.el:954-975`, Dired line text) | Rich container nodes with stable identity; fold is view state | Refresh by identity preserves point/folds; no section-ident bookkeeping; per-window folds | Text commands need CR2 resolved; packages parsing buffer text need rewriting | Magit/Dired/agenda ports are rewrites of the view layer, not the logic |
| D2 | Completion candidates are strings with smuggled text properties | Typed candidate structs plus a string adapter | Identity survives; annotations are rich; Embark gets objects | Two shapes in the API | Emacs tables keep working through the adapter |
| D3 | Filtering/highlighting candidates on the main thread | Keyed, streaming filter jobs on a realized candidate vector | No freeze with 100k candidates | Table realization still on editor thread | Orderless/flex logic ports as pure functions |
| D4 | Undo is a linear list; trees are rebuilt by vundo/undo-tree | Version DAG over persistent text; jump to any version | O(1) restore; branch native | Properties/markers/nodes must be part of the version; memory growth policy | `primitive-undo` consumers adapt; undo-fu/vundo features become built-in |
| D5 | Multiple cursors by fake overlays and command replay | First-class multi-selection (CR9) | One atomic edit/undo; modal packages simplify | Commands assume one point unless wrapped | Wrapping helper; most Emacs commands run on the primary only |
| D6 | Hint overlays touching the buffer view | Per-window annotation layer that doesn't touch revisions | Avy/quick hints are cheap, no jobs invalidated | Needs CR1 split revision | Avy ports directly |
| D7 | Popups by child frames/posframe with pixel math | In-page popovers anchored to node ids | No frame hacks, themeable, accessible | Needs cursor element identity | Corfu/eldoc-box ports are small; positioning code deleted |
| D8 | Job results dropped when stale; highlight stored as properties | Properties relocated by edits; job results rebased (CR5) | No flash of unstyled text; diagnostics stay anchored | Change journal | None visible |
| D9 | `TRAMP` for remote | Optionally connect a tab to a Tuna on the remote host; Vfs for zero-install | No TRAMP latency/quirks for main case | Remote install | Remote-aware packages see local paths |
| D10 | Folding is buffer-wide (indirect buffers for per-window) | Fold state per window/node | Same file in two windows with different folds | `org-fold` API rewritten; search must skip folds | Org port touches `org-fold-*` only |
| D11 | Chat/LLM output as flat text | Chat as node tree (message nodes, tool calls, reasoning, code blocks), streaming into text nodes | Collapsible tool output, copy buttons, structured history; user edits prompt while stream continues | Flat serialisation for export | gptel-like packages mostly rewrite their buffer layer |
| D12 | `ediff` via control buffer and hook-synced windows | Diff/merge as rich side-by-side node; scroll sync via layout | Aligned rows, intra-line spans; no window-config juggling | New renderer node kinds | ediff itself is not ported; smerge logic reused |
| D13 | Terminal inside a text buffer | Client-owned terminal widget node + server-side grid fallback | Throughput; correct rendering | Searching/copying needs projection API | Eat/vterm replaced, not ported |
| D14 | `current-buffer` global | `current-buffer` per command/task thread | Suspended commands keep their own context | Process callbacks must bind explicitly | `with-current-buffer` idiom unchanged |
| D15 | Prompt answered inline, injected by hacks | Commands declare prompt parameters in an interactive spec | Embark, macros, `repeat`, M-: call with arguments | Command authors write signature + prompt spec | Mechanical for `(interactive "…")` ports |

---

## Emacs equivalence notes

| Tuna | Emacs | Note |
|---|---|---|
| Text node | Buffer text + text properties | Near-miss: Tuna text node's properties live in the node, not necessarily on the text store |
| Rich node | (none); closest `display` property, widget.el, `magit-section`, tabulated-list entries | Has identity and own keymap/state, unlike text properties |
| Node attribute | Text property on a range (e.g. `invisible`), overlay property | A node attribute covers a whole node, not a range |
| Focus (node + point) | `point` in current buffer | Becomes a selection list if CR9 accepted |
| Overlay | Overlay | Proposed to be per-window-scopable and revision-neutral; Emacs overlays are buffer-wide and count as modifications only for redisplay |
| Job | `make-thread` / async process, `async.el`, `emacs-aio` | Jobs forbid live objects; Emacs threads share everything |
| Task (proposed) | Process filter/sentinel/timer callback; `aio` coroutine | Suspendable, unlike Emacs callbacks |
| Command suspension | `recursive-edit` / `read-from-minibuffer` | Same ergonomics, no nested command loop |
| Baton | Global interpreter lock | Emacs has no explicit baton API |
| Receipt | (none); `unload-feature` approximates | |
| Service | `cl-defgeneric` backend lists (xref, project), `completion-styles` | Services are replaceable slots with lifecycle |
| Scoped values (node/buffer/mode/global) | `defvar-local`, `setq-local`, `custom` | Dynamic `let` has no Tuna equivalent today (CR3) |
| Revision | `buffer-modified-tick`, `buffer-chars-modified-tick` | Emacs has two ticks (all vs text-only); Tuna proposes the same split plus decoration |
| Text projection (proposed) | `buffer-substring` of a rendered region, `display` string | |
| Candidate (typed) | Completion string with props | |
| Keymap stack | `overriding-terminal-local-map` > `overriding-local-map` > emulation > minor > local > global | Needs to be specified, not assumed |
| Window rules | `display-buffer-alist` | |
| Client widget node | `xwidget`, embedded `image` | |
| Excerpt (CR12) | Indirect buffer / `occur` + wgrep | |

---

## Open questions for the owner

1. **Coordinate model for multi-node buffers (CR2).**
   - Context: ADR 6 defers cross-node motion; packages need positions that span nodes.
   - Options: (a) buffer-level linear offsets; (b) node-qualified positions only.
   - Recommendation: (a) with node-qualified primitives underneath, so single-node buffers are unchanged and search/region/kill work in rich buffers.
2. **Org tables and similar projections: text underneath or node tree?**
   - Context: if a table is a rich node tree that serialises to pipes, round-tripping on every keystroke is costly and loses Org's text-first semantics.
   - Options: (a) text node + decoration that renders a grid and edits cells in place; (b) real nodes that serialise.
   - Recommendation: (a) for files that are text on disk; (b) for non-file buffers (Dired, agenda, Magit).
3. **Multi-selection now or later (CR9)?**
   - Recommendation: reserve it in ADR 6 now (selection list, one primary); implement only the primary.
4. **Client-owned widgets (terminal) vs ADR 7's "browser holds no editor state".**
   - Options: strict server rendering (fat morph only); opt-in widget class with its own channel.
   - Recommendation: opt-in, scoped to terminals/canvases/viewers, so throughput cases are not forced through morphs. Decide before the first terminal.
5. **Do commands declare prompt parameters (D15), or call `read-*` inline?**
   - Recommendation: declarative parameters as the documented style, inline reads still allowed. It makes Embark, macros and repeat cheap.

---

## Sources

Local evidence (read in this run):
- `/home/jay/Code/workbench-gerbil/tuna/docs/overview.md`; `/home/jay/Code/workbench-gerbil/tuna/agents/adr/0001`–`0007`
- Magit: `/home/jay/.config/emacs/var/elpaca/sources/magit/lisp/magit-section.el` (lines 107, 501-503, 954-975, 1639-1668, 1736), `magit-process.el` (277, 647), `magit-mode.el`
- Transient: `.../transient/lisp/transient.el` (126-135, 247-266, 2058-2061)
- Vertico `vertico.el` (220-248, 380, 451, 587-623); Consult `consult.el` (2266, 2490, 3835, 3928); Corfu `corfu.el` (278-301, 425-474, 709); Cape `cape.el`; Embark `embark.el` (94-99, 130-166, 315-319); Marginalia `marginalia.el` (479-482, 1334-1396); Orderless `orderless.el`; Avy `avy.el` (188, 216, 509-613); Meow `meow-core.el` (92, 157-171); Hel `hel-core.el` (32-65); yasnippet `yasnippet.el` (3689-3694); gptel `gptel.el`; Eat `eat.el` (159); all under `/home/jay/.config/emacs/var/elpaca/sources/`
- Emacs tree `/home/jay/Code/emacs/lisp/`: `org/org-fold-core.el` (140-169), `org/org-element.el`, `org/ob-core.el`, `org/org-agenda.el`, `org/org-capture.el`, `org/org-persist.el`, `org/org-table.el`; `dired.el` (567, 632, 1933, 2074-2090), `wdired.el` (253-348, 444); `progmodes/eglot.el` (1202, 1429), `progmodes/flymake.el` (76-103, 1517), `emacs-lisp/eldoc.el` (46, 145, 298); `treesit.el` (706, 1351); `comint.el` (117-130); `eshell/esh-io.el` (769); `net/tramp.el` (1357, 1572); `progmodes/compile.el` (88); `progmodes/xref.el` (237-251, 1252); `progmodes/project.el` (192); `vc/ediff-util.el`; `vc/smerge-mode.el`; `repeat.el` (285); `subr.el` (7009); `minibuffer.el` (161-187); `window.el` (272-294); `autorevert.el` (296); `which-key.el` (75-80)
- Datastar `ignore-morph`: `/home/jay/Code/datastar/datastar/library/src/plugins/backend/watchers/patchElements.ts` (164, 462)

Not verified / secondary: Evil, vterm, multiple-cursors, undo-tree, vundo, popper, tempel (not installed; described from general knowledge and marked unverified in the text).

---

## Acceptance report

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Report written to /home/jay/Code/workbench-gerbil/scratch/tuna-capability-audit/04-package-stress-tests.md in the brief's format: 100 inventory rows, 13 corner risks with ADR sentences, 15 divergences, equivalence notes, open questions, sources. Residual risks are listed in the residualRisks field."
    }
  ],
  "changedFiles": [
    "scratch/tuna-capability-audit/04-package-stress-tests.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/cat/head over ADRs, elpaca sources and Emacs lisp tree",
      "result": "passed",
      "summary": "Collected file:line evidence for package mechanisms; no state-changing commands run"
    }
  ],
  "validationOutput": [
    "Line citations checked via grep in this run; Evil, vterm, multiple-cursors, undo-tree, vundo, popper, tempel not installed and marked unverified"
  ],
  "residualRisks": [
    "Evil, vterm, multiple-cursors, undo-tree, vundo, popper and tempel were not read; their rows rely on general knowledge",
    "Org babel/export/capture, TRAMP and Eshell were checked only at entry-point level",
    "CR6 mechanism (signalling a running Gambit thread on quit) is unverified in Gambit",
    "No prototype was run; all verdicts are design review",
    "Rows 31, 41, 71 and the CR8 CSS anchor positioning point are design suggestions, not verified browser/Datastar behaviour beyond the ignore-morph attribute"
  ],
  "noStagedFiles": true,
  "diffSummary": "Created one new Markdown report; no other files touched.",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "Central answer: Emacs text+property UIs map to both text nodes and rich nodes; rich nodes need a text projection and a defined cross-node coordinate model (CR2). Highest-severity ADR gaps: CR1 (properties/overlays/PropString), CR2 (multi-node positions), CR4 (task tier), CR7 (keymap layers and hooks)."
}
```
