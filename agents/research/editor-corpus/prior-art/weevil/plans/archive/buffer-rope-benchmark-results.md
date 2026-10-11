# Buffer Storage Benchmark Results & Decision

Status: decided — rope is the default backend as of 2026-06-16
Date: 2026-06-16
Machine: Linux aarch64, Racket v9.1 [cs]. Corpus shape: `source` (mixed
ASCII + multibyte). NOTE: absolute millisecond figures and the resulting
speedup *multipliers* are machine-specific (a re-run on other hardware differs
by a constant factor — e.g. macOS hosts measured rope insert ~0.6 ms, string
~70 ms). The **durable, machine-independent result is the SCALING SHAPE**: rope
per-keystroke cost is flat across the 1 MB→10 MB sweep while the string's grows
~linearly. Decisions rest on that shape, not the headline multiplier. Methodology: `bench/buffer-bench.rkt` (≥5 warmup, ≥30
measured, double-GC per sample, adaptive batching; medians reported). Raw
artifacts are written under `bench/results/` (gitignored); reproduce with
`task bench -- --backend <string|rope> --size <1m|10m> --shape source`.

## Decision

**Ship the augmented persistent rope** (`rope.rkt` + `buffer-model-rope.rkt`)
as the production buffer backend. The string backend (`buffer-model-string.rkt`)
is retained as the differential-test oracle, not deleted.

The decision was made on **relative improvement over the current string
baseline** (not pre-committed absolute thresholds), per the owner's steer and
the plan's Phase C criteria: the rope must make the per-keystroke / conversion
hot paths *substantially flatter* than the string's linear growth and snapshots
far cheaper, without an unacceptable regression on the non-hot-path ops. It
does.

## Headline numbers (median ms unless noted)

| op | string @1MB | string @10MB | rope @1MB | rope @10MB | verdict |
| --- | --- | --- | --- | --- | --- |
| insert-char-at-point | 72 | **735** | **0.29** | **0.27** | rope flat; string linear (≫10²–10³× @10MB) |
| type-word (8 inserts) | 567 | ~5700 | **2.25** | **2.31** | rope flat |
| delete-char | 104 | 1093 | **0.56** | **0.55** | rope flat |
| delete-range | 106 | ~1060 | **0.55** | **0.53** | rope flat |
| backward-delete-word | 329 | ~3300 | **1.0** | **2.3** | rope flat-ish |
| large-paste (64 KB) | 73 | 736 | **0.75** | **0.75** | rope flat |
| char→byte | 9.5 | ~95 | **0.0024** | **0.0027** | string O(n); rope O(log n) |
| line/utf16-col→byte | 9.0 | ~90 | **0.011** | **0.013** | string O(n); rope O(log n) |
| byte→char | 0.0012 | 0.0012 | 0.0056 | 0.0066 | both fast (string index-assisted) |
| byte→line/utf16-col | 0.0019 | 0.0022 | 0.0056 | 0.0066 | both fast |
| line-N lookup | 0.0001 | 0.0001 | 0.004 | 0.0046 | both fast |
| slice render window (60 ln) | 0.002 | 0.002 | **0.053** | **0.053** | both fast & flat (rope after B6; pre-B6 was 92 ms) |
| load / open | 32 | 328 | **7.8** | **81** | rope faster (no per-char byte alloc) |
| serialize (whole buffer) | ~0 | ~0 | 9.3 | 95 | **string wins** (field read); rope O(n) |
| undo-retain (peak mem, K snaps) | ~130 MB | ~K×10 MB | **2.1 MB** | **1.5 MB** | rope shares structure (~60× less) |

## Interpretation

- **Per-keystroke editing** (the dominant operation — the client sends one
  keystroke → one command → one edit) goes from **O(n), ~0.7 s at 10 MB** on the
  string to **flat ~0.3 ms** on the rope. This is the whole point and the gate's
  primary signal: flat-vs-linear scaling, proven by the 1 MB→10 MB sweep.
- **O(n) string conversions** (`char→byte`, `line/utf16-col→byte`) — which the
  string computes by full linear scan — become **O(log n)** on the rope
  (sub-1 µs–10 µs). The string's index-assisted conversions (`byte→char`,
  `byte→line/col`, line lookup) were already fast; the rope keeps them fast.
- **Render window slice** is flat and negligible on both after Phase B6 switched
  `render.rkt` to `buffer-model-line-range-text` (the rope's pre-B6 92 ms full
  materialize is gone).
- **Snapshots** (for server-side undo, SSE render revisions, background
  tree-sitter) are ~60× cheaper on the rope via structural sharing — a
  capability the string cannot match and that the architecture depends on.
- **`load`/`open` is faster on the rope** (it avoids the string backend's
  per-char `string->bytes/utf-8` line-index build).
- **The one regression: `serialize`** (materialize the whole buffer to one
  string, the save-to-disk path) is O(n) on the rope (95 ms @10 MB) vs an O(1)
  field read on the string. This is acceptable: it is not a per-keystroke op,
  saving n bytes is inherently O(n), and 95 ms to serialize 10 MB is fine.

## Correctness basis

The rope is a **proven drop-in** for the string backend: the differential test
(`tests/buffer-model-differential-test.rkt`) runs seeded random edit sequences
against both backends and asserts identical `buffer-model-text`, identical
results for every conversion/scanner, identical `buffer-model-line-range-text`
over swept line ranges, and **identical `exn-message`** on error cases — after
every edit, including multi-leaf/multi-branch and CRLF/multibyte corpora. The
full editor suite (680k+ assertions) passes with the rope as the live backend.

## Large-file posture (100 MB measured, 2026-06-16)

Dedicated rope run at 100 MB (`source` shape, Linux aarch64, Racket CS 9.1):

| op | rope @1MB | rope @10MB | **rope @100MB** |
| --- | --- | --- | --- |
| insert-char-at-point | 0.29 | 0.27 | **0.63** |
| delete-char | 0.56 | 0.55 | **1.25** |
| backward-delete-word | 1.0 | 2.3* | **4.9** |
| type-word (8 inserts) | 2.25 | 2.31 | **5.25** |
| conversions (each) | <0.012 | <0.013 | **<0.032** |
| slice render window | 0.053 | 0.053 | **0.078** |
| load / open | 7.8 | 81 | **1569** |
| serialize (save) | 9.3 | 95 | **962** |
| undo-retain (mem) | 2.1 MB | 1.5 MB | **0.3 MB** |

(* pre-fix; backward-delete-word is now bounded — see the word-scanner note below.)

**Posture:** interactive editing is smooth at 100 MB. Per-keystroke edits stay
sub-millisecond to a few ms and grow only **logarithmically** with size (insert
0.29→0.27→0.63 ms across 1→10→100 MB — the O(log n) signature, not the
string's linear wall). Conversions and the render window stay flat and
negligible. Snapshots are nearly free even at 100 MB (0.3 MB to retain several
100 MB edit states — structural sharing). The only O(n) costs are `load` (~1.6 s)
and `serialize`/save (~1 s) at 100 MB, which are inherent to reading/writing
n bytes and are not per-keystroke. **Claim supported: Weevil edits 100 MB files
interactively** (open/save take ~1–2 s, as expected for that size). The prior
O(n)-per-keystroke wall is gone.

**Word motion (M-f / M-b / M-Backspace) was fixed** to a bounded outward rope
walk (was O(n): it sliced the whole prefix/suffix). It is now O(word + log n):
backward-delete-word at 100 MB is ~4.9 ms (was ~769 ms at 10 MB before the fix).

## Follow-ups (tracked, not blocking)

- **Word scanners** (`forward-word`/`backward-word`) are correctness-first
  O(distance) via a bounded `rope-slice`; a within-rope char walk would make
  them O(log n + word). Tune if benchmarks of those ops warrant.
- **Self-insert coalescing (Phase B4)** is unimplemented; per-keystroke insert
  is already ~0.3 ms flat, so it is an optional allocation optimization, not a
  latency need.
- **Error module unification:** `buffer-model-errors.rkt` currently *reproduces*
  the string/`position.rkt` messages; fully sharing them (refactor `position.rkt`
  to call the shared constructors) removes the copy-drift risk (the strict
  differential test guards it meanwhile).
- **`serialize`** could stream chunks to the output port instead of building one
  string if save latency on very large buffers becomes a concern.
