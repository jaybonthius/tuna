# ADR 0001: Controlled configuration trust and evaluation

Status: accepted — owner-chat-2026-08-05: accept-adr-set-and-start-slice-1

## Context

Tuna configuration must preserve the `CFG-01`, `CFG-02`, and `CFG-05` contract: read the complete file before effects, then expand and evaluate ordinary explicit imports and forms sequentially. Configuration is trusted arbitrary Racket code. “Controlled” describes its reader, namespace, ordering, diagnostics, and lifetime; it does not mean sandboxed, transactional, or safe for untrusted input.

The configuration namespace, installed host, and independently compiled extensions must share the authoritative Tuna module instance. A fresh module registry would split live definitions from compiled callers, while an ordinary module, `load`, or custom language would change failure ordering or the public file contract.

## Decision

`load-config!` will:

1. Normalize the source path, open it with line counting enabled, and read path-bearing syntax with `read-accept-reader`, `read-accept-lang`, and `read-accept-compiled` all disabled.
2. Read every top-level form before evaluating any form. A reader failure therefore applies no configuration forms.
3. Create an empty top level from a namespace anchor in the installed Tuna host, sharing its module registry, introduce ordinary `racket/base`, and retain the namespace for the application lifetime.
4. Evaluate retained forms in source order. Each form is wrapped as source-preserving `(#%top-interaction . form)` and passed to `eval`, so an explicit ordinary `require` affects later runtime bindings and transformers.
5. Preserve effects from forms completed before a later expansion or runtime failure. At the loader boundary, report the normalized path and active enclosing top-level form location, then re-raise the exact same raised value. Exact nested runtime-expression location is not promised.

Startup serializes configuration. There is no concurrent load protocol, rollback, unload, custom `#lang`, implicit Tuna language, module-form configuration, or sandbox claim.

## Rejected alternatives

- **Ordinary module plus `require`/`dynamic-require`:** module expansion precedes instantiation, so a later expansion failure prevents the required earlier runtime effects and makes a module language implicit policy.
- **Unadapted `load`:** evaluates before reading the whole file and enables reader/language/compiled inputs, violating the reader-failure boundary.
- **Bare `eval-syntax`:** lacks destination-namespace lexical enrichment. Explicit introduction could preserve behavior but adds phase bookkeeping without a demonstrated need; the selected `eval` route is smaller.
- **Fresh `make-base-namespace`:** creates a separate module registry and therefore a second Tuna live-registry instance.
- **Custom `#lang` or implicit prelude:** changes ordinary explicit-import configuration and runs language/reader policy before the selected boundary.
- **Sandboxing or transactional rollback:** would introduce a new security and persistence contract and cannot preserve trusted arbitrary effects and partial application.

## Consequences

### Behavioral and public

Configuration begins with ordinary Racket bindings and must explicitly import `tuna/prelude` or other installed modules. Later forms observe earlier imports and transformer replacement; already compiled code retains its earlier expansion. Reader failure has no form effects, while later expansion/runtime failure retains earlier effects and exact raised identity. Only enclosing-form source diagnostics are guaranteed.

### Security, lifecycle, and concurrency

Trusted configuration can perform arbitrary filesystem, network, process, thread, and other effects. Disabling reader extensions narrows accepted input modes but provides no authority isolation. The retained namespace owns top-level definitions, imports, and transformer state for the application lifetime. Serialized startup avoids shared-registry loading races; no concurrent `load-config!` behavior is supported.

## Validation obligations

Before acceptance of affected implementation, tests must prove normalized path sources, read-all/no-effects-on-reader-failure, sequential imports and effects, partial effects after expansion/runtime failure, local and imported transformer replacement, unchanged compiled expansions, exact raised-value identity, enclosing-form diagnostics without a nested-line claim, shared module-instance identity with compiled callers, ordinary installed value/transformer imports, and retained namespace behavior. Export and documentation review must reject sandbox, rollback, custom-language, or implicit-import claims.

## Traceability

- **Baseline IDs:** `CFG-01`, `CFG-02`, `CFG-04`, `CFG-05`, `LIVE-02`, `PKG-04`.
- **Matrix pattern IDs:** `CFG-01a`, `CFG-01b`, `CFG-01c`, `CFG-02a`, `CFG-02b`, `CFG-04a`, `CFG-05a`, `CFG-05b`, `CFG-05c`, `CFG-05d`, `LIVE-02`, `PKG-04`.
