# Plan: kernel cleanup

Owner-approved contract: ADR 12's "Kernel contract" section ([`agents/adr/0012-kernel-boundary-and-replaceability.md`](../adr/0012-kernel-boundary-and-replaceability.md)) and [`docs/briefs/2026-10-kernel-contract.md`](../../docs/briefs/2026-10-kernel-contract.md). Evidence: [`agents/research/kernel-audit-2026-10-12.md`](../research/kernel-audit-2026-10-12.md) and [`agents/research/kernel-contract/`](../research/kernel-contract/) (lane 3 gives per-export verdicts). Behavior must not change: every existing test keeps passing, adjusted only for moved names.

## Steps

Each step is a separate implementer task in its own worktree (AGENTS.md), merged only after the primary agent reads the whole diff for placement and a fresh read-only reviewer checks it against ADR 12. Each task brief names the layer that owns every moved piece.

1. **Mechanical checks first.** Add to `make test`: a search of non-test `tuna/kernel/*.ss` and `tuna/kernel.ss` for the forbidden nouns in ADR 12 (with an explicit, short allow-list for unavoidable words in comments), and a check that the kernel imports nothing from `tuna/services/` or `tuna/plugins/`. They will fail until the later steps land; commit them marked as expected failures or land them with step 7.
2. **Opaque input.** Replace `key-event` in `kernel/loop.ss` with opaque items wrapped in a private queue struct. `Input` gets `arrival` (queue or interrupt, replaces `quit-event?`) and `resolve!`. Move `key-event` and the browser fields to `tuna/services/keys.ss`; the web plugin builds it; the keys plugin interprets it. Remove `discard-input` until a caller exists.
3. **Commands out.** Move `command`, `define-command`, `defcommand`, `command-ref`, `command-entry` and the `commands` kernel field to the input contract and keys plugin. `Input-resolve!` returns a name and a thunk to run as a task. `current-command-name` stays generic (task name).
4. **Hooks owned by hook objects.** Hook objects hold their callbacks; delete the kernel's `hooks` field. Add the kernel's lifecycle hooks (plugin activated, plugin deactivated, service changed, task started, task finished). Keep failing callbacks removed and reported.
5. **Libraries.** Create `tuna/lib/`. Move timers there. Move jobs there (keying, coalescing, owner cancellation, cleared dynamic environment); the kernel keeps `result-poster`. Delete the `jobs` kernel field. Validity policies become the target's knowledge: `span`, `rebase-spans`, and text `change` records move to the buffers contract; the job library calls a target method such as `job-rebase`.
6. **Session slots out.** Move `slots.ss` and the `slots` field next to the session contract.
7. **Kernel object private.** Stop exporting `kernel`, `new-kernel`, `current-kernel` from `tuna/kernel.ss`; the web plugin receives an input-submitter closure (as jobs use `result-poster`); tests use a test-only facade. List `tuna/kernel.ss` exports explicitly. Delete exports with no caller (`revision-counter` and friends, `active-plugin-names`, others found by a dead-export search). Move test aids (`kernel/test-fixtures.ss`, `plugins/test-keys.ss`) to a test-support directory.
8. **Failure reporting.** Kernel failures go to stderr and a kernel hook; the `Messages` seam stays as the only consumed UI-ish service, with nothing added to it.
9. **Update docs:** ADR 2/3/8 references where names moved; `docs/overview.md` and `docs/diagrams/kernel-layers.svg` status to built; `docs/emacs-equivalents.md` if any concept changed.

## Not in this plan (separate briefs first)

- Making buffers really replaceable: behavior out of `services/buffers.ss` into the buffers plugin, plus a toy second buffers provider (audit P1-1).
- Taking the demo out of the default startup and moving `describe-services` into a help plugin (audit P2-4); `join-runs` into the renderer contract (P2-3); boot not hard-coding the web transport (P2-5); file helpers out of `services/session.ss` (P2-7).
- Hooks-and-advice milestone and the profiler (see `agents/STATUS.md`).
