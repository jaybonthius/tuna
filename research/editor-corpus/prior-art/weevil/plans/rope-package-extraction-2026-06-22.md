# Extracting the rope/SumTree into a standalone `rope` package

Status: **DONE** (2026-06-22). The augmented persistent rope was pulled out of
weevil into a standalone, weevil-agnostic Racket package, shrinking weevil's
core. This doc records the final design and outcome.

## Why

`weevil/private/core/rope.rkt` was already self-contained (only `racket/list` +
`racket/vector`, no weevil deps) with a single production consumer
(`buffer-model-rope.rkt`). The data structure is general-purpose, so it belongs
in its own package rather than buried in the editor core.

## Scope decision: a specialized text rope, NOT a generic SumTree

Zed ships two crates — `sum_tree` (generic `SumTree<T: Item>`) and `rope` (a
`SumTree<Chunk>` with a concrete `TextSummary`). That split is free in Rust
because generics are monomorphized at compile time. Racket CS has no such
guarantee: a generic summary (via `gen:` or threaded closures) would add an
indirect call on every hot-path conversion, and every byte↔char↔utf16↔line
lookup funnels through the seek engine. The repo's prior research already
rejected the generic route for this reason.

So we extracted the **specialized text rope** with its concrete summary monoid
(utf8 bytes / codepoints / utf16 units / LF newlines / utf16 width after the
last newline). A generic SumTree layer is an explicit non-goal.

## Package: `rope`

Single-package layout (the data structure is one source module), colocated in
the weevil repo for now like `weevil-terminal`, linked via `raco pkg`. MIT.

```
rope/
├── info.rkt              ; collection "rope", deps '("base"), MIT
├── LICENSE  README.md
├── main.rkt              ; public, contracted API (re-exports from private)
├── private/rope.rkt      ; full implementation, raw provides (monoid/structs incl.)
└── tests/rope-test.rkt   ; differential-vs-oracle + invariant fuzz suite (ROPE_FUZZ gate)
```

The implementation stays raw/uncontracted in `private/`; `main.rkt` applies the
public contracts once via `contract-out`. There is **no** unsafe/raw second
variant — one contracted public module is the whole API.

## Public API

The rope is an immutable, persistent, summary-augmented B+-tree of bounded UTF-8
string chunks. Canonical position is the **UTF-8 byte offset**; only **LF** is a
line break; **columns are UTF-16 code units**. Edits return a new rope and share
untouched structure, so retaining an old value is an O(1) snapshot.

A cursor coordinate is a first-class value (mirrors Zed `Point` / VS Code
`Position`; deliberately not named `point`, which means the cursor byte offset in
Emacs/weevil):

```racket
(struct position (line column) #:transparent)   ; column in UTF-16 code units
```

`contract-out` surface:

- predicates / coordinate: `rope?`, `position?`, `position`, `position-line`,
  `position-column`
- construct / materialize: `string->rope`, `rope->string`, `rope-slice`
- metrics (O(1)): `rope-byte-length`, `rope-char-length`, `rope-utf16-length`,
  `rope-line-count`
- conversions (O(log n)): `rope-byte->char`, `rope-char->byte`, `rope-byte->line`,
  `rope-char->line`, `rope-line-start-byte`, `rope-line-start-char`,
  `rope-byte->position`, `rope-position->byte`
- edits (persistent): `rope-insert`, `rope-delete`
- validation: `rope-valid-byte-offset?`, `rope-check-invariants`

The summary monoid and node structs (`summary`/`leaf`/`branch`) are **not**
public — they live in `private/rope.rkt` and are reached only by the package's
own test.

### Naming notes
- The old fused names `rope-byte->line/utf16-column` and
  `rope-line/utf16-column->byte` were replaced by `rope-byte->position` /
  `rope-position->byte`. In Racket `/` reads as "with"/a variant tag
  (`call/cc`, `for/list`, `/c`), not "and", so the slashed names were
  misleading.
- Columns are always UTF-16 here, so the `utf16` qualifier was dropped from the
  coordinate names (lengths keep it because they come in three units).
- `rope-byte->line` was added for symmetry with `rope-char->line`.

## weevil migration (completed)

- `buffer-model-rope.rkt` now `(require rope ...)` and uses the position API
  (`rope-byte->position` → `position-line`/`position-column`,
  `rope-position->byte` ← `(position line column)`, and `rope-byte->line` for the
  beginning/end-of-line helpers). The public `buffer-model-*` surface and
  signatures are unchanged — the rename is internal to the adapter.
- `"rope"` added to `weevil/info.rkt` deps (a real core→rope dependency, unlike
  the terminal plugin); package linked with `raco pkg install --link ./rope`.
- `weevil/private/core/rope.rkt` and `weevil/tests/rope-test.rkt` deleted
  (extracted, not copied); no dangling references remain.

## Validation

- `rope` package suite: 20,980 tests pass (smoke). `ROPE_FUZZ=1` un-gates the
  full exhaustive fuzz.
- full weevil suite (`raco test -j 8 weevil/tests weevil-terminal/tests`): 3,004
  tests pass. The buffer-model differential test now exercises the published
  package end-to-end against the string oracle.
- review pass: no blocking/should-fix; renames, contracts, `rope-byte->line`,
  and behavior verified; no weevil leakage in the package.

## Possible follow-ups (not done)

- Move `rope` to its own git repo / publish to the package catalog.
- Add Scribble docs.
</content>
