# Gerbil mechanics for memoized rendering: measurements

2026-10-22. The research lane timed out before writing its report. These numbers come from its raw output in `/home/jay/Code/workbench-gerbil/scratch/rendering-gerbil/`, summarized by the primary agent:
- benchmarks: `frame.ss`, `deps.ss`, `idioms.ss`;
- results: `frame-run1.txt`, `frame-run2.txt`, `deps-run1.txt`, `idioms-run1.txt`, `idioms-run2.txt`.

Gerbil v0.19-dev-63, Gambit v4.9.8, compiled executables, one machine. The figures are the runs' medians as printed and were not re-run. Treat them as orders of magnitude.

## Summary

- **The transport's string work matters more than assembly.** Assembling a screen from cached pieces is cheap at any level. The expensive part is the transport's whole-screen copies: stamping the screen, `patch-elements` splitting it into lines, and framing it.
  - Writing cached pieces straight to the stream's writer, already encoded as UTF-8 bytes, is about 60–100 times cheaper than today's path. At about 35 KB it costs 5 µs against 320 µs. At 395 KB it costs 30 µs against 3.7 ms.
- **Gerbil's SXML writer is the main cost of building HTML.** For 100 lines it takes 1.26 ms and allocates 4.9 MB. Writing the same HTML directly, with escaping, takes 0.08 ms. The owner is replacing the SXML writer separately.
- **Recording dependencies is cheap.**
  - Noting a read in a frame held by a parameter costs about 29 ns. A read with no tracking costs about 8 ns.
  - Validating a cached piece costs 0.01 µs for one recorded read and 0.14 µs for 100.
  - Binding a tracking frame per piece costs about 0.08 µs.
- **Weak-keyed tables are not ephemerons.** An entry whose value refers to its key is never collected: all 10,000 and all 100,000 such entries survived two garbage collections after their keys were dropped. Cache entries naturally refer to their node, so do not key caches by node in a weak table. Use a field on the node (the fastest lookup, 5.7 ns), or a table keyed by node id that is swept each frame.
- **Records.**
  - Use final `defstruct` or `defclass`. Dot access on a non-final `defclass` costs 13.7 ns, against 0.36 ns.
  - Typed signatures cost nothing at run time.

## Assembly and transport (Q1, `frame-run2.txt`)

The table gives time per frame and memory allocated, in fragments × characters each.

| Frame | One string-append | String port | Today's transport (assemble, stamp, `patch-elements`) | `patch-elements` alone on a prebuilt string | Pieces written as strings to the writer | Pieces written as UTF-8 bytes to the writer |
|---|---|---|---|---|---|---|
| 50 × 400 (19 KB) | 27 µs | 64 µs | 175 µs, 232 KB | 142 µs | 38 µs | 2.6 µs |
| 100 × 360 (35 KB) | 49 µs | 75 µs | 319 µs, 367 KB | 243 µs | 68 µs | 4.9 µs |
| 500 × 50 (24 KB) | 36 µs | 60 µs | 240 µs, 415 KB | 162 µs | 62 µs | 18 µs |
| 100 × 2,000 (197 KB) | 352 µs | 730 µs | 3,253 µs, 1.9 MB | 1,514 µs | 372 µs | 10 µs |
| 500 × 800 (395 KB) | 594 µs | 1,292 µs | 3,653 µs, 3.9 MB | 2,895 µs | 769 µs | 31 µs |

Writing pieces directly needs the event framing that `patch-elements` does today (`data: elements` before each line) to be done per piece. Pieces must keep their line breaks known, or contain none.

Stamping the screen root (`add-root-attributes`) copies the whole screen: 60 µs at 35 KB.

## Dependency recording (Q2, `deps-run1.txt`)

The table gives cost per read, from 1,000 reads per operation.

| What | Time | Allocation |
|---|---|---|
| Untracked read | 8 ns | 0 |
| Read a parameter, no frame | 24 ns | 0 |
| Read a parameter and record `(source . revision)` | 29 ns | 94 B |
| The same with 64 other parameters bound | 30 ns | 94 B |
| Read a global and record | 11 ns | 94 B |
| `parameterize` plus making a frame, per piece | 80 ns | 360 B |
| Validate 1, 5, 20 or 100 recorded reads | 0.01, 0.02, 0.04, 0.14 µs | 0 |
| Compare one subtree revision | 0.01 µs | 0 |

Looking up a cache entry, 10,000 lookups:

| Lookup | Time per lookup |
|---|---|
| Field on the node | 5.7 ns |
| `eqv` table by fixnum id | 17 ns |
| `eq` table | 24 ns |
| Weak-keyed table | 37 ns |

## Records and HTML writing (Q4, `idioms-run1.txt`, `idioms-run2.txt`)

**Records.**
- Making a `defstruct final` takes about 2.4 ns per record. A `defclass` takes 3.0 ns.
- Accessors take 0.36 ns. A non-final `defclass` accessor takes 0.84 ns, and its dot access 13.7 ns.

**HTML for 100 lines (15 KB).**

| How | Time | Allocation |
|---|---|---|
| Building the SXML | 7.7 µs | 83 KB |
| `write-sxml` to a string port | 1,260 µs | 4.9 MB |
| Writing strings directly, with escaping | 81 µs | 157 KB |
| One string port per line, to fill a per-line cache | 114 µs | 552 KB |
| Each line's string, then `string->utf8` | 137 µs | 585 KB |

**Gzip on a 36 KB frame**, for reference only (compression is roadmap item 8):

| Level | Time | Size |
|---|---|---|
| 1 | 90 µs | 6.8 KB |
| 6 | 417 µs | 5.5 KB |
| 9 | 1.3 ms | 5.3 KB |

## Not measured (the lane timed out)

- Fragment hashing.
- `string=?` on whole screens.
- A full memoized-render prototype.
