# Prior art: enforcing declared return types while keeping proper tail calls

Scope: how other Lisps/Schemes (and the gradual-typing literature) place return-type checks relative to tail calls, to guide a fix for Gerbil's `(Maybe T)` returns losing tail calls. Gerbil checkout `/home/jay/Code/workbench-gerbil/gerbil` @ `1c6c1538`.

## Summary

Every system that checks return types *and* guarantees tail calls uses one of three techniques: (1) prove the check redundant statically, so it is never emitted for a tail call; (2) keep the callee check but make it *tail-collapsible* (Racket's `tail-contract-key` continuation mark): a tail call into a callee carrying the same obligation skips the check, because an outer frame is already going to perform it; (3) put the check at module/language boundaries only. None accepts "wrap the body in a post-check" as the general mechanism for functions whose result type is already guaranteed by the callee. Gerbil's unchecked `:-` / checked `:` split is exactly technique (1)'s precondition, so the best fit is a *static* "the tail call's result is already known to satisfy the declared type" rule, with the check elided (not weakened) in that case.

## Observed facts in Gerbil (re-read at 1c6c1538)

- `src/gerbil/core/contract.ss:170-205`, module `TypeCast`, `return-contract`. For `(Maybe T)`: `(:? (begin-annotation (@type.return (nullable klass)) expr) base)` (line ~195), i.e. the body expression is wrapped by a checking form, so a call in tail position of `expr` is no longer in tail position. The `void` branch (lines 190-194) builds `(let (val expr) (if (or (not val) (predicate val)) val (contract-violation! ...)))` — same shape. Non-Maybe: `(: expr base)` or `(:- expr base)` (lines 183-184); `:-` expands to `(begin-annotation (@type klass) expr)` (line ~280-285), an annotation, no wrapper — tail calls survive.
- Callers of `return-contract` that decide this: lines 2374, 2502, 2586, 2600, 2604 (and interface dispatch at ~1989-2079).
- Parent-supplied measurement (not re-run by me): nullable self-recursion depth 10,000 → 10,011 frames vs ~11.

## Prior art, per system

Legend: where the check lives / tail calls survive? / optional types.

1. **Racket contracts (`->`, `->*`, `->i`)** — *Check in the callee wrapper, after return; tail calls survive via marks.* Direct evidence: `racket/collects/racket/contract/private/arrow-common.rkt` defines `tail-contract-key` and `check-tail-contract` (lines ~53-67): it does `call-with-immediate-continuation-mark tail-contract-key`; if the mark already holds a *matching or stronger* range contract for the same blame parties (`tail-marks-match?`, lines ~147-170, using `contract-struct-stronger?`), it calls the function **without** the range check, in tail position; otherwise it checks. Interpretation: the immediate caller frame is already responsible for the same (or stronger) obligation, so skipping is sound and space-bounded. `any` as range means no result check at all (Racket Reference §8.2 "Function Contracts": "If any is used as the last sub-form for ->, no contract checking is performed on the result"). Optional results are just `(or/c #f T)`; no special tail treatment. Racket CS relies on Chez continuation attachments for cheap marks (Flatt et al., ICFP'19; Chez PR #336).
2. **Typed Racket** — *Boundary only.* Deep types compile to contracts only where typed and untyped code meet; typed-to-typed calls are unchecked because the static checker proved them (Typed Racket Guide §6 and Reference §8, docs.racket-lang.org/ts-guide/typed-untyped-interaction.html, ts-reference/behavior-of-types.html). Where a contract does fire, it is the Racket mechanism above. Shallow/Optional modes check shapes locally or not at all. `Option`/`(U T #f)` is an ordinary union.
3. **Chez Scheme** — *No types; `optimize-level 3` removes primitive safety checks, not a type system.* Tail calls are always proper (R6RS). (Background knowledge from the Chez Scheme User's Guide; not re-fetched in this run.) Relevant only as the "unchecked = tail call survives" baseline.
4. **CHICKEN** — *Statically proven or trusted; no runtime check from `the`.* Manual: `(the TYPE EXPRESSION)` is "equivalent to EXPRESSION, but declares that the result will be of the given type"; `assume` is `(let ((v (the T v))) ...)` (wiki.call-cc.org/man/5/Types). The scrutinizer warns on provable mismatch; `-specialize` uses types to *remove* checks; `-strict-types` makes it more optimistic and "may result in unsafe code if type-declarations are violated". So `(the T (f x))` in tail position stays a tail call (it is an annotation) — this is the analogue of Gerbil's `:-`. Inference on that last point: from the documented "equivalent to EXPRESSION" wording; I did not inspect the generated C.
5. **SBCL/CMUCL** — *Check in the callee at the point of return, merged into tail calls when the compiler can prove it, otherwise trusted by policy.* SBCL manual §4.2.1: under default policy declarations "are asserted at runtime" unless "proven to always hold"; `sb-ext:truly-the` "declares the type ... the declaration is not checked" (the manual's own advice: "don't use it"). §5.3.4: the compiler is properly tail recursive; tail-frame elimination is a debug-policy matter. Practical note from library code: Serapeum's `require-type` uses a merge-tail-calls declaration to keep a type-check helper tail-recursive (github.com/ruricolist/serapeum/blob/master/types.lisp, indicative only). Result: SBCL's `the` on a call result is checked unless derivable from the callee's known ftype, and a checked `the` around a call does cost tail position; SBCL relies on type derivation (callee ftype) to delete the check. Support for the last sentence: interpretation of manual + compiler design, not a quote.
6. **Typed Clojure / core.typed** — *Static only by default.* Annotations are checked at compile/check time and erased; JVM has no TCO anyway (`recur` is the only guaranteed form). Not informative for Gerbil beyond "static typing needs no runtime check". Not verified against primary docs in this run (low confidence).
7. **Gambit** — *Declarations are trusted assumptions.* `(declare (not safe))`, `fixnum`, etc. change code generation and delete checks; `proper-tail-calls` is on by default (manual, gambitscheme.org/latest/manual/). No return-type checking. Gerbil's `:-` maps onto this layer.
8. **Literature.**
   - Herman, Tomb, Flanagan, "Space-efficient gradual typing" (HOSC 2010; users.soe.ucsc.edu/~cormac/papers/hosc2010.pdf): function-type enforcement by proxies grows without bound and "destroys tail recursion"; fix is coercions that are *merged* (normalized) so only a bounded number accumulate.
   - Siek & Wadler, "Threesomes, with and without blame" (2010): bounded-size merged casts; same goal, same conclusion. (From memory of the paper; not re-fetched.)
   - Greenberg, "Space-efficient manifest contracts" (POPL 2015, arXiv:1410.2813): "The standard algorithm for higher-order contract checking can lead to unbounded space consumption and can destroy tail recursion"; solves it for predicate contracts by merging pending checks.
   - Common conclusion (direct from abstracts): a naive post-return check is the *standard* way to break space safety; the cure is to avoid stacking identical obligations, not to drop them.

## Comparison

| System | Check lives | Tail call survives? | Optional/nullable |
|---|---|---|---|
| Racket `->` | callee wrapper | yes, via `tail-contract-key` mark merge | `(or/c #f T)`, no special case |
| Typed Racket | boundary only | yes (typed↔typed unchecked) | union |
| Chez | none | yes | n/a |
| CHICKEN `the` | statically proven / trusted | yes | `(or T false)` annotation only |
| SBCL `the` | callee, elided if derivable | yes only when check elided/proved | `(or null T)` ordinary |
| Gambit | trusted declarations | yes | n/a |
| Gerbil `:-` | trusted annotation | yes | — |
| Gerbil `Maybe` today | callee, after return, always | **no** | the broken case |

## General principle (inference from the above)

Return-type enforcement must be *tail-transparent*: a tail call to a callee that already guarantees (or will itself check) the same-or-stronger result type must not be wrapped in a post-check. Either prove it statically, or let the callee carry the obligation. A check may wrap only expressions whose result type is not otherwise guaranteed (literals, primitive/unchecked calls, untyped calls), where the check is a genuine safety need and cannot be avoided.

## Recommended fix

Closest match to Gerbil's existing `:`/`:-` split is the **static/boundary** design (Typed Racket/CHICKEN/SBCL-derivation), not Racket's runtime marks (too heavy, needs new runtime machinery in Gambit):

1. In `return-contract` for Maybe (lines ~186-195), walk the body's *tail positions* (through `begin`, `if`, `cond`, `let`, `case`, `when`…; the expander already has this in typed-definition code if available — verify). For each tail position:
   - tail call whose callee is statically known (same module or imported with a recorded signature) to return `(Maybe U)` or `U` with `U` a subtype of `T`, and which is itself checked at its own definition: emit it **unwrapped** (annotated `@type.return`, like `:-`), preserving the tail call;
   - anything else (literals, unknown/untyped/dynamic calls, interface dispatch through an unchecked wrapper — the case the comment names): keep `:?`; in tail position of a non-self call this loses the tail call, but it is a real check, and only in non-provable cases.
2. Interface-dispatch wrappers already check on the caller side (lines ~1989-2079 call `return-contract` with `#t/#f` flag); keep that, since it is the reason the comment says Maybe "always checks". Elide only when the callee's checkedness is certain.
3. Add regression tests: depth-100k mutual and self recursion with `(Maybe T)` returns finishing in bounded stack, plus negative tests that a Maybe function returning a wrong-type value from a non-provable tail call still raises.

Fallback if the compiler lacks per-callee signature info: a Racket-style *contract mark* is the only fully general runtime answer, but it changes the runtime and is unlikely to be upstream-acceptable for a language feature at this stage.

## Risks

- Soundness of elision depends on the callee's checkedness being real: `:-`-returning or `(declare (not safe))` callees must not count as proofs. Only callees whose own `return-contract` is checked (or `:`) qualify.
- Mutual recursion across modules / redefinition (`set!`, hot reload, REPL redefinition) can invalidate a static signature; limit elision to bindings the expander knows are immutable, or the pattern is unsound.
- The "adapts" half of the Maybe check (the `contract.ss:176` comment mentions adaptation of non-false results) may convert values, not just test them; if so, elision must apply only when no adaptation is needed. I did not trace what adaptation exists beyond `:?`.
- Subtyping: elision requires callee result ⊆ declared result; `(Maybe U)` with U ≠ T must still check.
- Typed Clojure, Chez, and Siek–Wadler entries rest on background knowledge, not fetched primary sources this run; they do not affect the recommendation.

## Sources

- Racket: https://github.com/racket/racket/blob/master/racket/collects/racket/contract/private/arrow-common.rkt (read: `tail-contract-key`, `tail-marks-match?`); https://docs.racket-lang.org/reference/function-contracts.html; https://docs.racket-lang.org/ts-guide/typed-untyped-interaction.html; https://docs.racket-lang.org/ts-reference/behavior-of-types.html; https://users.cs.utah.edu/plt/publications/icfp19-fddkmstz.pdf; https://github.com/cisco/ChezScheme/pull/336
- CHICKEN: https://wiki.call-cc.org/man/5/Types
- SBCL: https://www.sbcl.org/manual/ (§4.2.1, §5.3.4, `truly-the`)
- Gambit: https://www.gambitscheme.org/latest/manual/
- Herman/Tomb/Flanagan: https://users.soe.ucsc.edu/~cormac/papers/hosc2010.pdf; Greenberg: https://arxiv.org/abs/1410.2813
- Gerbil: `src/gerbil/core/contract.ss` @ 1c6c1538 lines 170-205, ~280-285, 1989-2079, 2374-2604.
