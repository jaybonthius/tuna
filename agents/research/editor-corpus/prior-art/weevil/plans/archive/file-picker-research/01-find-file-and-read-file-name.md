# Research: Emacs `find-file` / `read-file-name` public API (for Weevil)

## Summary
Emacs separates **visiting** (get/create a buffer for a file) from **displaying**
it, and exposes a clean layering: `find-file-noselect` is the library workhorse
(returns a buffer, no window side effects); the interactive `find-file*` commands
are thin wrappers that add a display target. File-name *reading* goes through
`read-file-name`, whose entire UI is swappable via the `read-file-name-function`
indirection variable. Extensibility comes from three repeated patterns: **normal/abnormal
hooks** (`find-file-hook`, `find-file-not-found-functions`), **`*-function`
indirection variables** (`read-file-name-function`), and **handler alists**
(`file-name-handler-alist`, which intercepts *every* primitive file op — the TRAMP seam).

> Environment note: this brief was written without live web access (no
> `web_search`/`fetch_content` in this subagent). Content is from the GNU Emacs
> Lisp Reference Manual nodes named below (canonical URLs are stable) cross-checked
> against the local Emacs 30.2 introspection catalog (`emacs-research/api-catalog/`).
> See **Gaps**.

Manual nodes (Elisp Reference Manual):
- Visiting Files — https://www.gnu.org/software/emacs/manual/html_node/elisp/Visiting-Files.html
- Subroutines of Visiting — https://www.gnu.org/software/emacs/manual/html_node/elisp/Subroutines-of-Visiting.html
- Reading File Names — https://www.gnu.org/software/emacs/manual/html_node/elisp/Reading-File-Names.html
- File Name Expansion — https://www.gnu.org/software/emacs/manual/html_node/elisp/File-Name-Expansion.html
- File Name Components — https://www.gnu.org/software/emacs/manual/html_node/elisp/File-Name-Components.html
- File Name Completion — https://www.gnu.org/software/emacs/manual/html_node/elisp/File-Name-Completion.html
- Magic File Names — https://www.gnu.org/software/emacs/manual/html_node/elisp/Magic-File-Names.html

---

## 1. Visiting Files — commands + core function
Node: *Visiting Files*. Signatures are Emacs 30.2 arglists.

| Name | Kind | Signature | Purpose | Extensibility seam |
|---|---|---|---|---|
| `find-file` | command | `(filename &optional wildcards)` | Visit FILENAME in its own buffer in the **selected window**; if already visited, just switch. Interactive reader = `find-file-read-args`. | Inherits all `find-file-noselect` seams. `wildcards` gated by `find-file-wildcards`. Reads name via `read-file-name`. |
| `find-file-other-window` | command | `(filename &optional wildcards)` | Same, but display via `switch-to-buffer-other-window`. | Same seams; display policy via `display-buffer` rules. |
| `find-file-other-frame` | command | `(filename &optional wildcards)` | Same, but in another frame. | Same. |
| `find-file-read-only` | command | `(filename &optional wildcards)` | Visit but set `buffer-read-only`. | Same. |
| `find-file-literally` | command | `(filename)` | Visit with **no conversions**: no coding/format/EOL conversion, no decompression, **no `set-auto-mode`, no `find-file-hook`** (sets buffer-local `find-file-literally`). Calls `find-file-noselect` with `rawfile=t`. | Deliberately bypasses the hook/mode seams — the "escape hatch". |
| `find-alternate-file` | command | `(filename &optional wildcards)` | Visit FILENAME, **killing the current buffer** (replaces what this buffer visits). Runs `kill-buffer-*` machinery first. | Same seams as visiting; plus `kill-buffer-hook`. |
| `find-file-existing` | command | `(filename)` | Like `find-file` but errors unless the file exists and disallows wildcards. Interactive reader uses must-match. | Same; tightens the reader (`mustmatch`). |
| `find-file-noselect` | function | `(filename &optional nowarn rawfile wildcards)` | **The workhorse.** Returns the buffer visiting FILENAME (creating it if needed) **without selecting/displaying**. Dedups against existing buffers by truename. `nowarn` suppresses prompts/warnings; `rawfile` = literal visit; `wildcards` may return a **list of buffers**. *This is the function Lisp programs should call.* | Funnels through `create-file-buffer`, `insert-file-contents`, `after-find-file` (→ `set-auto-mode`, `find-file-hook`, `find-file-not-found-functions`). All file ops pass through `file-name-handler-alist`. |

Key control variables (Visiting Files):
- `find-file-wildcards` (user-option, default `t`) — enable wildcard expansion.
- `find-file-visit-truename` (user-option) — set `buffer-file-name` to the chased-symlink truename.
- `find-file-existing-other-name` (user-option, default `t`) — reuse an existing buffer that visits the same file under a different name (e.g. symlink).
- `find-file-suppress-same-file-warnings` — silence "already visiting under another name".
- `large-file-warning-threshold` — prompt before visiting huge files.

---

## 2. Subroutines of Visiting
Node: *Subroutines of Visiting*. These are the internal stages `find-file-noselect` runs, but all are documented/public and individually callable.

| Name | Kind | Signature | Purpose | Extensibility seam |
|---|---|---|---|---|
| `create-file-buffer` | function | `(filename)` | Make and return a **fresh, uniquely-named** buffer for FILENAME (name from `file-name-nondirectory`, deduped via `generate-new-buffer`). Does **not** make it visit or select it. | Naming influenced by `uniquify`. Pure factory — easy to mirror. |
| `after-find-file` | function | `(&optional error warn noauto after-find-file-from-revert-buffer nomodes)` | Post-read buffer setup: read-only if file unwritable, "(New file)" messaging, **runs `set-auto-mode` + `find-file-hook`** (unless `nomodes`), and runs `find-file-not-found-functions` when the file is absent. | The hub that fires the two hooks + mode selection. `nomodes` disables all of it. |
| `insert-file-contents` | function | `(filename &optional visit beg end replace)` | Insert FILENAME's decoded contents after point; returns `(EXPANDED-FILENAME COUNT)`. With `visit` non-nil, mark buffer as visiting (sets `buffer-file-name`, clears modified flag, records modtime). Does coding/format conversion + decompression. `beg`/`end` = partial; `replace` = efficient in-place replace. | Runs `after-insert-file-functions`, `format-decode`; **dispatches through `file-name-handler-alist`** (remote/compressed reads). |
| `insert-file-contents-literally` | function | `(filename &optional visit beg end replace)` | Same, but **no conversion of any kind** and **bypasses handlers** (`inhibit-file-name-operation`), no `after-insert-file-functions`, no `format-decode`, no decompression. | The raw-bytes escape hatch. |
| `set-auto-mode` | function | `(&optional keep-mode-if-same)` | Choose + enable the major mode for the current buffer from filename/content. | Consults `magic-mode-alist`, file `-*- mode -*-`/local-variables, `interpreter-mode-alist`, `auto-mode-alist`, `magic-fallback-mode-alist`; gated by `enable-local-variables`, `inhibit-local-variables-regexps`. **All alist-driven → fully data-extensible.** |

Pipeline (what `find-file-noselect` actually does):
`expand-file-name` → check `get-file-buffer`/truename dedup → `create-file-buffer` →
`insert-file-contents` (or literal) → `after-find-file` → (`set-auto-mode` + `find-file-hook`).

---

## 3. Hooks & reader variables (the seams, named)

| Name | Kind | Contract | Purpose / when it runs |
|---|---|---|---|
| `find-file-hook` | hook (normal) | functions of **no args**, buffer current | Run by `after-find-file` after every successful visit (unless literal/`nomodes`). Per-buffer setup that isn't mode-specific. (Old name `find-file-hooks`, obsolete.) |
| `find-file-not-found-functions` | hook (abnormal) | functions of **no args**, called via `run-hook-with-args-until-success` | Run by `after-find-file` when visiting a **nonexistent** file; first non-nil return stops. Used to populate new buffers (templates, autoinsert). (Old name `find-file-not-found-hooks`.) |
| `read-file-name-function` | variable (`*-function` indirection) | a fn taking the **same 6 args** as `read-file-name` | If non-nil, `read-file-name` calls it instead of `read-file-name-default`. **The whole minibuffer file-reading UI is swappable here** (ido, helm, ivy/counsel). Default `nil`. |
| `read-file-name-completion-ignore-case` | user-option | boolean | Bound onto `completion-ignore-case` while reading. Default `t` on case-insensitive filesystems (macOS/Windows), else `nil`. |
| `insert-default-directory` | user-option | boolean (default `t`) | If non-nil, `read-file-name` prefills the minibuffer with the default directory so the user edits a full path; if nil, starts empty. |
| `find-file-wildcards`, `find-file-visit-truename`, `find-file-existing-other-name`, `find-file-suppress-same-file-warnings` | user-options | — | Visiting policy knobs (see §1). |

---

## 4. Reading File Names
Node: *Reading File Names*.

| Name | Kind | Signature | Purpose | Extensibility seam |
|---|---|---|---|---|
| `read-file-name` | function | `(prompt &optional dir default-filename mustmatch initial predicate)` | Read a file name in the minibuffer with completion; returns a string. `dir` = base dir (default `default-directory`); `default-filename` = value for empty input (defaults to visited file, else `dir`); `mustmatch` controls existence requirement; `initial` = initial minibuffer text (discouraged); `predicate` must return non-nil for an acceptable name. | **Delegates entirely to `read-file-name-function` if set**, else `read-file-name-default`. Uses `substitute-in-file-name` semantics (the `//` / `~` "discard prefix" trick) and file-name completion. |
| `read-file-name-default` | function | `(prompt &optional dir default-filename mustmatch initial predicate)` | The built-in implementation `read-file-name` falls back to. | Call this from a custom `read-file-name-function` to reuse default behavior. |
| `read-directory-name` | function | `(prompt &optional dir default-dirname mustmatch initial)` | Like `read-file-name` but forces a directory (predicate = `file-directory-p`). | Same indirection. |

`mustmatch` values (overloaded — note for API design):
- `nil` — any name allowed.
- `t` — must be an existing file.
- `confirm` — allow nonexistent, but ask for confirmation on RET.
- `confirm-after-completion` — confirm only if RET right after completing.
- a *function* — called as a predicate on the candidate.

During the read, `minibuffer-completing-file-name` is bound to `t` and
`completion-ignore-case` to `read-file-name-completion-ignore-case`.

---

## 5. File Name Expansion / Components / Completion
Nodes: *File Name Expansion*, *File Name Components*, *File Name Completion*.

| Name | Kind | Signature | Purpose | Extensibility seam |
|---|---|---|---|---|
| `expand-file-name` | function | `(name &optional default-directory)` | Make NAME absolute relative to DEFAULT-DIRECTORY; expand `~`/`~user`, collapse `.`/`..`. **Does not** expand `$env`, **does not** check existence, **does not** chase symlinks. | Goes through `file-name-handler-alist` (so TRAMP can expand remote names). |
| `substitute-in-file-name` | function | `(filename)` | Expand `$VAR`/`${VAR}` and `~`; if name contains an embedded absolute prefix (`//` or `~`), **discard everything before it**. This is what lets a user type an absolute path over a prefilled directory in the minibuffer. | Handler-dispatched. |
| `file-name-directory` | function | `(filename)` | Directory part (through last `/`), or nil. | Handler-dispatched. |
| `file-name-nondirectory` | function | `(filename)` | Part after last `/`. | Handler-dispatched. |
| `file-name-as-directory` | function | `(filename)` | Ensure trailing slash. | Handler-dispatched. |
| `directory-file-name` | function | `(dirname)` | Remove trailing slash (inverse). | Handler-dispatched. |
| `abbreviate-file-name` | function | `(filename)` | Replace home dir with `~` (and apply `directory-abbrev-alist`) for **display**. | Controlled by `directory-abbrev-alist`; handler-dispatched. |
| `file-name-completion` | function | `(file directory &optional predicate)` | Complete FILE within DIRECTORY → longest-common-prefix string / `t` (unique) / `nil`. Skips `completion-ignored-extensions`. | Handler-dispatched (remote completion); ignore-list via `completion-ignored-extensions`; `predicate` filter. |
| `file-name-all-completions` | function | `(partial directory)` | All completions of PARTIAL in DIRECTORY (does **not** apply the ignore-list). | Handler-dispatched. |

(Also in the Components node, useful: `file-name-extension`, `file-name-sans-extension`,
`file-name-base`, `file-name-concat` (28+), `file-name-sans-versions`.)

---

## 6. Magic File Names — the universal extensibility pattern
Node: *Magic File Names*. **This is the most important pattern to understand.**

| Name | Kind | Signature / shape | Purpose | Notes |
|---|---|---|---|---|
| `file-name-handler-alist` | variable | alist of `(REGEXP . HANDLER)` | If a file-op's name matches REGEXP, call HANDLER **instead of** the primitive. First match wins; order matters. | This is how TRAMP (remote `/ssh:host:/path`), jka-compr (`.gz`), ange-ftp, and `url-handler-mode` intercept **all** file ops globally. |
| HANDLER | function | `(operation &rest args)` | Called as `(funcall handler OPERATION . ARGS)` where OPERATION is the primitive's symbol (`insert-file-contents`, `expand-file-name`, `write-region`, `directory-files`, …) and ARGS are the original args. Returns what the primitive would. | A handler may carry an `operations` symbol-property listing which ops it handles (so it's skipped for others — a perf optimization). |
| `find-file-name-handler` | function | `(filename operation)` | Return the applicable handler (or nil), honoring the inhibit variables. | The lookup primitives use internally. |
| `inhibit-file-name-handlers` | variable | list of handlers | Handlers bind this (to themselves) to **re-invoke the real primitive** without infinite recursion (the `tramp-run-real-handler` idiom). | Paired with `inhibit-file-name-operation`. |
| `inhibit-file-name-operation` | variable | a symbol | The operation for which handlers are currently inhibited. | — |

Real-op call idiom inside a handler:
```elisp
(let ((inhibit-file-name-handlers
       (cons 'my-handler
             (and (eq inhibit-file-name-operation operation)
                  inhibit-file-name-handlers)))
      (inhibit-file-name-operation operation))
  (apply operation args))
```
The set of intercepted operations is a fixed, documented list (~80 ops incl.
`expand-file-name`, `substitute-in-file-name`, `insert-file-contents`,
`write-region`, `file-exists-p`, `directory-files`, `file-name-all-completions`,
`process-file`, `start-file-process`, …). **Crucially `expand-file-name`,
completion, and contents-reading are all handled**, which is why a single alist
entry makes remote/virtual files behave like local ones everywhere.

Design takeaway: it's an extremely powerful but **invasive global dispatch on every
primitive** with no static type/contract — a single regex+function pair reroutes the
entire filesystem layer. Power = uniformity; cost = every primitive must remember to
dispatch, and the handler protocol is stringly-typed (`operation` is a bare symbol).

---

## Recommendations for Weevil

### (1) Minimal public API surface (find-file + read-file-name)
Mirror Emacs's **noselect/select split** and the **swappable reader**, but express
seams as Racket parameters + explicit hook objects, and reuse `racket/path` instead
of reimplementing Emacs string-munging.

Commands (interactive):
- `(find-file path)` — visit + select in current window.
- `(find-file-other-window path)` — visit + select elsewhere.

Library functions (the real surface):
- `(find-file-noselect path) -> buffer` — **the workhorse**; dedups, creates buffer,
  reads contents, runs hooks, picks mode; no window side effects. Everything else builds on this.
- `(create-file-buffer path) -> buffer` — naming/dedup factory.
- `(insert-file-contents! buffer path [#:start #:end #:replace?]) -> count` — low-level read; expose a `#:literally?` raw variant.
- `(read-file-name prompt #:dir #:default #:must-match) -> (or/c path #f)` — minibuffer reader; `#:must-match` an **enum** (`'any | 'existing | 'confirm`) or a predicate, not Emacs's 5-way overload.

Seams (prefer parameters/hook objects over special vars):
- `current-read-file-name` — Racket **parameter** holding the reader impl (the `read-file-name-function` analog). Default = built-in; rebind to swap UI.
- `find-file-hook` — a **hook registry** object (`add`/`remove`/`run`); run after visit.
- `find-file-not-found-hook` — run-until-first-true on a missing file.
- `current-choose-major-mode` — parameter implementing the `set-auto-mode` analog, ideally backed by a data alist (regex/extension → mode) so it's data-extensible like `auto-mode-alist`.

File-name helpers: **don't reimplement Emacs**; thin-wrap `racket/path`:
- `expand-file-name` → `expand-user-path` + `simplify-path`/`path->complete-path`.
- directory/nondirectory/as-directory/file-name → `split-path`, `path-only`, `file-name-from-path`, `path->directory-path`.
- `abbreviate-file-name` (display only) → custom home→`~` substitution.
- completion → `directory-list` + filter behind `read-file-name` (respect a `completion-ignored-extensions` list).

### (2) Follow Emacs vs. cleaner pattern
Follow Emacs:
- **noselect/select layering** — keep `find-file-noselect` pure (no window effects). This is Emacs's best structural decision here.
- **`find-file-hook` / not-found hook** — keep these two extension points.
- **`create-file-buffer` dedup + uniquify** — reuse the same approach.
- **Swappable reader** — keep the indirection so a fuzzy/fancy picker can replace the default.
- **Data-driven mode selection** (`auto-mode-alist`-style) — keep the alist concept.

Diverge / cleaner:
- **Seams as parameters + hook objects**, not global special variables. Racket parameters give clean dynamic scoping; explicit hook objects give composition and isolation.
- **Reuse `racket/path`** (path objects, not strings) — avoids the whole `expand-file-name`/`file-name-*` reimplementation and its edge cases.
- **Collapse `mustmatch`** into an enum/predicate (Emacs's t/nil/confirm/confirm-after-completion/function is historical cruft).
- **Drop `initial`** from the reader (Emacs itself discourages it) — use default + completion.
- **Don't adopt `file-name-handler-alist` wholesale.** Instead of global stringly-typed dispatch on every primitive, define a **typed filesystem/backend interface** (Racket generic interface or a struct of ops: `read-contents`, `write-contents`, `list-dir`, `exists?`, `expand`…) threaded explicitly or via a `current-filesystem` parameter. Put the seam at the small `insert-file-contents`/`write-region`/`directory-list` chokepoint, not at 80 primitives. Adopt the alist-style multiplexing only if/when remote/virtual files become a real requirement.
- **Isolate hook errors** (Emacs `run-hooks` lets one bad hook abort the visit) — wrap hook runs so a buggy hook can't break file visiting.
- **Decouple reader UI from buffer state** — make the start directory + prefill explicit args rather than the implicit `insert-default-directory`/`default-directory` coupling.

### (3) Open design questions for the owner
1. **Remote/virtual files?** Is a TRAMP/url-handler analog in scope soon? Yes → design the backend interface now and route reads/writes/listing through it. No → use Racket FS directly and reserve a single chokepoint for later.
2. **Buffer dedup policy.** How to detect "same file via different path"? Use `normalize-path` and/or `file-or-directory-identity` (inode) instead of Emacs's truename strings. Mirror `find-file-visit-truename` / `find-file-existing-other-name`?
3. **Case sensitivity for completion.** Match the filesystem? *Relevant: this repo is on a case-insensitive macOS FS (per `CLAUDE.md`).* Default to insensitive like Emacs's `read-file-name-completion-ignore-case`?
4. **Major-mode selection.** Does Weevil have a mode system yet? The visit path needs a pluggable "choose mode for file" step (`set-auto-mode` analog) — alist by extension/regex/shebang/content?
5. **Wildcards.** Support `find-file-wildcards` (visit-many)? Probably defer.
6. **Literal/raw visiting.** Expose a `find-file-literally` analog and `#:literally?` on contents-reading for binary/no-conversion cases?
7. **Encoding/coding-system detection.** Emacs does heavy coding detection. What's Weevil's decode strategy (UTF-8 default? BOM/EOL detection? expose raw bytes mode)?
8. **Hook error semantics.** Abort-on-error (Emacs) vs. isolate-and-continue?
9. **New-file UX.** Visiting a nonexistent path creates an empty buffer ("(New file)") in Emacs — keep that, or require explicit create?

---

## Sources
- **Kept:** GNU Elisp Reference Manual — *Visiting Files*, *Subroutines of Visiting*, *Reading File Names*, *File Name Expansion*, *File Name Components*, *File Name Completion*, *Magic File Names* (URLs above). Primary, authoritative; define every symbol's contract and the three extensibility patterns.
- **Kept:** `emacs-research/api-catalog/emacs-api.csv` + `README.md` — local Emacs **30.2** runtime introspection (arglists, kinds, manual-node tags, docstrings). Confirms signatures/kinds match the live build.
- **Dropped:** none (no third-party blog/forum sources used; primary manual sufficed).

## Gaps
- **No live web fetch this run** — the `web_search`/`fetch_content` tools were not available to this subagent (only `Read`/`Write`). Signatures/contracts are from the Elisp manual nodes (stable, canonical URLs cited) cross-checked against the local 30.2 catalog; they were not re-verified against a freshly fetched HTML page. Recommend a quick confirm of arglists for `find-file-noselect`, `after-find-file`, and `read-file-name` against the cited manual nodes before finalizing the Weevil API.
- **CSV not exhaustively scanned** — 111k lines in hash order with no grep tool; specific rows weren't extracted line-by-line. To pull exact docstrings/arglists for a symbol, filter the CSV (e.g. `csv` + `name ==` as shown in the catalog README).
- **Out of scope here:** `write-region`/saving path, backup/auto-save (`make-backup-file-name`, `auto-save-file-name`), and coding-system detection internals — needed for the full file lifecycle but beyond find-file/read-file-name. Suggested next brief: "saving, backups, and coding systems".
