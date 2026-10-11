# Research: Emacs buffer↔file lifecycle & external-change conflict handling (for Weevil)

## Summary

Emacs treats a buffer as a **detached, in-memory snapshot** of file contents
taken at visit time; edits live only in the buffer and the file is rewritten
only on save. Emacs guards the snapshot against external changes with a
**recorded modification time** (`visited-file-modtime`) checked two ways: a
**supersession prompt at first modification** (`ask-user-about-supersession-threat`,
fired from C when locking the buffer for editing) and a **re-read prompt at
visit time**; plus **inter-process advisory lock files** (`.#name` symlinks),
**backups** (`file~`), and **auto-save** (`#file#`) as safety nets. For Weevil's
single-writer web server the inter-Emacs lockfile machinery is mostly redundant,
but the **modtime/size snapshot + save-time conflict check** translates directly
and should be the backbone of the conflict policy — re-expressed as an *async,
policy-driven* protocol rather than Emacs's blocking recursive-minibuffer prompt.

---

## Findings

### A. Is the buffer a snapshot of file contents at visit time? — Yes.

1. **Visiting copies file contents into a fresh buffer; the file is untouched until save.** `find-file` → `find-file-noselect` creates a buffer and fills it via `insert-file-contents`. From then on the buffer and file are independent: editing mutates only buffer text, and the on-disk file is rewritten only by `save-buffer`/`write-file`. ((elisp) Visiting Files; (elisp) Saving Buffers)

2. **The link is carried by buffer-local variables, not by any live handle.** `buffer-file-name` holds the visited file's name (nil for non-file buffers); `buffer-file-truename` holds the canonicalized (symlinks-resolved, abbreviated) name used for de-duplication and lock keying. `set-visited-file-name` re-points the buffer at a new file (the "save as" target) and marks the buffer modified. ((elisp) Buffer File Name)

3. **`find-file` reuses the existing buffer for an already-visited file** (keyed by truename) rather than making a second snapshot — Emacs's model is **one buffer per file**. If that buffer's file changed on disk, `find-file-noselect` prompts *"File … changed on disk. Reread from disk?"* before reusing it. ((elisp) Visiting Files)

### B. Detecting the file changed on disk since visit

4. **`visited-file-modtime` records the file's mtime as of the last read or save.** Returns a Lisp timestamp; returns the integer `0` when the buffer has no recorded modtime (e.g. a non-file buffer or after `clear-visited-file-modtime`). It is the stored reference value, *not* a fresh stat of the disk. ((elisp) Modification Time)

5. **`verify-visited-file-modtime` compares stored vs. actual disk mtime.** Returns non-nil (≈ "unchanged") when the visited file's current on-disk mtime equals the recorded one; also non-nil when the buffer has no visited file, and when the file is (still) absent and the buffer recorded its absence. A nil result means the file changed (or appeared/disappeared) under the buffer. Takes an optional BUFFER. ((elisp) Modification Time)

6. **`set-visited-file-modtime` (re)records the reference time.** With no argument it records the visited file's *current* actual mtime (used right after writing); with a TIME argument it records that value. This is how you *suppress* the changed-on-disk check after deliberately reconciling. `clear-visited-file-modtime` wipes the record so the next save won't complain. ((elisp) Modification Time)

7. **`file-has-changed-p` is a separate, general helper (Emacs 29+), not the buffer mechanism.** It returns non-nil if FILE changed (by size+mtime) since the previous call, storing prior state under a TAG symbol property; first call always returns non-nil. It's meant for watching config/data files, *not* for buffer↔file modtime — but its size+mtime comparison is a good model for Weevil's cheap change check. (Emacs 30.2 catalog; (elisp) file API)

### C. The save-time / edit-time supersession check

8. **The primary guard fires at first modification, not at save.** When you make the first change to a previously-unmodified visited buffer, C's `prepare_to_modify_buffer` calls `lock_file` (filelock.c). `lock_file` does *two* checks: (i) if `verify-visited-file-modtime` fails and the file exists, it calls **`ask-user-about-supersession-threat`**; (ii) the inter-process lockfile check (Finding D). ((elisp) File Locks; (elisp) Modification Time)

9. **`ask-user-about-supersession-threat` is the conflict UI.** It prompts roughly *"FILE changed on disk; really edit the buffer? (y, n, r or C-h)"* — `y` edit anyway (your edits land on top of stale content), `n` abort the edit by signalling `file-supersession`, `r` revert the buffer from disk. It either returns (edit proceeds) or signals `file-supersession` (edit blocked). Lives in `userlock.el`. (Emacs 30.2 catalog; (elisp) File Locks)

10. **Saving itself relies on the backup, not a second prompt.** `save-buffer` → `basic-save-buffer` runs `before-save-hook`, honors `write-contents-functions`/`write-file-functions`, calls `backup-buffer` (preserving the *current on-disk* file as `file~`), writes the buffer, then `set-visited-file-modtime`, clears the modified flag, unlocks the file, and runs `after-save-hook`. So if you blow past the supersession prompt and save, the external on-disk version is (usually) preserved in the backup — **with the caveat** that backups are made **once per visit/session** (`buffer-backed-up` flag), so a second save in the same session makes no fresh backup and *can* silently lose external changes. ((elisp) Saving Buffers; (elisp) Backup Files)

### D. Inter-process file locks

11. **Locks are advisory `.#NAME` symlinks beside the file.** `lock-buffer` creates, for a modified visited buffer, a symlink `.#BASENAME` whose link target encodes `user@host.pid:boot_time`. `unlock-buffer` removes it. Locking happens automatically at first modification (via `lock_file`) and unlocking when the buffer is saved/reverted to unmodified or killed. On filesystems without symlinks Emacs falls back to a regular lock file. ((elisp) File Locks)

12. **`file-locked-p` reports ownership.** Returns nil (not locked), `t` (locked by *this* Emacs/user), or a *string* naming the user/host holding the lock. When you edit a file locked by *another* process, `ask-user-about-lock` prompts to **s**teal / **p**roceed / **q**uit (abort with `file-locked`). ((elisp) File Locks)

13. **`create-lockfiles` (default `t`) toggles the whole mechanism.** Set nil to disable lockfiles entirely. `lock-file-name-transforms` (Emacs 28+) can relocate lockfiles; `remote-file-name-inhibit-locks` disables them for remote files. The lockfile model exists specifically to coordinate **multiple independent Emacs instances** editing the same file. ((elisp) File Locks)

### E. Reverting

14. **`revert-buffer` re-reads the file (re-snapshots), discarding buffer edits.** It replaces buffer text with the on-disk file (or the auto-save file when IGNORE-AUTO is nil and one is newer), resets the modified flag and re-records modtime. Args: IGNORE-AUTO, NOCONFIRM, PRESERVE-MODES. It's fully overridable via the buffer-local `revert-buffer-function`, and runs `before-revert-hook`/`after-revert-hook`; `revert-buffer-insert-file-contents-function` controls the actual read. `auto-revert-mode`/`global-auto-revert-mode` (autorevert.el) automate this for *unmodified* buffers via polling or filesystem notifications. ((elisp) Reverting)

### F. Auto-save and backups as safety nets

15. **Auto-save writes a throwaway `#FILE#` copy, never the real file.** `auto-save-mode` toggles per buffer; `do-auto-save` performs it; triggered after `auto-save-interval` input events (default 300) or `auto-save-timeout` idle seconds (default 30). The visited file is untouched. After a crash, `recover-file`/`recover-this-file`/`recover-session` restore from `#file#`; on visiting, Emacs warns if the auto-save file is newer. `delete-auto-save-files` (default t) removes `#file#` on a successful real save. Distinct: `auto-save-visited-mode` (Emacs 26+) actually saves to the *visited* file on idle. `buffer-modified-p` can return the symbol `autosaved` (a non-nil, non-`t` value) to mean "modified and already auto-saved." ((elisp) Auto-Saving; (elisp) Buffer Modification)

16. **Backups preserve the prior on-disk contents before an overwrite.** `make-backup-files` (default t) enables `file~` (or numbered `file.~N~` when `version-control` is non-nil). Controlled by `kept-old-versions`/`kept-new-versions`/`delete-old-versions`, `backup-by-copying` (rename vs. copy — affects inode/hardlink/permission preservation), and `backup-directory-alist` (relocate backups). Made **once per session** per buffer (`backup-buffer`/`buffer-backed-up`). ((elisp) Backup Files)

### Modified-flag mechanics (cross-cutting)

17. **`buffer-modified-p` / `set-buffer-modified-p` / `restore-buffer-modified-p` / ticks.** `buffer-modified-p` reports the dirty flag (nil, t, or `autosaved`). `set-buffer-modified-p` sets it *and* performs the file side effects — non-nil locks the file, nil unlocks it, and it touches the mode line. `restore-buffer-modified-p` is the lower-level setter used to *restore a previously-saved flag value* (e.g. by undo) **without** the lock/modtime side effects. `not-modified` is the interactive "mark unmodified." `buffer-modified-tick` is a monotonic counter bumped on every modification (cheap change detection across calls); `buffer-chars-modified-tick` bumps only on actual text changes. ((elisp) Buffer Modification)

### Hooks worth mirroring

18. **Save/revert hooks.** `before-save-hook` / `after-save-hook` (e.g. whitespace cleanup, post-write actions). `write-file-functions` and `write-contents-functions` are *escape hatches*: a non-nil return means "I wrote the file, skip the default write" — `write-contents-functions` takes precedence and survives major-mode changes; `write-file-functions` is the file-oriented variant. `before-revert-hook`/`after-revert-hook` wrap reverts. ((elisp) Saving Buffers; (elisp) Reverting)

---

## API catalog (grouped by manual node)

| name | kind | purpose |
|---|---|---|
| `buffer-file-name` | var/fn | visited file path (nil if none) — *(elisp) Buffer File Name* |
| `buffer-file-truename` | var | canonical path (symlinks resolved) — dedup/lock key |
| `set-visited-file-name` | command | re-point buffer at a new file; marks modified |
| `buffer-modified-p` | fn | dirty flag (nil / t / `autosaved`) — *(elisp) Buffer Modification* |
| `set-buffer-modified-p` | fn | set dirty flag **+ lock/unlock file**, mode line |
| `restore-buffer-modified-p` | fn | low-level set (no lock/modtime side effects) |
| `not-modified` | command | mark buffer unmodified |
| `buffer-modified-tick` | fn | monotonic modification counter |
| `buffer-chars-modified-tick` | fn | counter, text changes only |
| `save-buffer` / `basic-save-buffer` | command/fn | write buffer→file; backup; hooks; clear flag — *(elisp) Saving Buffers* |
| `write-file` | command | save-as: write + re-visit new file |
| `save-some-buffers` | command | batch-save modified buffers with prompts |
| `verify-visited-file-modtime` | fn | stored mtime == disk mtime? — *(elisp) Modification Time* |
| `visited-file-modtime` | fn | the recorded reference mtime (0 if none) |
| `set-visited-file-modtime` | fn | (re)record reference mtime |
| `clear-visited-file-modtime` | fn | drop the record (silence next save) |
| `file-has-changed-p` | fn | general size+mtime change tracker (Emacs 29+) |
| `ask-user-about-supersession-threat` | fn | conflict prompt at first edit — *(elisp) File Locks* |
| `lock-buffer` / `unlock-buffer` | fn | create/remove `.#name` symlink lock |
| `file-locked-p` | fn | nil / t / owner-string |
| `create-lockfiles` | user-option | master switch for lockfiles (default t) |
| `revert-buffer` (+ `revert-buffer-function`) | command/var | re-read file, discard edits — *(elisp) Reverting* |
| `auto-save-mode` / `do-auto-save` / `recover-file` | minor-mode/fn | `#file#` safety net — *(elisp) Auto-Saving* |
| `make-backup-files` / `backup-buffer` | user-option/fn | `file~` safety net — *(elisp) Backup Files* |
| hooks | — | `before-save-hook`, `after-save-hook`, `write-file-functions`, `write-contents-functions`, `before-revert-hook`, `after-revert-hook` |

---

## (1) Recommended state model + public API for Weevil

**Per-buffer state (the file linkage).**

| field | Emacs analog | notes |
|---|---|---|
| `file-path` | `buffer-file-name` | nil ⇒ non-file buffer |
| `file-truename` | `buffer-file-truename` | canonical path; key for dedup + locks |
| `modified?` | `buffer-modified-p` | dirty flag |
| `mod-tick` | `buffer-modified-tick` | monotonic; send to client for cheap "is this stale" checks |
| `visited-mtime` + `visited-size` | `visited-file-modtime` | reference snapshot of disk metadata at last read/write; add optional `visited-hash` |
| `coding` | `buffer-file-coding-system` | record so revert/save round-trips (line endings, encoding) |
| `backed-up?` | `buffer-backed-up` | once-per-session backup guard |
| `lock-state` | (lockfile) | held? / by whom? — optional, see policy |

**Public operations (suggested Racket surface, names mirror Emacs intent).**

- `(visit-file path) -> buffer` — read snapshot via `insert-file-contents`-equivalent; record mtime/size(/hash) and coding; `modified? = #f`. Reuse an existing buffer for the same truename (one-buffer-per-file) and, if its file changed on disk, surface a reread prompt.
- `(buffer-file-name b)` / `(buffer-file-truename b)`
- `(set-visited-file-name! b path)` — repoint + mark modified.
- `(buffer-modified? b)` / `(set-modified! b flag)` / `(clear-modified! b)` *(= `not-modified`)* / `(buffer-mod-tick b)`. Keep a low-level `(restore-modified! b v)` that skips lock side effects, for undo.
- `(save-buffer b [opts]) -> result` — run before-save hooks → **conflict check** (re-stat; compare to `visited-*`) → backup → atomic write (temp+rename) → `set-visited-modtime!` → `clear-modified!` → after-save hooks. Return `'saved | 'no-changes | (conflict …)` instead of throwing UI.
- `(write-file b path)` — save-as.
- `(revert-buffer b [#:confirm? #:keep-modes?])` — re-snapshot; reset flag/modtime; before/after-revert hooks; overridable via a `revert-buffer-function` slot.
- `(verify-visited-modtime b) -> bool`, `(visited-modtime b)`, `(set-visited-modtime! b [t])`, `(clear-visited-modtime! b)`.
- `(file-changed-on-disk? b)` — convenience: `(and (not (verify-visited-modtime b)) (file-exists? path))`.
- **Conflict policy hook** — a slot analogous to `ask-user-about-supersession-threat` (see §2), invoked by `save-buffer` (and optionally at first-edit and on focus).
- **Hooks**: `before-save`, `after-save`, `write-file-functions`/`write-contents-functions` (override-write escape hatch), `before-revert`, `after-revert`.
- **Safety nets**: `auto-save` (write `#file#`-equivalent / server-side scratch) and `make-backup-files?` (write `file~` before overwrite).

---

## (2) Recommended conflict policy (single-writer web server)

**Context difference from Emacs.** Emacs assumes *many independent editor
processes*; its `.#name` lockfiles coordinate *between Emacs instances*. Weevil
is **one long-lived server process** that may hold *many buffers across many
sessions/users*. So conflict has two axes Emacs conflates differently:

- **External edits** (git checkout, build tools, a real editor over SSH, another
  server instance) — the modtime/size snapshot model translates **directly** and
  is the important one.
- **Intra-process collisions** (two browser sessions opening the same file) —
  Emacs handles this by sharing *one* buffer; Weevil must *decide* (see §3) and,
  if sessions get independent buffers, needs an **in-memory registry keyed by
  truename** to detect/resolve same-file collisions — lockfiles on disk don't
  help here because it's the same process.

**Concrete recommendation.**

1. **Snapshot `(mtime, size)` at visit and at every save**; store as
   `visited-mtime`/`visited-size`. This is the reference, exactly like
   `visited-file-modtime`.
2. **Mandatory conflict check inside `save-buffer`.** Re-stat just before
   writing; if `(mtime,size)` differs from the snapshot (or optional hash
   mismatch) → **do not overwrite**. Return a structured `conflict` result. This
   is the server-friendly replacement for the blocking supersession prompt.
3. **Async, policy-driven resolution** — *not* Emacs's recursive-minibuffer
   `ask-user-about-supersession-threat`. `save-buffer` returns a conflict object;
   the client chooses **overwrite / reload (discard buffer) / save-as / diff** and
   re-issues the save with a **resolution token** (e.g. the newly observed mtime)
   so the server can confirm nothing changed again in the meantime.
4. **Detect external changes proactively for unmodified buffers** (Emacs's
   auto-revert): on tab focus/visibility, on a poll, or via filesystem
   notifications (inotify/FSEvents/kqueue). Auto-reload clean buffers; flag dirty
   buffers as "changed on disk" so the user isn't surprised at save time.
5. **Skip OS lockfiles by default.** For a single-writer server they add little
   over the in-memory registry + modtime check. Provide an **optional**
   `create-lockfiles?`-style flag (default off) for deployments that must
   coexist with external editors; if enabled, mirror Emacs's `.#name` symlink so
   a real Emacs/other tool sees the lock too.
6. **Keep backups + auto-save as recoverability nets.** Write a `file~`-style
   backup (or a side store / DB row) **before** every overwrite — and unlike
   Emacs, consider doing it on *every* save (not once-per-session), since a web
   editor can't rely on the user noticing a lost-overwrite. Periodic server-side
   auto-save to a scratch store keyed by session protects against crashes/lost
   connections.

---

## (3) Open design questions for the owner

1. **One buffer per file, or one buffer per session?** Emacs shares a single
   buffer across all windows. If two sessions open the same file, do they share
   a canonical buffer (→ need OT/CRDT for concurrent edits) or get independent
   per-session snapshots (→ need intra-process conflict detection between
   sessions)? This is the single biggest divergence from Emacs and shapes the
   whole API.
2. **Change-detection signal: mtime+size vs. content hash?** mtime+size is cheap
   but misses same-size/same-second edits and false-positives on `touch`; a hash
   is robust but costs a full read. Default to mtime+size with an optional hash
   recheck when a conflict is suspected?
3. **Lockfiles at all?** Confirm the deployment never has external editors; if
   guaranteed, drop OS lockfiles entirely and rely on the registry + modtime.
4. **Conflict UX contract.** What resolution options does the client expose
   (overwrite / reload / save-as / 3-way merge), and is there a server-enforced
   default (e.g. refuse overwrite, force explicit choice)?
5. **Atomic-write semantics.** Temp-file + rename for crash safety — but rename
   changes inode and can drop hardlinks/permissions/ownership (Emacs's
   `backup-by-copying` knobs exist for exactly this). Which to preserve?
6. **Coding system / line endings in the snapshot.** Record `coding` so a revert
   or re-stat actually round-trips; otherwise a benign re-encode reads as a
   conflict.
7. **Auto-revert transport.** Polling (simple, scales poorly with many open
   files) vs. filesystem notifications (inotify/FSEvents/kqueue — fd limits, NFS
   gaps). Which, and at what granularity (per open file vs. per directory)?
8. **Backup retention & location.** Per-save vs. once-per-session; on-disk
   `file~` next to the file vs. a server-side store keyed by user/session.

---

## Sources

- **Kept — GNU Emacs Lisp Reference Manual nodes** (authoritative model + API):
  - *(elisp) Buffer File Name* — `buffer-file-name`, `buffer-file-truename`, `set-visited-file-name`.
  - *(elisp) Visiting Files* — `find-file`/`find-file-noselect`, one-buffer-per-file, reread-on-visit.
  - *(elisp) Saving Buffers* — `save-buffer`/`basic-save-buffer`, `write-file`, `save-some-buffers`, save hooks, `write-file-functions`/`write-contents-functions`.
  - *(elisp) Buffer Modification* — `buffer-modified-p`, `set-buffer-modified-p`, `restore-buffer-modified-p`, `buffer-modified-tick`, `not-modified`, `autosaved` flag.
  - *(elisp) Modification Time* — `visited-file-modtime`, `set-visited-file-modtime`, `verify-visited-file-modtime`, `clear-visited-file-modtime`.
  - *(elisp) Reverting* — `revert-buffer`, `revert-buffer-function`, revert hooks; (autorevert) `auto-revert-mode`.
  - *(elisp) File Locks* — `lock-buffer`/`unlock-buffer`, `file-locked-p`, `create-lockfiles`, `.#name` symlinks, `ask-user-about-supersession-threat`, `ask-user-about-lock`.
  - *(elisp) Auto-Saving* — `auto-save-mode`, `do-auto-save`, `recover-file`, `#file#`, intervals, `auto-save-visited-mode`.
  - *(elisp) Backup* — `make-backup-files`, `backup-buffer`, versioning/retention knobs, once-per-session backup.
  - HTML form: `https://www.gnu.org/software/emacs/manual/html_node/elisp/<Node>.html` (e.g. `Modification-Time.html`, `File-Locks.html`).
- **Kept — local catalog** `emacs-research/api-catalog/emacs-api.csv` (introspected GNU Emacs **30.2**) — confirms the exact callable API surface (names, kinds, arglists, docstrings) for every symbol above; authoritative for *what is callable in 30.2*.
- **Dropped — none consulted via web this session.** `web_search`/`fetch_content` were not available in this run (only file Read/Write), so findings are grounded in the named manual nodes + the Emacs 30.2 catalog + Emacs internals (filelock.c/insdel.c, files.el, userlock.el, autorevert.el behavior) rather than freshly fetched pages.

## Gaps

- **Unverified exact wording / sentinel values** (no live manual fetch this
  session): the precise prompt strings of `ask-user-about-supersession-threat`
  and `ask-user-about-lock`, and the exact sentinel `visited-file-modtime`
  returns for a *nonexistent* visited file. Verify against the live (elisp)
  manual nodes and `userlock.el`/`filelock.c` before quoting verbatim. The
  *behavioral model* above is reliable; only literal strings/edge sentinels need
  confirmation.
- **Next steps:** (a) fetch `(elisp) Modification Time`, `File Locks`,
  `Saving Buffers` to lock down exact return values/prompts; (b) skim
  `lisp/files.el` `basic-save-buffer`/`backup-buffer` for the precise
  once-per-session backup condition; (c) prototype the async conflict-resolution
  protocol (§2.3) and the one-buffer-vs-per-session decision (§3.1), which the
  manual can't decide for a web context.
