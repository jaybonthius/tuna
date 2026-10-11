# Tuna live-extensibility research-program charter

Status: draft  
Oracle approval: pending  
Owner approval: pending

## Purpose

Develop the evidence and decisions for a clean-break, Emacs-inspired but Racket-native live-extensibility architecture for Tuna. The result should make trusted installed Racket packages able to extend a small, generic Tuna runtime without importing Emacs's editor object model or turning core into a catch-all plugin framework.

This charter is the restart point for the architect workflow. It is not the architecture, an implementation plan, or approval to modify Tuna.

## Settled inputs

These are program constraints supplied by the owner, not approval of a later design:

1. **Clean break:** compatibility with the current Tuna API, profiler API, package topology, or configuration surface is not required. No shim or migration design is required.
2. **Trust boundary:** extensions are trusted, in-process, installed Racket packages. Sandboxing and out-of-process isolation are not the design center.
3. **Live lifecycle:** a running host must support explicit package activation and deactivation. Loading a module, activating an extension, deactivating it, and unloading code are distinct operations.
4. **Generation rule:** future calls observe the newly committed generation; a call already in flight retains the generation it entered. Treat this as the working concurrency contract unless later evidence demonstrates that it is unsafe or incoherent; any rejection must be recorded as an owner decision before design proceeds.
5. **Profiler role:** the profiler is a later acceptance case for the selected generic architecture, not a design source or precedent. Core seams must first be justified generically and by materially different packages.

## Scope

The program may research and specify:

- stable Racket-native live definitions and coherent generation publication;
- distinct contracts for replacement, advice/gates, advisory observation, keyed contribution, and owned services;
- registration identity, ordering, introspection, duplicate policy, redefinition, revocation, and stale-handle behavior;
- running-host activation/deactivation, partial-activation rollback, resource ownership, drain/join, and deterministic failure handling;
- command, publication, rendering, delivery, transport, input-source, and page/route seams only where package use cases establish a generic need;
- concurrency semantics, reentrancy, callback authority, failure isolation, boundedness, and performance evaluation;
- package absence, independent composition, and optional-package dependency direction;
- Architecture Decision Record (ADR) impact where accepted Tuna decisions must be superseded.

Tuna core must remain limited to generic transport, failure, redefinition, publication, and lifecycle mechanics over opaque application state. Installed packages retain state shapes, commands, input semantics, renderers, layouts, documents, text stores, editor behavior, and other domain policy.

## Non-goals

- Implementing or editing Tuna source, tests, package metadata, or accepted ADRs during this charter/research stage.
- Preserving compatibility or designing deprecation shims.
- Designing profiler spans, trees, routes, selectors, or status policy into core.
- Selecting a final API in this charter.
- Defining an editor object model or adding a generic extension map to opaque application state.
- Promising Racket module/code unloading; explicit deactivation and resource cleanup are required, but unload is separate.
- Building a package manager, sandbox, distributed plugin protocol, or general-purpose web framework without independently established need.

## Public acceptance seam

The highest eventual behavior seam is an independently installed package used from trusted configuration against a running Tuna host: it activates through public generic interfaces, composes with an unrelated package, can be redefined and deactivated without stale cleanup damaging a newer generation, and leaves all owned work and resources terminal. A call already entered remains coherent on its acquired generation; the next call sees the replacement.

Core must also install, start, accept commands, publish/render opaque state, and stop with every optional package—including the profiler—absent. Profiler extraction and behavior are evaluated only after the generic seam passes non-profiler cases.

## Artifact map

All durable program artifacts live beneath this directory.

- `README.md` — this charter and current program status.
- `research/` — cited observations, alternatives, risks, and experiment proposals; research files are evidence, not decisions.
- `spikes/` — bounded hypothesis protocols and results. Any executable spike requires a separately authorized writer and checkout scope; this directory records the protocol and evidence, not standing permission to edit Tuna.
- `design/` — cross-report synthesis, materially different architecture alternatives, trade-offs, and `decision-log.md`.
- `reviews/` — independent Oracle verdicts, acceptance reviews, and responses. Reviews do not grant owner approval.
- `spec/README.md` — eventual behavior specification and implementation plan after research and decisions converge; it must state public acceptance behavior, dependency order, validation, risks, and independently useful slices.

No progress ledgers, locks, claims, or placeholder artifacts are part of this program.

## Current research set

The five parallel reports are complete as research inputs and await cross-report synthesis and review:

- `/home/jay/Code/workbench-racket/plans/tuna-live-extensibility/research/tuna-control-surface-inventory.md`
- `/home/jay/Code/workbench-racket/plans/tuna-live-extensibility/research/emacs-extension-architecture.md`
- `/home/jay/Code/workbench-racket/plans/tuna-live-extensibility/research/racket-mechanism-landscape.md`
- `/home/jay/Code/workbench-racket/plans/tuna-live-extensibility/research/package-use-case-matrix.md`
- `/home/jay/Code/workbench-racket/plans/tuna-live-extensibility/research/performance-evaluation-program.md`

Prior profiler evidence remains an input with a narrower role:

- `/home/jay/Code/workbench-racket/docs/tuna/profiler-extraction-research.md`

## Writer and safety rules

- There is exactly one writer per checkout. Parallel research and review are read-only.
- Only an owner-authorized writer may modify a named artifact or implementation scope. This charter authorizes no Tuna source, test, configuration, package, ADR, or Git-state change.
- Never stage, commit, switch, merge, rebase, reset, stash, clean, mutate worktrees/remotes, or delete user work.
- Derive Racket commands, collection paths, and test boundaries from repository evidence. Do not install/update packages or run setup without explicit authorization.
- No foreground REPL, watcher, server, unbounded process, unsafe kill command, or orphan worker. Spikes use deterministic synchronization and explicit time bounds; real server/process tests require separate evidence and authorization.
- Installed-package proofs use an explicitly authorized isolated package environment, never the normal user package environment.
- Do not execute extension callbacks while holding structural registry/runtime locks; any candidate that requires this fails its spike gate.

## Evidence and review gates

1. **Research synthesis:** reconcile the five reports and the profiler extraction evidence. Separate observed facts, inferences, proposals, and owner decisions. Surface contradictions rather than averaging them away.
2. **Alternative comparison:** compare materially different foundations and public seam shapes, including at minimum lexical stable cells versus module-redeclaration approaches; explicit hook families versus general advice; exact routes/prefix mounts versus route-less auxiliary publication; and lifecycle stack/stages versus dependency graphs where relevant. Reject speculative abstractions unsupported by at least two materially different package cases.
3. **Bounded spikes:** test the smallest private mechanisms needed to resolve hard uncertainties: coherent generation pinning, owned replacement and stale revocation, advice/redefinition if still justified, running-host activation/deactivation, failure/cleanup, command observation, and any selected web composition seam. Correctness failures stop performance evaluation.
4. **Performance evidence:** benchmark only candidates that pass behavior spikes. Record runtime/environment identity, bounds, raw results, allocation, contention, and variability. Relative measurements do not become pass/fail budgets without an owner-set budget.
5. **Draft specification:** define the smallest public interfaces and acceptance behaviors, package/core dependency direction, failure and concurrency contracts, lifecycle order, validation commands derived from repository evidence, migration non-requirement, and ADR consequences. The profiler appears only as a later acceptance case.
6. **Independent review:** obtain an actual Oracle verdict on the complete draft and record it under `reviews/`. Resolve blockers with evidence. Any substantive revision resets Oracle approval and owner approval to pending.
7. **Owner approval:** implementation may begin only after the owner explicitly approves the reviewed specification and both approval references are recorded. Do not infer approval from settled inputs, research completion, or review participation.

An ADR is justified for any accepted hard-to-reverse public architecture or for superseding existing lifecycle, package-topology, or web-boundary decisions. No ADR is selected or approved by this charter.

## Decision log format

Record decisions in `design/decision-log.md` as append-only entries during synthesis:

```text
D-NNN — Short title
Date: YYYY-MM-DD
Status: proposed | settled | rejected | superseded
Authority: owner | evidence-gate | specification
Question: the exact decision being resolved
Decision: concise behavior, or “none” while proposed
Rationale: why this option fits the goal and constraints
Alternatives: materially different options considered
Evidence: repository paths, primary sources, and spike/review references
Consequences: public behavior, risks, follow-up, and ADR impact
Supersedes: decision IDs or “none”
```

Only an explicit owner relay may mark a product, API, security, persistence, architecture, or scope choice `settled`. Evidence may reject a mechanism at a predefined gate but does not silently make product policy.

## Current status

- Charter: draft.
- Parallel research: five reports complete; synthesis not yet recorded.
- Spikes: not authorized or run by this charter.
- Architecture/design: not selected.
- Specification: not drafted.
- Oracle approval: pending.
- Owner approval: pending.
- Implementation: not authorized.
