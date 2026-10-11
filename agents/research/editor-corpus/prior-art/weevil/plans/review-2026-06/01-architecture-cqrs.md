# Weevil Review — Track: Architecture & CQRS Fidelity

Date: 2026-06-19
Reviewer track: architecture / CQRS fat-morph / single-writer fidelity
Scope: `weevil/private/core/{event-loop,command-loop,command-context,dispatch-context,keymap-resolver}.rkt`,
`weevil/private/web/{render,projection,text-projection,terminal-projection,buffer-view,page-template}.rkt`,
`weevil/components/{app,server,template,reload}.rkt`, `weevil/pages/{all,common,editor}.rkt`,
`weevil/dynamic.rkt`.

## Verdict

The CQRS + single-writer + fat-morph architecture is **faithfully realized and
genuinely well-built**. Commands go up through `POST /key|/scroll|/resize`,
every input is enqueued onto one async-channel, a single event-loop thread is
the only writer, immutable `session-state` is threaded functionally, and
`/events` streams the *whole* editor app (`#weevil-root`) down on every
revision. There are no per-element patch routes. The display-projection seam is
an elegant abstraction that kept the renderer content-model-agnostic when the
terminal (a genuinely different content model) was added.

The architecture's main erosion points are: (1) a raw-JavaScript "scripts"
side-channel riding the morph, (2) terminal-specific knowledge leaking into the
otherwise-generic event loop, and (3) a second, legacy projection path still
used only by the minibuffer. None are critical; all are tractable.

Note: the implementation is **well past** the documented Phase 1/1.5 plan
(terminals, async file I/O, directory completion, virtual scroll, mode line,
minibuffer stack). The plan/ADR are stale relative to the code; that is a
documentation-fidelity gap, not an architecture defect, but it makes the plan a
weak review oracle.

---

## What is GOOD (keep, don't churn)

- **Single-writer is real.** `event-loop.rkt` owns `state` (`event-loop.rkt:165`)
  and is the only place `set-current-session-state!` is called from the loop
  thread. All HTTP handlers in `pages/editor.rkt` only `enqueue-*!` — no handler
  mutates state. This matches the ADR "Single Writer Session Event Loop" exactly.
- **Scroll/resize/file-IO/terminal events ride the *same* channel as keys**
  (`event-loop.rkt:198-241`), so ordering is serialized with edits. This is the
  correct way to preserve command ordering across heterogeneous inputs.
- **`/events` truly sends the whole app.** `editor-events` (`pages/editor.rkt:24`)
  re-renders `render-editor-app` (the entire `main#weevil-root`) and
  `patch-elements/xexprs` morphs it; no `/buffer`, `/status`, `/cursor` routes
  exist (`components/app.rkt:14-22`). Stable element ids (`weevil-echo`,
  `weevil-completions`, `weevil-mode-line-<id>`) are used for in-place morphing,
  not as separate streams — this is correct fat-morph, not creeping patches.
- **Error robustness.** `handle-loop-error!` (`event-loop.rkt:251`) wraps each
  loop iteration, surfaces the error to the echo area, keeps the loop alive, and
  deliberately does **not** catch `exn:break`/custodian shutdown. This is the
  right call-loop survival posture.
- **The display-projection seam** (`projection.rkt`) is the strongest design in
  this track: a struct-of-procedures interface (`line-count`, `rendered-lines`,
  `cursor`, reserved `decorations`/`display->content`) with a kind dispatcher,
  `lazy-require` to break the cycle, and two providers (text/terminal). The
  renderer (`render-editor-window`) is genuinely content-model-agnostic.
- **The terminal-registry side table** (`term/terminal-registry.rkt`) is
  correctly *not* in the pure state, is lock-guarded, and its rationale (a live
  thread-owning pty handle cannot live in an `equal?`-comparable immutable
  value) is sound and well-documented.
- **Functional purity of transitions.** `commit-file-transition!`
  (`event-loop.rkt:243`) cleanly separates off-thread I/O (already done) from
  the pure fold + notify. `ensure-point-visible` is `eq?`-stable when point is
  already visible.

---

## Findings (prioritized)

### 1. Raw-JS "scripts" side-channel rides the fat morph
**Severity: Medium · Type: redesign/simplify · `event-loop.rkt:53`,
`command-context.rkt:60`, `render.rkt` scroll-script producers**

`editor-update` carries `(state scripts)` where `scripts` is a list of **raw
JavaScript strings** executed via `execute-script` next to the morph
(`pages/editor.rkt:29-30`). Any command can inject arbitrary JS through
`command-context-add-script!` (`command-context.rkt:60`), which takes a bare
`string?`.

The ADR's "Signals vs Server-Rendered HTML" section *does* sanction
"client actions" for browser-owned capabilities (scroll position, clipboard),
so the scroll re-anchor is legitimate in spirit. The problem is the **shape**:
an unbounded raw-JS escape hatch beside the declarative HTML-down model is
exactly the kind of "client-side logic leaking out of the server" the ADR warns
against, and it lives in the core command-context API rather than the renderer.

Recommendation: replace the `string?` script payload with a small typed
*client-action* vocabulary (e.g. `(scroll-to top-px)`, `(clipboard-read)`,
`(clipboard-write text)`) that the renderer/SSE layer — the one place allowed to
know DOM/JS — lowers into JS. This keeps the morph the only state-down channel
and the action vocabulary auditable/escapable-by-construction. It also matches
the ADR's "semantic specs, not raw HTML/JS" principle for the imperative side.

### 2. The generic event loop knows about terminals
**Severity: Medium · Type: refactor · `event-loop.rkt:8-16, 226-330`**

`event-loop.rkt` directly requires `term/terminal-registry`, `term/terminal-io`,
and `term/geometry`, and has terminal special-cases inlined in three arms:

- key arm gates `ensure-point-visible` on `(buffer-state-kind ... 'terminal)`
  (`event-loop.rkt:284-292`);
- scroll arm routes wheel deltas to `terminal-scroll!` (`event-loop.rkt:300-306`);
- resize arm calls `maybe-resize-terminal!` (`event-loop.rkt:223`, `:327`).

This is the same "renderer special-case" smell the projection seam *already
solved* elsewhere — only here it leaked into the single-writer loop. The loop
should dispatch on `buffer-state-kind` through a tiny per-kind interface
(`reanchor`, `handle-wheel`, `handle-resize`) so the loop stays generic and a
future buffer kind doesn't add more arms. Today the loop is coupled to one
concrete content model.

### 3. The key-event arm is a god-arm
**Severity: Medium · Type: simplify · `event-loop.rkt:262-298`**

The `[(key-event payload) ...]` arm is ~45 lines of inline logic: geometry
`parameterize`, `apply-key`, terminal-gated `ensure-point-visible`, the
dir-listing re-request hook, script appending, change detection, and notify.
The file arms already demonstrate the better pattern (`commit-file-transition!`).
Extract `handle-key-event!`, `handle-scroll-event!`, `handle-resize-event!` so
the loop body becomes a thin dispatch `match`, each handler is independently
testable, and the terminal coupling from finding #2 has a natural home.

### 4. Two parallel projection systems; minibuffer still on the legacy path
**Severity: Medium · Type: cleanup/refactor · `render.rkt:101-145, 325-330`,
`buffer-view.rkt`**

The main window renders through the new `display-projection` seam
(`projection.rkt` + `text-projection.rkt`), but the **minibuffer** still uses
the legacy `buffer-view.rkt` `buffer-projection` plus `render.rkt`'s legacy
whole-projection cursor injector `projection->pieces-with-cursor`
(`render.rkt:107`). So the codebase carries two cursor-injection
implementations (`projection->pieces-with-cursor` and `line-pieces-with-cursor`)
that a test must prove byte-identical (`module+ for-tests`). Route the
minibuffer through `make-text-projection` too; then the legacy injector and most
of `buffer-view.rkt`'s projection machinery can retire, removing the duplication
the equivalence test exists to police.

### 5. Dead code: `editor-state->buffer-projection` and the legacy state coupling
**Severity: Low · Type: cleanup · `buffer-view.rkt:5, 22-24, 112-115`**

`editor-state->buffer-projection` has **no callers** (only its definition and
the contract appear in the repo). It is the sole reason `buffer-view.rkt`
requires the old Phase-1 single-buffer `editor-state.rkt`. Deleting it drops a
dependency on a legacy module and shrinks the public surface of `buffer-view`.

### 6. No auth token / Origin (CSRF) check on POST routes
**Severity: Low (given current phase) · Type: note/redesign-later ·
`components/app.rkt:14-22`, `pages/editor.rkt:38-44`**

The ADR "Security" section mandates a startup auth token and an `Origin`-header
CSRF check on all POSTs. Neither exists: `/key`, `/scroll`, `/resize`,
`/force-reload` are unauthenticated. Mitigations in place: the server binds
`127.0.0.1` by default (`server.rkt:71`, `dynamic.rkt`), and Datastar's
`application/json` `fetch` triggers CORS preflight that an unconfigured server
won't satisfy cross-origin. This is explicitly Phase 6 work, so it is acceptable
*now*, but it should be tracked — the threat (any local process, or a
mis-skilled CORS setup) is real for an editor that can run shell commands.

### 7. `/force-reload` is an unauthenticated, side-effecting GET in prod
**Severity: Low · Type: note · `components/app.rkt:18-19`, `components/reload.rkt`**

`/reload` + `/force-reload` are wired unconditionally even though the
reload *client* is only injected when `debug?` (`page-template.rkt:36`). A GET to
`/force-reload` broadcasts a reload to all connected browsers. Harmless, but it
is another unauthenticated side-effecting route; consider gating the routes
themselves on `debug?` so prod doesn't expose them.

### 8. `request-json-payload` swallows parse errors silently
**Severity: Low · Type: note · `pages/editor.rkt:46-60`**

A malformed body becomes `(hash 'error <msg>)` and is still enqueued; for keys it
degrades gracefully (`normalize-key-payload` -> `#f` -> no-op), which is good
robustness. But the `'error` entry then vanishes with no log. Consider
`log-editor-warning` on the parse-failure branch so bad clients are observable.

### 9. Vestigial seam args / transitional aliases
**Severity: Low · Type: cleanup · `event-loop.rkt:189`, `keymap-resolver.rkt:78`**

- `current-editor-state` (`event-loop.rkt:189`) is documented as a transitional
  alias for `current-session-state`; schedule its removal once callers migrate.
- `active-keymap-layers` accepts a `dispatch-context` it ignores
  (`keymap-resolver.rkt:78`, `_context`). The comment justifies it ("signature
  compatibility"), but a parameter that is always ignored invites confusion —
  either drop it or convert it into an explicit seam comment that this is the
  intended extension point for context-sensitive layers.

---

## Cross-cutting observations

- **Comment density.** Several files (notably `event-loop.rkt`, `render.rkt`,
  `terminal-projection.rkt`) carry very long explanatory comment blocks,
  including `[FIX n]` history markers (`render.rkt:226`, `:241`, `:262`) that
  read like changelog entries baked into source. These will rot. Owner has
  flagged excessive inline comments globally; this track confirms it. Prefer
  short "why" notes and move design narratives to `plans/` / ADR. The `[FIX n]`
  tags in particular should go to git history, not the source.
- **Server boundary is clean.** `server.rkt`'s `break-enabled-dispatcher`
  converting dispatcher-level breaks to empty responses is a reasonable
  boundary; the `#;`-commented positional struct construction
  (`server.rkt:81-89`) is a stylistic oddity (faux keyword args via reader
  comments) but harmless.
- **`pages/all.rkt` / `common.rkt` / `template.rkt`** are thin and correct;
  `template.rkt` simply renames `render-page` from the public `ui.rkt`, keeping
  the page-template override seam (`page-template.rkt`'s `define-extension-point`)
  intact. Good adherence to the public-API-through-extension-points philosophy.

## Suggested sequencing

1. Extract per-event handlers from the loop (#3) — unlocks #2.
2. Introduce a per-buffer-kind dispatch interface for reanchor/wheel/resize (#2).
3. Replace raw-JS `scripts` with a typed client-action vocabulary (#1).
4. Unify the minibuffer onto `make-text-projection`; retire the legacy injector
   and dead `editor-state->buffer-projection` (#4, #5).
5. Track auth/CSRF for Phase 6 (#6, #7); add parse-failure logging (#8); prune
   vestigial aliases/args (#9).
