# Gerbil nullable returns: remove proven-redundant adapters, not contracts

**Recommendation:** optimize away the **whole return adapter** when the underlying expression already guarantees the nullable result. Do not make unchecked nullable results universally trusted. Existing `Maybe` contracts deliberately reject bad class results and convert raw interface implementations; those guarantees are tested.

**Evidence labels:** **Observed** means source inspection or an experiment below; **Documented** means an upstream statement; **Inference** means a proposed change, not a verified patch. Source citations are relative to `/home/jay/Code/workbench-gerbil/gerbil` at **`1c6c15385979f0092574fbc2b828f3fb656319b3`**, unless another commit is named. Installed compiler: **`v0.19-dev-63-g1cfb032c`**, Gambit **`v4.9.8-19-gea114fc3`**. `git diff 1c6c1538 1cfb032c -- src/gerbil/core/contract.ss src/gerbil/compiler/optimize-{call,top,base,ann}.ss` is empty: the relevant implementation matches. No Gerbil or Tuna implementation was changed.

## 1. What actually expands and compiles

**Observed:** core exports `def/c` as `def`, and `lambda/c` as `lambda` (`src/gerbil/core.ss:28–45`). Return parsing normalizes nested `(Maybe T)` to `(nullable T::t)` (`src/gerbil/core/contract.ss:145–161`).

- A `def` with contracted arguments generates a checked `f`, unchecked **`__f`**, and direct-call macro `@f` (`contract.ss:2458–2550`). There is no literal `__typed` name in this implementation. `f` checks/converts arguments then calls `__f`; `@f` performs the corresponding checks inline. A signature records `unchecked: __f`; the optimizer selects it only when argument proofs succeed (`src/gerbil/compiler/optimize-call.ss:189–220`). “Unchecked” concerns argument entry, not permission to return anything.
- `__f` wraps its body with `@type`, `@type.return`, and **two-argument** `return-contract`; `with-procedure-signature` adds another return adapter. The checked wrapper gets another through its signature (`contract.ss:2489–2531,2596–2626`). Consequently the generated nullable body can contain duplicate result checks. Return-only definitions and lambdas get a signature/adapter without a separate unchecked entry (`contract.ss:2552–2560,2628–2634`).
- `return-contract expr T` is **identity for ordinary T**, but checks/adapts `Maybe T`. The three-argument version uses `:` when `checked?` is true and `:-` when false **only for ordinary T**; Maybe ignores that flag (`contract.ss:174–199`). `definline` calls it with true. Interface checked dispatch uses true under `__DEBUG`, false otherwise; unchecked dispatch always passes false, in both direct macros and first-class wrappers (`contract.ss:1975–2081,2576–2586`). Interface extension bodies use the two-argument path (`contract.ss:2364–2382`). Thus changing only the false-flag branch would not repair ordinary nullable recursion.

**Observed optimizer behavior:** type collection/refinement reaches a fixed point, then verifies returns, then optimizes annotations and calls (`src/gerbil/compiler/optimize.ss:163–187`). Call result types come from procedure signatures, including imported signatures (`optimize-top.ss:623–644,939–962`). Nullable types have explicit subtype rules: false and T inhabit nullable T; nullable T does not prove T (`optimize-base.ss:345–368`). Branch joins retain nullability; stable truthy locals narrow to T (`optimize-top.ss:340–363,770–826`).

`@type.return` checks pre-adaptation body evidence, allowing unknown/overlapping results to retain runtime checks. `@type.signature` verification demands a provable subtype, except top/ordinary void (`optimize-call.ss:750–805`). Existing predicate and cast optimizers remove individually proven tests/conversions (`optimize-call.ss:154–174,226–281`), **not the nullable adapter as a unit**. Generated code below retains its result-binding continuation.

## 2. Why checks and interface adaptation exist; ordinary-return safety

**Documented:** `src/gerbil/compiler/nullable-types.md:79–93` explicitly promises validation of nonfalse class results, interface adaptation, and runtime checking of unknown/overlapping results. This is not merely missing optimizer metadata.

**Observed:** class `:?` checks `(or (not val) (predicate val))`; interface `:?` preserves false and invokes the interface constructor on other values (`contract.ss:249–275`). The local syntax variable `cast-it` resolves to that constructor, not a no-op assertion. It calls runtime `cast`, which returns an already-exact interface view unchanged, otherwise finds/builds a method prototype and copies a view containing the underlying object; incompatible objects raise (`contract.ss:1926–1939`; `src/gerbil/runtime/interface.ss:153–215`). A raw implementing object is **not** already the interface-view representation.

Runtime work is necessary for an unknown class value, overlapping nullable types, or a raw implementation needing an interface view. It is redundant for a proven compatible class-or-false result, false itself, or a proven exact target view-or-false. `(Maybe :void)` needs its explicit void-or-false test; ordinary `=> :void` means unspecified result. `(Maybe :t)` needs no value test (`contract.ss:191–198,257–265`).

**Observed, important correction:** ordinary typed returns are **not uniformly verified body proofs**. The typed `__f` path asserts its return using `@type`; `@type.return` intentionally preserves ordinary assertions unless the underlying evidence is nullable (`optimize-call.ss:761–765`). Experiments:

- `(def (f (x : :t)) => :fixnum x)` compiled and returned `"wrong"` when called indirectly.
- Even `(def (f (x : :string)) => :fixnum x)` compiled.
- `(def (f x) => :fixnum x)` failed compilation: `cannot verify procedure return type; no type information`.
- The corresponding typed `(Maybe :fixnum)` procedure rejected `"wrong"` at runtime.

Therefore replacing nullable contracts with ordinary unchecked assertions would **weaken existing safety**, not merely restore parity. `:-` itself is explicitly annotation-only and accepts only an identifier (`contract.ss:279–285`).

## 3. Standalone reproduction

**Observed:** this source has no Tuna dependency. Saved as `/home/jay/Code/workbench-gerbil/scratch/maybe-tail/gerbil-repro.ss`; its `main` additionally runs the safety probe above.

```scheme
prelude: :gerbil/core
(export main)
(def (trace-now) => :string
  (:- (continuation-capture
        (lambda (k)
          (let (port (open-output-string))
            (display-continuation-backtrace k port 0 0 0 1000000 0)
            (get-output-string port)))) :string))
(def (frame-count (trace : :string)) => :fixnum
  (let loop ((i 0) (count 0))
    (if (fx< i (string-length trace))
      (loop (fx1+ i)
            (if (char=? (string-ref trace i) #\newline) (fx1+ count) count))
      count)))
(def (plain (n : :fixnum)) => :string
  (if (fxzero? n) (trace-now) (plain (fx1- n))))
(def (nullable (n : :fixnum)) => (Maybe :string)
  (if (fxzero? n) (trace-now) (nullable (fx1- n))))
(def (return-only n) => (Maybe :string)
  (if (fxzero? n) (trace-now) (return-only (fx1- n))))
(def (main)
  (for-each
    (lambda (spec)
      (displayln (car spec) ": "
        (map (lambda (n) (frame-count ((cdr spec) n))) '(1 10000))))
    (list (cons 'plain plain) (cons 'nullable nullable)
          (cons 'return-only return-only))))
```

Every Gerbil command ran with this prefix:

```sh
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 600
```

From the scratch directory, expand with `/opt/gerbil/bin/gxi -e '(import :gerbil/expander) (import-module "gerbil-repro.ss")'`, compile with `/opt/gerbil/bin/gxc -O -d . gerbil-repro.ss`, then run `/opt/gerbil/bin/gxi -e '(import "gerbil-repro") (main)'` (prefix each command). Balance and expansion passed.

| Procedure | Frames, depth 1 | Frames, depth 10,000 |
|---|---:|---:|
| Ordinary typed | 9 | 10 |
| Nullable typed | 12 | 10,012 |
| Nullable return-only | 11 | 10,011 |

Counts include harness frames; bounded versus linear growth is the result. Generated `gerbil-repro~0.scm:77–113` binds the recursive result then checks it twice; `:142–160` does so once for return-only. Ordinary recursion is directly in tail position (`:54–62`).

A second scratch-only compiler-shape experiment replaced the class check with `(if value (: value :string) value)`. The optimizer removed the string predicate, but the result binding/conditional remained: **10 / 10,010 frames**. Merely improving predicate folding or changing `or` to `if` is insufficient (`gerbil-branch-prototype.ss`, generated `~0.scm:64–73`).

## 4. Existing tests and history

**Observed:** `src/gerbil/test/maybe-test.ss:8–33` tests source behavior and syntax hygiene. `compiler-test-support/maybe-provider.ss:17–57` and `maybe-client.ss:24–120` cover typed/untyped procedures, optional/keyword/inline paths, false, class rejection, raw/view adaptation, extension methods, unchecked interface dispatch and first-class wrappers. `compiler-test.ss:162–218` verifies native behavior, generated checks/casts and cross-module nullable signatures; `nullable-type-test.ss:11–40` covers subtype/normalization/join rules. Negative fixtures include `maybe-bad-{return,typed-return,void-return}.ss` and `maybe-raw-return.ss`. No nullable recursion-depth or continuation-frame regression was found; a search of `src/gerbil/test` for tail-call/tail-recursion/backtrace/frame-count tests also found none.

**Documented:** [PR #1496](https://git.cons.io/mighty-gerbils/gerbil/pulls/1496), including its [read-only comments API](https://git.cons.io/api/v1/repos/mighty-gerbils/gerbil/issues/1496/comments), was reachable. Review concentrated on unsafe nullable dotted dereferences and preserving nullable metadata. Vyzo approved emitting checked accessors for nullable chains ([comment 2797](https://git.cons.io/mighty-gerbils/gerbil/pulls/1496#issuecomment-2797)); later reported repair and rebootstrap ([2811](https://git.cons.io/mighty-gerbils/gerbil/pulls/1496#issuecomment-2811)). The fetched discussion does **not** discuss tail calls or authorize weaker return checks.

**Observed history:** on the requested HEAD, `3964ba4e` introduced `return-contract`; later `d801e7a1` fixed interface rest signatures/exports without changing its semantics. Across local refs, **`a10b8ac8e1daa6cb76fe19d2d1ba4ff51ad2567f`** (2026-09-22, “infer omitted procedure return annotations”) later adds `#f`/omitted-return identity cases and refactors return annotation construction, but keeps the always-check Maybe branch. It is not an ancestor of the requested HEAD. No later `return-contract` change appeared in the local all-ref content history beyond that commit; this is not a claim about unfetched upstream branches.

## 5. Candidate fixes

All assessments below are **inference**, except the measured conditional-shape failure.

| Candidate and source seam | Safety and likely maintainer assessment |
|---|---|
| **(a) Extend `:-` to `(Maybe T)`**, `contract.ss:279–285`, reusing resolver `:145–161` | Coherent explicit unsafe assertion, but **not a fix for `=>`**. It cannot validate unknown returns or construct interface views. Replacing automatic contracts with it fails current safety expectations. Keep interfaces checked unless already proven views. Public grammar expansion is unnecessary for the bug fix. |
| **(b) Make false-flag class returns annotation-only**, `contract.ss:178–184` | **Reject.** Unchecked interface dispatch may return arbitrary raw values; current class-return tests expect rejection even through `&Results-item`. Ordinary typed bodies use the two-argument path anyway. Broadening this to bodies would lose bad-result rejection. Retaining interface checks does not repair the class safety regression. |
| **(c) Elide adapters for proven compatible calls/results**, `contract.ss:174–199`; optimizer annotation handling `optimize-ann.ss:46–70`, using type queries/subtyping above | **Best bounded fix.** Preserve fallback evaluation/checking exactly once. Remove the whole binding/test/cast wrapper only when pre-adaptation evidence proves the target representation-or-false. This includes nullable self/mutual and imported typed calls. Raw interface dispatch remains checked/adapted; already-correct views can be elided. Macro expansion alone lacks the optimizer's inferred/imported call facts. |
| **(d) Extend (c) into tail branches**; same seams plus a tail-position traversal | Useful when a body has an unknown terminal branch and a guaranteed nullable recursive branch. Push the adapter through `if`, final `begin`, and binding bodies; check unknown leaves, leave proven calls tail. Do not enter nested lambdas or move across cleanup/dynamic-control boundaries casually. More work than (c), but preserves safety instead of trusting unknown bodies. |

Core-macro changes require regenerated `src/bootstrap/gerbil/core/contract*` artifacts; optimizer changes additionally require affected bootstrap compiler artifacts and metadata. Use the existing **`make rebootstrap`** workflow, then rebuild/verify from bootstrap (`Makefile:31–38`, `src/bootstrap.sh:10–27`); do not hand-edit generated Scheme. This applies to each candidate touching core/compiler; test additions alone do not need regeneration.

## Recommended fix

**Inference:** propose (c) upstream as removal of a provably redundant nullable **return adapter**, retaining an internal marker around its checked fallback so the optimizer can recover the original expression and target. Preserve `@type.return` verification **before** elimination. Do not use the adapter's own enclosing `@type (nullable T)` as its proof: that would prove itself. A known call's return signature or independently inferred expression subtype is the relevant evidence.

Use existing type-directed optimizer machinery, not user macros matching callee spelling. Cover self/mutual recursion, cross-module and first-class known calls, lambdas, false/void/top, class failures, raw-interface conversion and unchecked dispatch. Assert both generated tail-call shape and bounded continuation depth. Retain all existing negative/runtime tests. Add (d) if branch-local unknown results still prevent recursive cases needed by the issue; do not silently weaken those checks.

## Risks

- This is research, not an implemented or bootstrap-tested compiler patch. Only standalone experiments were run; existing upstream suites were inspected, not rerun.
- An optimizer-only repair does not make interpreted/unoptimized adapters tail-transparent. Unknown dynamic results genuinely require post-return validation/adaptation. Universal tail transparency needs a separate contract-semantics design; neither `:-` nor an unchecked flag supplies it safely.
- R7RS proper-tail-recursion rules do not themselves make a call in an expanded check's initializer a tail call. The issue is Gerbil's typed-source tail behavior; the safe repair must remove redundant work, not assume the standard licenses dropping necessary checks.
- Ordinary typed assertions already allow lies. Do not widen that trust boundary to Maybe or accidentally use raw implementations as interface-view evidence. Maintainer acceptance is inferred from existing invariants and review discussion, not promised.
