# Tuna input keymaps architecture review

## Result

No Blockers or production architecture/correctness defects found. One Important benchmark-validation issue remains.

The implementation otherwise matches the approved scope: supported Gerbil v19 APIs, opaque final structs, canonical modifier bitset, private sorted-vector lookup, defensive entry/modifier handling, bounded outcome observers, and unchanged runtime installation authority. Source `gxi`, normal `gxc`, and `gxc -O` validation passed.

## Findings

### Important — benchmark lookup measurements include construction/setup

**Evidence:** `/home/jay/Code/workbench-gerbil/tuna/tuna/test/keymap-benchmark.ss:45-57` constructs all query sequences, the higher-precedence map, its binding, and map lists inside `checked-lookups`. `/home/jay/Code/workbench-gerbil/tuna/tuna/test/keymap-benchmark.ss:83-91` times the entire call to that function after garbage collection. Thus those construction allocations and time are included in the reported “lookup” measurement.

This conflicts with the explicit requirement to measure lookup separately from construction at `/home/jay/Code/workbench-gerbil/plans/tuna-input-keymaps/spec.md:220`, and makes the claim at `/home/jay/Code/workbench-gerbil/research/tuna-input-keymaps-implementation-report.md:133-137` imprecise.

**Consequence:** The benchmark passes and its contamination is small relative to 5,000 iterations, but its timing/allocation figures are not pure resolver-lookup measurements.

**Smallest safe correction:** Construct both maps, query sequences, and ordered-map lists before the garbage collection and timed region; pass that prepared workload into a function containing only the repeated `resolve-key-sequence` calls and checks.

## Verified without findings

- Sorted-vector lower-bound and adjacent-prefix logic are correct and retain `O(log B × L)` lookup complexity: `/home/jay/Code/workbench-gerbil/tuna/tuna/lib/keymap.ss:230-259,265-334`.
- Structural value equality aligns with comparator identity; modifier and entry aliases are not retained through the public API: `tuna/lib/keymap.ss:28-55,84-175,265-303`.
- Public representation remains bounded; backing vectors, masks, map entries, and generated accessors are not exported: `tuna/lib/keymap.ss:3-49`.
- Validation and variant accessor failures are synchronous and domain-checked: `tuna/lib/keymap.ss:57-175,265-303,336-371`.
- Runtime growth is limited to the four approved observers and does not expose installation: `tuna/lib/runtime.ss:25-30,89-107,132-171`.
- Dispatcher behavior remains application/test-local and directly invokes targets on the owner call stack: `tuna/test/input-dispatch-test.ss:47-99`.
- README scope and ownership wording is accurate: `tuna/README.md:152-235`.
- No accidental production dispatcher, command registry, macro syntax, global keymap, browser mapping, or public installation seam was added.

## Residual risks

- Gerbil does not enforce transitive immutability; argument specifications, roots, and shared descendants remain immutable by contract.
- The synthetic benchmark gives entries distinct first strokes, so it does not characterize a heavily shared-prefix workload or establish a product latency budget.
- Root rollback cannot undo external mutation or input/output performed by application acquisition or targets.