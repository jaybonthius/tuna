# Weevil architecture review — 2026-06-19

This directory is a current architecture map and design review of Weevil. It is based on:

- direct source review of `weevil/`, `tests/`, `docs/`, `ADR.md`, `TODO.org`, and `emacs-research/`
- five focused subagent review passes under `subagents/`
- cross-checks against the existing `plans/review-2026-06/` snapshot, which has since been partly implemented

## Start here

1. `architecture.md` — concise map of the current application architecture and invariants.
2. `recommendations.md` — prioritized design/architecture changes I recommend.
3. `emacs-comparison.md` — how Weevil currently aligns with and diverges from Emacs.
4. `implementation-plans/` — phased plans for the recommended changes.
5. `diagrams/*.drawio` — editable draw.io diagrams.
6. `subagents/*.md` — detailed evidence notes by subsystem.

## Diagram index

- `diagrams/weevil-system-overview.drawio` — whole application at a glance.
- `diagrams/weevil-input-render-flow.drawio` — key/input through command loop to SSE render.
- `diagrams/weevil-state-object-model.drawio` — session, frame, pane, buffer, marker, rope model.
- `diagrams/weevil-terminal-subsystem.drawio` — terminal lifecycle, PTY/engine boundary, CQRS integration.

## Headline verdict

The load-bearing design is strong: server-owned editor state, a single serialized writer, immutable state transitions, a public/private extension boundary, a real buffer storage seam, and a carefully isolated terminal subsystem. This is not a rewrite situation.

The main risks are *foundational gaps before growth*: command metadata/interactive arguments, buffer-local variables, live marker adjustment, render/client JS consolidation, backpressure, and future per-session isolation.

## Later refinement

After this review, the owner clarified the target as a small performant kernel with optional bundled/plugin behavior. See `../kernel-plugin-roadmap-2026-06-19/` for the updated roadmap and boundary plan. That roadmap should be read before implementing the older `implementation-plans/` here.
