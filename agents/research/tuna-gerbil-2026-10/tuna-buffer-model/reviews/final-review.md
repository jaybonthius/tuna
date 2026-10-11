## Review

**Resolved: both previous P1 findings. No remaining proposal blockers in this focused recheck.**

- **Correct — overlay relocation:** §11, `spec.md:214–218`, now defines crossed-endpoint collapse to the smaller mapped position, verifies `(2,0) -> [0,0)`, and gives zero-width overlays one affinity or explicit insertion expansion. These policies sit above §8 anchor mapping without contradicting it. §24 includes the crossed replacement and subsequent point-insertion cases (`spec.md:417`).
- **Correct — uncertain input:** §20, `spec.md:336–346`, now distinguishes a projection from a completed resynchronization fence. Mutex-ordered epoch rotation rejects late old-epoch requests; disabled admission and the owner fence settle previously admitted intents before resumption. The completion marker persists under coalescing, including later projections of that epoch. This resolves the delayed-command counterexample without independent mirror state or replay guarantees. §24 covers fencing and retained markers (`spec.md:424`).
- **Correct — related clarifications:** Copied text becomes an unassociated draft (§5, `spec.md:122`); LF/code-point columns are explicit (§6, `spec.md:136`); typed versus programmatic inheritance and preceding sticky-value precedence are specified (§10, `spec.md:204`); content undo does not rewind disk baselines (§15, `spec.md:266`). No consequential contradiction found in these corrections.

No issues found.

- **Merge verdict: OK** for the focused proposal recheck. Implementation remains outside this review and requires separate authorization.