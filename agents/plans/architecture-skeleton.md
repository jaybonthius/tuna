# Plan: architecture skeleton

Owner brief (approved 2026-10-11): [`docs/briefs/2026-10-architecture-skeleton.md`](../../docs/briefs/2026-10-architecture-skeleton.md). Governing decisions: ADRs [2](../adr/0002-plugins-contexts-and-services.md), [3](../adr/0003-command-loop-and-jobs.md), [4](../adr/0004-state-ownership.md), [6](../adr/0006-buffers-nodes-and-text-store.md), [7](../adr/0007-rendering-and-transport.md), [8](../adr/0008-input-keymaps-and-command-composition.md), [9](../adr/0009-settings-and-scoped-values.md), [10](../adr/0010-security-clients-and-trust.md), [11](../adr/0011-window-management-is-a-plugin.md), [12](../adr/0012-kernel-boundary-and-replaceability.md). Gerbil rules: [`agents/guides/gerbil.md`](../guides/gerbil.md).

## Shape

```text
tuna/kernel/       plugin runtime, service registry, editor loop, ids and revisions
tuna/kernel.ss     the kernel's public facade
tuna/plugins/<name>/ or tuna/plugins/<name>.ss   one directory or file per plugin
tuna/main.ss       boot: start the kernel, activate the standard plugin set
```

- The kernel imports no plugin. Plugins import only `:tuna/kernel` and the public facades of the services they use. Defaults get no private access (ADR 12).
- Contracts are `:std/interface` interfaces, each declared once next to the service name and its tier.
- Names are working names; adjust when Gerbil idiom suggests better, and keep `docs/emacs-equivalents.md` consistent.
- Tests are co-located `*-test.ss`; HTTP behavior is tested against a real server on an ephemeral loopback port.

## Stages

Each stage is one implementer task in its own worktree (see AGENTS.md), merged after review, then demoed to the owner before the next starts.

### Stage 1: kernel and connection (merged 2026-10-11, `5ed19f9`)

- **Plugin runtime.** Define, activate, deactivate plugins; contexts; receipts that undo in reverse order; owner-tagged entries with priorities for slot-like effects; dependency declaration on services; provenance (plugin, source location, documentation) on registrations.
- **Service registry.** Named services with an interface, a tier (`startup` or `live`), one provider at a time, dependents deactivated and reactivated on replacement, refusal to replace startup-tier services live, and data for `describe-services`.
- **Editor loop.** One loop owning the baton; each command runs as a task in its own thread (`spawn-thread`); input events are processed in order; redisplay coalesces after a task finishes and the queue is empty. Quit lane per ADR 3 (cooperative flag checked by `check-quit` and at yield points; forced `thread-interrupt!` after a grace period or a second quit; thread-scoped `inhibit-quit`). Suspension and prompts are stage 3.
- **Shared vocabulary.** Identity allocation and revision counters.
- **Web transport plugin** (startup tier). Loopback listener; per-launch token printed with the URL, exchanged for an `HttpOnly`, `SameSite=Strict` cookie; every route checks the cookie, `Host`, and `Origin`; page shell, `POST /commands` (validated event with client id and sequence number, `204` before enqueue), one SSE stream per client whose writer always sends the newest screen and never blocks the loop. Update the keyboard plugin to send the client id (per tab, `sessionStorage`) and sequence number. Salvage patterns from `tuna-old-2026-10/tuna/server.ss` and `embed.ss`, not their dependencies.
- **Key handling plugin** (startup tier). Global keymap with owner-tagged bindings in `keymap-set` syntax; key resolution; the quit key bound to the quit lane.
- **HTML renderer plugin** (live tier). Renders the screen from editor state through SXML: for now a status line, an echo area, and a panel for help output.
- **Demo plugin.** `C-c l` runs a command that loops forever (calling `check-quit`), a second command that loops without checking (to exercise forced quit); `C-h s` shows `describe-services` (each service, tier, provider, dependents).
- **Done when:** `make test` passes, including tests that two plugins binding the same key survive deactivation in either order, startup-tier services refuse live replacement, a cooperative and a non-cooperative endless command are both stopped by the quit key, and requests without the cookie or with a foreign `Origin` or `Host` are rejected; `make run` prints the URL, two tabs mirror the screen, `C-c l` then `C-g` recovers, and `C-h s` lists the services.

### Stage 2: text and editing

The buffer is a node tree from the start; the text node is one node kind among several (ADR 6). Nothing may assume one text node per buffer.

- **Carry-over from stage 1.** Move the echo area and help panel out of the kernel (`tuna/kernel/state.ss`) into plugins. Make `keymap-set` record source locations.
- **Prelude.** A thin `:tuna/prelude` (usable as `#lang :tuna` if Gerbil supports it cleanly; otherwise the `prelude:` header) re-exporting `:gerbil/core` plus `defcommand`, `keymap-set`, and `defplugin` forms that lower to ordinary context registrations (ADR 1). Basic editing is written with it.
- **Text store service** (live tier). An interface for length, slicing, line/position conversion, chunk iteration, and edits returning a new persistent version. Default: a persistent rope of string chunks caching character and newline counts (see Weevil's design in `agents/research/editor-corpus/prior-art/weevil/`). Toy: an immutable plain-string store, also used as the rope's test oracle. Swapping the provider live migrates every text's current content.
- **Texts, buffers, views, nodes.** A text holds the current store version, character and content revisions, a bounded change journal, and undo history with a boundary per command. A buffer has a name, a node tree, and a default point. A node has an identity, a kind, attributes, and children; node kinds are registered through plugin contexts and supply render procedures. A text node refers to a text. A view (the single window's) holds the focused text node, point, and goal column; points relocate through change records. Buffer positions are 1-based character (code point) positions.
- **Basic editing plugin.** Self-insert for printable keys, newline, delete backward and forward, character and line motion with goal column, line start and end, and undo (`C-/`, `C-_`) by command boundary. It edits the focused text node only.
- **Rendering.** The HTML renderer walks the current view's buffer tree and dispatches on node kind; the text node renders its lines with the cursor. Whole-buffer rendering is fine; no scrolling yet.
- **Tree demo.** The demo plugin registers `column` and `heading` node kinds and a `*welcome*` buffer `(column (heading "Welcome to Tuna") (text "…"))`; `C-c b` switches between `*scratch*` and `*welcome*`; `C-c s` swaps the text store; `C-c p` turns basic editing off and on.
- **Done when:** `make test` passes, including randomized rope-versus-string differential tests (with non-ASCII and emoji), 1-based position conversions, undo, a live text-store swap that keeps text and point, editing off and on leaving no stray bindings or commands, and rendering of the `*welcome*` tree; in a browser, typing, deleting, motion, undo, buffer switching, both swaps, and `C-h s` work. Cross-node cursor motion is out of scope.

### Stage 3: questions, settings, and slow work

Suspension at yield points and the input-target stack; tasks registered through contexts and cancelled on deactivation; `input-pending?` and `discard-input`; minibuffer and `read-string`; `C-c r` rename; `with-settings` on parameters with the scope chain stub; jobs with keys and the `rebase` validity policy over the change journal; the slow digit highlighter.

### Stage 4: swaps and saving

Toy plain-text renderer and toy two-window window manager with independent views, swapped live; autosave and a session slot restored on restart; keydown-to-screen latency measurement; overview and diagrams updated to what was built.
