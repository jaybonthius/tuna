# Recommended design and architecture changes

Priorities are based on reversibility and blast radius, not just current bugs.

## P0 — decide foundations before more extension code grows

### 1. Decide the command model and add command metadata

Current commands are nullary thunks that read a dynamic command context. That works, but it diverges from Emacs `interactive` commands and makes prefix args, command arguments, docstrings, `M-x`, `describe-command`, and command palettes harder to add later.

Recommendation: either:

- add an Emacs-like `interactive`/argument/prefix convention now; or
- explicitly bless dynamic-context commands as the design and update the ADR.

Either way, add command metadata now: public name, docstring, category, interactive? flag, maybe argument spec. This is the highest-leverage architectural choice.

### 2. Add buffer-local variables/options before modes grow

Several surfaces are waiting for this: cursor type, mode-line format, modes, options, and future faces/theme behavior. Add a real buffer-local table with global-default fallback before mode APIs become richer.

Minimum shape:

```text
option default table
buffer-local override table on buffer-state
option-ref resolves buffer local -> default
set-option! stays global; set-buffer-local-option! is explicit
```

### 3. Make markers live, or clearly name them non-tracking

`marker-state` carries insertion-bias intent, but markers do not auto-adjust across edits. That blocks correct multi-pane shared-buffer behavior, overlays, diagnostics, regions, and multi-cursor later.

Recommendation: before split panes/overlays, add a marker registry per buffer and edit fixup for insert/delete. Interim safety fix: clamp/validate saved default point/mark when restoring a pane view.

## P1 — tighten current architecture

### 4. Make `rev` mean one thing

`session-state-set-message` changes visible state without bumping `rev`. The render still notifies because equality changes, but `data-rev` is no longer a complete render-version signal.

Recommendation: either bump `rev` for echo/message changes, or split names into `edit-rev` and `render-rev`.

### 5. Split and test the client-expression/render seam

`client-action-script.rkt` is a good typed seam for server-requested actions, but `render.rkt` still embeds large Datastar JS expression strings for input payloads.

Recommendation:

- move key/paste/scroll/resize/select-target expressions into a small `client-expressions.rkt`;
- test those payload shapes;
- remove the stale `dispatch-context` import from `render.rkt`;
- collapse the duplicate cursor injector logic once the equivalence test is trusted.

### 6. Add queue coalescing/backpressure for `/events`

Each subscriber has an unbounded async channel, and each revision can render a full app for each subscriber. This is fine now, but slow tabs can accumulate stale states.

Recommendation: per subscriber, keep only the latest pending state/update, or coalesce by `rev` before rendering.

### 7. Move synchronous terminal control off the writer thread

Terminal output is correctly off-thread, but resize/scroll/shutdown control calls are made from the event-loop arm. If a PTY/control operation blocks, the single writer stalls.

Recommendation: post terminal control commands to the terminal owner thread and make event-loop arms non-blocking.

### 8. Add `kill-buffer`/pane teardown with terminal cleanup

The terminal subsystem now has strong shutdown primitives, but there is no user-facing buffer/pane deletion path. When that lands, terminal buffers must call `terminal-shutdown!` and unregister their controller.

Also add buffer/history caps to avoid unbounded long-session growth.

## P2 — expand Emacs-like extension surface

### 9. Flesh out modes, hooks, and faces

Current modes are mostly `(id, keymap)`. Add:

- mode setup/teardown;
- `*-mode-hook` lifecycle;
- auto-mode associations;
- public minor-mode enable/disable;
- display name/lighter;
- a minimal face/theme vocabulary in `faces.rkt`.

Also add standard hooks where behavior exists: `before-save-hook`, `after-save-hook`, `find-file-hook`, and eventually `after-change-functions`.

### 10. Add mark/region/kill-ring primitives

Basic editing APIs exist, but the classic Emacs compositional vocabulary is incomplete: mark, active region, region bounds, kill/yank, kill-ring, `kill-line`, `kill-region`.

Add these after live markers or alongside them.

### 11. Encapsulate the singleton runtime behind a session object

Do not build multi-session now, but make new refactors session-shaped. Event loop state, subscribers, side tables, and queues are module-global today. Wrap them in a runtime/session manager before routing/auth makes multi-session mandatory.

### 12. Introduce ChangeSet/dirty-surface metadata when render performance demands it

The current full-app Datastar morph is simple and correct. Keep it until profiling says otherwise. The next step should be structured edit/render metadata, not ad hoc DOM patch routes.

## Docs/test cleanup

- Update `ADR.md`: terminal is no longer a v1 non-goal; reconcile `*-keymap` vs `*-mode-map` naming.
- Refresh or supersede `docs/emacs-architecture-synthesis.md`; its current-state section predates several landed refactors.
- Mark `plans/review-2026-06/` as a historical/actioned snapshot.
- Reword `TODO.org` compound-key item: prefix sequences work; remaining concern is priority/indicator behavior.
- Add tests for SSE disconnect/unsubscribe, runtime-config env resolution, marker edit stability, and route-level resize/scroll behavior.

## Things I would not change

- Keep server-owned state and the CQRS split.
- Keep the public/private module boundary.
- Keep byte offsets canonical internally and char positions public.
- Keep the rope seam and differential oracle tests.
- Keep terminal live controllers out of pure session state.
- Keep full-app render until measured pressure justifies incremental redisplay.
