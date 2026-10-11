# Customizing Tuna packages

**Candidate slice; performance acceptance is blocked.** Functional checks pass, but repeated native-storage benchmark slowdowns remain unexplained. See [measurements](customization-benchmarks.md). These interfaces are implemented in the working tree, not an accepted release.

## Live bindings

With `prelude: :tuna/prelude`, ordinary module/top-level `def`, `def*`, `define`, `defvalues`, and `define-values` retain native grammar and live replacement. Ordinary compiled callers see replacement; a bare procedure value captures the current effective implementation, including advice.

```scheme
prelude: :tuna/prelude
(def (step (n : :fixnum)) => :fixnum (fx+ n 1))
(def saved step)
(def live (function-ref step))
(set! step (lambda ((n : :fixnum)) => :fixnum (fx+ n 2)))
(list (step 1) (saved 1) (live 1)) ; (3 2 3)
(function-ref-set! live
  (lambda ((n : :fixnum)) => :fixnum (fx+ n 3)))
(live 1) ; 4
```

`function-ref` takes a lexical identifier, not a quoted module/name pair. Renamed imports and aliases identify the same entry; distinct bindings with identical printed names remain distinct. Missing targets, macros, local native bindings and native storage operations are unsupported; nonprocedure values are rejected when obtaining the reference. `function-ref-set!` takes the reference and a procedure, preserves advice, and rejects installing the entry's own reference. Failed updates leave published state intact. New procedure signatures belong to the replacement, not the live reference.

Ordinary calls retain an atom-published effective value without a registry lookup or lock per call. Native struct/class constructors, accessors, mutators and Gerbil methods remain specialized. Customize ordinary behavior above storage rather than storage operations themselves.

### Existing runtime facilities (unchanged)

Runtime advice still uses the positional interface `(advice-add! live 'name 'before procedure)`, with kinds `before`, `after`, and `around`. `before` observes arguments; `after` observes return values; `around` receives `next` and arguments. First registered is outermost; same-name replacement keeps position. `(advice-remove! live 'name)` removes it. The proposed runtime keyword/depth interface is **not implemented** in this slice.

`named-value-ref`, `named-value-set!`, and `named-bound?` remain available for explicit named management of ordinary values. The low-level `:tuna/bindings` module retains its two-argument named `function-ref` for existing registry users; it is not the prelude's lexical form. Its setter now also takes a reference. Named reservation is not supported by the lexical form.

`make-hook`, `hook?`, `hook-add!`, `hook-remove!`, and `hook-run!` are unchanged. Hooks run named callbacks over an ordered snapshot, discard results and propagate exceptions. Pass `(function-ref callback)` for a live callback; bare procedures remain captures. Re-evaluating `(def changed (make-hook))` creates a new object. `defhook`, priorities and contextual hooks are not implemented.

## Expansion-time macros

The prelude supplies ordinary macro-authoring bindings, including typed lambdas, `syntax-case`, `syntax->datum`, and `with-syntax`, without manual phase imports for transformer bodies. Ordinary module-level, phase-zero Tuna `defrule`, `defrules`, and `defsyntax` retain native patterns, literals, guards, shorthand headers and explicit transformer expressions.

```scheme
prelude: :tuna/prelude
(import :example/macros)
(redefrule (bump x) (+ x 10))
(redefrules total (list)
  ((_ (list x ...)) (+ x ... 10))
  ((_ x) (number? (syntax->datum #'x)) (+ x 10)))
(redefsyntax (scale stx)
  (syntax-case stx () ((_ x) #'(* 3 x))))
;; The explicit expression form also works, including renamed imports.
(redefsyntax scale
  (lambda ((stx : :t)) => :t
    (syntax-case stx () ((_ x) #'(* 4 x)))))
(defsyntax-snapshot saved-bump bump)
(redefrule (bump x) (+ x 20))
(list (saved-bump 3) (bump 3)) ; (13 23)
```

Replacement forms target an existing Tuna macro through lexical identity. They reject missing targets and native/object transformers; ordinary defining forms never silently patch another module. Replacement preserves advice. Snapshots capture the current effective transformer, including advice, rather than following later changes.

### Advice

These forms are available through the prelude or `:tuna/macros`. Their first operand is a macro identifier. Name, callback and depth expressions execute as transformer code; registrations never generate runtime callback calls.

```scheme
(macro-advice-add! bump 'offset around:
  (lambda ((next : :procedure) (stx : :t)) => :t
    (with-syntax ((result (next stx))) #'(+ result 100)))
  depth: -10)
(macro-advice-list bump) ; ((offset around: -10))
(macro-advice-remove! bump 'offset)
```

Exactly one kind is required:

- `before-call:` observes the whole input syntax object before delegation.
- `after-call:` observes the whole input after normal return.
- `after-return:` observes output syntax after normal return.
- `around:` receives `next` and the whole input, controlling delegation.

Observers preserve the transformer's result. Exceptions propagate; after observers do not run after an exception. `depth:` takes a fixnum; smaller depths are outermost. Equal depths retain registration order. Re-registering a symbol name replaces its callback/kind without duplication, preserving position and depth unless a new depth is supplied. Inspection captures ordered `(name kind depth)` entries at its **expansion point**. Removing an absent name is harmless. Invalid updates do not publish partial state; callback side effects are not rolled back.

### Expansion boundaries

Customization belongs to the current compiler process and selected use phase. Renamed identifiers share identity; other bindings and shifted use phases do not share policy. Already-expanded code and snapshots do not change. Gerbil may defer expansion of definition initializers: textual placement of a runtime `def` before customization does not establish that its initializer has already expanded. Use snapshots or separately compiled consumers when capture is required.

Load/evaluate customization in the process expanding the intended consumer. A separately compiled provider does not persist its compilation-time advice into future compiler processes. Fresh processes start with definitions, not another process's policy. Source-module reload refreshes implementation while preserving advice and target identity. Hygienically introduced private names are distinct but have no promised identity across regeneration.

Native expansion retains source attribution and hygiene; callbacks must return valid hygienic syntax. Arbitrary native/object-transformer interception, positive-phase defining-form wrapping, compiled macro-module reload, concurrent expansion mutation, registry reload, contexts, specialization and advanced filters are not promised.

## Verification

From the checkout root, run `PYTHONDONTWRITEBYTECODE=1 python3 tests/run.py`. The runner uses installed `/opt/gerbil` and a read-only-root Bubblewrap sandbox, with only fresh `/tmp` scratch writable. It retains commands, source/generated hashes and `validation.log`. Tests include separately compiled callers, lexical aliases and hygienic identities, grammar, advice ordering/payloads, rejected updates, snapshots, source attribution, phase/process isolation and source reload. Generated runtime code is checked for absence of macro-registry machinery. Existing hook/runtime/storage regressions remain covered.
