# 1. Plain Gerbil core with a thin `:tuna` prelude for packages

Status: accepted (2026-10-11)

## Context

Tuna must be extensible the way Emacs is: users and packages change behavior while the program runs, and ports of Emacs packages should feel mechanical. The previous Gerbil attempt achieved function-level redefinition by replacing `def` with a macro that routes every definition through an atom-backed live cell plus advice. That cost about 9% on a call microbenchmark, made expansion order observable (`ISSUES.org` in `tuna-old-2026-10`), and duplicated something the compiler already supports.

Gerbil emits `(declare (block))` for every module, which lets Gambit assume that a module's own globals are never mutated, so intra-module calls ignore an external `set!`. Gambit's `(declare (separate))` withdraws that assumption. A check on Gerbil `v0.19-dev-63` with `gxc -O` (2026-10-11) confirmed: under `block`, an external `set!` of an imported procedure changes external callers but not the module's own callers; under `separate`, both observe the replacement. Interpreted reload of a module (`import-module path #t #t`) re-evaluates all its definitions.

## Decision

- The core is written in ordinary Gerbil with `prelude: :gerbil/core`, typed signatures, `defclass`/`defstruct`, and `std/interface` for replaceable services.
- Packages (including Tuna's own default editing behavior) use a thin prelude, `:tuna/prelude`, usable as `#lang :tuna`. It re-exports `:gerbil/core` plus declarative forms such as `defcommand`, `defplugin`, `defcustom`, `defhook`, and `defkeymap`. Each form expands to an ordinary registration through a plugin context ([ADR 2](0002-plugins-contexts-and-services.md)). The prelude does **not** rewrite `def`.
- Modules intended to be redefined piecemeal are compiled with `(declare (separate))`; the prelude may emit it. Redefinition then works through ordinary `set!` from a REPL or `init.ss`, and whole-module reload works through Gerbil's loader.
- Emacs-shaped names (`point`, `insert`, `goto-char`, `save-excursion`, `define-key`, `add-hook`, `interactive`) are used where the semantics really match, to make porting mechanical. Where Tuna deliberately differs, it uses a different name.
- An Elisp compatibility layer or translator is out of scope for the core. It may become a separate package later.

## Consequences

- Core code gets full compiler optimization; only packages opting into `separate` pay for late binding.
- Function-level redefinition of core internals that are not exposed as services, commands, hooks, or `separate` modules is not supported. The intended extension points are services, commands, hooks, and advice on those.
- The surface syntax of `#lang :tuna` can evolve without changing semantics, because all forms lower to plain registrations.
- Full-program optimization combined with runtime `eval` failed in earlier research (`Unbound variable: __eval-import`). Treat FPO as unsupported for Tuna until re-verified.

## Alternatives considered

- **Every `def` is a live cell (previous attempt).** Rejected: measurable cost everywhere, surprising expansion semantics, and it solves redefinition at the wrong granularity.
- **A full `#lang tuna` with Elisp-like semantics (dynamic scope, symbol cells).** Rejected for now: high cost, fights Gerbil's module system, and is not needed to port packages by hand or with LLM assistance.
- **No prelude at all.** Rejected: registration boilerplate would leak plugin-context plumbing into every package.
