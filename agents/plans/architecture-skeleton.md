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

### Stage 2: text and editing (merged 2026-10-11)

The buffer is a node tree from the start; the text node is one node kind among several (ADR 6). Nothing may assume one text node per buffer.

- **Carry-over from stage 1.** Move the echo area and help panel out of the kernel (`tuna/kernel/state.ss`) into plugins. Make `keymap-set` record source locations.
- **Prelude.** A thin `:tuna/prelude` (usable as `#lang :tuna` if Gerbil supports it cleanly; otherwise the `prelude:` header) re-exporting `:gerbil/core` plus `defcommand`, `keymap-set`, and `defplugin` forms that lower to ordinary context registrations (ADR 1). Basic editing is written with it.
- **Text store service** (live tier). An interface for length, slicing, line/position conversion, chunk iteration, and edits returning a new persistent version. Default: a persistent rope of string chunks caching character and newline counts (see Weevil's design in `agents/research/editor-corpus/prior-art/weevil/`). Toy: an immutable plain-string store, also used as the rope's test oracle. Swapping the provider live migrates every text's current content.
- **Texts, buffers, views, nodes.** A text holds the current store version, character and content revisions, a bounded change journal, and undo history with a boundary per command. A buffer has a name, a node tree, and a default point. A node has an identity, a kind, attributes, and children; node kinds are registered through plugin contexts and supply render procedures. A text node refers to a text. A view (the single window's) holds the focused text node, point, and goal column; points relocate through change records. Buffer positions are 1-based character (code point) positions.
- **Basic editing plugin.** Self-insert for printable keys, newline, delete backward and forward, character and line motion with goal column, line start and end, and undo (`C-/`, `C-_`) by command boundary. It edits the focused text node only.
- **Rendering.** The HTML renderer walks the current view's buffer tree and dispatches on node kind; the text node renders its lines with the cursor. Whole-buffer rendering is fine; no scrolling yet.
- **Tree demo.** The demo plugin registers `column` and `heading` node kinds and a `*welcome*` buffer `(column (heading "Welcome to Tuna") (text "…"))`; `C-c b` switches between `*scratch*` and `*welcome*`; `C-c s` swaps the text store; `C-c p` turns basic editing off and on.
- **Done when:** `make test` passes, including randomized rope-versus-string differential tests (with non-ASCII and emoji), 1-based position conversions, undo, a live text-store swap that keeps text and point, editing off and on leaving no stray bindings or commands, and rendering of the `*welcome*` tree; in a browser, typing, deleting, motion, undo, buffer switching, both swaps, and `C-h s` work. Cross-node cursor motion is out of scope.

### Stage 3: questions, settings, and slow work (merged 2026-10-11)

- **Carry-over from stage 2.** Add the `adapt` dependency kind (ADR 2) and declare the buffers plugin's text-store dependency with it, replacing the lazy per-text conversion; `C-h s` then lists buffers as a dependent. Group consecutive self-inserts into one undo group (Emacs groups up to 20). Restore point when undoing a forward delete.
- **Suspension and prompts** (ADR 3). Tasks suspend only at documented yield points and return the baton while waiting. Prompts push input targets; only the innermost waiting prompt receives input, answers are delivered innermost-first. A minimal minibuffer plugin shows the prompt and the answer being typed (reusing the text node and basic editing), with `read-string` as the first prompt. `C-g` in a prompt abandons it: the waiting command receives `quit`.
- **Tasks and input.** Tasks registered through plugin contexts (including a simple timer) are cancelled on deactivation. `input-pending?` and `discard-input`.
- **Settings** (ADR 9). `defsetting` with a default and documentation; `with-settings` binds through a Gerbil parameter; resolution is dynamic layer, then buffer, then global for now. A binding made by one command is invisible to another command waiting at a prompt.
- **Jobs** (ADR 3). `start-job` with a key (a newer job with the same key cancels the pending one), plain-data input, a cleared dynamic environment, results posted back and applied on the baton, and the three validity policies: `exact-revision`, `target-alive`, `rebase` (map result ranges through the text's change journal since the snapshot revision, dropping ranges touched by intervening edits).
- **Decorations.** A minimal per-text layer of named highlight ranges with faces; changing it bumps the decoration revision, not the content revision (ADR 4); ranges relocate with edits; the HTML renderer draws them.
- **Demo.** `C-c r` renames the current buffer through `read-string`. A slow highlighter job colors digits about 0.3 s after each change, using the `rebase` policy.
- **Done when:** `make test` passes, including the `adapt` swap, undo grouping, prompt suspension with the editor still dispatching keys, `C-g` abandoning a prompt, nested prompts answered innermost-first, timer tasks cancelled with their plugin, `with-settings` isolation across a waiting command, job replacement by key, each validity policy, and rebased highlights landing on the right characters after edits made while the job ran; in a browser, `C-c r` renames, digits color shortly after typing even while typing continues, `C-g` abandons a prompt, and `C-h s` shows buffers depending on the text store.

### Stage 4: swaps and saving (merged 2026-10-12)

- **Carry-over from stage 3.** The demo highlighter skips the minibuffer's text. Jobs posting several results: build only if cheap, otherwise add it to `TODO.md`.
- **Toy plain-text renderer** (live tier). Renders the same screen as preformatted plain text, using each node kind's plain-text render procedure or its text projection; `C-c v` swaps between it and the HTML renderer without losing state.
- **Window manager service** (live tier; ADR 11). A minimal contract: the frame's windows in order, the selected window, select a window, the next window (`C-x o`), show a buffer in a window, render the frame's window area, and export/import a neutral description (windows, their views, the selection) for live replacement. Each window shows a view; views own point (ADR 6). Default provider: one window. Toy provider: two windows side by side on the same buffer, each with its own view and point. `C-c w` swaps providers live, handing windows over through the neutral description; the renderer draws whatever the window manager provides.
- **Persistence** (ADR 5). Session slots registered through plugin contexts (name, schema version, `save` to plain data, `restore`). The session file `$XDG_STATE_HOME/tuna/session.ss` is written with `write` when idle and on exit, via a temporary file and atomic rename, and read with `read` plus validation, never evaluated; a corrupt file is moved aside and reported; unknown slots are preserved. Autosave writes unsaved buffer text to `$XDG_STATE_HOME/tuna/autosave/`. On start, buffers (names, text) and points are restored. Tests use a temporary state directory.
- **Latency.** Measure keydown-to-screen time: server-side from event arrival to the screen being written to each client's stream, plus an end-to-end browser measurement if practical. Expose recent numbers somewhere inspectable (for example a demo help command) and report median and 95th percentile for typing in `*scratch*`. **Retracted 2026-10-12:** the instrumentation this produced lived in the kernel's display contract and the web transport plugin, violating ADR 12; it was reverted. Measurement belongs to an external profiler plugin built on general-purpose hooks.
- **Done when:** `make test` passes, including the renderer swap, the window-manager swap preserving each window's point, `C-x o` between two views of one buffer with independent points, session save and restore across a simulated restart, a corrupt session file being moved aside, and atomic writes; in a browser, `C-c v`, `C-c w`, `C-x o` and a real restart (text, names, points come back) work; latency numbers are reported.
