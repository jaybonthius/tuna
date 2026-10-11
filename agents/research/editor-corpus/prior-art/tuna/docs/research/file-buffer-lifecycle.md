# File-buffer lifecycle

## Question

What must a file-backed buffer retain so visiting, saving, reverting, and
external file changes remain safe?

## Findings

A file-backed buffer is an in-memory snapshot. Visiting reads a file into the
buffer; edits affect that snapshot; saving explicitly writes it back. Record a
canonical file identity separately from its display path, so opening the same
file through aliases does not silently create competing identities.

At visit and after every successful save, record enough file fingerprint data to
detect an external change. Start with modification time and size; add a content
hash only when a concrete false-negative case requires it. Before writing,
re-read the fingerprint. If it differs, do not overwrite: return a structured
conflict result that an interactive command can resolve as reload, save-as,
diff, or explicit overwrite.

A successful save should write safely, then refresh the fingerprint and clear
the dirty flag. Reverting replaces the snapshot from disk, refreshes the
fingerprint, and clears dirty state. Save and revert extension hooks belong at
these operation boundaries, not in UI code.

## Open decisions

- Whether one file identity has one shared buffer or independent session
  snapshots.
- Atomic-write behavior when preserving inode, permissions, or hard links
  matters.
- Auto-reload policy for clean buffers and presentation of dirty conflicts.
- Backup and recovery policy.

Do not inherit Emacs lockfile behavior by default. It coordinates independent
Emacs processes; Tuna should first define its own multi-session and external
writer policy.

## Sources

- [Emacs: Visiting Files](https://www.gnu.org/software/emacs/manual/html_node/elisp/Visiting-Files.html)
- [Emacs: Buffer File Name](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-File-Name.html)
- [Emacs: Modification Time](https://www.gnu.org/software/emacs/manual/html_node/elisp/Modification-Time.html)
- [Emacs: Saving Buffers](https://www.gnu.org/software/emacs/manual/html_node/elisp/Saving-Buffers.html)
- [Emacs: Reverting](https://www.gnu.org/software/emacs/manual/html_node/elisp/Reverting.html)
- [Emacs: File Locks](https://www.gnu.org/software/emacs/manual/html_node/elisp/File-Locks.html)
