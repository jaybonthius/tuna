# Weevil Architecture Synthesis (Emacs-Relevant)

> Status: historical synthesis. Several "current state" notes below predate the
> 2026-06-19 architecture refactor work (rope, prefix keys, error isolation,
> decomposed session-state, terminal subsystem, client-action seam). For the
> current review and roadmap, start with
> `plans/architecture-review-2026-06-19/README.md` and
> `plans/kernel-plugin-roadmap-2026-06-19/README.md`.

## Purpose
This document synthesizes:
1. Weevil’s current core architecture and public API surface.
2. Emacs architecture lessons that are directly relevant to Weevil’s near/future core.
3. Where Weevil is already on a strong path.
4. Prioritized architecture changes to improve long-term extensibility and safety.
5. A practical sequencing roadmap.

---

## 1) Current Weevil architecture/API surface

### Core runtime shape (today)
- **Single global session state + single global event loop thread** in `weevil/private/core/event-loop.rkt`.
- Input flow: **`/key` -> `enqueue-key!` -> `dispatch-key` -> command execution -> SSE `/events` patch**.
- Command execution is wrapped in dynamic command context (`command-context`) and runs `pre-command-hook`/`post-command-hook`.
- Rendering is server-owned (`weevil/private/web/render.rkt`) and currently patches a full app tree on updates.

### State/data model
- Canonical state root: `session-state` with buffers, panes, frame, selected input target, minibuffer stack, revision, id counters.
- Internal positions are **UTF-8 byte offsets**; public `point` is **Emacs-like 1-based char position** (`point-char`), with explicit low-level `point-byte`.
- Current frame model is effectively single-pane (`pane-leaf`), with minipane/minibuffer support.
- Buffer storage is currently string-backed via private `buffer-model` abstraction.

### Public extension surface (`weevil/config`)
- Commands: `define-command`, registry, command-context accessors.
- Keymaps: `make-keymap`, `define-key!`, remap, normalization.
- Buffer editing: insert/delete/move/point APIs.
- Minibuffer APIs and minibuffer keymap.
- Modes registry (major/minor), hooks, options.
- UI helpers (`request-page-refresh!`, page/static helpers).
- `faces` is currently a placeholder.

### Known constraints/risks
- Process-global mutable registries (commands/modes/options/hooks).
- No per-session isolation yet (state, queue, subscribers are global).
- No error isolation boundary around command/hook failures in the loop.
- Key dispatch is single-key oriented (no prefix key sequences yet).
- No marker model/undo journal/invalidation engine yet.

---

## 2) Emacs lessons relevant to Weevil’s near/future core

Only the lessons that map directly to Weevil’s next architecture steps:

1. **Stable extension vocabulary beats feature churn**  
   Emacs durability comes from stable concepts (commands, keymaps, hooks, modes, vars), not internals.  
   **Implication:** lock API compatibility policy early.

2. **Separate shared text from per-view cursor/selection state**  
   Emacs distinguishes buffer text from window point and supports shared text with independent views (indirect buffers).  
   **Implication:** keep buffer data distinct from pane/view state; multi-pane can then scale cleanly.

3. **Point is not enough; markers/regions need first-class semantics**  
   Emacs uses markers for edit-stable anchors and explicit insertion behavior.  
   **Implication:** introduce marker + region primitives before advanced navigation/selection/overlays.

4. **Keymap composition/precedence is foundational**  
   Emacs key resolution depends on layered maps and prefix sequences.  
   **Implication:** formalize precedence and add prefix key sequences without breaking existing bindings.

5. **Hooks and mode lifecycle conventions matter**  
   Emacs scales by consistent lifecycle hooks and mode conventions.  
   **Implication:** move from generic hooks/registries toward typed lifecycle events and predictable mode enable/disable semantics.

6. **Buffer-local vs global option semantics are essential**  
   Emacs separates defaults from buffer-local values.  
   **Implication:** add true buffer-local option table with fallback to defaults.

7. **Redisplay should be incremental and invalidation-driven**  
   Emacs redisplay architecture tracks change classes and unchanged regions.  
   **Implication:** introduce change metadata and dirty-surface invalidation; avoid full rerender as default long-term path.

8. **Mutation path must be centralized and failure-safe**  
   Emacs command loop is central; module boundaries are explicit and defensive.  
   **Implication:** preserve single-writer semantics but add session isolation, error containment, and extension trust boundaries.

---

## 3) Where Weevil already aligns well

- Clear **public/private boundary** (public modules vs `weevil/private/*`).
- Correct early decision: **byte-canonical internals + char-oriented public point API**.
- Strong command-loop framing: input intents routed through one mutator path.
- Existing keymap layering already models **minor > major > global**, and minibuffer isolation is explicit.
- Renderer is already treated as a projection (not source of truth).
- Good test coverage around core invariants (positions, key normalization, dispatch order, render contracts).

---

## 4) Prioritized architecture changes

## P0 (foundation; do first)

1. **Public API compatibility contract**
   - Add API version/capability checks, deprecation/alias policy, and additive-first evolution rules.
   - Touchpoints: `weevil/config.rkt`, docs, new `weevil/api.rkt` (or equivalent).

2. **Per-session runtime isolation**
   - Replace singleton state/queue/subscribers with session manager + one loop per session.
   - Touchpoints: `private/core/event-loop.rkt`, `pages/editor.rkt`, app bootstrap.

3. **Command/hook error isolation**
   - Prevent extension errors from killing session loops; report structured errors.
   - Touchpoints: `private/core/command-loop.rkt`, `private/core/event-loop.rkt`.

4. **Canonical edit `ChangeSet` model**
   - Every text mutation returns structured change metadata (ranges/deltas).
   - Touchpoints: `private/core/buffer-model.rkt`, `private/core/session-state.rkt`.

## P1 (core extensibility semantics)

5. **Marker + region model**
   - Introduce edit-stable anchors with insertion bias and explicit region semantics.
   - Enables robust selection, overlays, navigation packages.

6. **Buffer-local option/state table**
   - Add true local values with global-default fallback.
   - Unblocks mode-local behavior without hidden coupling.

7. **Keymap evolution: prefix sequences + explicit precedence phases**
   - Keep existing bindings compatible while adding multi-key dispatch.

8. **Mode/hook lifecycle expansion**
   - Add typed lifecycle hooks (buffer/mode/command/minibuffer) and predictable mode activation conventions.

## P2 (scale/perf/safety)

9. **Incremental redisplay pipeline**
   - Dirty-surface invalidation + targeted patches; render once per rev and fan out.

10. **Frame/pane layout tree + true multi-pane**
   - Move from single leaf to split tree; preserve per-pane view state.

11. **Undo transaction journal (command-boundary aware)**
   - Coalescing for self-insert bursts; restore point/mark correctly.

12. **Extension trust tiers + async job supervisor**
   - Keep trusted init path; optional sandboxed/untrusted mode; background jobs that cannot block typing loop.

---

## 5) Suggested sequencing roadmap

### Phase A — API + runtime hardening (P0)
- API compatibility contract.
- Session manager/per-session event loop.
- Command failure containment.
- Introduce `ChangeSet` as internal edit currency.

### Phase B — semantic core (P1)
- Marker/region model.
- Buffer-local options and mode-local state.
- Key sequence dispatch.
- Typed hook/mode lifecycle.

### Phase C — scalable UX (P2)
- Incremental redisplay + per-rev render fanout.
- Layout tree/multi-pane support.
- Undo journaling.
- Extension trust tiers + async job/process boundary.

### Phase D — confidence gates (continuous)
- Expand tests for: session isolation, ordering/backpressure, loop survival after command errors, invalidation correctness, and extension boundary behavior.

---

## References (from `emacs-research/`)

### Local index
- `emacs-research/emacs-research.org`

### Primary sources
- GNU Emacs Internals: https://www.gnu.org/software/emacs/manual/html_node/elisp/GNU-Emacs-Internals.html
- Buffer Internals: https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Internals.html
- Buffer Gap: https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Gap.html
- Window Point: https://www.gnu.org/software/emacs/manual/html_node/elisp/Window-Point.html
- Markers overview: https://www.gnu.org/software/emacs/manual/html_node/elisp/Overview-of-Markers.html
- Active Keymaps: https://www.gnu.org/software/emacs/manual/html_node/elisp/Active-Keymaps.html
- Hooks: https://www.gnu.org/software/emacs/manual/html_node/elisp/Hooks.html
- Major Mode Conventions: https://www.gnu.org/software/emacs/manual/html_node/elisp/Major-Mode-Conventions.html
- Defining Minor Modes: https://www.gnu.org/software/emacs/manual/html_node/elisp/Defining-Minor-Modes.html
- Creating Buffer-Local Bindings: https://www.gnu.org/software/emacs/manual/html_node/elisp/Creating-Buffer_002dLocal.html
- Defining Commands: https://www.gnu.org/software/emacs/manual/html_node/elisp/Defining-Commands.html
- Interactive Call: https://www.gnu.org/software/emacs/manual/html_node/elisp/Interactive-Call.html
- Writing Dynamic Modules: https://www.gnu.org/software/emacs/manual/html_node/elisp/Writing-Dynamic-Modules.html
- Emacs redisplay source commentary (`xdisp.c`): https://raw.githubusercontent.com/emacs-mirror/emacs/master/src/xdisp.c
- EMACS (1981): https://www.gnu.org/software/emacs/emacs-paper.html
- Finseth, *The Craft of Text Editing*: http://www.finseth.com/craft/

