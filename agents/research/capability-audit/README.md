# Capability audit (2026-10-11)

Five parallel read-only research lanes audited ADRs 1–7 against Emacs (core, real packages) and post-Emacs needs, looking for decisions that would paint Tuna into a corner. The lane reports are kept verbatim; this page is the synthesis and records what was done with each finding. The owner-facing summary is [`docs/briefs/2026-10-capability-audit.md`](../../../docs/briefs/2026-10-capability-audit.md).

| Lane | Report |
|---|---|
| Brief given to every lane | [brief.md](brief.md) |
| 1. Command loop, input, keymaps, minibuffer, completion | [01-command-loop-and-input.md](01-command-loop-and-input.md) |
| 2. Buffers, text model, display | [02-buffers-text-and-display.md](02-buffers-text-and-display.md) |
| 3. Runtime, extension mechanisms, environment | [03-runtime-and-environment.md](03-runtime-and-environment.md) |
| 4. Real-package stress tests | [04-package-stress-tests.md](04-package-stress-tests.md) |
| 5. Beyond Emacs, browser and server realities, prior art | [05-beyond-emacs-and-browser.md](05-beyond-emacs-and-browser.md) |

The reports' inventories contain several hundred capability rows, most rated *covered* or *later*. Consult them when designing any subsystem; they cite Emacs source lines and manual nodes.

## Owner decisions taken during the audit

1. **Buffer positions are 1-based**, as in Emacs, because positions are human-facing and counting from 1 is the better design for them, not merely for porting. → [ADR 6](../../adr/0006-buffers-nodes-and-text-store.md)
2. **Ordinary browser tabs are a first-class client** (remote development). Keys the browser reserves (`C-w`, `C-n`, `C-t`) are simply unavailable there; bindings are customizable and Tuna does not need to mimic Emacs keys exactly. No special launch mode is required. → [ADR 7](../../adr/0007-rendering-and-transport.md)
3. **No fixed-width cell grid.** Buffers must be able to mix monospace and proportional text, even within one buffer. Layout belongs to the browser; how screen-relative commands learn layout facts (event-attached facts, measurement requests, Rocket components doing local-only work such as scrolling and wrapping) is an open research item. → [ADR 7](../../adr/0007-rendering-and-transport.md)
4. Datastar documentation is vendored in [`agents/reference/datastar/`](../../reference/datastar/).

## Corner risks and their resolution

| # | Finding (lanes) | Resolution |
|---|---|---|
| 1 | `C-g` queued behind a runaway command can never interrupt it (1–5) | Quit lane at receipt + `thread-interrupt!` raising `quit`; thread-scoped `inhibit-quit` — [ADR 3](../../adr/0003-command-loop-and-jobs.md) |
| 2 | No dynamic (`let`-style) binding of settings; `current-buffer`/match data shared across suspended commands (1–4) | Dynamic layer on Gerbil parameters at the top of an open scope chain — [ADR 9](../../adr/0009-settings-and-scoped-values.md) |
| 3 | Point on the buffer, so no per-window cursors (2, 4, 5) | Text / Buffer / View split; point and scroll live on views — [ADR 6](../../adr/0006-buffers-nodes-and-text-store.md) |
| 4 | No propertized strings; properties/overlays undefined; decoration changes invalidate jobs (2, 4) | Styled text as the exchange value; overlays defined; separate text and decoration revisions — [ADR 6](../../adr/0006-buffers-nodes-and-text-store.md), [ADR 4](../../adr/0004-state-ownership.md) |
| 5 | Positions undefined in multi-node buffers (2, 4) | `(node, position)` primitive plus a buffer-level linear order; implementation deferred — [ADR 6](../../adr/0006-buffers-nodes-and-text-store.md) |
| 6 | Server cannot know layout (2, 4, 5) | Browser owns layout; layout-facts mechanism is an open research item; no cell-grid assumption — [ADR 7](../../adr/0007-rendering-and-transport.md) |
| 7 | Browser-reserved keys (1, 5) | Best-effort capture; tabs first-class; remap unreachable keys — [ADR 7](../../adr/0007-rendering-and-transport.md) |
| 8 | Unauthenticated command endpoint = code execution via CSRF/DNS rebinding (5) | Token, Host/Origin checks, loopback default — [ADR 10](../../adr/0010-security-clients-and-trust.md) |
| 9 | IME, dead keys, mobile, screen readers need a focused editable element (1, 5) | Hidden input proxy allowed; buffer text never browser-edited — [ADR 7](../../adr/0007-rendering-and-transport.md) |
| 10 | Command-loop state homeless; keymap layering, hooks, macros, prefix args unspecified (1, 4) | Input sessions, activation context, keymap stack, hook set — [ADR 8](../../adr/0008-input-keymaps-and-command-composition.md) |
| 11 | Reverse-order receipts break overlapping slot-like effects (1) | Owner-tagged entries; inverse removes only the owner's entry — [ADR 2](../../adr/0002-plugins-contexts-and-services.md) |
| 12 | Advice limited to commands and services (3) | Advice on any export of a `separate` module, full combinator set — [ADR 1](../../adr/0001-language-and-extension-surface.md), [ADR 2](../../adr/0002-plugins-contexts-and-services.md) |
| 13 | No suspendable non-interactive work; revision-only job validity starves highlighting and drops streams (2, 4) | Tasks; job validity policies with rebasing — [ADR 3](../../adr/0003-command-loop-and-jobs.md) |
| 14 | Several suspended commands resuming out of order corrupt restored state (1) | Input-target stack answered innermost-first; let-style state in thread parameters — [ADR 3](../../adr/0003-command-loop-and-jobs.md) |
| 15 | No seam for remote files / processes (TRAMP) (3, 4) | Path-dispatched file-system and process services — [ADR 5](../../adr/0005-persistence.md), [ADR 2](../../adr/0002-plugins-contexts-and-services.md) |
| 16 | Invalid UTF-8 cannot round-trip; Gambit rejects surrogate code points (3) | Reserved code points for raw bytes; coding/EOL/BOM recorded — [ADR 5](../../adr/0005-persistence.md) |
| 17 | Reload strands plugin `defclass` state (3, 5) | Reload round-trips state through session slots — [ADR 2](../../adr/0002-plugins-contexts-and-services.md) |
| 18 | No manifest, so no M-x/help/autoload for inactive plugins (3, 5) | Generated static manifest and autoload stubs — [ADR 2](../../adr/0002-plugins-contexts-and-services.md) |
| 19 | Events lack client identity, sequence, and screen revision (1, 5) | Event identity fields — [ADR 7](../../adr/0007-rendering-and-transport.md), [ADR 10](../../adr/0010-security-clients-and-trust.md) |
| 20 | "Frame" means a rendered drawing in Tuna but a top-level window in Emacs (1, 5) | Rendered output renamed **screen**; **frame** reserved for the Emacs meaning — overview and ADRs |
| 21 | Process output floods the queue (4) | Per-process coalescing with a bound — [ADR 3](../../adr/0003-command-loop-and-jobs.md) |
| 22 | Window display protocol unspecified (2, 4) | Window contract with `display-buffer` and window configurations — [ADR 11](../../adr/0011-window-management-is-a-plugin.md) |

## Not adopted, or deferred

- Fixed-width cell-grid layout (lanes 2, 5): rejected by the owner.
- Native app shell as the primary launch mode (lane 5): not required; ordinary tabs are first-class.
- Font-lock results as a cache instead of buffer properties (lane 2 D3): plausible, decide when highlighting is built.
- Resumable debugger, plumber service, moldable multi-view node kinds, selection-first command layer: good ideas with no architectural blocker; listed as candidate divergences in [`docs/emacs-equivalents.md`](../../../docs/emacs-equivalents.md).
- CRDT/OT collaboration, sandboxed or out-of-process plugins: non-goals for now (Xi retrospective); nothing in the ADRs precludes them.
