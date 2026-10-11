# Tuna input keymaps acceptance review

## Result

No Blocker, Important, or Note findings survived verification. The uncommitted Tuna implementation conforms to the owner-approved acceptance/behavior contract.

## Verified behavior

- Public keymap exports exactly match the contract: `tuna/lib/keymap.ss:3-26`.
- Canonical modifiers, validation, normalization, and defensive publication are implemented at `tuna/lib/keymap.ss:51-123`.
- Sequence construction and checked access are implemented at `tuna/lib/keymap.ss:125-157`.
- Binding validation and opaque argument-spec propagation are implemented at `tuna/lib/keymap.ss:159-175`.
- Map copying, validation, duplicate detection, and exact-plus-prefix rejection are implemented at `tuna/lib/keymap.ss:249-303`.
- Exact, continuation, undefined, absent, and ordered fallback semantics are implemented at `tuna/lib/keymap.ss:307-371`.
- The runtime adds exactly four outcome observers at `tuna/lib/runtime.ss:27-30,95-107`.
- The application-owned dispatcher directly invokes targets, clears prefixes, propagates outcomes, and raises on invalid composition without nested submission at `tuna/test/input-dispatch-test.ss:59-102`.
- Dequeue-time root behavior, live replacement, independent runtimes, rollback, recovery, and result propagation are exercised at `tuna/test/input-dispatch-test.ss:197-462`.
- Resolver and observer contract coverage appears at `tuna/test/keymap-test.ss:19-233` and `tuna/test/state-outcome-test.ss:9-28`.
- Source, normal `gxc`, and `gxc -O` matrix coverage includes all new modules and suites at `tuna/test/run-command-runtime-matrix.sh:29-105`.
- The benchmark checks public exact, absent, continuation, undefined, and layered queries separately from construction at `tuna/test/keymap-benchmark.ss:29-101`, across three execution modes at `tuna/test/run-keymap-benchmark-matrix.sh:11-58`.
- Production scope remains limited to the pure resolver and four runtime observers; dispatcher and acquisition logic exist only in the test fixture.

## Validation gaps

None material. The focused tests, full three-mode runtime matrix, package build, and benchmark matrix passed. Final Tuna status matched the original eleven implementation paths and contained no staged files.

## Residual risks

- Transitive immutability remains contractual for argument specifications, roots, requests, and shared descendants.
- Atomic rollback cannot undo external input/output or mutable global effects.
- The benchmark records measurements but establishes no product performance threshold.
- Host normalization, browser capture, Input Method Editor behavior, and accessibility remain intentionally out of scope.