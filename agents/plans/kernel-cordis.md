# Plan: align the kernel with Cordis

Owner-approved brief: [`docs/briefs/2026-10-kernel-cordis.md`](../../docs/briefs/2026-10-kernel-cordis.md) (2026-10-14). Evidence: [`agents/research/cordis-alignment/README.md`](../research/cordis-alignment/README.md) (the Cordis paper, arXiv 2608.25512 v1, and source at `a71c658`; divergences D1–D12).

## Invariants (every stage)

- This effort changes the kernel on purpose. Each kernel change is named in the stage report with its line delta, and ADR 12's kernel contract is amended in the same merge; nothing outside the brief enters the kernel.
- No compatibility: removed mechanisms (handover, adapters, provider priority) are deleted with every caller and test updated in the same change; no forwarders or fallbacks (AGENTS.md).
- Boundaries (AGENTS.md "Keep boundaries clean") and `make test` green; each stage checked in a real browser on an isolated run (temporary `XDG_*` directories), with screenshots.
- Emacs facilities stay first-class; interactive evaluation behaves as in Emacs (brief, "Emacs facilities stay first-class").
- Implementation by `openai-codex/gpt-6.1-sol` in its own worktree per stage; review, browser check, and merge by the primary agent.

## Stages

1. **Declared use, ties, command ownership** (no change to swapping yet).
   - Declared use (D7): `service-provider` and the contract dispatchers check that the calling owner (the task's plugin, or the activating context) declared the service; a violation is an error naming the plugin and the service. Plugins declare optional services explicitly (replacing today's comment blocks); code with no plugin owner stays unchecked. Every plugin's `requires:` and optional list is made exact.
   - Ties (D6): entry tables break equal priority by an order the activator supplies (boot passes each declaration's position in `init.ss`), never by registration time; a reload then equals a fresh start (test: reload the older of two equal-priority bindings; the winner does not change).
   - Command ownership (D4): a task started for a command is owned by the command's plugin context and is cancelled by its receipt (test: a command waiting at `read-string` is quit when its plugin turns off).
   - Same name replaces (Emacs `add-hook` idempotence): registering under the same owner and name replaces the earlier registration, for hook callbacks (today `add-hook-callback!` duplicates) and every other named registration (commands, key bindings, entries). Test: registering twice leaves one.
   - Late lookup: a hook callback given as a named module-level function refers to the binding, not the value captured at registration, so redefining it takes effect at once. Test: redefine the function (with `(declare (separate))`, ADR 1) and the hook runs the new definition.
2. **One provider; swap is restart plus restore** (D1, D2, D3).
   - One provider per service: a second `context-provide!` raises, naming both plugins. Delete provider `priority:`, `withdraw-provider!` hand-back, `hand-over!`, `handover:` on services, `context-adapt!`, adapters and stranded-adapter bookkeeping; dependents of a changed provider restart (deactivation closure, then activation).
   - Swap path (one path for swap, reload and restart, outside the kernel, in the start-up/reload code): capture the saved data of the plugins in the closure from the session store, turn the closure off, turn the new provider and dependents on, restore. Failures turn the old version back on, as reload does today.
   - Neutral saved forms in the layout and buffers contracts so another provider can restore a different provider's data (layout: views by buffer name and node id, selected view, frame marks; buffers: buffers, texts and points via autosave as today). A provider restores its own slot when it has one, the neutral one otherwise.
   - Start-up-only services become reload policy (deferred, as `boot.ss` already does) instead of `check-live-change!` in the kernel.
   - Tests and the demo select doubles by configuration instead of outranking (`priority: 10` in `tuna/test-support/`); the demo's swap commands (`C-c w`, `C-c B`, `C-c v`, `C-c s`) use the swap path.
3. **The session owner** (interactive evaluation): one always-on owner, exempt from declared-use checks, under which interactive evaluation runs; untouched by `reload-config`. Provide the minimal entry point (evaluate a form or a buffer's forms as the session owner) and test, as in Emacs, that a key bound that way persists across `reload-config`, that re-evaluating unchanged code changes nothing (same name replaces), and that a changed binding adds the new key while the old one stays. The user-facing commands (`eval-buffer`, `M-:`) may come with the REPL work if they need editor support not yet built.
4. **Record** (primary agent): amend ADRs 2, 3, 4, 5, 11, 12 (and 13 where handover appears) with each kept divergence (D3, D4, D5, D8, D9, D10, D11, D12) and its reason, the slot rule for state, and the session owner; update `docs/overview.md`, `docs/emacs-equivalents.md`, `TODO.md`.

After this plan: rewrite the parked package-layout brief on this foundation (one concept, one package owning its contract and default; our plugins get no special access).

## Not in this plan

Kernel enforcement of optional dependencies beyond the declared list; per-plugin config update in place (Cordis `internal/update`; add only when a plugin needs it); labels on receipts; the evaluation commands' editor UI; help showing where a function was defined.
