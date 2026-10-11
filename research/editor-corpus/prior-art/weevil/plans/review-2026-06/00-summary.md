# Weevil full review — consolidated summary (2026-06)

Seven focused review tracks, each with a detailed report in this directory:

1. `01-architecture-cqrs.md` — CQRS / fat-morph / single-writer fidelity
2. `02-public-api-extensibility.md` — public API boundary & Emacs-likeness
3. `03-core-buffer-model.md` — rope / buffer-model layer
4. `04-session-state.md` — the 1348-LOC session-state god-module + state layer
5. `05-terminal-subsystem.md` — terminal scope / design / safety
6. `06-tests.md` — test suite: integration vs unit, gaps, safety gating
7. `07-comments-and-hygiene.md` — comment density, dead code, doc staleness

All findings below were independently spot-checked against the source.

## Headline verdict

The core architecture is **sound and faithfully implemented**. CQRS is real: commands
go up, one event-loop thread is the only writer, immutable `session-state` is threaded
functionally, and `/events` streams the whole `#weevil-root` app on every revision with
no per-element patch routes. The rope buffer layer is the strongest part of the codebase.
This is *not* a rewrite situation — it is a "pay down vibe-coded debt and tighten the
boundaries" situation.

The work splits into five recurring themes. None is structural failure; all are about
keeping the next 6 months pleasant.

## Cross-cutting themes (ranked)

### Theme A — Machine-safety & resource leaks (P0, do first)
- **Ungated subprocess tests run in the default suite.** `tests/pty-test.rkt`,
  `tests/terminal-io-test.rkt`, and `tests/event-loop-terminal-event-test.rkt` spawn
  `/bin/sh … sleep 30` gated only by `pty-supported?`, **not** `WEEVIL_E2E`. CLAUDE.md
  requires such tests to be hard-gated. `tests/e2e/terminal-server-test.rkt` is the
  correct template (gated at `:147`). → Wrap each in `(when (getenv "WEEVIL_E2E") …)`.
- **`terminal-close!` has zero production callers** (`terminal-io.rkt:225`, only tests
  call it). No buffer-kill / disconnect / shutdown sweep → orphaned shells, threads, and
  PTYs leak for the VM lifetime. → wire teardown: per-terminal custodian + close on buffer
  kill + a shutdown sweep over `terminal-registered-ids`.

### Theme B — Layering leaks: pure core emits browser JavaScript (P1)
The pure state core hands raw JS strings to the render path, which breaks the "core owns
data, render owns DOM" boundary and the ADR's declarative-state-down rule.
- `session-state.rkt:292` `reanchor-script` returns *plain browser JavaScript* from a
  pure state transition (`ensure-point-visible`).
- `command-context.rkt:60` `command-context-add-script!` takes a bare JS string.
- This even reaches the **public API**: `ui.rkt` `request-page-refresh!` emits
  `"window.location.reload()"` (and `reload.rkt:20` duplicates the same reload via its own
  SSE route).
- → Have transitions return *data* (target scroll px, action keyword); never JS.

**Datastar grounding (the "client-action vocabulary" already exists — don't invent it).**
The Racket Datastar SDK has exactly two *declarative* state-down channels —
`patch-elements` (the fat morph) and `patch-signals` — plus `execute-script` as the narrow
*imperative* escape hatch (itself just a `<script>` tag inside a patch-elements event). The
ADR's signal allowlist (`sel`, `scroll`, `viewport`, `browser`) maps 1:1 onto
`patch-signals` consumed by client effects (`data-effect`, `data-on-signal-patch`,
`data-attr`). So:
- **Scroll re-anchor** (`reanchor-script`): the code's own comment already names the fix
  ("a future patch-signals push is the clean elimination"; "signals are ONLY valid inside
  `data-*` expressions, NEVER inside executed scripts"). The editor surface *already* has a
  `$scrollTop` signal (`render.rkt:287`) + a `data-on:scroll` sync. **Primary fix:** pure
  core returns the target px; render layer pushes `patch-signals {scrollTop: px}` and a
  `data-effect`/`data-attr` on `.editor` applies it. This keeps the server's authoritative
  `scroll-top-px` (which drives the virtual-scroll window) in lockstep with the client.
  *Alternative:* the SDK's `data-scroll-into-view` (Pro; `#:instant? #:vcenter?`) on the
  cursor element rides the fat morph with no second event — but it cedes the scroll math to
  the browser, so the server's `scroll-top-px` can diverge from the rendered window; prefer
  the signal approach for that reason.
- **`request-page-refresh!` / reload:** a genuine one-shot imperative action with no
  declarative equivalent — `execute-script` is the legitimate idiom. Keep it, but confine it
  to a named render-layer helper (not generated in pure state) and de-dupe with `reload.rkt`.
- **Clipboard (future, kill-ring ↔ system clipboard):** copy/kill lowers to the SDK's
  first-class `clipboard` action (`@clipboard(text)`); yank is a `@post` round-trip. Design
  the vocabulary once with these in mind. (Pro is already on the page via `datastar-pro.js`.)

### Theme C — `session-state.rkt` is a god-module (P2, structural)
1348 LOC, ~90 exports, 44 dependents, ~15 responsibilities (panes, windows, frames,
minibuffer, completion, scroll/viewport, files, terminal snapshots, echo messages,
focus/input-target…). The immutable discipline inside it is excellent; the problem is the
pile. Decompose **behind a re-export aggregator** so all 44 call sites stay unchanged and
behavior doesn't move:
`session-core` (struct + `state-with-rev` + selected-pane/view + input-target + pending-keys),
`session-edit`, `session-minibuffer`, `session-buffers`, `session-windows`,
`session-viewport` (no JS — see Theme B), `session-terminal`, `session-echo`; with
`session-state.rkt` becoming the thin aggregator. Strictly one-way deps, module-by-module.

Also: `session-state-set-message` (`:1325`) is the one transition that mutates without
bumping `rev` (relies on the loop's `equal?` check). Route through `state-with-rev` for a
single invariant.

### Theme D — Dead / superseded Phase-1 code (P1, easy wins)
- `editor-state.rkt` — Phase-1 state model superseded by `session-state`; its only live
  touchpoints are one dead projection fn (`buffer-view.rkt:112`
  `editor-state->buffer-projection`, no callers) and the `current-editor-state` alias
  (`event-loop.rkt:189`, one test caller). Delete the dead fn + alias, retire the module.
- `marker-state.rkt:20,28` — `marker-state-after-insert/-after-delete` never called in
  production (markers don't track edits). Wire into the edit path or document as
  non-tracking.
- `window-state.rkt` — unused parallel `window-*` struct vocabulary alongside the live
  `pane-*`. Quarantine or remove.
- `buffer-model-string.rkt` — production-dead (oracle/bench only); relocate to test-support
  and label "TEST ORACLE ONLY."

### Theme E — Terminal: a working, in-scope feature (fix teardown; update the stale ADR)
The terminal works and is a real feature. The ADR's "What's Not In v1" list is **stale** —
it predates the terminal landing. Correct the doc (mark the terminal in scope), do **not**
quarantine or remove working code. The CQRS integration (immutable snapshot in state, live
controller in a keyed side table) is correct and the code quality is high.

The genuine, scope-independent findings stand on their own merits:
- **Teardown leak (P0):** `terminal-close!` has no production caller — wire it into buffer
  kill + a shutdown sweep, with a per-terminal custodian (Theme A).
- **Test gating (P0):** the pty/shell tests must be gated behind `WEEVIL_E2E` (Theme A).
- **`pty.rkt` SIGHUP/SIGKILL (P1):** dead `(unless … (void))` then unconditional SIGKILL —
  the "polite then hard" intent never runs; clean it up.
- **Out-of-process engine (later, multi-session-era):** in-process libghostty means one
  segfault would take down the whole VM. Irrelevant today (single session); becomes a real
  prerequisite when multi-session lands. Note now, build later.
See `05-terminal-subsystem.md` for specifics.

### Theme F — Comments, dead docs, plans sprawl (P1, owner-flagged)
Comment density is 16–31% in the worst files, heavy on history narration (`[FIX 5/6/7]`
tags referencing a fix-list that lives nowhere), `Phase 1a/Design B` temporal labels, and
`;; ====` decorative banners. Much of the prose *is* valuable (FFI threading contracts,
async-staleness rules, `eq?`-stability invariants) — the problem is it's undifferentiated.
Adopt a 5-rule comment policy (07 report): (1) why not what; (2) no chronology/`[FIX N]`;
(3) one header line, no banners; (4) invariant/contract comments are protected; (5) long
rationale in a block above the def, not inline. This alone removes ~23 tags + ~55 banner
lines with zero invariant loss.

Doc staleness: `TODO.org:35` claims the event loop has no error handling — false since
`event-loop.rkt:362` `handle-loop-error!` landed. `PLAN.md` is historical Phase-1/1.5.
`plans/` is ~58 files of mostly *completed* design docs. → `plans/archive/` for shipped
plans, keep `ADR.md` + a forward `ROADMAP` + active-only `TODO.org` + `docs/EXTENDING.md`
as living docs, add `plans/README.md` with a one-line anti-sprawl rule. Delete nothing.

### Theme G — Public API boundary tightening (P1)
The public/private split is fundamentally sound (`weevil/config` is runtime-free, `unsafe/`
hatch is correct, handles are opaque, `defaults.rkt` is built 100% through public modules).
Gaps a third-party author would hit:
- `completion.rkt:25-52` — the entire public reader surface (`completing-read`,
  `read-buffer`, `read-file-name`, table ctors, exit-action registry) has **zero contracts**
  while every other module uses `contract-out`. Add `contract-out`.
- `ui.rkt:9-11` → `config.rkt` — `render-page` / `static-uri` rendering internals leak onto
  the normal public surface; drop `render-page`, move `static-uri` to `unsafe/ui`.
- `mode-line.rkt:8` — `(struct-out mode-line-context)` leaks a 9-field positional ctor;
  export accessors + a keyword `make-mode-line-context`.
- `terminal.rkt:66-74` — public module `struct-copy`s private `session-state`/`buffer-state`
  to set major mode; add a real `session-state-set-buffer-major-mode` core setter.
- Naming: keymaps are `*-keymap`/`global-keymap`, ADR mandates `*-mode-map`
  (`ADR.md:961`). Rename or amend the ADR.
- `commands.rkt:18,50` — remove the already-deprecated `current-command-scope` from the
  public contract now.

## What is genuinely good (do not churn)
- Robust single-writer loop with correct error isolation (`handle-loop-error!` deliberately
  does not catch `exn:break`/custodian shutdown); all heterogeneous inputs (key/scroll/
  resize/file/dir/terminal) serialized on one async channel.
- The rope: immutable/persistent, one `seek-leaf-by` engine for all conversions, associative
  summary monoid, real `rope-check-invariants`, no per-char UTF-8 allocs.
- The differential test (`buffer-model-differential-test.rkt`) — string-oracle vs rope over
  seeded random edits across the full public contract. Highest-value test in the repo; keep.
- The display-projection seam (`make-text-projection`) and the page-template extension point.
- Terminal FFI GC discipline + non-blocking `read-bytes-avail!` inside `handle-evt`
  (the classic blocking-read footgun, correctly avoided).
- `options.rkt` contracts at define/set/default; `keymap.rkt` inheritance/remap/cycle-guard;
  `config-loader.rkt` matches the plan exactly.

## Suggested sequencing

**P0 (safety, hours):**
- Gate the 3 subprocess test files behind `WEEVIL_E2E`.
- Wire terminal teardown (per-terminal custodian + close on buffer kill + shutdown sweep);
  fix the `pty.rkt` SIGHUP/SIGKILL dead-code path.
- Update the ADR: mark the terminal in scope (remove it from "What's Not In v1").

**Multi-session (decided: yes, eventually — a constraint, not a workstream now):**
Don't build multi-session now, but make the in-flight P2 refactors *session-shaped* so we
don't have to redo them. The hard part is already solved: state is immutable and threaded
through a single-writer loop. What's left is that the loop's `state`/`event-channel`/
`subscribers`/locks (`event-loop.rkt:173+`) and side-tables (`terminal-registry`, keyed by
buffer-id) are module-global singletons. So: (1) when decomposing the event loop + session
state (P2), package the runtime into a per-session object looked up by session id rather
than cementing globals; (2) ensure buffer/pane ids and the terminal-registry key are
session-scoped so two sessions can't collide; (3) per-session custodian for cleanup.
Routing + auth (the Phase-6 security item) and the out-of-process terminal engine are the
actual build-out — defer those until you start the feature.

**P1 (boundary + cleanup, low-risk, high-value):**
- Theme B: lift JS-string generation out of the pure core into a typed client-action
  vocabulary in the render layer (fixes `session-state`, `command-context`, `ui`).
- Theme D: delete dead Phase-1 code (`editor-state.rkt`, `buffer-view.rkt:112`,
  `current-editor-state`).
- Theme G: `completion.rkt` contracts; pull rendering internals out of public `ui`/`config`;
  `mode-line` struct-out; `terminal` private struct-copy; drop `current-command-scope`.
- Theme F: adopt the comment policy + strip `[FIX N]`/banners/phase labels; mark stale
  TODO/PLAN items; archive `plans/`.
- `set-message` rev-bump (Theme C invariant).

**P2 (structural, planned):**
- Theme C: decompose `session-state.rkt` behind a re-export aggregator, module by module.
- Buffer layer: relocate string backend to test-support; simplify the differential adapter's
  `who`-symbol mimic pre-checks (`buffer-model-rope.rkt:110-250`).
- Tests: add the missing integration coverage (in-process `POST /key`→`/events` round trip,
  `/events` disconnect cleanup, config-loader resolution, user-`init.rkt` rebind takes
  effect), then prune/consolidate the low-value pure-unit tests (06 report has the list).
  **Datastar grounding:** use the SDK's `datastar/testing` module (`make-recording-sse` →
  list of parsed `sse-event` structs with `type`/`data-lines`) to drive the route handlers
  with a mock SSE and assert on the emitted `datastar-patch-elements` / `datastar-patch-signals`
  events. This gives a true CQRS round-trip test with **no real server** (machine-safe) and
  also lets a test assert the "`/events` is the only state-down channel" invariant directly.
