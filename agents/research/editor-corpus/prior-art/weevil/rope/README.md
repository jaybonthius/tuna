# rope

An immutable, persistent, summary-augmented B+-tree of bounded UTF-8 string
chunks (Zed SumTree style). Every node carries a summary monoid, so all length
and coordinate queries are O(log n) and edits return a new rope that shares all
untouched structure.

## Invariants

- UTF-8 **byte offsets** are the canonical position; they must land on a
  codepoint boundary.
- Only **LF** (`\n`) starts a new line; CR is ordinary text.
- **Columns** are counted in UTF-16 code units.
- Edits are **persistent**: retaining an old value is an O(1) snapshot.

## Usage

```racket
(require rope)

(define r  (string->rope "hello\nworld"))
(define r2 (rope-insert r 5 ", there"))   ; -> "hello, there\nworld"
(rope->string r)                          ; -> "hello\nworld" (unchanged)
(rope-line-count r2)                       ; -> 2
(rope-byte->position r2 13)                ; -> (position 1 0)
(rope-position->byte r2 (position 1 0))    ; -> 13
```

## Tests

```sh
raco test rope/tests/rope-test.rkt
```
