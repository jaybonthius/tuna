# 1. Typed Gerbil core and open Tuna package functions

Status: accepted (2026-10-11); amended 2026-10-15 after the approved [hooks-and-advice brief](../../docs/briefs/2026-10-hooks-and-advice.md). Open functions and function advice are built; command/service targets and the inspection command are next.

## Context

Tuna must be extensible the way Emacs is: users, configuration and packages can change package functions while the program runs, including private helpers. The previous Gerbil attempt used an atom-backed live-cell framework with observable expansion order and about 9% overhead in a call microbenchmark (`ISSUES.org` in `tuna-old-2026-10`). We initially rejected rewriting `def` and relied on `(declare (separate))` instead.

That original experiment covered untyped functions. Later compiled probes showed that Gerbil's optimized typed callers can bypass a replaced binding even under `separate`. Three [spikes](../research/hooks-advice/) proved a smaller alternative using documented macros and a private procedure cell, with stable names and working target-only recompilation. The owner approved open-by-default package functions, keeping Gerbil modules and privacy rather than introducing Emacs's global namespace.

Emacs packages routinely advise arbitrary named functions of other packages, and `let`-bind special variables around calls. Gerbil parameters are thread-scoped dynamic bindings inherited by child threads, which gives the latter without changing Gerbil's lexical semantics.

## Decision

- The core is written in ordinary Gerbil with `prelude: :gerbil/core`, typed signatures, `defclass`/`defstruct`, and `std/interface` for replaceable services.
- Packages use `#lang :tuna/prelude`, which re-exports Gerbil core plus `defplugin`, open procedure forms and redefinition. Editor forms such as `defcommand` and `keymap-set` come from their own contracts, not the prelude.
- Top-level procedure `def`, literal `lambda`/`case-lambda` definitions and `def*` are open: a typed entry point reads the current implementation from a private cell. Compiled and previously saved callers see replacements. `def/closed` keeps ordinary Gerbil definitions for measured hot spots. Local definitions, values, methods and structs are unchanged; foreign macros retain their lexical definition forms.
- `open-definition` reads the current implementation; `install-open!`, `set!` on an open identifier, and `redefine` replace it through the defining module's typed installer. Syntax metadata uses Gerbil's documented `setq-macro` role and `syntax-local-value`; no runtime registry or compiler-generated bindings are mutated. Replacement procedures must honor the original signature. The prelude retains `(declare (separate))`, but it is not what makes typed redefinition work.
- Exports still control normal imports. Private open functions can be reached by module-context evaluation, using `import-module`, `current-expander-context` and `eval` as Gerbil's documented `enter!` does. This does not duplicate module state. A plain `def` in that context conflicts with the existing open binding; future `eval-defun` must use `redefine`.
- **Advice** uses one `advise!` with function, command and service-operation targets and ten combinators (`before`, `after`, `around`, `override`, `filter-args`, `filter-return`, `before-while`, `before-until`, `after-while`, `after-until`). Function targets are built, including private open functions. Command/service targets and the inspection command are approved but not built yet. Kernel procedures, ordinary Gerbil libraries and `def/closed` functions are excluded; their extension points are hooks and services. Hooks remain notifications, not advice targets. Ownership and removal follow [ADR 2](0002-plugins-contexts-and-services.md).
- **Temporary binding** of settings and command context (Emacs `let` on special variables) is provided by `with-settings`, built on Gerbil parameters ([ADR 9](0009-settings-and-scoped-values.md)). Gerbil itself stays lexically scoped.
- Emacs-shaped names (`point`, `insert`, `goto-char`, `save-excursion`, `keymap-set`, `add-hook`, `interactive`) are used where the semantics really match, to make porting mechanical. Where Tuna deliberately differs, it uses a different name or records the divergence in [`docs/emacs-equivalents.md`](../../docs/emacs-equivalents.md).
- An Elisp compatibility layer or translator is out of scope for the core. It may become a separate package later.

## Consequences

- Core code keeps normal optimization; open package calls pay for a cell read and indirect call. Stage-1 paired CPU measurements found about +0.95 microseconds per self-insert and +0.34 microseconds per movement key, not zero overhead; unchanged-redraw ranges overlapped. The clean-build median increased 10.4%. Tests and repeated configuration evaluation also cost more. Evidence: `agents/research/hooks-advice/stage-1.md`.
- Gerbil's existing `(Maybe T)` return checks already prevent proper tail recursion in those functions; open entry points add two frames per recursive level. The upstream issue is deferred in `TODO.md`, not worked around by weakening checks.
- Tooling sees syntax metadata rather than an ordinary function binding. Runtime names and source locations were checked; language-server go-to-definition remains unverified because the available server could not build.
- Emacs code that advises a primitive (for example `insert`) must instead hook the corresponding service or hook.
- The surface syntax of `#lang :tuna` can evolve without changing semantics, because all forms lower to plain registrations.
- Full-program optimization combined with runtime `eval` failed in earlier research (`Unbound variable: __eval-import`). Treat FPO as unsupported for Tuna until re-verified.

## Alternatives considered

- **Open only explicitly declared functions.** Rejected by the owner as the default because it limits Emacs-like customization of other packages' helpers. It remains the owner-approved fallback if open-by-default proves complicated or unidiomatic.
- **The previous live-cell framework.** Not reused. The current mechanism is a small typed entry point and private cell, with compile-time metadata rather than atom registries or marker-token calls.
- **A full `#lang tuna` with Elisp-like semantics (global dynamic scope, symbol cells).** Rejected: high cost and fights Gerbil's module system. Parameters cover the dynamic-binding idiom where Emacs code needs it.
- **No prelude at all.** Rejected: registration boilerplate would leak plugin-context plumbing into every package.
