# Tuna capability audit: shared brief for research lanes

You are one of five parallel, **read-only** research lanes. Do not edit, create, or delete any file except the single output file your parent binds for you. Do not modify `/home/jay/Code/workbench-gerbil/tuna` or the Emacs checkout. Do not run Git commands that change state.

## Goal

Tuna is a new Emacs-like computing environment written in Gerbil Scheme, rendered in the browser. The owner wants "pretty much anything in Emacs" to be possible eventually, plus things Emacs lacks, without literally cloning Emacs. Before building the first prototype, we must check that the **current architecture decisions do not paint us into a corner**.

Your lane audits one slice of capabilities. For each capability, decide whether the current architecture already allows it, needs later design but fits, or is blocked/made painful by a current decision (a **corner risk**). Also record where Tuna could do **better than Emacs** (a proposed **divergence**), and record the **Emacs equivalent** for each Tuna concept you discuss, because the owner wants equivalences documented.

Divergence from Emacs is welcome whenever it is an improvement, but every divergence must be explicit, justified, and note what it costs when porting Emacs packages.

## Read first (required)

1. `/home/jay/Code/workbench-gerbil/tuna/docs/overview.md` — plain-language architecture.
2. `/home/jay/Code/workbench-gerbil/tuna/agents/adr/0001` through `0007` — the decisions you are auditing.
3. Skim `/home/jay/Code/workbench-gerbil/tuna/agents/research/README.md` and use prior research when relevant (verify, do not trust blindly).

## Evidence

- GNU Emacs source checkout: `/home/jay/Code/emacs` at commit `541f693ca2e8de166cfe52c39bbfc497142215e9` (installed Emacs is 30.2). The Elisp manual sources are in `doc/lispref/*.texi`; the user manual in `doc/emacs/`. Codebase-memory project for structural search: `home-jay-Code-emacs` (cbm_* tools). Prefer the manual for contracts and source for mechanism.
- Installed Emacs packages for real-world usage: `/home/jay/.config/emacs/var/elpaca/sources/` (includes magit, meow, and others).
- Gerbil v0.19 source/docs: `/home/jay/Code/workbench-gerbil/gerbil` (docs under `doc/`; Gambit manual at `src/gambit/doc/gambit.txi`). Installed toolchain `/opt/gerbil`.
- Web search/fetch is available for external facts (browser APIs, prior art). Cite URLs.

Cite every non-obvious claim (manual node or `file:line`, or URL). Distinguish fact from inference. Do not pad; prefer one precise row over three vague ones.

## Output format (Markdown, in this order)

```
# <Lane title>

## Summary
At most 10 bullets: the most important corner risks first, then the best improvement opportunities.

## Inventory
| # | Capability | Emacs mechanism / equivalent | Relied on by | Tuna today (ADR) | Status | Notes |
Status is exactly one of: covered, later, corner-risk, divergence.
- covered: the ADRs already allow it with no change.
- later: fits the architecture; just needs design when built.
- corner-risk: a current ADR blocks it or makes it needlessly hard.
- divergence: you propose Tuna deliberately do it differently from Emacs.
Aim for completeness over prose: dozens of rows is expected.

## Corner risks
For each: the capability, which ADR and which sentence causes the risk, a concrete scenario that breaks, and the smallest change to the decision that keeps the door open (not a full design).

## Proposed divergences (improvements over Emacs)
For each: what Emacs does, what Tuna could do instead, why it's better, cost, and the porting impact on Emacs packages.

## Emacs equivalence notes
Tuna term ↔ Emacs term mappings discovered in this lane, including near-misses where the names match but the semantics differ.

## Open questions for the owner
Only genuine product decisions that evidence cannot settle. Include context, options, and your recommendation.

## Sources
```

Keep the whole report under about 25,000 words. Finish with a complete report even if some areas get shallower coverage; say which areas were shallow.
