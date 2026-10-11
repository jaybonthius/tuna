# Roadmap

Each milestone is a working program that can be shown in the browser. Write a short plan (one page or less) when a milestone starts; record hard-to-reverse choices as ADRs.

## Next: architecture skeleton

Prove every seam in [the ADRs](adr/README.md) with the least feature code:

- the editor loop accepts browser keys, runs commands under the baton, and redisplays to every connected tab;
- a scratch buffer is one text node backed by the default persistent `TextStore`; typing, deleting, and basic motion work;
- basic editing is a plugin: deactivating it removes its commands and keys, and reactivating restores them;
- a second `TextStore` implementation can replace the default through the service registry;
- a command prompts in direct style through a minimal minibuffer and resumes with the answer;
- a deliberately slow fake highlighter runs as a job: edits render first, decorations arrive later, and stale results are discarded during fast typing;
- a session slot and autosave survive a restart;
- keydown-to-patched-frame latency is measured.

Out of scope: windows and splits, files, modes, completion UI, real highlighting.

## Later, roughly in order

1. Commands, prefix keymaps, `M-x`, minibuffer completion, echo area.
2. Files: find-file, save, revert, autosave; many buffers; buffer switching; large-file viewport.
3. Windows, splits, mode line; major and minor modes as plugins.
4. Real syntax highlighting and language-server integration as jobs and subprocesses.
5. First rich (non-text) buffer kind and navigation across nodes.
6. Attached REPL, `init.ss` reload, package reload.
7. Per-tab frames; client-side reactivity where it pays off.
