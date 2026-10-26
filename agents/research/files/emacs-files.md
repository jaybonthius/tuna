# Emacs file APIs: what a Tuna `files` layer must account for

**Date:** 2026-10-24. **Scope:** read-only inventory for the `files` plugin brief (`docs/briefs/2026-10-files.md`).
**Evidence:** GNU Emacs checkout `/home/jay/Code/emacs` at commit `541f693ca2e` (2026-07-16). Citations are `path:line` at that commit; `lispref/` means `doc/lispref/`.
**Labels:** "Tuna:" lines are recommendations, so they are inference unless stated otherwise. "(inference)" marks any other claim not read directly from source.

## Summary

Emacs file handling is mostly Lisp in `lisp/files.el`, built on a few C primitives in `src/fileio.c`: `insert-file-contents`, `write-region`, `verify-visited-file-modtime`, `expand-file-name`, and `find-file-name-handler`.

Every primitive first looks for a path-dispatched handler, so remote access (TRAMP), compression (`jka-compr`), and encryption (`epa-file`) can plug in without changes to callers. Packages hook in at a few well-known points:
- `find-file-hook`
- `before-save-hook` and `after-save-hook`
- `write-contents-functions`, which can take over a save
- `revert-buffer-function`, `buffer-stale-function`, `before-revert-hook`, and `after-revert-hook`
- `kill-buffer-hook`

Tuna needs equivalents of these hooks, a file service with path dispatch, a modification and staleness model, and a lossless byte representation. Most other Emacs features are optional policy.

**Emacs analog for "the text visits the file":** an indirect buffer shares its text with a base buffer. Only the base buffer visits the file, and saving from an indirect buffer saves the base (`lisp/files.el:6115-6116`, `find-buffer-visiting` docstring `lisp/files.el:2361-2362`). This is the closest Emacs precedent for Tuna's design, where one text can be shown in several buffers.

---

## 1. Visiting files

### The pipeline

`find-file` (`files.el:1967`) reads a name with `read-file-name` (`files.el:1959`) and calls `find-file-noselect` (`files.el:2545`), which:

1. Normalizes the name with `abbreviate-file-name (expand-file-name f)` (`files.el:2558-2560`).
2. Handles directories. If the name is a directory, it calls `find-directory-functions` (default `dired-noselect`, `files.el:585`) when `find-file-run-dired` is set (`files.el:2561-2568`). This is how Dired takes over.
3. Expands wildcards (`files.el:2569-2580`).
4. Looks for an existing buffer: first `get-file-buffer`, which matches the exact name, then `find-buffer-visiting` (`files.el:2354`), which compares truename, then file identifier (`buffer-file-number`, the inode and device). The second match is skipped if `buffer-file-numbers-unique` is nil (it is nil on Windows, `files.el:217`). On a match under another name it warns "X and Y are the same file" and reuses that buffer when `find-file-existing-other-name` is set (default t, `files.el:184`; logic at `files.el:2581-2605`).
5. Checks size with `abort-if-file-too-large` (`files.el:2500`), which can offer to open the file literally (§6).
6. If a buffer already exists, calls `verify-visited-file-modtime`. If the file changed on disk, it either reverts silently (when the name matches `revert-without-query`), prints a hint (when `query-about-changed-file` is nil, `files.el:2429`), or asks "changed on disk. Reread / Discard your edits?" (`files.el:2615-2660`). It also re-syncs read-only state with the file's writability, and refuses to visit the same file both literally and normally (`files.el:2661-2737`).
7. Otherwise creates a buffer with `create-file-buffer` (`files.el:2266`), which calls uniquify, then runs `find-file-noselect-1` (`files.el:2744`). That function:
   - inserts the file with `insert-file-contents f t`. VISIT=t sets the file name and modtime and marks the buffer unmodified.
   - on a missing file, runs `find-file-not-found-functions` until one returns non-nil (`files.el:602`, `files.el:2780-2787`).
   - sets `buffer-file-truename`, `buffer-file-number`, and `default-directory` (the file's own directory), and applies `backup-enable-predicate` (`files.el:2788-2802`).
8. Runs `after-find-file` (`files.el:2895`), which:
   - sets `buffer-read-only` from `file-writable-p`.
   - prints warnings: "(New file)", "write protected", or "X has auto save data; consider M-x recover-this-file" (`files.el:2924-2939`).
   - turns on `auto-save-mode`.
   - makes backup files and files without write permission read-only.
   - calls `normal-mode` (`files.el:2983`), which chooses the major mode through `set-auto-mode` (`files.el:3587`) and applies file-local and directory-local variables through `hack-local-variables` (`files.el:4252`).
   - adds a final newline if `require-final-newline` is `visit`/`visit-save`.
   - runs `find-file-hook` (`files.el:612`, `files.el:2965-2978`).

### Choosing the major mode

The `set-auto-mode` docstring gives this priority (`files.el:3590-3597`):
1. the `-*- mode -*-` line
2. `mode:` in the Local Variables section
3. `auto-mode-alist` in `.dir-locals.el`
4. `interpreter-mode-alist`, matched against the `#!` line (`files.el:3347`)
5. `magic-mode-alist`, matched against the buffer's beginning (`files.el:3461`)
6. `auto-mode-alist`, matched against the file name (`files.el:3037`)
7. `magic-fallback-mode-alist` (`files.el:3473`)

`major-mode-remap-alist` (`files.el:3736`) is applied last.

### Per-buffer state (C, `src/buffer.c`)

- `buffer-file-name` (5428): the visited name.
- `buffer-file-truename` (5433): with links chased. Used for locks and for matching visits.
- `default-directory` (5413).
- `buffer-file-number` (`files.el:209`): the file identifier.
- `buffer-file-coding-system` (5301).
- `buffer-auto-save-file-name` (5439).
- `buffer-backed-up` (5448).
- `buffer-saved-size` (5452).

### Names

- `expand-file-name` (`src/fileio.c:994`) resolves a name against `default-directory`. Each buffer has its own `default-directory`, and every relative path, subprocess, and file prompt uses it.
- `abbreviate-file-name` (`files.el:2298`) replaces the home directory with `~` and applies `directory-abbrev-alist`. Visited names are kept in this abbreviated form.
- `file-truename` (`files.el:1546`) chases symlinks at every level. When `find-file-visit-truename` is set (default nil, `files.el:191`), the visited name becomes the truename.
- `lispref/files.texi:1187` ("Truenames") and `:2505` ("File Name Expansion") document these.

### Unique buffer names

`create-file-buffer` calls `uniquify--create-file-buffer-advice` (`files.el:2290-2291`). `uniquify-buffer-name-style` defaults to `post-forward-angle-brackets` (`lisp/uniquify.el:108`), so two `foo.c` buffers become `foo.c<src>` and `foo.c<lib>`. Names are rationalized again when buffers are killed (`uniquify-after-kill-buffer-flag`, `uniquify.el:151`).

### Packages that depend on this

| Hook or API | Users |
|---|---|
| `find-file-hook` | `vc-refresh-state` (`lisp/vc/vc-hooks.el:1007`), `save-place-find-file-hook` (`lisp/saveplace.el:255`), `recentf` (`lisp/recentf.el:1115`), `auto-insert` (`lisp/autoinsert.el:458`), `epa-file`, TRAMP connection-local variables (`lisp/net/tramp-integration.el:592`), `auto-revert` (`lisp/autorevert.el:362`) |
| `find-file-not-found-functions` | `tramp.el`, `epa-file.el` |
| `auto-mode-alist` | every major-mode package |
| `default-directory` | `compile`, `grep`, `shell`, `project`, `magit` |

**Tuna:**
- Expose `find-file` (a command) and `find-file-noselect` (returns the existing view of the text, or a new one), plus `find-file-hook` and a not-found hook.
- Store name, truename, and file identifier on the visited text. Match visits by truename and file identifier so two paths to one file share a text. This is stronger than Emacs, which only warns and optionally reuses.
- Keep `default-directory` per buffer.
- Make mode choice a separate rule table owned by the `modes` plugin. It is out of scope here, but leave `find-file-hook` as the hand-off point.
- Plan for unique buffer names. The file plugin does not need to implement them yet.

---

## 2. Saving

### The pipeline

`save-buffer` (`files.el:5987`) calls `basic-save-buffer` (`files.el:6103`). The steps:

1. **Indirect buffers:** save the base buffer instead (`files.el:6115-6116`).
2. **Changed-on-disk check:** if the buffer is modified, or its file has disappeared, call `verify-visited-file-modtime`. On a mismatch, ask "X has changed since visited or saved. Save anyway?" (`files.el:6121-6131`).
3. **Final newline:** handled by `require-final-newline` (`files.el:348`). Modes set it from `mode-require-final-newline` (default t, `files.el:371`). The newline is added or the user is asked (`files.el:6132-6149`).
4. **`before-save-hook`**, with errors demoted so a failing hook cannot block the save (`files.el:6062`, `6150-6152`).
5. **`write-contents-functions`** (buffer-local; `files.el:650`). If any returns non-nil, the save counts as done, and backups, the default write, and `write-file-functions` are all skipped (`files.el:6153-6155`). This lets a buffer save to something other than a file. The hook belongs to the buffer's contents: changing the major mode clears it, and `set-visited-file-name` does not.
6. **No file name yet:** ask "File to save in" and call `set-visited-file-name` (`files.el:6156-6172`).
7. **`vc-before-save`** is hard-coded here. Then `write-file-functions` runs (`files.el:624`, permanent-local). It belongs to the visited file, so `set-visited-file-name` discards it. Again, the first non-nil return means "already written". Missing parent directories are offered for creation (`files.el:6173-6191`).
8. **The real write, `basic-save-buffer-2`** (`files.el:6238`):
   - If the file is write-protected, ask and temporarily add write permission (`files.el:6240-6254`).
   - Make a backup once per editing session, unless `buffer-backed-up` is set (`files.el:6255-6258`; §4).
   - **Precious path:** when `file-precious-flag` is set and the directory is writable, or `break-hardlink-on-save` applies, write to `<file>.tmp` (created with strict permissions by `make-temp-file`) and `rename-file` it over the original. The old modtime is restored if the write fails (`files.el:6259-6313`).
   - **Default path:** `write-region` straight into the existing file, which keeps the inode, owner, and hard links. If the write fails and the backup was made by renaming, the backup is renamed back (`files.el:6314-6366`).
9. **Afterwards:**
   - record `buffer-file-coding-system` from `last-coding-system-used`.
   - refresh `buffer-file-number`.
   - restore file modes and extended attributes (`setmodes`).
   - call `vc-after-save`.
   - delete the auto-save file if it was recent.
   - run `after-save-hook` (`files.el:6069`, `6195-6222`).

### Saving through a symlink

With the default path, `write-region` writes through the link. On the precious path the rename replaces the symlink with a regular file unless `file-preserve-symlinks-on-save` is set (`files.el:6085`, `6302-6309`; docstring `6085-6089`).

`file-precious-flag` is "advisory": if the directory is not writable, Emacs writes in place (`files.el:270-272`). It also breaks hard links (`files.el:266-267`).

### Durability

`write-region-inhibit-fsync` defaults to non-nil, so Emacs does not call `fsync` (`src/fileio.c:6971-6990`). The comment there cites research arguing that fsync often fails to guarantee durability on real hardware.

### Other entry points

- `set-visited-file-name` (`files.el:5140`): renames what the buffer visits. It runs `after-set-visited-file-name-hook` (`files.el:5137`) and discards `write-file-functions`.
- `write-file` (`files.el:5261`): save as.
- `save-some-buffers` (`files.el:6495`):
  - `C-x s`, with options to skip, view, or diff (`save-some-buffers-action-alist`, `files.el:6378`).
  - `buffer-save-without-query`.
  - `save-some-buffers-default-predicate` (`files.el:6425`).
  - `save-some-buffers-functions` (`files.el:6480`), which lets abbrev files and similar non-buffer state join the prompt.
- `save-buffers-kill-emacs` (`files.el:8591`).
- `kill-buffer--possibly-save` (`lisp/simple.el:11502`): "Buffer X modified; kill anyway?", with answers y, n, or s (save, then kill).

### Packages that depend on this

| Hook | Users |
|---|---|
| `before-save-hook` | `eglot` willSave (`lisp/progmodes/eglot.el:2431`), `copyright-update`, `delete-trailing-whitespace` and `whitespace-cleanup` (users add these), `time-stamp`, formatters (apheleia and format-all, both third-party) |
| `after-save-hook` | `eglot` didSave (`eglot.el:2432`), `executable-make-buffer-file-executable-if-script-p` (`lisp/progmodes/executable.el`), byte-compile-on-save, flymake/flycheck checks on save (inference), `recentf` (through `write-file-functions`, `recentf.el:1116`) |
| `write-contents-functions` | `org-src` (saves an edit buffer back into its Org source buffer), `hexl`, `diff-mode`, `nndraft` |
| `write-file-functions` | `whitespace`, `shadowfile`, `forms` |

**Tuna:**
- Expose `save-buffer`, `save-some-buffers` with a predicate and extra "unsaved things" providers, and `write-file` / `set-visited-file`.
- Hooks: `before-save-hook` (errors demoted), a **save-override** hook equivalent to `write-contents-functions` (first non-nil wins), and `after-save-hook`.
- Drop the separate `write-file-functions` / `write-contents-functions` pair. One override hook is enough; keep the per-file versus per-content distinction only if a second user needs it (inference).
- The brief chooses "always temporary file plus rename". That matches Emacs's precious path, so these must be handled explicitly:
  1. chase symlinks and rename onto the target;
  2. copy mode bits, and owner where possible;
  3. decide what to do with hard links (rename breaks them; Emacs's default write keeps them);
  4. fall back to an in-place write when the directory is not writable;
  5. decide about fsync.
- Hard-code the "changed on disk; save anyway?" check into the save function, not into a hook.

---

## 3. Modification state and external changes

### Modified flag

`buffer-modified-p` (`src/buffer.c:1505`) compares two counters, `SAVE_MODIFF < MODIFF`. It returns `autosaved` when the latest change has been auto-saved.

`set-buffer-modified-p` (`buffer.c:1548`) also locks or unlocks the file. `restore-buffer-modified-p` (`buffer.c:1575`) does not touch the mode line.

`buffer-modified-tick` and `buffer-chars-modified-tick` (`buffer.c:1638`, `1661`) are monotonic counters used for caches.

Undoing back to the saved state clears the flag because undo records the saved time (`lispref/buffers.texi:529`, "Buffer Modification").

Changing only text properties also marks a buffer modified unless the change is wrapped in `with-silent-modifications`. Font-lock and jit-lock do this.

### Modtime

The buffer records the file's mtime and size when it visits or saves.
- `verify-visited-file-modtime` (`src/fileio.c:6121`): true if the file's current mtime equals the recorded one and, when known, the size also matches (`fileio.c:6145-6150`).
- `visited-file-modtime` (`fileio.c:6165`).
- `set-visited-file-modtime` (`fileio.c:6177`).
- `clear-visited-file-modtime`.
- Overview: `lispref/buffers.texi:622`.

### Supersession (someone else changed the file)

The check runs at two points:
- **The first modification of an unmodified buffer.** `prepare_to_modify_buffer` calls `lock-file` (`src/insdel.c:2170-2174`). If the file is stale, `lock_file` (`src/filelock.c:600-608`) calls `userlock--ask-user-about-supersession-threat`. That function first re-reads the file and compares it with the buffer, and if the contents are identical it silently refreshes the modtime (`lisp/userlock.el:112-155`). Otherwise it asks `ask-user-about-supersession-threat` (`userlock.el:158`): y = edit anyway, n = signal `file-supersession` and block the edit, r = revert.
- **Save** (§2 step 2).

`ask-user-about-supersession-threat` is documented as redefinable policy.

### Revert

`revert-buffer` (`files.el:7185`):
- binds `revert-buffer-in-progress` (`files.el:7151`).
- runs the `revert-buffer-restore-functions` capture and restore lambdas (`files.el:7160`; by default they restore read-only state).
- calls `revert-buffer-function` (`files.el:7070`, permanent-local).

The default, `revert-buffer--default` (`files.el:7242`):
- can offer to revert from the auto-save file.
- asks for confirmation unless NOCONFIRM is set or the name matches `revert-without-query`.
- runs `before-revert-hook`.
- calls `revert-buffer-insert-file-contents-function` (`files.el:7081`). Its default (`files.el:7311`) calls `insert-file-contents … 'if-regular`, using REPLACE.
- recomputes the truename and calls `after-find-file`. That re-runs `normal-mode` unless PRESERVE-MODES is set, which re-initializes buffer-local state.
- runs `after-revert-hook` (`files.el:7135`, `7140`, `7256-7307`).

REPLACE keeps markers only in the unchanged prefix and suffix of the buffer, and records only the difference in undo (`src/fileio.c:4075-4081`; `lispref/backups.texi:708-715`). `revert-buffer-with-fine-grain` diffs with `replace-region-contents` to keep more markers, overlays, and properties, within `revert-buffer-with-fine-grain-max-seconds` = 2.0 (`files.el:7360`).

The default revert keeps the undo history: the FIXME at `files.el:7293` asks whether to throw it away. So a revert can itself be undone.

### Detecting stale buffers

`buffer-stale-function` (`files.el:7105`) has a default (`files.el:7092`) that returns true when the buffer visits a readable file, **is not modified**, and the modtime check fails.

Non-file buffers supply their own function, so Auto Revert covers them too: Dired (`dired.el`) and the buffer menu (`buff-menu.el`). For them, `buffer-auto-revert-by-notification` (`files.el:7125`) says that watching the directory is enough.

### Auto Revert (`lisp/autorevert.el`)

**Enabling:** `auto-revert-mode` (396) is per buffer. `global-auto-revert-mode` (505) is global, and with `global-auto-revert-non-file-buffers` (219) it also covers non-file buffers. Both are **off by default**.

**Timing:**
- Polls every `auto-revert-interval` = 5 s (147).
- With `auto-revert-use-notify` = t (286), it also adds a file-notify watch (666-705). Polling continues as well unless `auto-revert-avoid-polling` (313) is set.
- Notifications are debounced: after one event, a 2.5 s lockout coalesces bursts of events (`auto-revert--lockout-interval`, 700).

**What it does not watch:**
- symlinks (it falls back to polling, 669-671).
- mounted file systems and remote files (`auto-revert-notify-exclude-dir-regexp`, 301). Remote files are never auto-reverted unless `auto-revert-remote-files` is set (280).

**How it reverts** (`auto-revert-handler`, 817):
- calls `buffer-stale-function` with `t`.
- reverts with `(revert-buffer 'ignore-auto 'dont-ask 'preserve-modes)`.
- keeps point at the end of the buffer for any window whose point was there, so tailing a log works.
- keeps `buffer-read-only`.
- ignores errors when the file has been deleted, leaving the buffer as it was.
- refreshes VC state.

**Related:** `auto-revert-tail-mode` (440) appends only the new bytes. `inhibit-auto-revert` (a macro, 788) suppresses reverts during a block.

### file-notify (`lisp/filenotify.el`)

- `file-notify-add-watch FILE FLAGS CALLBACK` (390): FLAGS are `change` and `attribute-change`. Events have the form `(desc ACTION file [file1])`, where ACTION is `created`, `deleted`, `changed`, `renamed`, `attribute-changed`, or `stopped`.
- Also `file-notify-rm-watch` (471) and `file-notify-valid-p` (506).
- **Backends** (36-41): inotify, kqueue, gfilenotify, and w32notify. A path-dispatched handler can supply remote watching.
- **On a file, inotify, gfilenotify, and w32notify watch the parent directory and filter by name** (350-388, 434-447). That is why a watch survives another program saving by atomic rename. kqueue watches the file itself (361-372).
- A `stopped` event means the watch has ended, and callers fall back to polling (`autorevert.el:732-745`).

### Packages that depend on this

| API | Users |
|---|---|
| `before-revert-hook` / `after-revert-hook` | `eglot` (didClose/didOpen around a revert, `eglot.el:2427-2428`), `vc-hooks`, `image-mode`, `doc-view` |
| `revert-buffer-function` | every special buffer: Dired, `ibuffer`, `proced`, `help`, `occur`, magit's `g` |
| `buffer-modified-p` | the mode line, `save-some-buffers`, `kill-buffer` |
| `buffer-modified-tick` | caches in many packages |

**Tuna:**
- Represent "modified" as **"the text's current revision differs from its saved revision"**, or a content comparison. With a persistent rope this is cheap and is better than Emacs's counters, because undoing back to the saved state naturally reads as unmodified.
- Store the saved revision and file stamp (mtime, size, inode) on the text, not the buffer.
- Provide `revert` with a replace-by-diff that keeps marks and undo, plus `revert-function` as a per-buffer override. Non-file buffers such as `proced` already need "regenerate".
- Provide `before-revert` and `after-revert` hooks and a `stale?` predicate.
- Do the supersession check at first edit and at save. Compare contents before prompting, as `userlock.el` does, to avoid false alarms when only the mtime changed.
- Watch through the file service, watching the parent directory, with debouncing and a polling fallback for network and remote files.
- The brief's recommendation to reload unmodified files by default is a deliberate divergence. It equals `global-auto-revert-mode` = on and needs a row in `docs/emacs-equivalents.md`.

---

## 4. Locking and crash safety

### Lock files (`src/filelock.c`)

- When an unmodified buffer is first modified, Emacs creates `.#name` in the file's directory: a symlink whose target is `user@host.pid:boot`. The name comes from `make-lock-file-name` (`files.el:7837`) and can be moved elsewhere with `lock-file-name-transforms` (`files.el:545`). Locking is disabled with `create-lockfiles` (`filelock.c:818`), and skipped for remote files with `remote-file-name-inhibit-locks` (`files.el:567`).
- If another process holds the lock, Emacs calls `ask-user-about-lock` (`userlock.el:43`): steal, proceed, or quit.
- API: `lock-file`, `unlock-file`, `lock-buffer`, `unlock-buffer`, and `file-locked-p` (`filelock.c:677-770`).
- Users often turn locks off because the `.#` files confuse file watchers and build tools (inference: widely reported, not verified here).

### Auto-save (the `#file#` files)

- `auto-save-mode` writes `#name#` beside the file. Remote files go to `temporary-file-directory` instead (`auto-save-file-name-transforms`, `files.el:399`; name from `make-auto-save-file-name`, `files.el:7717`).
- Auto-save runs after `auto-save-interval` = 300 input events (`src/keyboard.c:13843`) or `auto-save-timeout` = 30 s of idle time (`keyboard.c:13849-13854`), through `do-auto-save` (`fileio.c:6315`).
- If a large part of the text is deleted, auto-saving pauses (`auto-save-include-big-deletions` = nil, `fileio.c:6964`). This protects the last good copy.
- The auto-save file is deleted on save (`delete-auto-save-file-if-necessary`, `files.el:6046`).
- `after-find-file` warns when an auto-save file is newer than the file.

### Recovery

- `recover-this-file` and `recover-file` (`files.el:7470`, `7477`) show a diff or listing and replace the buffer's contents.
- `recover-session` (`files.el:7540`) reads `~/.emacs.d/auto-save-list/.saves-PID-HOST` (`auto-save-list-file-prefix`, `lisp/startup.el:402`), which lists every auto-save file of a crashed session.

### `auto-save-visited-mode`

`auto-save-visited-mode` (`files.el:494`) is a different feature: it saves the **real file** after `auto-save-visited-interval` = 5 s of idle time (`files.el:447`). It calls `save-some-buffers :no-prompt`, so every save hook runs. It is filtered by `auto-save-visited-predicate` (`files.el:460`).

### Backups (`backup-buffer`, `files.el:5381`)

- A backup is made on the first save of each editing session (`buffer-backed-up`).
- **Names:** `file~`, or numbered `file.~N~` when `version-control` is set (`files.el:298`); `kept-new-versions` (`files.el:340`); `delete-old-versions`. `backup-directory-alist` (`files.el:5702`) moves them elsewhere.
- **Copy versus rename:** renaming moves the original inode aside and writes a new file. Copying is used when `backup-by-copying`, `backup-by-copying-when-linked`, `backup-by-copying-when-mismatch` (default t, so owner and group are kept), or `backup-by-copying-when-privileged-mismatch` (uid/gid ≤ 200) applies (`files.el:125-160`; `lispref/backups.texi:168`, "Rename or Copy").
- Backups are disabled with `make-backup-files` (`files.el:96`), `backup-inhibited` (`files.el:119`), or `backup-enable-predicate`.

### Packages that depend on this

| Feature | Users |
|---|---|
| Locks | collaborative or shared-host editing. Little package API. |
| Auto-save | `auto-save-hook`, `recover-session` |
| Backups | VC: `vc-make-backup-files`, plus VC's own `.~rev~` files |

**Tuna:**
- The brief's design is already safer than Emacs: autosaves go to the state folder, keyed by file truename, so the user's directories stay clean, and they are restored automatically at start.
- Keep a `recover` command that shows a diff against the file on disk, rather than silently replacing the text.
- Skip lock files and numbered backups for now, as the brief says. Leave a `file-locked?` seam in the file service if collaboration is planned (inference).
- Skip the pause-after-big-deletion rule, because the state-folder autosave can keep a history (inference).
- `auto-save-visited-mode` is a small plugin on top of `save-some-buffers` with a predicate. Defer it.

---

## 5. Encodings and line endings

### Representation

- Emacs characters are 22-bit: `0..#x10FFFF` is Unicode, `#x110000..#x3FFF7F` holds characters not unified with Unicode, and **`#x3FFF80..#x3FFFFF` represent raw bytes** in the `eight-bit` charset (`lispref/nonascii.texi:33-60`, `:380-386`, `:791-797`).
- Bytes that fail to decode become eight-bit characters, and encoding writes them back as the same bytes. That is why visiting and saving a file round-trips even when its encoding was guessed wrong.
- Exception: encoding a character the coding system **cannot** represent gives undefined output, and "Emacs can't report errors that result from encoding unsupported characters" (`nonascii.texi:1104-1109`). `select-safe-coding-system` (`nonascii.texi:1473`) is the guard: it asks the user on save.

### Choosing a coding system when reading

- `coding-system-for-read` overrides everything.
- Otherwise `find-auto-coding` (`lisp/international/mule.el:1874`; `nonascii.texi:1698-1712`) tries, in order:
  1. `auto-coding-alist` (by file name, `mule.el:1760`)
  2. `auto-coding-regexp-alist` (by content, `mule.el:1790`)
  3. a `coding:` tag in the `-*-` line or the Local Variables section
  4. `auto-coding-functions`
- Then `file-coding-system-alist`, then `undecided`, which detects the encoding from content and prefers UTF-8 (`nonascii.texi:1091`).
- The priority list is set by `prefer-coding-system` (`lisp/international/mule-cmds.el:381`).
- Null bytes push detection toward binary (`inhibit-null-byte-detection`, `nonascii.texi:1426`).

### What a coding system records

- **Line endings:** each coding system has `-unix`, `-dos`, and `-mac` variants (`nonascii.texi:1114-1135`). Detection records the EOL type, so a CRLF file is shown with LF and saved back as CRLF. `inhibit-eol-conversion` (`nonascii.texi:1844`) turns this off.
- **Byte-order mark:** `utf-8-with-signature` and `utf-8-auto` (`lisp/international/mule-conf.el:1388-1400`) record whether a BOM was present and write it back.

### On save

- The coding system is `buffer-file-coding-system`, or `save-buffer-coding-system` if set (`nonascii.texi:1205-1233`).
- If the text cannot be encoded, `select-safe-coding-system` asks, and the answer becomes the new `buffer-file-coding-system`.
- `basic-save-buffer` then stores `last-coding-system-used` (`files.el:6195-6199`).
- Commands: `revert-buffer-with-coding-system` (re-read with an explicit encoding) and `set-buffer-file-coding-system` (change the encoding used on save).

### Literal visits

`raw-text` keeps bytes but still converts line endings. `no-conversion`, also called `binary`, is `raw-text-unix` (`nonascii.texi:1131-1147`).

`find-file-literally` (`files.el:2867`) and `insert-file-contents-literally` (`files.el:2808`) turn off decoding, format conversion, `jka-compr` and `epa` handlers, local variables, mode selection, and the final-newline rule. The buffer becomes unibyte, the coding system `no-conversion`, and the mode Fundamental (`files.el:2799-2804`).

### Packages that depend on this

| API | Users |
|---|---|
| `coding:` cookies | Lisp files and old sources |
| CRLF preservation | everyone on mixed-OS repositories |
| Literal and binary visits | `hexl-mode`, `image-mode`, `archive-mode`, `tar-mode` |
| `last-coding-system-used` and `buffer-file-coding-system` | LSP clients (position encodings), diff tools |

**Tuna:**
- **Lossless round-trip is the requirement.** Every byte that fails to decode needs a reversible in-text representation (CR-7 in `agents/research/capability-audit/03-runtime-and-environment.md`). Gambit rejects lone surrogates, so the `surrogateescape` trick is unavailable. Use a private-use or tagged mapping, plus a per-text "decoded-with" record: encoding, EOL type, BOM, and any final-newline policy.
- Even a UTF-8-only first version must record and write back the **EOL type and BOM**. Otherwise CRLF files are silently rewritten on save.
- The brief's choice to open non-UTF-8 files read-only is a safe stand-in, as long as detection catches invalid UTF-8 and null bytes.

---

## 6. Large, special, remote, and directory files

### Large files

- `large-file-warning-threshold` = 10,000,000 bytes (`files.el:2412`). `abort-if-file-too-large` (`files.el:2500`) offers y, n, or "l" (open literally).
- `out-of-memory-warning-percentage` exists and is off by default (`files.el:2420`).
- Emacs has no paging: the whole file is read into the buffer. The third-party `vlf` package adds paging (inference).

### Long lines (`lisp/so-long.el`)

`so-long` targets very **long lines**, which are a display-performance problem, not file size. `global-so-long-mode` (1919) checks `so-long-predicate` (653) on visit, using `so-long-threshold` = 10000 columns (563) and `so-long-max-lines` (574). It then switches to `so-long-mode` or `so-long-minor-mode` per `so-long-action` (727), which turns off expensive modes, and can be reverted (`so-long-mode-revert`, 1574).

### Binary files

There is no special file type in Emacs. Binary content is detected through coding detection (null bytes → `no-conversion`), and `magic-mode-alist` routes images and archives to their modes.

### Special files

`insert-file-contents` refuses VISIT on non-regular files such as FIFOs and `/dev/*`, and needs END for them (`fileio.c:4069-4072`).

### Directories

`find-file` on a directory hands off to `find-directory-functions`, which defaults to `dired-noselect` (`files.el:585`).

### Magic file names (`lispref/files.texi:3324`)

- `file-name-handler-alist` (`fileio.c:6854`) is a list of `(REGEXP . HANDLER)`.
- **Every** primitive file operation calls `find-file-name-handler` (`fileio.c:370`) first. If a handler matches, it receives `(OPERATION . ARGS)` and either implements the operation or re-calls it with `inhibit-file-name-handlers` and `inhibit-file-name-operation` bound (`files.texi:3360-3600`). The manual lists about 70 operations (`files.texi:3360-3460`).
- `safe-magic` marks handlers that are safe to stack (`files.texi:3561`).
- Helpers: `file-remote-p` (`files.el:1401`), `file-local-name` (`files.el:1502`), `file-local-copy`, `unhandled-file-name-directory` (`fileio.c:575`), and `without-remote-files` (`files.texi:3726`). The `/:` prefix quotes a name so no handler applies (`file-name-non-special`, `files.el:8699`).
- Users: TRAMP and its archive and crypt variants, `jka-compr` (`.gz` and other compressed files), `epa-file` (`.gpg`), `image-file`, and `ange-ftp`.
- Handlers also take over lock and auto-save naming, modtime checks, and file-notify (seen at `files.el:7722`, `7842`; `fileio.c:6138-6141`; `filenotify.el:431`). Recovery and watching therefore work for remote files as well.

**Tuna:**
- Keep the file service as one interface whose provider is chosen by path, with a path-dispatch table rather than a global provider. That is the Emacs handler model with a closed, typed set of operations instead of about 70 untyped ones (inference: a typed interface is safer).
- Include in that interface from the start:
  - stat, with the file identifier and mtime
  - read-bytes, write-bytes, and atomic replace
  - list-directory
  - watch
  - make the "remote" and "local name" queries
  - name lock and recovery files
- Hand directories off to a hook that Dired can claim later.
- Large files: warn at a threshold. Long lines: leave to a later plugin.

---

## 7. Remembering

| Package | Hooks it uses | Settings | Stores |
|---|---|---|---|
| `recentf` (`lisp/recentf.el`) | `find-file-hook`, `write-file-functions`, `kill-buffer-hook`, `kill-emacs-hook` (`recentf-used-hooks`, 1113-1119) | `recentf-max-saved-items` = 25 (76), `recentf-exclude` (109), `recentf-filename-handlers` (default `abbreviate-file-name`, 331), auto-cleanup of missing files (280, 418) | `recentf-save-file`, mode 0600 (85, 99) |
| `save-place` (`lisp/saveplace.el`) | restores on `find-file-hook` (436), records on `kill-buffer-hook` and `kill-emacs-hook` (255-259, 307) | `save-place-limit` 400 (85), optional autosave interval (236), forgets unreadable files (91); also covers Dired (456) | an alist from file name to position |
| `savehist` (`lisp/savehist.el`) | — | `savehist-additional-variables` (59), autosaves every 300 s (126) | minibuffer histories and listed variables |

**Tuna:**
- Recent files and saved places become session slots, as the brief says.
- Key both by **truename**, and store a "visited" event stream rather than hooking `write-file-functions`.
- `savehist` belongs to the minibuffer and history plugin, not to files.

---

## The 10 most important API surfaces for Tuna's `files` contract

1. **File service** (interface, provider chosen by path): `stat` (kind, size, mtime, file identifier, mode, owner, symlink target), `read-bytes`, `write-bytes`, `replace-atomically`, `list-directory`, `watch`, `truename`, `remote?`. This is the Emacs handler model, typed.
2. **Visit record on the text:** file name, truename, file identifier, disk stamp at the last read or save, decoded-with (encoding, EOL, BOM), and saved revision. Emacs spreads these over buffer-local variables.
3. **`find-file-noselect` and `find-file`:** one text per truename or file identifier, returning existing views, plus a directory hand-off hook and a not-found hook.
4. **`find-file-hook`**, run after the visit is fully set up, plus a mode-selection hand-off for the `modes` plugin.
5. **`save-buffer` / `save-some-buffers` / `write-file` / `set-visited-file`**, with a predicate and extra providers of unsaved things for `save-some-buffers`.
6. **Save hooks:** `before-save-hook` (errors demoted), a save-override hook (the `write-contents-functions` equivalent; first non-nil wins), and `after-save-hook`.
7. **`modified?`** on the text, comparing revisions, plus a "set unmodified" escape and a modified-tick for caches.
8. **Staleness and revert:** `stale?`, `revert` (replace by diff, keeping marks and undo, with a per-buffer `revert-function` override), `before-revert-hook` and `after-revert-hook`, and an auto-revert policy setting.
9. **Supersession policy:** an overridable function called at first edit and at save, which compares content before prompting.
10. **`default-directory` per buffer** and file-name helpers: `expand`, `abbreviate`, `relative`, and `local-name`.

Also needed, but owned by other plugins: autosave and recovery (the `autosave` plugin); recent files and places (`session`); uniquified buffer names (`buffers`).

## Pitfalls Emacs users hit, and the Tuna stance

- **Supersession prompts at awkward moments.** The "changed on disk; really edit?" prompt appears at the first keystroke, not at save. Emacs added a content comparison (`userlock.el:112-150`) to stop false alarms from `touch` and git checkouts. Tuna: warn in the echo area and ask only at save, as the brief proposes. Compare content, not only mtime.
- **Revert resets modes.** Plain `revert-buffer` re-runs `normal-mode`, which drops buffer-local state and minor modes. Only `preserve-modes` (used by Auto Revert) avoids this (`files.el:7302`). Tuna: revert replaces the text by diff and never re-initializes the buffer.
- **Revert and undo.** Revert is undoable because REPLACE records the difference, but the undo record can be the whole file. Markers survive only in the unchanged prefix and suffix unless fine-grain is used (`backups.texi:708-715`). Tuna's revert should be a single undoable step that keeps marks.
- **Auto-revert lag and failures.** Polling is every 5 s. Notification is skipped for symlinks, NFS, and remote files, and has a 2.5 s debounce. A deleted file leaves the buffer silently stale. Tuna should report deletion and renaming explicitly.
- **Atomic saves by other programs replace the inode.** A per-file watch (kqueue) loses it, while directory watches keep working (`filenotify.el:361-372`). Tuna: watch the parent directory.
- **Precious saves break symlinks and hard links.** With `file-precious-flag` but without `file-preserve-symlinks-on-save`, a symlink becomes a regular file. Hard links always break (`files.el:266-267`, `6302-6309`). Tuna's "temporary file plus rename" design must chase symlinks, copy modes, and choose a hard-link policy.
- **Save as a different user.** Rename-based backups or saves can change owner and group. That is why `backup-by-copying-when-mismatch` defaults to t. Tuna: preserve owner where permitted, or write in place when the file is not owned by the user.
- **CRLF and BOM churn.** If EOL and BOM are not recorded per file, every line changes on save. Emacs records them in the coding system. Tuna must record them from day one.
- **Silent corruption on save.** Characters the encoding cannot represent produce undefined bytes without an error (`nonascii.texi:1108-1109`). Only `select-safe-coding-system` prevents this. Tuna: refuse or ask on save.
- **Lock and auto-save litter.** `.#file` and `#file#` beside files trigger watchers, linters, and git status, so many users disable them. Tuna's state-folder autosave avoids this.
- **The same file under two names.** Symlinked paths produce two buffers unless the truename and file identifier match. Emacs only warns, unless `find-file-existing-other-name` (default t) applies. Tuna's "text visits the file" plus truename matching fixes this structurally.
- **Final newline.** `require-final-newline` can silently add a newline on save, which shows up in diffs. Tuna: make it a setting chosen per mode, off by default for unknown types (inference).
- **Hooks that block saving.** An error in `before-save-hook` is demoted (`files.el:6150-6152`), but `write-file-functions` and `after-save-hook` errors are not. Formatters in `before-save-hook` that move point are a common complaint (inference). Tuna: demote errors in every save hook and log them.

## Missing evidence

- Third-party package claims (apheleia, vlf, magit's use of `revert-buffer-function`, users disabling lock files) come from general knowledge, not this checkout.
- The behaviour of `insert-file-contents` REPLACE on very large files, and any time limits, was not inspected beyond the docstring.
- Exact `rename-file` behaviour with respect to owner and ACLs on the precious path was not traced into C.
