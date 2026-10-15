# Writing Gerbil for Tuna

Distilled 2026-10-11 from the Gerbil maintainers' agent guidance (`/home/jay/Code/workbench-gerbil/gerbil/AGENTS.md`, `src/std/AGENTS.md`, `CONTRIBUTING.md`), `doc/reference/dev/optimizing.md` in that checkout, and the workbench's earlier research. When this guide and the Gerbil sources disagree, the sources win; re-read them when in doubt. Tuna decisions live in [`../adr/`](../adr/README.md).

## Toolchain

- Tuna targets Gerbil v0.19-dev, installed at `/opt/gerbil`. The Gerbil MCP server runs against the same build (`gerbil_version` reports it). The checkout at `/home/jay/Code/workbench-gerbil/gerbil` is for reading; never modify it or `/opt/gerbil`.
- `gerbil build` (via `make`) compiles modules with the optimizer (`-O`) by default. Do not use full-program optimization (`--optimized`); runtime `eval` and module reload depend on separate compilation ([ADR 1](../adr/0001-language-and-extension-surface.md)).

## Editing protocol (required)

From the Gerbil maintainers. For every Gerbil source file you edit:

1. Before the first edit, run `gerbil_check_balance` on the file to establish a passing baseline. If it fails, stop and report; do not repair inherited code as a side task.
2. Make the smallest edit that does the job.
3. Immediately run `gerbil_check_balance` again. If it fails, the last edit caused it: re-read exactly that region and fix only that edit. Never hunt for parentheses elsewhere.
4. Then run `gerbil_check_syntax` (with `loadpath` set to the project's `.gerbil/lib` when importing Tuna modules). Distinguish a real syntax error from an MCP or environment failure; if MCP cannot check, expand the forms with `gxi` in their module context instead.
5. Only after both pass: continue editing, compile, or run tests.

Prefer `gerbil_balanced_replace`, `gerbil_balanced_insert`, and `gerbil_wrap_form` for structural edits.

## Gerbil MCP: which tool when

| Need | Tools |
|---|---|
| Does this API exist; what does it do? | `gerbil_module_exports`, `gerbil_doc`, `gerbil_describe`, `gerbil_function_signature`, `gerbil_apropos`, `gerbil_stdlib_source`, `gerbil_find_definition` |
| Known recipes and pitfalls | `gerbil_howto`, `gerbil_anti_pattern_lookup`, `gerbil_error_fix_lookup`, `gerbil_explain_error` |
| Try code | `gerbil_eval`, `gerbil_repl_session`, `gerbil_expand_macro`, `gerbil_trace_macro` |
| Check code | `gerbil_check_balance`, `gerbil_check_syntax`, `gerbil_batch_syntax_check`, `gerbil_compile_check`, `gerbil_verify`, `gerbil_lint`, `gerbil_check_arity`, `gerbil_check_exports`, `gerbil_check_import_conflicts` |
| Build and test | `gerbil_build_and_report`, `gerbil_run_tests`; or `make` and `make test` |
| Performance | `gerbil_profile`, `gerbil_benchmark`, `gerbil_benchmark_compare`, `gerbil_heap_profile` |

MCP results are evidence, not authority: confirm surprising answers against source or a quick `gxi` run.

## Conventions

From the stdlib guidance, adapted to Tuna:

- **Types.** Give every top-level procedure parameter and return type signatures, not only exported ones, as precisely as known. Annotate every struct and class. Use `:? Type` for nullable values. Let contracts enforce declared types; don't add manual checks the types already guarantee. Use dotted access on typed values; use `using` for a typed binding reused in a body and `(:- expression Type)` for a one-off assertion. Validate what types cannot express (ranges, formats, external data).
- **Structure.** Use interfaces (`:std/interface`) and concrete classes for specialized behavior, not procedure slots in a struct or long predicate dispatch. For a single implementing class, use `implement`. Name procedures that construct interface instances `new-…`. Export public APIs explicitly; internal helpers must not leak through a public facade. Use descriptive internal names, not a `~` prefix.
- **Threads.** Use `spawn-thread` (or `spawn/name` for actors), never raw `make-thread`/`thread-start!`. Exception: Tuna jobs start through `make-root-thread` with `thread-main` (`tuna/lib/jobs.ss`), the only way to give them the empty dynamic environment ADR 3 requires. Name worker procedures with a `-thread` suffix. Hold the mutex when signaling a condition variable; prefer `do-with-lock` for simple critical sections. The stdlib treats cancellation as cooperative and avoids injecting exceptions with `thread-interrupt!`; Tuna's quit lane uses interruption only as a last resort ([ADR 3](../adr/0003-command-loop-and-jobs.md)).
- **Cleanup.** `unwind-protect!` is cheaper but only for audited bodies that never escape through continuations; otherwise use `unwind-protect`.
- **Reuse.** Use existing stdlib operations before writing helpers; avoid intermediate collections, repeated scans, and whole-input copies. Don't wrap a simple expression in a one-use helper. Don't defensively copy values callers treat as immutable; document the ownership convention instead.
- **Errors.** Let underlying exceptions propagate unless translating them serves a purpose. Give errors that share handling a common base class.
- **Style.** Two-space indentation and the style of surrounding code. Multiline `import`/`export` forms put the first operand on the head line and align the rest under it.

## Performance

From `optimizing.md`, in order:

1. Profile first; optimize only measured hot spots.
2. Use `fx`/`fl` operations for fixnums and flonums in hot code (or `(declare (fixnum))`).
3. Use `(declare (not safe))` only surgically in proven hot spots; bugs there become memory corruption.
4. Avoid `apply` in hot paths; prefer `case-lambda` and optional lambdas.
5. Prefer direct calls to known procedures. Keep optional, keyword, and case lambdas at module interfaces, not as internal first-class procedures.
6. Use `unchecked: #t` accessors internally once types are checked at the boundary; in production `implement` blocks, use the generated unchecked `__` bindings of typed procedures.
7. Interface dispatch is much faster than generic method dispatch; Tuna's services use interfaces for this reason.

Measure proposed optimizations with reproducible benchmarks before keeping them.

## Known toolchain issues

- `gxc -O` loops forever compiling an empty self-loop such as `(let lp () (lp))` (Gerbil v0.19-dev-63; confirmed with a one-line module). Give such loops a body, for example a counter. Tracked in `TODO.md`.
- `thread-interrupt!` blocks its caller until the target thread runs the interrupt; call it from a helper thread when the target may be stuck in foreign code.

## Tests

- Co-located `foo-test.ss` files exporting `foo-test` suites from `:std/test`; run with `make test` (`gerbil test ./tuna/... ./plugins/... ./tests/...`). Test-support modules must not end in `-test.ss`.
- Test support lives in `tests/support/` directories (a concept's doubles in `plugins/<concept>/tests/support/`, kernel helpers in `tuna/tests/support/`, shared fixtures in the top-level `tests/support/`), as modules that are not in `build.ss`; tests import them by relative path. Only tests and the demo (`demo/`) may import or include them (`tuna/tests/unit/boundary-test.ss` checks this). A plugin's test (`plugins/<concept>/tests/`) activates only the plugins it tests, the plugins that fill the slots those require (and the slots those require in turn), and stand-ins, from test support or defined in the test, for anything else it needs: input and messages (`test-input`, `test-messages`), a session that saves nothing, typing. It drives its plugins directly or through those stand-ins, never through another plugin's commands. Tests that combine many real plugins go in the top-level `tests/integration/`.
- The kernel object is private. Every test that needs a kernel runs in a fresh one from `call-with-fresh-kernel` (`tuna/tests/support/kernel.ss`): `(call-with-fresh-kernel plugins (lambda () ...))` activates PLUGINS, and afterwards stops the editor loop (start it in the thunk with `start-editor-loop!` when needed) and deactivates every plugin, so no kernel is dropped with live hook callbacks. Name the plugin list (`editing-plugins`); wrap the call only to reset test state or to boot in a particular order. Do not create or select kernels any other way; kernel tests that check internals import them from the kernel's modules.
- Gate expensive or browser-dependent tests behind a feature (`gerbil test -D feature`) rather than running them by default.
