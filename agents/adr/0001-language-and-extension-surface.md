# 1. Plain Gerbil core with a thin `:tuna` prelude for packages

Status: accepted (2026-10-11); amended after the [capability audit](../research/capability-audit/README.md) (advice targets, dynamic binding).

## Context

Tuna must be extensible the way Emacs is: users and packages change behavior while the program runs, and ports of Emacs packages should feel mechanical. The previous Gerbil attempt achieved function-level redefinition by replacing `def` with a macro that routes every definition through an atom-backed live cell plus advice. That cost about 9% on a call microbenchmark, made expansion order observable (`ISSUES.org` in `tuna-old-2026-10`), and duplicated something the compiler already supports.

Gerbil emits `(declare (block))` for every module, which lets Gambit assume that a module's own globals are never mutated, so intra-module calls ignore an external `set!`. Gambit's `(declare (separate))` withdraws that assumption. A check on Gerbil `v0.19-dev-63` with `gxc -O` (2026-10-11) confirmed: under `block`, an external `set!` of an imported procedure changes external callers but not the module's own callers; under `separate`, both observe the replacement. Interpreted reload of a module (`import-module path #t #t`) re-evaluates all its definitions.

Emacs packages routinely advise arbitrary named functions of other packages, and `let`-bind special variables around calls. Gerbil parameters are thread-scoped dynamic bindings inherited by child threads, which gives the latter without changing Gerbil's lexical semantics.

## Decision

- The core is written in ordinary Gerbil with `prelude: :gerbil/core`, typed signatures, `defclass`/`defstruct`, and `std/interface` for replaceable services.
- Packages (including Tuna's own default editing behavior) use a thin prelude, `:tuna/prelude`, usable as `#lang :tuna`. It re-exports `:gerbil/core` plus declarative forms such as `defcommand`, `defplugin`, `defcustom`, `defhook`, and `keymap-set`. Each form expands to an ordinary registration through a plugin context ([ADR 2](0002-plugins-contexts-and-services.md)) that also records the definition's origin (plugin, source location, documentation). The prelude does **not** rewrite `def`.
- Package modules are compiled with `(declare (separate))` by default; the prelude emits it. Redefinition then works through ordinary `set!` from a REPL or `init.ss`, and whole-module reload works through Gerbil's loader.
- **Advice** can target commands, service methods, hooks, and any exported binding of a `separate` module, with Emacs's full combinator set (`before`, `after`, `around`, `override`, `filter-args`, `filter-return`, `before-while`, `before-until`, `after-while`, `after-until`). Core modules compiled with `block` are deliberately not advisable; their extension points are services and hooks. This is a documented divergence.
- **Temporary binding** of settings and command context (Emacs `let` on special variables) is provided by `with-settings`, built on Gerbil parameters ([ADR 9](0009-settings-and-scoped-values.md)). Gerbil itself stays lexically scoped.
- Emacs-shaped names (`point`, `insert`, `goto-char`, `save-excursion`, `keymap-set`, `add-hook`, `interactive`) are used where the semantics really match, to make porting mechanical. Where Tuna deliberately differs, it uses a different name or records the divergence in [`docs/emacs-equivalents.md`](../../docs/emacs-equivalents.md).
- An Elisp compatibility layer or translator is out of scope for the core. It may become a separate package later.

## Consequences

- Core code gets full compiler optimization; package code pays for late binding, which is what makes it redefinable and advisable.
- Emacs code that advises a primitive (for example `insert`) must instead hook the corresponding service or hook.
- The surface syntax of `#lang :tuna` can evolve without changing semantics, because all forms lower to plain registrations.
- Full-program optimization combined with runtime `eval` failed in earlier research (`Unbound variable: __eval-import`). Treat FPO as unsupported for Tuna until re-verified.

## Alternatives considered

- **Every `def` is a live cell (previous attempt).** Rejected: measurable cost everywhere, surprising expansion semantics, and it solves redefinition at the wrong granularity.
- **A full `#lang tuna` with Elisp-like semantics (global dynamic scope, symbol cells).** Rejected: high cost and fights Gerbil's module system. Parameters cover the dynamic-binding idiom where Emacs code needs it.
- **No prelude at all.** Rejected: registration boilerplate would leak plugin-context plumbing into every package.
