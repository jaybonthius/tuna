# Research corpus

Prior research collected from earlier Tuna, Weevil, and workbench efforts. Everything here is **historical evidence, not a decision**. Current decisions live in [`../adr/`](../adr/). When a document conflicts with an ADR, the ADR wins; when it conflicts with current Gerbil source, the source wins.

Most documents were written by agents against earlier Gerbil (v0.18/early v0.19) or Racket toolchains. Re-check version-sensitive claims and never transfer benchmark numbers across languages, machines, or architectures.

## Start here

| Topic | Read first |
|---|---|
| What Tuna must eventually support, and which decisions changed because of it | [`capability-audit/README.md`](capability-audit/README.md) |
| What earlier attempts tried and why they stalled | [`editor-corpus/prior-attempts-audit.md`](editor-corpus/prior-attempts-audit.md) |
| Open editor-model questions | [`editor-corpus/research-gaps.md`](editor-corpus/research-gaps.md) |
| How Emacs extensibility actually works | [`live-extensibility-racket/research/emacs-extension-architecture.md`](live-extensibility-racket/research/emacs-extension-architecture.md) |
| Emacs command loop | [`editor-corpus/prior-art/workbench-gerbil/research/emacs-command-loop-runtime-architecture.md`](editor-corpus/prior-art/workbench-gerbil/research/emacs-command-loop-runtime-architecture.md), [`editor-corpus/prior-art/tuna/docs/research/emacs-command-loop.md`](editor-corpus/prior-art/tuna/docs/research/emacs-command-loop.md) |
| Emacs state scopes and recovery | [`tuna-gerbil-2026-10/tuna-app-state/emacs-state-and-recovery.md`](tuna-gerbil-2026-10/tuna-app-state/emacs-state-and-recovery.md), [`editor-corpus/prior-art/workbench-gerbil/research/emacs-host-neutral-state-model.md`](editor-corpus/prior-art/workbench-gerbil/research/emacs-host-neutral-state-model.md) |
| Text storage: gap buffer vs. rope vs. SumTree | [`editor-corpus/prior-art/weevil/plans/archive/buffer-data-structure-research.md`](editor-corpus/prior-art/weevil/plans/archive/buffer-data-structure-research.md), [`editor-corpus/prior-art/tuna/docs/research/gap-buffer-benchmark.md`](editor-corpus/prior-art/tuna/docs/research/gap-buffer-benchmark.md), [`editor-corpus/prior-art/weevil/plans/archive/buffer-rope-benchmark-results.md`](editor-corpus/prior-art/weevil/plans/archive/buffer-rope-benchmark-results.md) |
| Structured (tree) buffers | [`tuna-gerbil-2026-10/plans/buffer-model-spec.md`](tuna-gerbil-2026-10/plans/buffer-model-spec.md) and [`tuna-gerbil-2026-10/tuna-buffer-model/`](tuna-gerbil-2026-10/tuna-buffer-model/) |
| Gerbil redefinition and `block`/`separate` | [`editor-corpus/prior-art/workbench-gerbil/research/gerbil-runtime-redefinition-architecture.md`](editor-corpus/prior-art/workbench-gerbil/research/gerbil-runtime-redefinition-architecture.md) |
| Gerbil threads and concurrency primitives | [`workbench-gerbil/gerbil-command-loop-concurrency-primitives.md`](workbench-gerbil/gerbil-command-loop-concurrency-primitives.md) |
| Datastar protocol | [`workbench-gerbil/12-current-datastar-release-and-protocol.md`](workbench-gerbil/12-current-datastar-release-and-protocol.md) |

## Directory map

| Directory | Contents |
|---|---|
| [`capability-audit/`](capability-audit/) | The 2026-10-11 audit of the ADRs against Emacs and post-Emacs needs: five lane reports and a synthesis of what changed. **Read before designing any subsystem.** |
| [`window-management/`](window-management/) | Layout-tree, Niri, and Emacs-style window research, the owner's layout notes, and reference code from Racket Tuna and Weevil. |
| [`../reference/datastar/`](../reference/datastar/) | Vendored Datastar documentation (v1.0.4, including Rocket). |

Prior-attempt material:

| Directory | Origin | Contents |
|---|---|---|
| [`editor-corpus/`](editor-corpus/) | `~/Code/workbench-racket/docs/tuna/research/` (Aug 2026) | A curated, hash-verified corpus of earlier Racket Tuna, Weevil, and workbench-gerbil research on buffers, text storage, views, command loops, keymaps, and Emacs state. Has its own [README](editor-corpus/README.md) and `SHA256SUMS`. |
| [`tuna-gerbil-2026-10/`](tuna-gerbil-2026-10/) | `../tuna-old-2026-10/` (Sep–Oct 2026) | Structured-buffer and application-state research plus the plans that grew too large to execute: buffer-model spec, app-state spec, the unfinished editor-core spec (from the stashed work), and the customization roadmap with Emacs comparisons. |
| [`workbench-gerbil/`](workbench-gerbil/) | `../research/` | Gerbil mechanisms not already in `editor-corpus/`: concurrency primitives, custom languages and config surfaces, attached REPLs, house style, static asset embedding, package/test conventions, Datastar protocol and SSE fan-out/disconnect behavior, extensible web seams. |
| [`live-extensibility-racket/`](live-extensibility-racket/) | `~/Code/workbench-racket/plans/tuna-live-extensibility/` and `tuna-racket/docs/adr/` | Plugin/extension research: Emacs extension mechanisms, a package use-case matrix, control-surface inventory, architecture options, and the Racket port's ADRs on live registries and package topology. The 200 KB lifecycle model and spike reviews were deliberately not copied. |
| [`weevil/`](weevil/) | `~/Code/weevil/` | Architecture and extension guide of the most complete earlier editor (Racket). |
| [`owner-notes/`](owner-notes/) | `~/Code/tuna/docs/notes/jays-thoughts/`, `~/Code/weevil/TODO.org` | The owner's own notes on layout, state, window topology, cursor and keybinding behavior. |
| [`emacs-web/`](emacs-web/) | `~/Code/emacs-web/docs/research/` | Feasibility research on rendering stock Emacs into a browser. |

## Not copied, but useful

- GNU Emacs source: `/home/jay/Code/emacs` (see the `emacs-reference` skill).
- Gerbil v0.19 source and docs: `/home/jay/Code/workbench-gerbil/gerbil`.
- `gerbil-emacs` (gemacs), an Emacs clone in Gerbil by Jaime Fournier with ~1,000 commands on Scintilla/Qt: `/home/jay/Code/workbench-gerbil/gerbil-emacs`. Useful as a command-behavior reference, not as an architecture.
- Weevil source (rope, panes, terminals, completion): `/home/jay/Code/weevil`.
- Datastar source and docs: `/home/jay/Code/datastar/datastar` (July 2025 checkout); community Q&A export: `/home/jay/Code/datastar-discord-export`.
- The previous Gerbil Tuna checkout, including its branches and `stash@{0}` buffer work: `/home/jay/Code/workbench-gerbil/tuna-old-2026-10`.
- Cordis (plugin contexts with revertible effects): <https://github.com/cordiverse/cordis>, paper <https://arxiv.org/abs/2608.25512>.
