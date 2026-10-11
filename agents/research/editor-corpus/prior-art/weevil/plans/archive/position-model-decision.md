# Position Model Decision

## Context

Phase 1.75 introduced private UTF-8 byte-offset internals. Follow-up
review confirmed that Emacs public `point` is character-oriented and
1-based, while internals can still use byte offsets.

## Option matrix

| Option | Public `point` | Internal model | Pros | Cons |
| --- | --- | --- | --- | --- |
| A. Keep byte-based `point` | 0-based UTF-8 byte offset | Byte-only | Matches internals directly | Not Emacs-like; confusing for user commands on multibyte text |
| B. Character `point`, 0-based | 0-based character index | Byte-only | Human-readable unit | Still non-Emacs; awkward beginning-of-buffer semantics |
| C. Character `point`, 1-based + explicit `point-byte` | 1-based character position (`1` at BOB, `N+1` after `N` chars) | Byte-canonical with derived char positions | Emacs-compatible public API; clear high-level vs low-level access | Requires conversion at API boundary |
| D. Track char+byte internally now | 1-based character position | Dual char+byte fields | Closest to Emacs C internals; faster repeated conversions | More invariants and drift risk before markers/selections justify it |
| E. Revert/rewrite Phase 1.75 | TBD | TBD | Removes accidental public byte API entirely | Throws away useful tree-sitter/render/storage foundation |

## Recommendation (approved)

Adopt **Option C**.

- Keep private core/editor/render/storage positions canonical as UTF-8
  byte offsets.
- Make public `point` Emacs-like and character-oriented (1-based).
- Make public `point-char` explicit character accessor with the same
  1-based semantics as `point`.
- Keep public `point-byte` as explicit low-level UTF-8 byte offset
  accessor (0-based).

## Rationale

This keeps internal invariants aligned with tree-sitter and storage
needs while presenting user-facing behavior that matches Emacs and avoids
byte/character confusion in extension code.

Do not add dual char+byte internal tracking yet. Revisit it when markers,
selection ranges, line/column movement, or benchmarks show conversion cost
or invariant complexity justifies storing both coordinates.
