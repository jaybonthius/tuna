# auto-revert

Keeps buffers in step with their source, as Emacs's `global-auto-revert-mode` does. A file buffer with no unsaved edits reloads when its file changes on disk, keeping cursors on their text; one with unsaved edits is left alone and marked `Stale`. Loading the plugin turns it on.
