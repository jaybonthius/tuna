# Architecture decisions

Each record covers one hard-to-reverse choice. Change a decision by amending its record (noting the amendment in its status line) or by writing a new record that supersedes it; do not silently contradict it in code. Every divergence from Emacs must also appear in [`docs/emacs-equivalents.md`](../../docs/emacs-equivalents.md).

| # | Decision |
|---|---|
| [1](0001-language-and-extension-surface.md) | Plain Gerbil core; packages use a thin `:tuna` prelude, compile as `separate`, and are redefinable and advisable |
| [2](0002-plugins-contexts-and-services.md) | Everything is a plugin; receipts revert owner-tagged effects; manifests; replaceable services |
| [3](0003-command-loop-and-jobs.md) | One editor loop with a baton; quit lane; tasks that suspend at documented yield points; jobs with validity policies |
| [4](0004-state-ownership.md) | Owner-confined mutable objects, persistent text, split revisions, change journal, no rollback |
| [5](0005-persistence.md) | Files through path-dispatched services, byte-exact encodings, autosave, per-plugin session slots, plain Scheme data |
| [6](0006-buffers-nodes-and-text-store.md) | Texts, buffers, and views; node-tree buffers; 1-based positions; selections; styled text; replaceable `TextStore` |
| [7](0007-rendering-and-transport.md) | Server-rendered screens over Datastar; ordinary tabs first-class; layout belongs to the browser |
| [8](0008-input-keymaps-and-command-composition.md) | Input sessions, layered keymaps, command-loop hooks, interactive specifications |
| [9](0009-settings-and-scoped-values.md) | Settings with schemas, an extensible scope chain, combiners, and a thread-scoped dynamic layer |
| [10](0010-security-clients-and-trust.md) | Token-authenticated clients, client identity, and the trust boundary |
| [11](0011-window-management-is-a-plugin.md) | Window management is a replaceable plugin over a small window contract; the default is a recursive layout tree with pluggable container kinds |
