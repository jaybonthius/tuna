# Text-Editing Motion + Word Deletion Plan (Emacs-faithful, no kill ring)

Status: proposed
Date: 2026-06-15
Scope: add buffer TEXT-EDITING MOTION (line + word) and a single simple word
DELETION command to the Weevil editor, modeled on Emacs's motion-function /
command split, with a clean public API. The owner-requested surface is exactly:
`C-a`→beginning-of-line, `C-e`→end-of-line, `M-ArrowLeft`→backward-word,
`M-ArrowRight`→forward-word, `M-Backspace`→delete-the-previous-word — PLUS the
canonical Emacs word-motion aliases `M-f`→forward-word / `M-b`→backward-word.
This is research option **(b)**: `M-Backspace` is a PLAIN DELETE (recoverable
only by a future undo, NOT by yank). **HARD CONSTRAINT: NO kill ring, NO yank,
NO kill-region, NO mark/region, NO `C-k`/`C-w`/`C-y`.** The delete command is
named honestly as a DELETE (`backward-delete-word`), never `backward-kill-word`.
All scanning is codepoint-aware (UTF-8). All motion clamps to the existing
`buffer-state-read-only-until` lower bound, so in the minibuffer `C-a` and the
word ops stop at the prompt automatically (Weevil's single-mechanism analog of
Emacs `constrain-to-field`). The frontend already `preventDefault`s every chord
and the keymap already normalizes all six chords, so NO frontend / keymap /
config change is needed (verified).

## Goal

Add Emacs-shaped, codepoint-correct line + word motion (`move-beginning-of-line`,
`move-end-of-line`, `forward-word`, `backward-word`) and a plain
`backward-delete-word` (no kill ring) as pure motion functions on the selected
view in `session-state.rkt`, expose them as public command wrappers + bindings
(`C-a`, `C-e`, `M-ArrowLeft`, `M-ArrowRight`, `M-Backspace`, `M-f`, `M-b`), with
the word-constituent predicate as an internal default + documented syntax-table
seam — while explicitly deferring the entire kill/yank/region subsystem.

## Emacs anchors

Verified in `/tmp/weevil-research/emacs-motion-commands.md` and
`emacs-kill-delete.md` against the source tree at `/tmp/emacs-mirror-emacs`.

- **`scan_words`** (`src/syntax.c:1459`) — the word-scan engine: forward = skip
  non-word chars until a word-constituent, then skip word chars; a boundary is
  the transition. Backward mirrors it. Drives `forward-word`/`backward-word`.
- **Syntax table / `char-syntax`** (`src/syntax.c:1098`, `1074-1078`;
  `syntax.texi:160`) — word-constituent class `Sword` ('w'); letters+digits by
  default. This is the swappable classifier we model with a predicate.
- **`Fforward_word`** (`src/syntax.c:1576`) — `scan_words`, then clamp to
  `ZV`/`BEGV` on a buffer edge, then `Fconstrain_to_field` (field/prompt
  boundary). Returns nil if it stopped early.
- **`backward-word`** (`lisp/simple.el:8899`) — `(forward-word (- arg))`; `M-b`.
- **`left-word`/`right-word`** (`lisp/bindings.el:1162`/`1186`) — the real
  `M-<left>`/`M-<right>`; for LTR text reduce to `backward-word`/`forward-word`.
  (We implement LTR only — no bidi.)
- **`move-beginning-of-line`** (`lisp/simple.el:8462`) — the real `C-a`: raw bol
  ignoring fields, then `constrain-to-field` clamps to the input-field start, so
  `C-a` stops at the **end of the minibuffer prompt**.
- **`move-end-of-line`** (`lisp/simple.el:8418`) — the real `C-e`.
- **Default global bindings** (`lisp/bindings.el:1344/1345/1608/1609/1623/1625`)
  — `C-a`/`C-e`/`M-f`/`M-b`/`M-<right>`/`M-<left>`.
- **DELETE vs KILL** (`doc/lispref/text.texi:621`/`888`) — deletion removes text
  WITHOUT saving to the kill ring (recoverable only via undo); killing saves to
  the ring for yank. Emacs default `M-DEL`=`backward-kill-word` is a KILL
  (`simple.el:8955`→`kill-word`→`kill-region`). We deliberately diverge per the
  owner's no-kill-ring decision and implement option **(b)**: the word-boundary
  logic is identical to `backward-word`; the only difference is `delete-region`
  (discard) instead of save-to-ring. Name it `backward-delete-word`.

## Verified current state (re-confirmed against code)

- `weevil/private/core/position.rkt` — codepoint helpers: `char-index->byte-offset`
  (L66), `byte-offset->char-index` (L74), `previous-codepoint-boundary` (L99),
  `next-codepoint-boundary` (L108), `char-utf-8-byte-length`, `utf-8-byte-length`.
  Newlines are ordinary chars (see `byte-offset->line/utf16-column`, L118). **No
  bol/eol or word scanner exists.** `contract-out` provide block at L5-23.
- `weevil/private/core/buffer-model.rkt` — flat-string model; wrappers
  `buffer-model-previous-boundary` (L57) / `buffer-model-next-boundary` (L60),
  `buffer-model-delete` (L74, char-range), `buffer-model-byte-length`,
  `buffer-model-text`. `contract-out` block at L6-30. **No word/line wrappers.**
- `weevil/private/core/buffer-state.rkt` — `buffer-state-read-only-until` is the
  per-buffer point-min; 0 for normal buffers, prompt-end byte for the minibuffer.
- `weevil/private/core/session-state.rkt` — pure ops on the SELECTED VIEW:
  `session-state-insert` (L766), `session-state-newline` (L780),
  `session-state-backspace` (L783, clamps to read-only-until),
  `session-state-backward-char` (L796, clamps to read-only-until),
  `session-state-forward-char` (L808, clamps to byte-length),
  `session-state-delete-forward-char` (L821). All bump `rev` via the
  `state-with-current-buffer+pane` / `state-with-current-pane` helpers and return
  the SAME state (eq?-stable no-op) at a boundary. Provide list L66-72.
  `session-state-replace-minibuffer-input` (L693) shows the `buffer-model-delete`
  + `pane-state-with-collapsed-point` pattern.
- `weevil/buffer.rkt` — `contract-out` block L8-20 (`insert!`, `newline!`,
  `delete-backward-char!`, `backward-char!`, `forward-char!`,
  `delete-forward-char!`, point accessors, buffer-list, switch); thin wrappers
  call `update-state!` of a `session-state-*` fn (L22-44). **No word/line wrappers.**
- `weevil/defaults.rkt` — provide list L16-34; command defs (`backward-char-command`
  L56, `forward-char-command` L59, `delete-forward-char-command` L62);
  `global-keymap` bindings block (~L150-179) with `ArrowLeft`→backward-char,
  `ArrowRight`→forward-char, `Backspace`→delete-backward-char, `Delete`→
  delete-forward-char; `minibuffer-keymap` reparents `global-keymap` (~L181) and
  ALREADY binds `M-ArrowDown`/`M-ArrowUp`/`M-Enter` (minibuffer-specific
  completion nav). `C-a`/`C-e`/`M-ArrowLeft`/`M-ArrowRight`/`M-Backspace`/`M-f`/
  `M-b` are UNBOUND — no conflict with the existing `M-Arrow{Down,Up}`/`M-Enter`.
- `weevil/keymap.rkt` — `normalize-key-payload` (L230): `code` "KeyA"→"a",
  "KeyE"→"e", "KeyF"→"f", "KeyB"→"b"; named keys `ArrowLeft`/`ArrowRight`/
  `Backspace` map to themselves; `modifier-prefix` ctrl→"C-", alt→"M-". So
  `C-a`,`C-e`,`M-ArrowLeft`,`M-ArrowRight`,`M-Backspace`,`M-f`,`M-b` all fall out
  with NO keymap change.
- `weevil/config.rkt` — re-exports `(all-from-out "buffer.rkt")`,
  `"defaults.rkt"`, `"keymap.rkt"`, `"commands.rkt"`. New `buffer.rkt` exports +
  `defaults.rkt` commands become public automatically. **No config.rkt edit.**
- `weevil/private/web/render.rkt` — keydown handler runs `evt.preventDefault()`
  UNCONDITIONALLY, then POSTs the chord. Browser defaults (Ctrl+A select-all,
  Alt+Arrow history) are already swallowed. **No frontend change.**
- Tests — `tests/completion-display-test.rkt` (L27) has a `payload` helper with
  `#:alt?`/`#:ctrl?`/`#:meta?`/`#:shift?` plus `dispatch`/`type-string`/`run-command`
  helpers; `tests/keymap-test.rkt` has a normalization-assertion pattern (manual
  modifier hashes for `C-a`). Reuse both.

## Key decisions

### Decision 1 — Word-boundary model: internal default predicate + documented syntax-table seam

**Decision.** Implement a MINIMAL, Emacs-shaped word model: a single
**word-constituent predicate** `word-char?` (default = `char-alphabetic?` OR
`char-numeric?`, i.e. Emacs `\w`) plus pure scanners in `position.rkt` that
char-index-walk the flat string. Keep the predicate **internal with a documented
seam**, NOT a public parameter yet: the scanners take an OPTIONAL
`#:word-char? [word-char? default-word-char?]` argument so the syntax-table
extension point is wired in code, but the default is hard-bound and the buffer-
model / session-state callers use the default. Add a comment marking
`default-word-char?` as "the future syntax-table seam (Emacs `Sword`/char-syntax)".

**Rationale.** YAGNI for a configurable syntax table now; but threading the
optional argument means the future syntax-table object slots in WITHOUT changing
the scanner signatures or callers. Mirrors how Emacs centralizes word membership
in `SYNTAX (ch) == Sword`. **Anchor:** `src/syntax.c:1074-1078` / `Fchar_syntax`
(`syntax.c:1098`) — letters+digits are the default word constituents.

### Decision 2 — Word motion semantics (exact, matching `scan_words`)

**Decision.** Char-index-based scanners returning byte offsets:
- **`word-boundary-forward text byte [word-char?]`**: from the char at `byte`,
  (1) skip forward over non-word chars, (2) then skip forward over word chars;
  return the byte offset of the landing char (AFTER the word). At end-of-text,
  return byte-length (the `ZV` clamp). If already past all words, lands at end.
- **`word-boundary-backward text byte [word-char?]`**: from the char before
  `byte`, (1) skip backward over non-word chars, (2) then skip backward over word
  chars; return the byte offset of the word START. At beginning, return 0 (the
  `BEGV` clamp).

`session-state-forward-word` = `word-boundary-forward`, then clamp UP to
byte-length. `session-state-backward-word` = `word-boundary-backward`, then clamp
DOWN to `read-only-until`. `M-ArrowLeft`/`M-b` = backward-word;
`M-ArrowRight`/`M-f` = forward-word (the Emacs `left-word`/`right-word` reduce to
these for LTR). **No bidi, no script-boundary `word_boundary_p`, no
`find-word-boundary-function-table`** (subword etc.) — minimal scan only.
**Anchor:** `scan_words` (`syntax.c:1459`) forward/backward loops;
`Fforward_word` edge clamp (`syntax.c:1576`).

### Decision 3 — Line motion + minibuffer field boundary

**Decision.** Add to `position.rkt`:
- **`beginning-of-line-byte text byte`**: scan backward to the byte AFTER the
  previous `#\newline`, or 0 if none (plain bol, NOT back-to-indentation).
- **`end-of-line-byte text byte`**: scan forward to the byte OF the next
  `#\newline`, or byte-length if none.

`session-state-move-beginning-of-line` computes bol then returns
`(max bol read-only-until)` — so in the minibuffer `C-a` stops at the END OF THE
PROMPT (Weevil's single-mechanism analog of Emacs `constrain-to-field`).
`session-state-move-end-of-line` computes eol then clamps to byte-length.
Multi-line buffers (scratch) are handled by the newline scan. **Anchor:**
`move-beginning-of-line`/`move-end-of-line` (`simple.el:8462`/`8418`) +
`constrain-to-field`; the recon's note that `read-only-until` IS the existing
clamp mechanism.

### Decision 4 — Word deletion (PLAIN DELETE, no kill ring)

**Decision.** `session-state-backward-delete-word`: compute the
`word-boundary-backward` target from point, clamp the target DOWN to
`read-only-until` (so it cannot delete the minibuffer prompt), then
`buffer-model-delete [target, point)`, set point = target. Plain delete; **no
ring, no save**. If `point <= read-only-until` (nothing deletable) or target =
point, eq?-stable no-op. Name the fn/command/wrapper to reflect DELETE:
`session-state-backward-delete-word`, `backward-delete-word-command`,
`backward-delete-word!`. **Anchor:** `emacs-kill-delete.md` option (b); the
word-boundary logic is identical to `backward-word`, only `delete-region`
(discard) instead of save-to-ring. This intentionally diverges from Emacs default
`M-DEL`=`backward-kill-word` per the owner's explicit no-kill-ring decision.

### Decision 5 — Motion-function vs command architecture + public API

**Decision.** Follow the Emacs split exactly:
- **Pure motion functions** in `session-state.rkt` (next to L796-834), operating
  on `session-selected-view` UNIFORMLY (pane AND minibuffer) and clamping to
  `read-only-until`: `session-state-move-beginning-of-line`,
  `session-state-move-end-of-line`, `session-state-forward-word`,
  `session-state-backward-word`, `session-state-backward-delete-word`. Add all
  five to the provide list (L66-72). Pure motion uses `state-with-current-pane`;
  the delete uses `state-with-current-buffer+pane`. Every boundary case returns
  the SAME state object (eq?-stable no-op) to avoid spurious re-render — mirror
  the existing motion fns.
- **Public command wrappers** in `buffer.rkt` (after L43, with `contract-out`
  entries L8-20): `move-beginning-of-line!`, `move-end-of-line!`, `forward-word!`,
  `backward-word!`, `backward-delete-word!` — each a one-line `update-state!`.
- **Commands + bindings** in `defaults.rkt`: `define-command` for each (after
  L62) + provide (L16-34) + `define-key!` on `global-keymap`.
- All public via the existing `all-from-out` re-exports. **Confirm NO config.rkt
  edit needed.** **Anchor:** Emacs motion-function/command split
  (`emacs-motion-commands.md` §4).

### Decision 6 — Bindings (global, inherited by minibuffer) + M-f/M-b aliases

**Decision.** Bind on `global-keymap` (inherited by `minibuffer-keymap` via its
parent):
```
(define-key! global-keymap "C-a" move-beginning-of-line-command)
(define-key! global-keymap "C-e" move-end-of-line-command)
(define-key! global-keymap "M-ArrowLeft"  backward-word-command)
(define-key! global-keymap "M-ArrowRight" forward-word-command)
(define-key! global-keymap "M-Backspace"  backward-delete-word-command)
(define-key! global-keymap "M-f" forward-word-command)   ; canonical Emacs word-fwd
(define-key! global-keymap "M-b" backward-word-command)  ; canonical Emacs word-bwd
```
`M-f`/`M-b` are Emacs's PRIMARY word bindings (`bindings.el:1608/1609`) and avoid
the macOS Alt+Arrow intercept entirely — bind the SAME commands. Confirm
`M-ArrowLeft`/`M-ArrowRight` do NOT conflict with the existing minibuffer-specific
`M-ArrowDown`/`M-ArrowUp`/`M-Enter` (different keys). Confirm normalization (no
`keymap.rkt` change) and that the frontend already `preventDefault`s (no frontend
change). **Anchor:** `bindings.el:1344/1345/1608/1609/1623/1625`.

### Decision 7 — Other optional aliases: ADD trivial char aliases, DEFER M-d

**Recommendation.**
- **ADD NOW (Decision 6):** `M-f`/`M-b` — canonical, faithful, zero new code.
- **ADD NOW (trivial, pure aliases — one `define-key!` line each, NO new
  commands):** `C-f`→`forward-char-command`, `C-b`→`backward-char-command`,
  `C-d`→`delete-forward-char-command`. These are exact Emacs defaults
  (`C-f`/`C-b`/`C-d`) and reuse the EXISTING commands — pure aliases, no risk,
  high faithfulness payoff. Include them.
- **DEFER:** `M-d` (forward delete-word). It is NOT a pure alias — it needs a new
  `session-state-forward-delete-word` + wrapper + command (the forward symmetric
  of Decision 4). Keep scope tight; this milestone ships the owner-requested
  surface + the trivial faithful aliases. `M-d` is a clean follow-up (and would
  reuse `word-boundary-forward` + `buffer-model-delete` directly).
- **NEVER (hard constraint):** anything kill-related (`C-k`/`C-w`/`C-y`, kill
  ring, yank, region/mark).

## Tasks (green-per-slice, TDD)

Slicing rule (matches `completion-nav-keys-plan.md` /
`minibuffer-mode-unification-plan.md`): **each slice = a production change shipped
WITH the tests that prove it; `raco make weevil tests && raco test tests` is
green at every slice boundary.** Per slice write the failing test FIRST, run it,
watch it go RED, then implement to GREEN. **Recompile gotcha: run
`raco make weevil tests` (or clear `compiled/*.zo`) BEFORE `raco test tests`
every slice** — stale bytecode masks the RED/GREEN signal. (Check `Taskfile.yml`
for the canonical build/test targets first.) Drive everything WITHOUT a browser:
pure scanner unit tests, `session-state` fn tests, `dispatch-key` tests using the
`payload` helper with `#:ctrl?`/`#:alt?`, and keymap normalization assertions.

### Slice 1 — pure word + line scanners in position.rkt + buffer-model.rkt

1. **(RED first)** Add `tests/core-position-test.rkt` (or extend an existing
   core-position/buffer-model suite) covering, against `word-boundary-forward`,
   `word-boundary-backward`, `beginning-of-line-byte`, `end-of-line-byte`:
   - forward/backward word across `"foo bar  baz"` (multi-space gaps), landing
     after-word / at word-start;
   - punctuation as non-word (`"foo.bar"` → two words);
   - **multibyte:** `"héllo wörld"` (é, ö are word chars; offsets are BYTE
     offsets stepping over 2-byte UTF-8) — assert byte offsets land on codepoint
     boundaries, never mid-char;
   - digits are word chars (`"a1 b2"`);
   - buffer-edge clamps: forward at end → byte-length; backward at 0 → 0;
   - bol/eol with newlines: `"ab\ncd\nef"` from mid-line-2 → bol = byte after
     first `\n`, eol = byte of second `\n`; bol at buffer start → 0; eol at
     buffer end (no trailing newline) → byte-length; point ON a newline.
   Run → RED (functions absent).
2. **(GREEN)** `position.rkt`: add `default-word-char?` (comment: future
   syntax-table seam), `word-boundary-forward`, `word-boundary-backward`,
   `beginning-of-line-byte`, `end-of-line-byte` (each `#:word-char?` where
   relevant), all char-index based and returning byte offsets via the existing
   `char-index->byte-offset`/`byte-offset->char-index`. Add their `contract-out`
   entries (L5-23). `buffer-model.rkt`: add `buffer-model-forward-word`,
   `buffer-model-backward-word`, `buffer-model-beginning-of-line`,
   `buffer-model-end-of-line` wrapping the `position.rkt` fns over
   `buffer-model-text` (mirror `buffer-model-previous-boundary`, L57); add their
   `contract-out` entries. Acceptance: Slice-1 tests green; codepoint + newline +
   edge cases pass.

### Slice 2 — session-state line motion (C-a/C-e) + minibuffer prompt clamp

3. **(RED first)** Add session-layer tests (in `tests/core-editor-state-test.rkt`
   or the closest existing session-state suite): build a multi-line scratch
   state, set point mid-line, assert `session-state-move-beginning-of-line` /
   `-move-end-of-line` move point to bol/eol; assert idempotent calls at bol/eol
   are **eq?-stable** no-ops; **minibuffer case:** open a read-string minibuffer,
   type input, assert `C-a` (the pure fn) stops at `read-only-until` (the prompt
   end), NOT byte 0. Run → RED.
4. **(GREEN)** `session-state.rkt`: add `session-state-move-beginning-of-line`
   (`(max bol read-only-until)`) and `session-state-move-end-of-line` (clamp to
   byte-length), using `session-selected-view` + `state-with-current-pane`,
   eq?-stable when unchanged. Add to provide list. Acceptance: tests green.

### Slice 3 — session-state word motion (forward/backward-word) + clamps

5. **(RED first)** Session-layer tests: forward/backward word move point over
   `"foo bar"`; backward-word clamps to `read-only-until` in the minibuffer
   (cannot cross prompt); forward-word at end and backward-word at point-min are
   eq?-stable no-ops; multibyte word over `"héllo wörld"` lands correctly.
   Run → RED.
6. **(GREEN)** `session-state.rkt`: add `session-state-forward-word`
   (`buffer-model-forward-word`, clamp up to byte-length) and
   `session-state-backward-word` (`buffer-model-backward-word`, clamp down to
   `read-only-until`), `state-with-current-pane`, eq?-stable when unchanged. Add
   to provide list. Acceptance: tests green.

### Slice 4 — backward-delete-word (NO kill ring)

7. **(RED first)** Session-layer tests: from end of `"foo bar"`,
   `session-state-backward-delete-word` yields `"foo "` with point at byte 4;
   second call yields `""`; deleting at point-min is an eq?-stable no-op;
   **minibuffer case:** with point in input, it deletes back to (and stops at)
   `read-only-until` and CANNOT delete the prompt; multibyte span deletes whole
   codepoints. Assert NO kill-ring/yank surface is touched (there is none).
   Run → RED.
8. **(GREEN)** `session-state.rkt`: add `session-state-backward-delete-word` —
   compute `buffer-model-backward-word` target, `(max target read-only-until)`,
   `buffer-model-delete [target, point)`, point = target, via
   `state-with-current-buffer+pane`; eq?-stable when `point <= read-only-until`
   or target = point. Add to provide list. Acceptance: tests green.

### Slice 5 — public wrappers + commands + bindings + dispatch/normalization tests

9. **(RED first)** (a) Extend `tests/keymap-test.rkt` with normalization
   assertions: `C-a`→"C-a", `C-e`→"C-e", `M-ArrowLeft`→"M-ArrowLeft",
   `M-ArrowRight`→"M-ArrowRight", `M-Backspace`→"M-Backspace", `M-f`→"M-f",
   `M-b`→"M-b" (and the optional `C-f`/`C-b`/`C-d`). (b) Add dispatch tests
   (reuse the `payload` helper with `#:ctrl?`/`#:alt?`): in a scratch buffer,
   `(payload "a" "KeyA" #:ctrl? #t)` runs beginning-of-line; `(payload "e" "KeyE"
   #:ctrl? #t)` end-of-line; `(payload "ArrowLeft" "ArrowLeft" #:alt? #t)` /
   `"f"/"KeyF" #:alt? #t` move by word; `(payload "Backspace" "Backspace"
   #:alt? #t)` deletes the previous word. (c) A **minibuffer dispatch test**
   proving `C-a` stops at the prompt (point = `read-only-until`) and
   `M-Backspace` cannot delete the prompt. Run → RED (commands/bindings absent).
10. **(GREEN)** `buffer.rkt`: add `move-beginning-of-line!`, `move-end-of-line!`,
    `forward-word!`, `backward-word!`, `backward-delete-word!` (one-line
    `update-state!` each) + `contract-out` entries. `defaults.rkt`: add the five
    `define-command`s + provides, and the `global-keymap` bindings from
    Decision 6, PLUS the recommended trivial aliases `C-f`→`forward-char-command`,
    `C-b`→`backward-char-command`, `C-d`→`delete-forward-char-command` (no new
    commands). Acceptance: full suite green; minibuffer prompt-clamp dispatch
    test green. Confirm NO `keymap.rkt`, `config.rkt`, or frontend edit was made.

## Files to modify

- `weevil/private/core/position.rkt` — add `default-word-char?` (seam comment),
  `word-boundary-forward`, `word-boundary-backward`, `beginning-of-line-byte`,
  `end-of-line-byte` + `contract-out` entries.
- `weevil/private/core/buffer-model.rkt` — add `buffer-model-forward-word`,
  `buffer-model-backward-word`, `buffer-model-beginning-of-line`,
  `buffer-model-end-of-line` + `contract-out` entries.
- `weevil/private/core/session-state.rkt` — add `session-state-move-beginning-of-line`,
  `-move-end-of-line`, `-forward-word`, `-backward-word`, `-backward-delete-word`
  (after L834) + provide list (L66-72).
- `weevil/buffer.rkt` — add `move-beginning-of-line!`, `move-end-of-line!`,
  `forward-word!`, `backward-word!`, `backward-delete-word!` + `contract-out`.
- `weevil/defaults.rkt` — add the five `define-command`s + provides + the
  `global-keymap` bindings (`C-a`/`C-e`/`M-ArrowLeft`/`M-ArrowRight`/
  `M-Backspace`/`M-f`/`M-b` + trivial `C-f`/`C-b`/`C-d` aliases).
- `tests/core-position-test.rkt` (new or extend) — scanner unit tests.
- `tests/core-editor-state-test.rkt` (or closest session-state suite) — session
  line/word/delete tests incl. minibuffer prompt clamp.
- `tests/keymap-test.rkt` — normalization assertions for the new chords.

**No change required (verified):** `weevil/keymap.rkt` (all chords normalize),
`weevil/config.rkt` (`all-from-out` covers new provides),
`weevil/private/web/render.rkt` / frontend (`preventDefault` already swallows
browser defaults).

## New files

- `tests/core-position-test.rkt` — pure scanner unit tests (only if no suitable
  existing core suite; otherwise extend in place). No production new files.

## Dependencies

Strict order **1 → 2 → 3 → 4 → 5**. Slice 1 (pure scanners) underpins the
buffer-model wrappers used by every session op. Slices 2–4 are independent of
each other given Slice 1 but share the `read-only-until` clamp pattern; do them
in order for review clarity. Slice 5 (wrappers/commands/bindings) depends on the
session ops from 2–4.

## Risks

- **Stale bytecode.** `raco make weevil tests` before `raco test tests` every
  slice or RED/GREEN runs against old `.zo`.
- **Off-by-one in scanners (byte vs char).** All scanning is char-index based,
  converting to byte offsets only at the boundary — assert byte offsets in tests
  and exercise multibyte input so a mid-codepoint bug fails loudly.
- **read-only-until clamp direction.** `C-a`/backward-word/backward-delete-word
  clamp DOWN to `read-only-until`; `C-e`/forward-word clamp UP to byte-length.
  Inverting either lets `C-a` cross the prompt or delete it — covered by the
  explicit minibuffer tests.
- **Spurious re-render.** Boundary cases MUST return the same state (eq?-stable
  no-op), mirroring existing motion fns; a fresh `struct-copy` at a boundary
  bumps `rev` and re-renders needlessly.
- **macOS Alt+Arrow / WM intercept.** Some OS/WM-level chords may eat Alt+Arrow
  before the page sees them (outside app control). `M-f`/`M-b` are bound to the
  SAME commands as a faithful, intercept-free path, so motion is always reachable.
- **Empty / single-word / all-punctuation buffers.** Scanners must not loop or
  index past the string on empty text or text with no word chars — covered by
  edge-case tests.

## Non-goals / deferred

- **NO kill ring, NO yank, NO `kill-region`** — `M-Backspace` is a PLAIN DELETE
  (option (b)); recoverable only via a future undo, never via yank. The command
  is named `backward-delete-word`, NOT `backward-kill-word`.
- **NO `C-k` / `C-w` / `C-y`** or any kill-related command.
- **NO mark / region changes** — `pane-state-with-collapsed-point` keeps
  deactivating mark on motion/edit; no region commands added.
- **NO undo** — a separate future subsystem; delete is recoverable only once undo
  lands.
- **NO bidi** — LTR only; `M-ArrowLeft`=backward-word, `M-ArrowRight`=forward-word
  directly (no `left-word`/`right-word` direction dispatch).
- **NO syntax-table object yet** — only a swappable internal `word-char?`
  predicate with a documented seam; no `char-syntax`, `Sword` table, script
  boundaries, `find-word-boundary-function-table`, or `subword-mode`.
- **DEFER `M-d`** (forward delete-word) — not a pure alias (needs a new
  `session-state-forward-delete-word`); clean symmetric follow-up reusing
  `word-boundary-forward` + `buffer-model-delete`.
- **NOT changing `keymap.rkt`, `config.rkt`, or the frontend** — verified
  unnecessary.
