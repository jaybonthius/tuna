---
name: gerbil-reference
description: Find authoritative Gerbil v0.19 and Gambit behavior, idioms, and APIs for Tuna code. Use before relying on a Gerbil API, macro behavior, compiler declaration, concurrency primitive, or package/test convention.
---

# Gerbil reference

Tuna targets the Gerbil v0.19 development branch. The installed toolchain is `/opt/gerbil` (`gxi --version`). Do not guess APIs.

## Sources, in order

1. The Gerbil MCP tools (`gerbil_check_syntax`, `gerbil_check_balance`, `gerbil_eval`, documentation and module-export lookups). Use them to confirm a form expands and an API exists.
2. Gerbil documentation in `/home/jay/Code/workbench-gerbil/gerbil/doc/` (`reference/std/`, `reference/gerbil/`, `guide/`).
3. Gerbil source in `/home/jay/Code/workbench-gerbil/gerbil/src/` (codebase-memory project `home-jay-Code-workbench-gerbil-gerbil`). Its branch may differ from the installed build; check `gxi --version` against `git -C /home/jay/Code/workbench-gerbil/gerbil describe`.
4. Gambit manual: `/home/jay/Code/workbench-gerbil/gerbil/src/gambit/doc/gambit.txi` for threads, declarations (`block`, `separate`), and runtime primitives.
5. Prior Tuna research in `agents/research/workbench-gerbil/` and `agents/research/editor-corpus/prior-art/workbench-gerbil/research/`. Re-verify version-sensitive claims.

## Editing protocol and conventions

Follow [`agents/guides/gerbil.md`](../../../agents/guides/gerbil.md): balance-check before the first edit and after every edit, syntax-check before compiling, and apply its conventions and performance rules.

## Facts Tuna relies on

- Modules compile with `(declare (block))`; use `(declare (separate))` where external `set!` must reach intra-module calls ([ADR 1](../../../agents/adr/0001-language-and-extension-surface.md)).
- Gambit threads are preemptive green threads; the installed runtime is not SMP (`gerbil-runtime-smp?` is `#f`). Do not share mutable state across threads ([ADR 3](../../../agents/adr/0003-command-loop-and-jobs.md)).
- `thread-interrupt!` runs a thunk in the target thread; raising from it unwinds the target with cleanups, even when blocked. The caller then receives an `abandoned-mutex-exception` to swallow. `thread-terminate!` skips cleanups; never use it for quit ([ADR 3](../../../agents/adr/0003-command-loop-and-jobs.md)).
- Parameters (`parameterize`) are thread-scoped and inherited by child threads; Tuna's dynamic settings layer uses them ([ADR 9](../../../agents/adr/0009-settings-and-scoped-values.md)).
- Gambit rejects surrogate code points and invalid UTF-8; built-in codecs are ASCII, ISO-8859-1, UTF-8, UTF-16.
- Replaceable services use `:std/interface`.
- Tests are `*-test.ss` files exporting `*-test` suites (`:std/test`), run with `make test`.
