# Mutable gap-buffer plan

## Status

Implemented. The standalone correctness suite, approval-host performance gates,
and basic editable-buffer integration pass.

## Decision

Tuna's private editable-text store is a pure-Racket mutable UTF-8 byte gap
buffer with a separate Scintilla-style LF line-start partition index.

- The representation is opaque.
- There is one implementation and no provider protocol.
- Public/editor integration is out of scope for this plan.
- SumTree, ropes, piece trees, undo, views, markers, properties, overlays, and
  derived caches are out of scope.

## Text semantics

- Coordinates are exact logical UTF-8 byte offsets.
- Edit ranges are half-open `[start,end)` ranges interpreted against the text at
  the start of that batch.
- Every endpoint must be in range and on a Unicode scalar boundary; Tuna never
  rounds an invalid coordinate.
- Only byte `#x0A` starts a line. Lines and UTF-16 columns are zero-based. CR,
  CRLF, NEL, LS, and PS receive no special treatment beyond their bytes/scalars.
- Empty text has one line. A trailing LF creates an empty final line.
- Equal-position insertions preserve caller order.
- An empty range with an empty replacement is discarded. A byte-identical
  nonempty replacement remains an edit.

## Private module

Create `tuna/api/private/buffer-content.rkt`. `buffer-content` and all physical
storage/index records remain opaque.

| Private export | Meaning |
|---|---|
| `(struct content-edit (start end replacement) #:transparent)` | One old-text edit; replacement is immutable valid UTF-8 bytes. |
| `(struct content-change (old-start old-end new-start new-end) #:transparent)` | One retained edit with old and final-document ranges. |
| `(struct content-change-set (before-byte-length after-byte-length changes) #:transparent)` | Retained changes in final output order. |
| `(struct content-location (line line-byte-start char-column utf16-column) #:transparent)` | Coordinates for one valid byte boundary. |
| `(make-buffer-content bytes)` | Construct content from immutable valid UTF-8 bytes. |
| `(buffer-content? value)` | Recognize content without exposing it. |
| `(buffer-content-byte-length content)` | Return logical byte length. |
| `(buffer-content-valid-byte-offset? content value)` | Return `#t` only for an in-range scalar boundary; return `#f` otherwise. |
| `(buffer-content-apply! content edits)` | Apply one old-text batch atomically; return its change set. |
| `(buffer-content-snapshot content)` | Return immutable logical bytes; cache reuse and object identity are unspecified. |
| `(buffer-content-slice content start end)` | Return immutable copied bytes for a scalar-aligned range. |
| `(buffer-content-write content start end out)` | Stream a range directly from at most two physical spans. |
| `(buffer-content-locate-byte content offset)` | Resolve a byte boundary to line, line start, scalar column, and UTF-16 column. |
| `(buffer-content-resolve-position content line utf16-column)` | Resolve a valid line/UTF-16 position to a byte boundary. |

Except for `buffer-content-valid-byte-offset?`, malformed arguments raise a
procedure-named contract exception without changing content.

### Batch ordering

1. Validate every edit against the pre-batch bytes.
2. Discard empty/empty edits.
3. Reject overlapping consumed ranges and insertions strictly inside one.
4. Order each boundary `p` as: a replacement ending at `p`, insertions at `p` in
   caller order, then a replacement beginning at `p`.
5. Compute final coordinates, deleted bytes, forward operations, inverse
   operations, result records, and required text/index capacity before mutation.
6. Apply forward operations right-to-left. Apply equal-position insertions in
   reverse so their final bytes retain caller order.

Each retained edit has one `content-change`. Its `new-start` and `new-end` are
coordinates in the final document. Equal-position insertions remain separate
changes.

### Location examples

For `#"a\n"`:

- byte `0` is line 0, line start 0, columns 0;
- byte `1` is the LF on line 0 at columns 1;
- byte `2` is EOF on line 1, line start 2, columns 0.

The end column of a non-final line resolves to its LF byte. A supplementary
scalar occupies two UTF-16 units; resolving the interior unit is invalid.

### Internal invariants

- Backing bytes are mutable and `0 <= gap-start <= gap-end <= capacity`.
- Prefix plus suffix is valid UTF-8 and equals the logical text.
- Gap movement uses overlap-safe `bytes-copy!`; growth is geometric.
- Physical coordinates never leave the module.
- The line partition starts with 0 and contains exactly one entry after every
  logical LF. It uses a private vector gap and lazy suffix delta rather than one
  object per line.
- Snapshot bytes are immutable. A retained snapshot cannot change after an edit.
- A discarded batch does not move the gap or invalidate the current cache.
- The object is not thread-safe; later editor integration supplies synchronization.

`buffer-content-apply!` is semantically failure-atomic:

- preparation performs all validation and required allocation before mutation;
- one prepared splice and publication of its completed-splice progress marker run
  in the same break-disabled extent, allocate nothing, invoke no callback, and
  cannot fail for valid input;
- breaks are re-enabled only after that marker is visible;
- an exception or break between marked splices replays prevalidated,
  preallocated inverse operations with breaks disabled before escaping;
- recovery restores logical bytes and line-index correctness, but need not
  restore gap placement, capacity, cache identity, or an internal epoch;
- failure of a prepared forward or inverse splice is an internal invariant
  violation, not a recoverable contract error.

Expose invariant/failure-injection hooks only through a test submodule.

## Task 1: implement and prove correctness

Files:

- `tuna/api/private/buffer-content.rkt`
- `tuna-test/tuna/api/private/buffer-content.rkt`

Work:

- Implement the byte gap, geometric growth, LF partition, scalar validation,
  ordered batch preparation/application, immutable reads, streaming writes, and
  coordinate conversion.
- Build a slow immutable-bytes oracle independent of the implementation.
- Add deterministic tests for ASCII and 2/3/4-byte scalars, malformed UTF-8,
  boundary rejection, insert/delete/replace, gap movement in both directions,
  repeated growth, leading/trailing/consecutive LF, CRLF and Unicode separators,
  UTF-16 surrogate interiors, retained snapshots, cross-gap slices/writes,
  overlap rejection, boundary ties, equal-position ordering, no-ops, and
  byte-identical replacements.
- Inject failures and breaks at every prepared-splice boundary and prove complete
  semantic rollback.
- Add fixed-seed randomized differential traces containing local, far, and
  1–200-edit batches. Compare text, change sets, line starts, coordinate round
  trips, slices, writes, and invariants after every operation. Failures report
  the seed, operation number, prior bytes, and batch.
- Include a deterministic 10,000-edit batch correctness case.

Gate:

- Focused tests and `make test` pass.
- `make format`, `make review`, and `git diff --check` introduce no new issue.
- No existing production module imports the new store.
- A fresh correctness reviewer approves the API, invariants, failure atomicity,
  and oracle coverage.

## Task 2: establish the performance gate

Files:

- `tuna-bench/buffer-content/workloads.rkt`
- `tuna-bench/buffer-content/run.rkt`
- `tuna-test/tuna/api/private/buffer-content-benchmark.rkt`
- `docs/research/gap-buffer-benchmark.md`
- `Makefile`

`make test` runs only timing-free workload/hash/report-shape tests. Timing runs
only through an explicit `benchmark-buffer-content` target. Add `tuna-bench` to
format/review file discovery.

### Approval host

- Host: `tungo`
- OS: Linux 6.8.0-47-generic x86_64
- CPU: AMD Ryzen 9 7940HS
- Memory: 60 GiB
- Racket: v9.2 CS

A different host may produce a report, but cannot silently replace the approval
host or its gates.

### Measurement protocol

- Check in deterministic workload/corpus definitions. Record their SHA-256 hashes
  and all parameters in the report.
- Construct stores and expected oracle results outside timed regions.
- Force collection before, never during, an aggregate sample.
- Run one untimed warmup and five independent measured samples for aggregate
  workloads. Report median plus all raw samples.
- For local/far latency, run 20 untimed operations followed by at least 200 timed
  operations and compute p99 by nearest rank.
- Prepare the local gap at the edit point. For far latency, alternate edits at
  opposite document ends so every timed operation crosses the document.
- Prepare scattered batches with the gap at EOF; the descending batch may move it
  monotonically across the document once.
- Measure snapshot copy only after a retained one-byte mutation invalidates the
  cache. Report cached snapshot lookup separately.
- Validate final bytes against the flat oracle outside the timed region.
- On this host, measure cumulative allocation as the difference between
  `current-memory-use 'cumulative` readings. Mark unavailable measurements
  unsupported rather than substituting retained heap.

### Workloads and gates

| Workload | Gate |
|---|---:|
| 20,000-edit local insert/backspace trace | <= 50 ms; <= 128 MiB allocation |
| One local edit in 10 MiB, p99 | <= 1 ms |
| One far edit across 100 MiB, p99 | <= 16 ms |
| 200 scattered old-text edits in 10 MiB | <= 16 ms |
| 10,000 scattered old-text edits in 10 MiB | <= 250 ms |
| 10,000 ordinary/high-line-count conversions in 10 MiB | <= 100 ms |
| Cold immutable snapshots at 1/10/100 MiB | <= 10/50/250 ms |

Report the long-line coordinate case separately because a line-start-only index
intentionally scans within one line.

The JSON report contains the host/Racket identity, schema version, workload and
corpus hashes, gap starting position, parameters, raw wall/CPU/allocation samples,
summary statistics, validation result, and gate decision. The authoritative
local report is `.state/gap-buffer-benchmark.json`; the research document records
methodology, results, and report SHA-256.

Gate:

- Every replay validates against the flat oracle.
- Applicable gates pass on the approval host.
- A fresh performance reviewer approves the timed boundaries, gap setup, corpus,
  hashes, and report.
- A failure stops integration for diagnosis; it does not introduce another
  representation inside this plan.

## Integration boundary

Basic integration is implemented by
[`editable-buffer-api-plan.md`](editable-buffer-api-plan.md) and recorded in
[ADR 0002](../adr/0002-runtime-owned-subject-text.md).

The editor runtime owns lazy live content for existing file subjects under the
existing editor lock. The public layer adds string reads, exact byte-position
conversion, and insert/delete/replace operations. A private update-local LIFO of
prepared reversal handles preserves the existing nested-update failure contract
without whole-buffer snapshots.

This integration adds no revisions, content persistence, event redesign, undo,
markers, properties, overlays, view editing state, derived caches, alternate
provider, or subject rename.

## Subagent execution loop

Run each task with one writer and fresh read-only reviewers:

1. A `context-builder` or `scout` prepares the exact task handoff and file/test
   map.
2. One `worker` is the sole writer in the active worktree.
3. The worker runs focused tests, `make format`, `make review`, `make test`,
   `git diff --check`, and the task-specific benchmark checks.
4. Two fresh `reviewer` passes run in parallel: correctness/atomicity and
   simplicity/scope. They do not edit project files.
5. The parent accepts only concrete findings, returns them to the same writer,
   and repeats review. Stop after approval or three review rounds.

Do not start Task 2 while Task 1 is red, and do not start integration while Task
2 is red. Escalate new public or representation decisions to the owner.

## Task 1 worker prompt

> Implement only Task 1 of `docs/plans/gap-buffer-plan.md`. Create the private
> buffer-content module and its focused tests. Keep the representation opaque;
> fully prepare old-text batches before mutation; apply right-to-left; maintain
> the LF partition incrementally; make the operation failure-atomic at prepared
> splice boundaries; and compare deterministic/random behavior with a flat
> immutable-bytes oracle. Do not modify editor state, runtime, updates,
> persistence, events, public APIs, active design docs, benchmarks, or add
> provider/alternate-storage abstractions. Run focused tests, `make format`,
> `make review`, `make test`, and `git diff --check`. Report changed files,
> commands/results, random seeds, and blockers.
