# How other editors handle files (research for the `files` plugin)

**Date:** 2026-10-26. **Status:** evidence, not decisions (ADRs override). Read-only research for `docs/briefs/2026-10-files.md`.

**Sources, pinned:** all read from source or official docs on 2026-10-26.

| Editor | Source and pin |
|---|---|
| Zed | `zed-industries/zed` @ `2c335b81dc94d109bfcf05e8e54aba208837b33a` |
| VS Code | `microsoft/vscode` @ `f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b` |
| Helix | `helix-editor/helix` @ `ba40e547426b0f9896c8bdc699a4ab11f2b37dbc` |
| Kakoune | `mawww/kakoune` @ `4d4ee86c2d039c2a5f29f109e7e59105d2073046` |
| Neovim | `runtime/doc/{options,editing,autocmd,recover,news}.txt` on `master` (HEAD `3ee26cf91f28cfac9d0f862849118c93643ea2ba`, the 0.13 development cycle) |
| Sublime Text | Only an unofficial mirror of the Sublime Text 3 (ST3) default settings, build 3143 (`twolfson/sublime-files@3143.0.0`). This is **stale**; Sublime Text 4 defaults may differ. |

Links below use `…/blob/<sha>/path#Lnn`. Labels: **[src]** means read in source or docs. **[inf]** means my inference.

## Summary

- **Detecting changes:** every modern editor uses an OS watcher and checks the file again before saving. The OS watcher is inotify on Linux, through the Rust `notify` crate in Zed and through `parcel-watcher` or Node's `fs.watch` in VS Code. Zed and VS Code fall back to polling only for network or virtual filesystems. Kakoune polls with `stat` every 500 ms. Neovim checks on focus, after shell commands and on `:checktime`; its development branch adds OS watchers. Helix does not watch at all.
- **When a file changes:** reload silently if the buffer is unmodified, applied as a *diff* so cursors and undo survive. If the buffer is modified, mark a conflict and ask at save time.
- **Saving:** opinions split. VS Code and Zed write **in place**: they truncate the file and write it again. VS Code calls `fdatasync`; Zed calls no sync. Helix and Neovim do a backup-then-write that switches between rename and copy depending on links. Kakoune and Sublime offer an opt-in temporary file plus rename.
- **Encodings:** Zed and Helix detect BOM, then UTF-8, then `chardetng`. VS Code checks the BOM and UTF-16 heuristics, then guesses with `jschardet` only if `files.autoGuessEncoding` is on (off by default). Neovim tries a list of encodings. Kakoune supports only UTF-8.

---

## 1. Detecting external changes

### Zed
- **Watching backend [src]:** native `notify` watcher; inotify on Linux, where one watch covers one directory. Zed polls instead on 9p, NFS, CIFS/SMB and FUSE filesystems, but not virtiofs. It detects these with `statfs` (`detect_requires_poll_watcher_linux`). The poll interval defaults to 2 s, clamped to 0.5–30 s, and can be set through `ZED_FILE_WATCHER_POLL_MS`. `ZED_FILE_WATCHER_MODE=native|poll` forces a mode. [fs_watcher.rs#L292-L398](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/fs/src/fs_watcher.rs#L292), [#L1503](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/fs/src/fs_watcher.rs#L1503)
- **Watch-limit fallback [src]:** when the OS watch limit is hit (`notify::ErrorKind::MaxFilesWatch`, i.e. inotify ENOSPC), Zed stops registering new native watches for a cooldown, 5 s by default, and retries later. An inotify queue overflow becomes a `Rescan` event that rescans the affected subtree. [fs_watcher.rs#L892-L903, #L725-L740](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/fs/src/fs_watcher.rs#L892)
- **Debounce [src]:** events are batched with `FS_WATCH_LATENCY = 100 ms`. [worktree.rs#L84](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/worktree/src/worktree.rs#L84)
- **What is compared [src]:** the file's `DiskState` (`Present{mtime}`, `New`, `Deleted`). A conflict is `disk mtime > saved_mtime && has_unsaved_edits`. [buffer.rs#L2556](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/language/src/buffer.rs#L2556)

### VS Code
- **Watching backend [src]:** recursive watching uses `@parcel/watcher`, with the inotify backend on Linux, FSEvents on macOS and the Windows backend on Windows. Non-recursive watches of single files use Node's `fs.watch`. Changes are coalesced with a 75 ms delay and then throttled. [parcelWatcher.ts#L159, #L177](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/node/watcher/parcel/parcelWatcher.ts#L159), [nodejsWatcherLib.ts#L25-L33](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/node/watcher/nodejs/nodejsWatcherLib.ts#L25)
- **Rename-based saves by other tools [src]:** a delete event on a watched file waits `FILE_DELETE_HANDLER_DELAY = 100 ms`. If the file exists again, VS Code reports a change and re-attaches the watcher, "to support 'atomic save' operations where a tool may … delete a file and then create it". [nodejsWatcherLib.ts#L410-L440](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/node/watcher/nodejs/nodejsWatcherLib.ts#L410)
- **Deleted files [src]:** a text model becomes "orphaned" only after waiting 100 ms and confirming the file is gone. Network shares sometimes report false delete events (vscode#13665). [textFileEditorModel.ts#L158-L200](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L158)
- **Fallbacks [src]:** inotify ENOSPC is logged once; there is no automatic fallback to polling. [parcelWatcher.ts#L582](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/node/watcher/parcel/parcelWatcher.ts#L582) Polling exists, using parcel snapshots and `getEventsSince`, but is marked *deprecated, WSL1 only*. [watcher.ts#L155-L171](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/common/watcher.ts#L155) Users tune watching with `files.watcherExclude` and `files.watcherInclude`.
- **What is compared [src]:** the `etag` is `mtime.toString(29) + size.toString(31)`. [files.ts#L1570](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/common/files.ts#L1570) At write time, "dirty write prevention" applies when the disk mtime is newer and the etag differs. If the new buffer has the same size as the file on disk, VS Code reads the file and allows the write when the bytes are identical; otherwise it fails with `FILE_MODIFIED_SINCE`. The comment explains that mtime alone gave false positives on remote filesystems, and that the size check is a deliberately weak check instead of hashing. [fileService.ts#L502-L537](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/common/fileService.ts#L502)

### Neovim
- **Focus and checktime [src]:** the timestamp, mode and size are compared after shell commands, `:terminal` jobs, `FocusGained` and `:checktime`. The `FileChangedShell` autocommand lets the user handle it, through `v:fcs_reason` and `v:fcs_choice`. When the timestamp changed but the buffer is unmodified, Neovim re-reads the file and compares the text; if it is equal, there is no warning. [editing.txt *timestamp*](https://github.com/neovim/neovim/blob/3ee26cf91f28cfac9d0f862849118c93643ea2ba/runtime/doc/editing.txt), [autocmd.txt *FileChangedShell*](https://github.com/neovim/neovim/blob/3ee26cf91f28cfac9d0f862849118c93643ea2ba/runtime/doc/autocmd.txt)
- **OS watchers, development branch [src]:** `news.txt` lists "'autoread' uses file system watchers … instead of only on FocusGained or :checktime" under changes since 0.12, so it is **unreleased**. Watchers start when a buffer loads, restart after `:write`, and stop when the buffer is deleted or `autoread` is turned off. `autoread` is on by default in Neovim.

### Helix
- **No watcher [src]:** a comment in `editor.rs` says "This can be removed once proper file watching is implemented". Reloading is manual with `:reload` and `:reload-all`. At save time Helix refuses if the disk mtime is newer than the last save: "file modified by an external process, use :w! to overwrite". [editor.rs#L2250](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/editor.rs#L2250), [document.rs#L1050-L1058](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs#L1050)

### Kakoune
- **Polling [src]:** in normal mode, every `fs_check_timeout` (500 ms by default), Kakoune `stat`s the current buffer's file. If the mtime differs, it compares the **size plus a murmur3 hash** of the mmapped file, and only then treats the file as changed. A `touch` alone is ignored. [client.cc#L398-L436](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/client.cc#L398), [options.asciidoc](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/doc/pages/options.asciidoc)

### Sublime Text (ST3, stale)
- The default settings document `always_prompt_for_file_reload: false`: the file "automatically reload[s] … if it hasn't been edited. If a file has unsaved changes, a prompt will always be shown." The mechanism is not documented. [ST3 Preferences](https://github.com/twolfson/sublime-files/blob/3143.0.0/Packages/Default/Preferences.sublime-settings)

## 2. What happens when a file changes

| Editor | Unmodified buffer | Modified buffer | Cursor and undo across reload |
|---|---|---|---|
| Zed | Emits `ReloadNeeded` and reloads automatically ([buffer.rs#L1795](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/language/src/buffer.rs#L1795)) | Sets a conflict flag and shows a tab indicator. Saving prompts "This file has changed on disk since you started editing it. Do you want to overwrite it?" with **Overwrite / Discard Edits / Cancel** ([pane.rs#L2263, #L2373](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/workspace/src/pane.rs#L2263)) | The reload computes a **diff** and applies it as one transaction (`apply_diff`), so anchors and cursors move with the text and the reload is undoable. If the user edited while the reload ran, it marks a conflict instead ([buffer.rs#L1685-L1770](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/language/src/buffer.rs#L1685)) |
| VS Code | Reloads ("never reload dirty models") ([textFileEditorModelManager.ts#L134](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/services/textfile/common/textFileEditorModelManager.ts#L134)) | Nothing happens until save. Save then fails with "The content of the file is newer. Please compare…" and offers **Compare** (a diff editor), **Overwrite** and **Revert**. `files.saveConflictResolution` defaults to `askUser` and can be set to `overwriteFileOnDisk` ([textFileSaveErrorHandler.ts#L129, #L247](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/contrib/files/browser/editors/textFileSaveErrorHandler.ts#L129)) | Reload content goes through the model as edits (`EditSources.reloadFromDisk`). New: `reconcileExternalChanges` performs a **three-way rebase** of the user's edits onto the disk changes. It returns `Conflict` when they overlap and `Unavailable` for large models ([textFileEditorModel.ts#L352-L420](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L352)). Its callers are outside my sparse checkout; **[inf]** they are probably the AI/chat edit flows, not ordinary file watching |
| Neovim | With `autoread`, reloads unless the file was deleted. The old text is kept, and `u` shows the previous contents | A W11-style prompt offers OK or Load File. `:w` warns "WARNING: The file has been changed since reading it!!! Do you really want to write to it (y/n)?" ([editing.txt](https://github.com/neovim/neovim/blob/3ee26cf91f28cfac9d0f862849118c93643ea2ba/runtime/doc/editing.txt)) | Reload is undoable, per the `autoread` docs |
| Helix | Manual `:reload` only | `:w` refuses; `:w!` forces | The reload diffs ropes (`compare_ropes`), applies the result as a transaction and appends it to history, so it is undoable and selections are mapped ([document.rs#L1282-L1321](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs#L1282)) |
| Kakoune | `autoreload=ask` (default) shows a modal: y/enter reload, n/esc keep, Y/N always. `yes` reloads silently | The same prompt appears whether or not the buffer is modified ([client.cc#L404-L431](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/client.cc#L404)) | The reload is a line diff recorded as one undo group ([buffer.cc#L203](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/buffer.cc#L203)) |
| Sublime (ST3) | Reloads automatically | Prompts | Not documented |

## 3. Saving

| Editor | Method | Sync to disk | Metadata, links, symlinks |
|---|---|---|---|
| Zed | **In place:** `File::create`, which truncates, then streams rope chunks through a `BufWriter`. Non-UTF-8 text is encoded in memory and written with `std::fs::write`. An `atomic_write` (temp file in the same directory, then `persist`/rename) exists but serves other uses such as settings ([fs.rs#L982-L1059](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/fs/src/fs.rs#L982), [worktree.rs#L1844](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/worktree/src/worktree.rs#L1844)) | Only `flush()`; no `fsync` seen in `save` | In-place writing keeps the inode, permissions and hard links, and writes through symlinks **[inf]** |
| VS Code | **In place** by default: `open(path,'w')`. On Windows it uses `r+` plus `ftruncate`, to keep hidden attributes and alternate data streams (#931, #6363). An atomic mode (temp file named with a postfix, then rename) exists in the disk provider and is **refused for symlinks**, because the rename might cross disks. Ordinary text saves do not request it; providers can enforce it ([diskFileSystemProvider.ts#L264-L330, #L425-L462](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/node/diskFileSystemProvider.ts#L264), [fileService.ts#L388](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/common/fileService.ts#L388)) | `fdatasync` on closing a write handle; disabled if it fails (#9589) ([#L535](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/node/diskFileSystemProvider.ts#L535)) | Read-only files: offers "Overwrite" (chmod) or "Retry as Sudo/Admin" |
| Helix | `atomic-save` (default **true**), which is really a Vim-style backup: rename the original to `name*.bck` in the same directory, or **copy** it if the file is a hard link (nlink > 1) or a symlink. Then `File::create` the target, write and `sync_all`. On failure the backup is restored; on success `copy_metadata` runs and the backup is deleted. Symlinks are resolved with `read_link`, so the write goes to the target. The documented trade-off is that it "may confuse some file watching/hot reloading programs" ([document.rs#L1059-L1180](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs#L1059), [book/editor.md#L62](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/book/src/editor.md)) | `sync_all`, ignoring ENOTSUP (SMB on macOS) | **[inf]** In the rename path there is a short window where the target path does not exist. That is not atomic replacement; it trades atomicity for "the old bytes are never destroyed before the new ones exist" |
| Neovim | `writebackup` on: back up, then write. `backupcopy=auto`: **rename** when safe; **copy then overwrite in place** when the file is a hard or symbolic link or its attributes cannot be reproduced. Options `breaksymlink` and `breakhardlink` exist. The docs list the "rename" trade-offs: not all attributes copied, links broken, the new file owned by the current user. They also name `crontab -e` as a case where rename breaks ([options.txt 'backupcopy'](https://github.com/neovim/neovim/blob/3ee26cf91f28cfac9d0f862849118c93643ea2ba/runtime/doc/options.txt)) | `fsync` on by default, global-local | chown is attempted after rename; if it fails, `auto` falls back to copying |
| Kakoune | `writemethod=overwrite` (default) opens and writes in place. `replace` uses `mkstemp` next to the file, chmod, chown if root, then `rename`. It only applies to regular files ([buffer_utils.cc#L202-L256](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/buffer_utils.cc#L202)) | `fsync` only with a `-sync` flag | `-force` temporarily chmods `u+w` |
| Sublime (ST3) | `atomic_save: false` by default: "write to an alternate file, and then renam[e] it over the original" | Not documented | Not documented |

**Why some choose in place [src + inf]:**
- It keeps hard links, symlinks, inode identity, ownership, ACLs, xattrs, Windows alternate data streams and hidden attributes.
- Inode-based watchers (an inotify watch on the *file*) keep working.
- It works in directories the user cannot write to but whose files they can.
- It avoids leaving stray temporary files in watched trees.

The cost is a torn file if the editor crashes or the disk fills mid-write. VS Code mitigates this with `fdatasync` and hot-exit backups; Zed relies on unsaved-buffer serialization.

## 4. Encodings, line endings, final newline

- **Zed [src]:**
  - Detection order: BOM (`Encoding::for_bom`); then a binary check of the first 1 KiB; then streaming strict UTF-8, rejecting ESC bytes so ISO-2022-JP is caught; if that fails, `chardetng` over the file, then `encoding_rs` decoding. [file_content.rs](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/file_content/src/file_content.rs), [worktree.rs#L7272](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/worktree/src/worktree.rs#L7272)
  - The encoding and `has_bom` are stored on the buffer and used on save. There is an encoding selector and `reload_with_encoding`.
  - Line endings are **normalized to LF in the rope**. `LineEnding` is detected from the first 1000 bytes and re-applied on save, so a file with mixed endings becomes uniform **[inf from code]**.
  - **[inf]** Invalid UTF-8 never reaches a lossy UTF-8 decode, because it falls through to `chardetng`, which picks a legacy encoding that is usually byte-lossless (e.g. windows-1252). The reload path ignores `_had_errors`, so a forced encoding can be lossy.
- **VS Code [src]:**
  - Detection: BOM (UTF-8, UTF-16LE/BE); then a scan of 512 bytes for zero bytes, with UTF-16 heuristics, binary otherwise; then, **only if `files.autoGuessEncoding` (default false)**, `jschardet` on up to 64 KiB, optionally limited by `files.candidateGuessEncodings`. Otherwise `files.encoding` applies (default `utf8`, per-language). [encoding.ts#L27-L30, #L477-L540](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/services/textfile/common/encoding.ts#L27), [files.contribution.ts#L190-L215](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/contrib/files/browser/files.contribution.ts#L190)
  - Files are saved back in their detected encoding.
  - Line endings: the majority CR/CRLF versus LF wins, and mixed endings are normalized (`normalizeEOL` defaults to true). [pieceTreeTextBufferBuilder.ts#L27-L58](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/editor/common/model/pieceTree/pieceTreeTextBufferBuilder.ts#L27) `files.eol` defaults to `auto`.
  - `files.insertFinalNewline` and `trimFinalNewlines` both default false.
  - **[inf, not verified in code]** Invalid UTF-8 decoded as UTF-8 becomes U+FFFD, and saving writes the replacements: a lossy round trip.
- **Neovim [src]:**
  - `fileencodings` defaults to `ucs-bom,utf-8,default,latin1`: try each in order, and the first that decodes without error wins. latin1 accepts anything, so it should come last.
  - "Conversion can cause loss of information". `++bad=X|keep|drop` controls unconvertible characters, and the default replaces them with `?`.
  - `fileformats` defaults to `unix,dos` on Unix: CRLF is chosen only if **all** lines end in CRLF.
  - `fixendofline` (on) adds a missing final EOL. Turning it off together with `endofline` preserves a missing one.
  - **[inf]** UTF-8 to latin1 fallback is a lossless byte round trip, because latin1 is a bijection on bytes.
- **Helix [src]:** BOM first, then `chardetng`, with UTF-8 allowed; a manual override is possible. The docs warn that "As a Rope can only contain valid UTF-8, replacement characters may appear in the encoded text" on write. [document.rs#L604-L640](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs#L604) `insert-final-newline` defaults to true. The status line shows the encoding when it is not UTF-8. **[inf]** The rope keeps the original line endings, and `detect_indent_and_line_ending` only picks the ending used for new lines.
- **Kakoune [src]:** UTF-8 only. A UTF-8 BOM is stripped and remembered (`BOM` option). `eolformat` becomes `crlf` only if the file has CRLF and no bare LF. `finaleol` is `present|missing|ifnotempty`, detected on load and kept. [buffer_utils.cc#L120-L145](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/buffer_utils.cc#L120) **[inf]** Buffers are byte strings, so invalid bytes round-trip unchanged.
- **Sublime (ST3) [src, stale]:** ASCII, UTF-8 and UTF-16 are detected; otherwise `fallback_encoding` (Windows-1252) is used. Files are saved with the encoding they were opened with. Files with NUL bytes open as hexadecimal. `ensure_newline_at_eof_on_save` defaults to false.

## 5. Crash safety

- **Zed [src]:** with `session.restore_unsaved_buffers` (default **true**), dirty buffer contents, path and mtime are serialized to the workspace SQLite database, so quitting does not prompt. [items.rs#L1303](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/editor/src/items.rs#L1303), [persistence.rs#L20](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/editor/src/persistence.rs#L20), [project_settings.rs#L86-L92](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/project/src/project_settings.rs#L86)
- **VS Code [src]:** working-copy backups are scheduled 1000 ms after a change (2000 ms in "delayed" mode) ([workingCopyBackupTracker.ts#L91](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/workbench/services/workingCopy/common/workingCopyBackupTracker.ts#L91)). `files.hotExit` defaults to `onExit`; the web version uses `onExitAndWindowClose`. A model can be restored from a backup, including its orphaned flag.
- **Neovim [src]:** a swap file, `.name.swp` in `$XDG_STATE_HOME/nvim/swap//`, is written every 200 characters typed (`updatecount`) or after 4000 ms idle (`updatetime`). Recovery uses `-r`/`:recover`. The swap file also warns when the same file is open twice.
- **Helix and Kakoune:** none found beyond Helix's transient save backup.
- **Sublime (ST3) [src, stale]:** `hot_exit: true` preserves unsaved changes and the undo stack across restarts (forum statements; not verified in official docs).

## 6. Large and binary files

| Editor | Large files | Binary files |
|---|---|---|
| Zed | Refuses files of 6 GB or more: "File is too large to load", a stopgap for memory use (#27283) ([worktree.rs#L1721](https://github.com/zed-industries/zed/blob/2c335b81dc94d109bfcf05e8e54aba208837b33a/crates/worktree/src/worktree.rs#L1721)) | `analyze_byte_content` on the first 1 KiB: magic headers (PDF, ELF, PNG and others), NUL counts and control-character ratios. Binary files are not opened as text |
| VS Code | Asks for confirmation above `workbench.editorLargeFileConfirmation`: 1024 MB for local files, 10 MB remote, 50 MB on the web. Model "large file optimizations" above 20 MB or 300 K lines turn off tokenization and similar features; above 256 M characters, heap operations are refused ([files.ts#L1632](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/platform/files/common/files.ts#L1632), [textModel.ts#L189-L191](https://github.com/microsoft/vscode/blob/f9b2ea8f6fde03aea6ccd18738bd314ce7b6c79b/src/vs/editor/common/model/textModel.ts#L189)) | NUL byte in the first 512 bytes that is not UTF-16 means `FILE_IS_BINARY`: an error with an "open anyway" option |
| Neovim | No threshold. With a swap file, the whole file need not be in memory | `binary` option; no automatic detection |
| Kakoune | mmap. Files larger than `INT_MAX` bytes are rejected ([file.cc#L229](https://github.com/mawww/kakoune/blob/4d4ee86c2d039c2a5f29f109e7e59105d2073046/src/file.cc#L229)) | None |
| Helix | None found | None found |
| Sublime (ST3) | Not documented | Hexadecimal view when NUL bytes are present |

## Comparison

| | Zed | VS Code | Neovim | Helix | Kakoune | Sublime (ST3) |
|---|---|---|---|---|---|---|
| Detection | OS watcher (inotify per directory); poll on network/FUSE; cooldown at watch limit | parcel/inotify (recursive), `fs.watch` (single files) | Focus, shell, `:checktime`; OS watchers on master | None (check at save) | `stat` poll 500 ms + size + murmur3 | Watcher (undocumented) |
| Compared | mtime | mtime + size, then bytes if equal size | mtime, mode, size; then text | mtime | mtime → size + hash | ? |
| Unmodified buffer | Auto-reload | Auto-reload | Auto-reload if `autoread` (default on) | Manual | Ask (default) | Auto-reload |
| Modified buffer | Conflict flag; Overwrite/Discard at save | Error at save; Compare/Overwrite/Revert | Prompt; y/n at `:w` | `:w` refuses; `:w!` | Ask | Prompt |
| Reload keeps cursor/undo | Yes (diff) | Yes (edits) | Undoable | Yes (diff) | Yes (diff) | ? |
| Save | In place | In place (+atomic option) | Backup + rename or copy (`auto`) | Backup-rename, or copy for links | In place (`replace` opt-in) | In place (`atomic_save` opt-in) |
| fsync | No | `fdatasync` | Yes | `sync_all` | Opt-in | ? |
| Encodings | BOM → UTF-8 → chardetng | BOM → UTF-16 heuristic → (opt-in jschardet) → setting | Try a list; latin1 last | BOM → chardetng | UTF-8 only | Detect UTF-8/16 → fallback cp1252 |
| Line endings | Normalized to LF; restored on save | Majority wins, normalized | Detected (dos only if all CRLF) | Kept in the rope **[inf]** | Detected; kept | `default_line_ending` for new files |
| Crash safety | Unsaved buffers in a database | Backups after 1 s; hot exit | Swap file | — | — | Hot exit |
| Large/binary | 6 GB refuse; binary refused | Confirm above 1 GB; binary → error | No limits | — | mmap, ≤ 2 GB | Hex view |

## What Tuna should copy, improve, or avoid

**Copy:**
1. **Reload as a diff, not a replace** (Zed, Helix, Kakoune, VS Code). Compute the edit from old text to new and apply it as one undoable change. Markers, cursors and other buffers' views move correctly. If the user edited while the file was being read, mark a conflict instead (Zed's version check). This fits Tuna's persistent ropes, since diffing two ropes is cheap when they share structure **[inf]**.
2. **Auto-reload when unmodified, conflict when modified.** This is the consensus of Zed, VS Code, Neovim and Sublime, and it supports the brief's recommendation. Ask at save time, with **overwrite / reload (discard mine) / show diff** (VS Code's three, Zed's two). The diff can come later as a plugin.
3. **Check again at save, and confirm content before reporting a conflict.** Compare mtime **and** size; when the size is equal, compare bytes or a hash before declaring a conflict. VS Code (bytes) and Kakoune (murmur3) do this to avoid false positives from `touch`, `git checkout` of identical content, and network filesystems' unreliable mtimes. Keep a content hash with the visit, so the check needs no full read of the old file **[inf]**.
4. **Keep a file's encoding, BOM, line-ending convention and final-newline state on the visited file, and write them back unchanged.** Zed stores `encoding` and `has_bom`; Kakoune stores `BOM`, `eolformat` and `finaleol`. Default: never add or strip a final newline silently (Kakoune and Neovim keep what they found). Make `require-final-newline` a setting, as Emacs does.

**Improve:**
1. **Watcher strategy with fallback.** Run the watcher thread in the file service provider and have it post events to the editor thread.
   - Watch each visited file's **parent directory** with inotify (`IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_ATTRIB`) and filter by name. A file watch dies when another tool saves by rename; a directory watch survives it (Zed watches directories; VS Code re-attaches after 100 ms).
   - Debounce about 100 ms (Zed 100 ms, VS Code 75 ms) and coalesce events per file.
   - On `IN_Q_OVERFLOW`, re-stat every visited file. Treat a watch error (ENOSPC, or a network filesystem detected with `statfs`, as Zed does) as "poll this file every ~2 s".
   - Always also re-check (stat, then hash) **on browser focus/visibility regain and before every save**. The watcher is an optimization; the stat check is the truth.
   - Confirm deletes after a short delay, so rename-based saves do not look like deletions (VS Code).
   - Verify Gerbil `std/os/inotify` exposes the overflow and directory event flags before relying on them **[to verify]**.
2. **Non-UTF-8 files.** Prefer a *lossless* rule over Zed and Helix's guessing:
   - Stage 1, matching the brief: strict UTF-8, with or without BOM (BOM remembered), and CRLF preserved, are editable. Anything else (invalid UTF-8, UTF-16 BOM, NUL bytes) opens **read-only** with an echo-area note. That never corrupts a file, unlike VS Code's U+FFFD or Helix's replacement on write.
   - Later: decode UTF-16 with a BOM and declared encodings (a coding cookie or a user command), and represent undecodable bytes reversibly. Options are Emacs's raw-byte characters or Python's `surrogateescape`, which maps bytes to U+DC80–U+DCFF. Whether Gambit characters can hold lone surrogates is **[to verify]**. Avoid automatic heuristic guessing (`chardet`) as a default: VS Code ships it off, and a wrong guess silently changes bytes on save.
   - **[inf]** A latin-1 fallback (Neovim) is lossless but shows mojibake, unreadable text from the wrong decoding. A raw-byte representation is better because valid UTF-8 parts stay readable.
3. **Line endings.** Unlike Zed and VS Code, do not normalize mixed endings silently. Either keep CR in the text, as Emacs does for mixed files, or record the convention and open mixed files with a note. Recommendation: normalize only when the file is uniformly CRLF (Neovim's "all lines" rule and Kakoune's), and otherwise keep the bytes as-is.

**Avoid / decide:**
1. **Atomic versus in-place save.** Recommendation: **temporary file plus rename by default, falling back to in-place when rename would change the file's identity.**
   - **Atomic:** write a temp file in the **same directory** (Zed's cross-device lesson, zed#8437); `fsync` the temp file; copy mode, and owner/group when possible; `rename`; then `fsync` the directory.
   - **In place**, the Neovim `backupcopy=auto` rule, when any of these holds: the target is a hard link (nlink > 1); the owner or group cannot be preserved (chown fails, or the file belongs to someone else); the directory is not writable; or the file has xattrs/ACLs the provider cannot copy **[inf: check what Gerbil exposes]**. To make in-place safe, write a backup copy first (Helix and Neovim `writebackup`), then truncate and write, `fsync`, and delete the backup.
   - **Symlinks:** resolve the link and save to the target's directory (Helix's `read_link`; Emacs's `file-truename`), never replacing the link itself. VS Code instead refuses atomic mode for symlinks.
   - **Why not in-place everywhere, as VS Code and Zed do:** a crash or full disk mid-write truncates the user's file. Tuna's autosave covers the *buffer*, not the *file on disk*.
   - **Why not Helix's rename-the-original-away:** there is a window where the path does not exist, and watchers see a delete.
   - The brief's "temporary file renamed over the old one; permissions kept; symlink saves through" matches this. **Add the hard-link and ownership fallback.**
2. **Do not rely on mtime alone** (Helix's approach). Coarse or skewed mtimes on network filesystems give false conflicts and missed changes (VS Code's comment).
3. **Ignore your own writes.** After saving, record the new (mtime, size, hash) **before** the watcher event arrives, so Tuna's own save does not trigger a reload or conflict. Zed refreshes the entry after `write_file`; Neovim restarts watchers after `:write`.
4. **Large and binary files.** Detect binary from the first few KiB (NUL bytes that are not UTF-16, or known magic numbers, as Zed does) and open read-only with a note rather than refusing. Set a confirmation threshold (VS Code asks above 1 GB locally) instead of a hard limit, and measure where the rope and the browser display actually struggle **[inf]**.

## Contradictions

- **"Atomic save" means different things.** In Helix it is a backup-rename of the *original*. In Kakoune, Sublime and VS Code's provider it is a temp file renamed over the original. Helix's docs say it "may confuse some file watching" programs; VS Code's watcher has code just to survive other tools' atomic saves. Both are consistent: rename-based saves break per-file watches.
- **Defaults on modified buffers differ.** Kakoune asks even for modified buffers, and reloading discards edits but is undoable. The others never auto-reload a modified buffer.

## Missing evidence

- Sublime Text 4 defaults and its mechanism (only an ST3 mirror and forum posts were read).
- VS Code: who calls `reconcileExternalChanges`; whether opening invalid UTF-8 warns before a lossy save.
- Zed: whether any path calls `fsync` on save (none in `RealFs::save`).
- Gerbil/Gambit: inotify flag coverage, `statfs`, `fsync` on directories, `chown`, xattrs, and whether `char` allows surrogate code points (all **[to verify]** before design).
- Neovim's watcher-based `autoread` is unreleased (master after 0.12); details may change.
