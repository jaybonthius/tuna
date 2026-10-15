# Plan: check declared service use when a plugin loads, not on every call

Owner decision 2026-10-14, after the independent review (`agents/research/code-review-2026-10-14.md`, Q2, option (b) moved to load time). Cause: the per-call check (Cordis stage 1) attributes each call to a plugin through an ambient `current-context`; every thread and callback boundary must re-scope it by hand; it crashed `M-x` on the Mac path (`3963901`) and has about 8 more unscoped sites.

## Decision

- **Where:** start-up code (`tuna/boot.ss` and the configuration library), when a configuration's plugins are loaded, at start-up, `reload-config` and `tuna check`, before any plugin turns on. Not the kernel.
- **Rule:** a plugin whose module (or a module of its own package that it imports) imports a contract module must declare that contract's service in `requires:`, `optional:` or `provides:`. A violation refuses that plugin, reported in the start-up report: "keys imports the settings contract but does not declare settings-service". Same rule for our packages and anyone's. The user's own `init.ss` code and `config:` blocks stay exempt.
- **Deleted:** per-call checking (`check-service-use!`), the context switch in service dispatch and its cache fields for attribution, `unchecked:`, attribution-only `context-bind`/`call-with-context` sites, and their tests. Dispatch becomes a plain cached lookup.
- **Kept:** ownership of registrations (receipts, explicit `ctx`, owner-tagged entries), implicit registration during activation (`current-context` there), commands cancelled with their plugin (`call-with-task-owner`'s receipt), the session owner owning evaluated code (explicit context in `evaluate`).
- **Also:** the keys plugin's `arrival` reads no settings (review cleanup item 1).
- **Record:** ADR 2 divergence (Cordis checks every access; Tuna checks at load), ADR 12 "Declared use" amended; primary agent.

## Acceptance

`make test` green; tests for the load-time rule (violation refused and reported, declared passes, user code exempt, third-party-style package checked the same way); starter and demo in a real browser, including `M-x`; dispatch benchmark at or below the old 133 ns.
