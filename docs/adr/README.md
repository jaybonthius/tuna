# Architecture decisions

Each record covers one hard-to-reverse choice. Change a decision by writing a new record that supersedes the old one; do not silently contradict it in code.

| # | Decision |
|---|---|
| [1](0001-language-and-extension-surface.md) | Plain Gerbil core; packages use a thin `:tuna` prelude; redefinition through `separate` modules, `set!`, and module reload |
| [2](0002-plugins-contexts-and-services.md) | Everything is a plugin; contexts revert what plugins register; replaceable parts are `std/interface` services |
| [3](0003-command-loop-and-jobs.md) | One editor thread with a baton; direct-style commands that can wait for input; background jobs on snapshots |
| [4](0004-state-ownership.md) | Owner-confined mutable objects, persistent text, per-object revisions, no rollback |
| [5](0005-persistence.md) | Files, autosave, per-plugin session slots, and custom settings as plain Scheme data |
| [6](0006-buffers-nodes-and-text-store.md) | Buffers are node trees; text lives behind a replaceable persistent `TextStore` |
| [7](0007-rendering-and-transport.md) | Server-rendered HTML frames over Datastar; the browser is a terminal |
