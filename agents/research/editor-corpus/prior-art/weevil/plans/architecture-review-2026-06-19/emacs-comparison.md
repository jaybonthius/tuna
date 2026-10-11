# Weevil vs Emacs architecture comparison

Weevil is intentionally Emacs-like in extension vocabulary and command-loop semantics, but not a clone. This compares the parts that matter architecturally.

| Emacs concept | Weevil current state | Assessment |
|---|---|---|
| Command loop | Every key goes through one Racket event loop and command dispatch | Strong alignment |
| Self-insert as command | Printable fallback dispatches to commands | Strong alignment |
| Buffers vs windows | Buffer content separated from pane point/mark/scroll | Strong alignment conceptually; only one visible pane today |
| Frames/window tree | `frame-state` is currently a leaf pane | Target exists; split tree not implemented |
| Minibuffer | Real minibuffer buffer+pane with context stack | Strong alignment |
| Keymaps | parent maps, prefix maps, remapping, minor/major/global precedence | Strong alignment; naming docs need cleanup |
| Hooks | generic hook registry plus pre/post-command hooks | Good base; lifecycle/save/change hooks missing |
| Modes | major/minor registries with keymaps | Thin; lacks setup/teardown/hooks/auto-mode/minor toggles |
| Options/custom vars | contract-checked global options | Good base; buffer-local variables absent |
| Markers | marker structs exist but do not track edits | Biggest semantic gap |
| Regions/kill-ring | not present as public vocabulary | Important missing editor primitive |
| Faces/themes | `faces.rkt` is empty | Public surface absent |
| Redisplay | full-app Datastar morph from server-rendered state | Correct for Weevil's current architecture; less incremental than Emacs redisplay |
| Extension stability | public/private modules and unsafe hatch | Good; needs API version/deprecation policy |
| Async jobs | file/terminal workers post results to command loop | Good; keep state mutation centralized |
| Terminal | real PTY/libghostty subsystem | Beyond original ADR; design is solid and should be documented as in-scope |

## Where Weevil is already better-shaped than many editor experiments

- It does not let browser DOM become source of truth.
- It routes all editor-affecting inputs through one serialized mutation point.
- Defaults are registered through public APIs, which keeps extension seams honest.
- It has an actual buffer storage contract and rope implementation rather than leaking strings everywhere.
- Terminal state uses snapshots plus a live-controller side table, preserving pure session-state semantics.

## Emacs lessons to adopt next

1. **Stable command metadata early.** Emacs packages rely heavily on discoverable interactive commands and documentation.
2. **Buffer-local state is foundational.** Modes, options, faces, and display behavior all need local overrides.
3. **Markers must track edits.** Emacs marker insertion type is not optional if overlays, regions, diagnostics, and multi-window editing are goals.
4. **Mode lifecycle conventions matter.** Setup hooks and enable/disable semantics are how extension code composes.
5. **Redisplay should stay centralized.** If Weevil becomes incremental, it should still flow through structured state/change metadata, not random DOM patch endpoints.

## Important difference to preserve

Weevil's browser is only an input/render surface. Do not drift toward a client-side editor model unless you intentionally abandon the current architecture. The server-owned CQRS model is a coherent design and currently implemented well.
