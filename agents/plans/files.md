# Plan: files

Brief (approved 2026-10-26): [`docs/briefs/2026-10-files.md`](../../docs/briefs/2026-10-files.md). Research: [`agents/research/files/emacs-files.md`](../research/files/emacs-files.md), [`agents/research/files/other-editors.md`](../research/files/other-editors.md). ADR 5 (persistence).

## Invariants

- A text visits the file (visit record on the text: file name, true name, file identity, disk state at last read/save including a content hash, encoding, BOM, line-ending convention, final newline, saved revision); one text per file (true name / identity); buffers show it.
- All file I/O goes through a file service (`files` contract, interface; provider = local disk). No plugin calls the OS for files directly.
- Bytes round-trip exactly: UTF-8 ± BOM editable; uniform CRLF shown as lines and written back as CRLF; mixed endings kept as bytes; final newline kept; anything else (invalid UTF-8, UTF-16, binary by first KiB) opens read-only with an echo-area note. No encoding guessing.
- Saving: temp file in the same folder, fsync, copy mode (owner where allowed), rename, fsync folder; in place after a backup copy when renaming would change identity (hard links, owner not preservable, folder not writable); symlinks save through. Save hooks' errors reported and logged.
- Picker: `C-x C-f` is `completing-read` with a `file` table computed from the input (folder listing through the file service), category `file`, annotator (size, modified, already open), and picker keys through the prompt handle (`DEL` after `/` deletes a folder name, `~/` goes home). Sources (named groups in one list) extend completion in stage 2.
- Kernel unchanged. Docs updated as each stage merges.

## Stages

1. **Open and save.** Check Gerbil first (inotify overflow/folder events, folder fsync, chown). `files` contract + plugin: file service and local provider; visiting (`find-file`, `find-file-noselect`, `find-file-hook`, mode hand-off hook for later); the picker; `C-x C-s`, `C-x s`, `C-x C-w`; encodings/line endings/binary as above; unsaved marker in the status line; asking before killing an unsaved buffer and before quitting; `default-directory` per buffer; `before-save-hook`, save takeover hook, `after-save-hook`.
2. **Recent files and remembered places.** Session slots; completion sources (named groups in one list), with "Recent files" in the picker.
3. **Changes on disk.** Folder watches on a background source, ~100 ms burst absorption, polling fallback, re-check on tab focus and before save, content comparison, own saves ignored; reload by diff as one undoable change keeping cursors, marks and modes; conflict at save (overwrite / reload theirs); deleted/renamed reported; `revert`, `before-revert-hook`, `after-revert-hook`.
4. **Autosave for file buffers** in the state folder, restored on start.
