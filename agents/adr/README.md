# Architecture decisions

Each record covers one hard-to-reverse choice. Change a decision by amending its record (noting the amendment in its status line) or by writing a new record that supersedes it; do not silently contradict it in code. Every divergence from Emacs must also appear in [`docs/emacs-equivalents.md`](../../docs/emacs-equivalents.md).

| # | Decision |
|---|---|
| [1](0001-language-and-extension-surface.md) | Typed Gerbil core; Tuna-prelude package functions are open by default, with `def/closed` for hot spots; private module-context redefinition and planned owner-scoped advice |
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
| [12](0012-kernel-boundary-and-replaceability.md) | A small fixed kernel (plugin runtime, execution rules, hooks and identities, consumed seams); every editor feature is a plugin, replaceable at startup or live |
| [13](0013-views-layout-and-frames.md) | Buffers are UI; views (not windows) in a layout owned by a plugin; buffers changed in place with revisions; movable frames and frame marks; the buffers contract covers editing and undo |
| [14](0014-completion.md) | Completion: typed candidates, a session object, engine and UI slots, style and annotator registries, a commands contract split from keys; no advice |
| [15](0015-scroll-state.md) | Scroll state on items: the browser scrolls natively, with its own scroll bar over spacers sized by the measured average item height, and reports what it measured; the server places items; positions are never guessed; scroll reports are special events |
| [16](0016-several-tabs-mirror-one-editor.md) | Several tabs mirror one editor; per-tab state is three things on the server (identity and connection, keys in progress, what the browser measured), keyed by a tab-id signal |
| [17](0017-memo-and-sources.md) | Drawing only what changed: every piece of the screen drawn through `memo`, reused while no source it read (recorded automatically) has a newer revision; lines compared by value; outside state as sources that post only differences |
| [18](0018-terminals-in-helper-processes.md) | Terminals live in helper processes (one per terminal, holding the pseudo-terminal and a libghostty-vt screen) so they survive Tuna restarts and plugin swaps; Tuna keeps a mirror fed from a snapshot and the live stream; reboots restore context, never processes |
