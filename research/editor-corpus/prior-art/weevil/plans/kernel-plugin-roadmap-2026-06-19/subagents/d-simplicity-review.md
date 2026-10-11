# Simplicity review — extensible kernel + optional plugins direction

Reviewer pass: simplicity / overengineering / minimal next step.
Sources read: `ADR.md` (extensibility + trusted-config ADRs), `PLAN.md`
(Phase 1 / 1.5), `docs/racket-style.md`, `plans/architecture-review-2026-06-19/*`
(architecture, recommendations, emacs-comparison, implementation-plans),
current source layout (`weevil/*.rkt`, `weevil/private/*`,
`extension-point.rkt`, `config-loader.rkt`, `defaults.rkt`).

## Headline

The "extensible kernel" half of the proposal is **not new** — it is already the
shipped design and the ADR's stated architecture: a small private kernel, a
large stable public API (`weevil/config`, `commands`, `keymap`, `hooks`,
`modes`, `options`, ...), and built-in defaults (`weevil/defaults.rkt`)
registered *through that same public API*, loaded ahead of an optional user
`init.rkt` via `config-loader`. There is nothing to invent here; there is work
to *finish* (P0 semantic foundations).

The "optional plugins" half is the part that risks overengineering. **There is
no plugin system today, and ADR v1 explicitly lists "plugin package manager"
and "sandboxed third-party plugin system" as non-goals.** The only place
`use-plugin!` exists is as *aspirational examples in the style guide* — API
documented before any implementation or any second concrete plugin exists.
Treat "plugin" as a word to defer, not a system to build now.

## Where the direction is sound

- "Robust config fallback" is the right instinct: a missing/empty config dir
  and a missing `init.rkt` must be fine, and the editor must boot a complete
  default editor with no user config. The plan/ADR already specify this.
- "Small kernel, big public API, defaults-as-config" matches ADR verbatim
  ("Default editor behavior is loaded as configuration"). Keep it.
- `define-extension-point` (38 lines: boxed, contract-checked, late-bound
  provider with stable caller) is a *good* minimal seam. It is the correct
  shape for overridable providers (page template) and should be the ceiling of
  abstraction, not the floor of a larger framework.
- "No premature abstraction" is exactly the right constraint to apply *to the
  plugin idea itself*.

## Traps and overengineering risks

| # | Trap | Why it bites | Mitigation |
|---|------|-------------|------------|
| 1 | Building a plugin runtime (registry, `use-plugin!`, enable/disable, deps, ordering) in parallel with the already-working `defaults + init.rkt + public API` model | Two ways to extend, two failure modes, double the surface to keep stable — for zero current users | Do not add a plugin runtime. The extension system already exists; it is "require public modules + register". |
| 2 | Generalizing a plugin abstraction from **zero** factored plugins | The terminal — the obvious "first plugin" — is currently wired into core, not extracted. You cannot find the right plugin boundary from one hypothetical example. Needs >=2 real ones. | If validating plugins at all, *first extract* terminal as a thin `(use-plugin! 'terminal)` that only calls existing public registration APIs. If it won't extract cleanly, the boundary isn't ready — that is the signal, cheaply bought. |
| 3 | `#:on-fail 'warn` / skip-broken-plugin conflicting with the plan's "invalid `init.rkt` fails loudly with the file path" rule | Mixed failure semantics confuse users debugging their own trusted config | Decide policy explicitly (see decisions). Recommendation: user `init.rkt` = fail loud; only *optional third-party* plugins degrade — and that only matters once a plugin manager exists, i.e. not now. |
| 4 | Pre-creating extension points / hook / option registries "for future command/mode/UI lifecycle" (Phase 1.5 DoD hints at this) | Speculative seams with no caller are dead weight that look like API and ossify | Add an extension point only when a real internal caller needs to override. Keep the "minimal hook/option registries" genuinely minimal — no provider slots for features that don't exist. |
| 5 | Registering plugin/global state on the current process-global singletons (event loop, subscribers, side tables) | Entrenches the singleton the architecture review already flagged for the eventual session-object wrapper; makes multi-session harder | Don't grow new global registries for a plugin layer. If extension state must be added, prefer routing it toward the planned session/runtime object. |
| 6 | Renaming/relabeling toward "kernel/plugin" vocabulary | ADR already says "private editor kernel"; churn for no behavior change | Keep existing names; no rename pass. |

## Minimal next step (recommended)

**Do not build a plugin system. Finish the kernel foundations the existing
review already prioritized — they gate any richer extension surface, plugin or
not.** A "plugin" is meaningless until modes have lifecycle and buffers have
local state, because those are precisely what a plugin would manipulate.

Pick the single highest-leverage P0 item and ship it in small commits:

1. **Buffer-local options/variables** (`option-ref` resolves buffer-local ->
   global default; `set-buffer-local-option!` explicit). Modes, options, faces,
   cursor-type, and mode-line format all wait on this. This is the foundation
   the architecture review calls out and the cheapest enabler of real
   extensibility.
2. Then **command metadata** (name, docstring, category, interactive? flag) —
   needed for `M-x`, `describe-command`, palettes, and for any plugin to expose
   discoverable commands.

These are additive, reversible, and serve the "extensible kernel" goal directly
without introducing a new mechanism.

If the owner wants to *probe* the plugin direction cheaply: extract terminal as
a thin convenience wrapper (`use-plugin!` that just runs the same public
registrations `defaults.rkt` would). This is a packaging experiment, not a
runtime — and it surfaces whether the boundary is real before committing to a
lifecycle.

## Decisions the owner should make

1. **Is "plugin" a v1 concept at all?** ADR v1 says no plugin manager / no
   sandbox. Either (a) keep config + defaults + public API as the *only* v1
   extension model and demote `use-plugin!` style-guide examples to "future",
   or (b) define what a v1 "plugin" is. Pick one; the style guide and ADR
   currently disagree.
2. **Failure policy.** Fail-loud for `init.rkt` (user's own trusted file) vs
   degrade-and-warn for optional plugins. Write it down. Do not mix.
3. **If plugins are in scope: packaging-convenience or real lifecycle?**
   - Packaging convenience (thin wrapper over public API, `dynamic-require` by
     id): cheap, safe, can land later with little risk.
   - Real lifecycle (enable/disable/teardown/options/deps): blocked on modes
     lifecycle + buffer-local state + session-object wrapper. Don't start
     until those exist.
4. **Do P0 foundations gate the plugin concept?** Recommendation: **yes.** No
   plugin work until buffer-local + command metadata land.
5. **Where does extension state live given the process-global singleton?**
   Accept entrenchment now, or route new extension state through the planned
   session/runtime wrapper first.

## Notes

- `weevil/config.rkt` is 41 lines (a re-export aggregate) and `defaults.rkt` is
  338 lines of public-API registration — this is the healthy shape; defaults
  are config, not hardcoded core. Preserve it; resist moving default behavior
  into a "plugin runtime."
- `extension-point.rkt` is correctly **private** and ADR confirms
  `define-extension-point` is an implementation detail, not public API. Keep it
  that way; do not promote it into a public plugin-authoring primitive.
- Net: the cheapest, simplest path to "more extensible" is to finish the
  kernel's semantic foundations and keep "plugins" as a vocabulary you adopt
  later, only after >=2 concrete extractions prove the boundary.
