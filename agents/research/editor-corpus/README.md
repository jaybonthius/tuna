# Tuna editor research

This directory collects prior editor/buffer work and records what Tuna still
needs to investigate before choosing an editing architecture.

Start here:

1. [`working-model.md`](working-model.md) — the provisional product direction
   used as the research lens.
2. [`prior-attempts-audit.md`](prior-attempts-audit.md) — what the old
   implementations established, where they conflicted, and how they grew out of
   control.
3. [`research-gaps.md`](research-gaps.md) — prioritized missing research,
   especially GNU Emacs buffer behavior.
4. [`prior-art/`](prior-art/) — verbatim source documents retained for direct
   inspection.

The working model and audits are not Architecture Decision Records (ADRs). They
are intended to keep later design work evidence-based without freezing an API or
representation prematurely.

## Provisional direction

Tuna's core should remain an unopinionated, live-configurable Lisp runtime. It
holds opaque authoritative state, applies configured commands, and invokes
configured rendering; installed packages and trusted user configuration define
what the state means.

Current editor exploration treats the complete editor state as a literal tree
of composable Racket values. Package-defined layout trees may contain
package-defined document trees. Concrete node fields and children express the
state directly; buffer, view, pane, mode, cursor, and text-store ownership are
not core assumptions. Text storage implementations such as gap buffers and
ropes should remain replaceable package choices.

See [`working-model.md`](working-model.md) for the current scope and open
questions.

## Curated prior art

### Tuna Racket attempt

Root: [`prior-art/tuna/`](prior-art/tuna/)

High-value material:

- current-at-capture architecture and roadmap;
- the accepted runtime-owned mutable text decision;
- exact UTF-8 gap-buffer semantics, integration contract, and benchmark;
- an earlier persistent-rope/piece-tree recommendation;
- Emacs command-loop, keymap-context, and file-lifecycle research;
- the buffer/view/layout-leaf rendering investigation.

These documents are intentionally contradictory in places. In particular,
`persistent-text-storage.md` favored a persistent summary rope, while the later
implemented Tuna slice selected a mutable gap buffer with cached immutable
snapshots and reversal journals. Both are retained because the new
`tuna-racket` architecture has not yet established which trade-off applies.

The earlier, unmerged generic SumTree implementation survived only in Git stash
parents. Its plan, accepted-at-the-time ADR, benchmark report, raw benchmark
artifact, validator/runner sources, and performance summary are preserved
separately under
[`prior-art/tuna-stashed-sum-tree/`](prior-art/tuna-stashed-sum-tree/).
The benchmark-attested plan blob is retained at its original path; a later
working revision is named `sum-tree-buffer-plan-later-working-revision.md` so
the two contracts cannot be confused.

### Workbench Gerbil attempt

Root: [`prior-art/workbench-gerbil/`](prior-art/workbench-gerbil/)

High-value material:

- Emacs state scopes, revisions, undo, hooks, and redisplay lessons;
- a Racket Emacsen runtime boundary;
- server-owned web application/rendering constraints;
- one explicit recursive diagnostic tree UI;
- detailed Emacs/browser key-resolution and input context research.

This body establishes reusable runtime and rendering constraints, but it did not
implement editor buffers or editable UI-tree leaves. Direct and transitive
`research/*.md` dependencies of the curated Workbench-Gerbil documents are also
retained so their evidence chains can be inspected locally.

### Weevil family

Root: [`prior-art/weevil/`](prior-art/weevil/)

High-value material:

- string/gap-buffer/piece-tree/rope comparison;
- a working augmented persistent Racket rope and benchmark decision;
- buffer/text/view/marker ownership models;
- display-projection and server-rendered line/cursor work;
- focus, mode, and position research;
- architecture and simplicity reviews documenting actual overgrowth.

`/home/jay/Code/weevil` is the canonical source used here. `weevil_lima` had the
same tracked Git tree at capture. The old `weevil-live-reload`,
`weevil-niri-layout`, and `weevil-terminal` worktree snapshots contain many
byte-identical copies plus branch-specific experiments; those duplicates were
not copied.

## Provenance

The copied directory suffix mirrors its source suffix:

| Copied root | Original root | Source state at capture |
|---|---|---|
| `prior-art/tuna/` | `/home/jay/Code/tuna/` | HEAD `9c8f2977f11fd338f4c6a5c072919188b12c52a9`; four copied architecture/text documents had pre-existing unstaged changes |
| `prior-art/tuna-stashed-sum-tree/` | `/home/jay/Code/tuna/` Git objects and ignored benchmark artifact | attested plan blob `4ebf2042abe42894cc8980a7d6e0df5c2c40b3d9`; later plan from `fca1b23`; ADR/runner/docs from `15ec8bd`; raw artifact SHA-256 `d376a07c…` |
| `prior-art/workbench-gerbil/` | `/home/jay/Code/workbench-gerbil/` | HEAD `6b22b3508a9675868aab9056b65fd88ceaa056b1`; the copied research files were untracked working-tree documents |
| `prior-art/weevil/` | `/home/jay/Code/weevil/` | clean HEAD `093b09d26931898417bcd5d3a5909cbdc53b399e` |

Every copied file is byte-for-byte identical to its source at capture.
[`prior-art/SHA256SUMS`](prior-art/SHA256SUMS) records content hashes. Because
some sources were unstaged or untracked, the hashes—not only Git commits—are the
reproducible provenance boundary.

## Material inspected but not copied

- `/home/jay/Code/tunaverse/`: no relevant research; its `sumtree/` directory
  was empty and its README referenced an absent Tuna checkout.
- `/home/jay/Code/workbench-gerbil/tuna-racket-spike/`: runtime
  redefinition/configuration experiment only; no buffer or UI-tree work.
- Weevil sibling snapshots: mostly duplicate research; canonical copies came
  from `/home/jay/Code/weevil`.
- old SQLite/Deta Tuna plans and earlier duplicated layout sketches: superseded
  and likely to mislead this research.
- generated Emacs API CSV files and subagent transcripts: too broad/noisy for the
  curated corpus; the API-catalog methodology and analysis are retained.

## How to use this corpus

- Treat copied files as historical evidence, not current Tuna decisions.
- Prefer current `tuna-racket` code and accepted ADRs for existing kernel
  behavior.
- Do not promote historical buffer, view, pane, mode, cursor, or storage
  vocabularies into Tuna core; packages may introduce them when their own
  behavior requires them.
- Re-run performance work against Tuna's real edit/render path; old machine
  numbers show scaling and trade-offs, not portable latency promises.
- Research a missing semantic family before designing an API around an analogy
  to Emacs, Weevil, or the old Tuna implementation.
