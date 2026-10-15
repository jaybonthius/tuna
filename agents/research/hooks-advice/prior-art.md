# Prior art for hooks and advice, beyond Emacs

Read-only research for the Tuna "hooks and advice" brief. Labels: **F** = observed in a primary source (cited); **R** = the source's stated rationale; **I** = my inference. Tuna repo at `57a2b45`. Web pages were fetched 2026 (no version pins; they are living docs).

## Summary

Every system below answers the same five questions differently: *who owns a wrapper, how are wrappers ordered, how are they removed, do they survive redefinition, can you see them.* Emacs `advice-add` answers "anyone, by position, by name, by symbol-cell indirection, `advice--p` on the function object". Improvements are available on each axis, and the strongest evidence is negative: Clojure's robert.hooke is disowned by its maintainers, and AOP's "obliviousness" is its most-criticised property. The pattern that keeps winning is **a small declared set of extension points, with owner-scoped registration, explicit ordering, and a listing of who is attached**, with arbitrary-function wrapping kept as a visible, second-class escape hatch.

## 1. Common Lisp: method combination (declared, structured composition)

- **Model (F).** In standard method combination, auxiliary methods carry exactly one qualifier `:before`, `:after` or `:around`; `:around` methods run first and may call `call-next-method`; then all `:before` methods most-specific-first, the primary method, then all `:after` methods most-specific-last; before/after return values are ignored and `call-next-method` in them is an error. [CLHS 7.6.6.2](http://www.lispworks.com/documentation/HyperSpec/Body/07_ffb.htm).
- **Ordering (F, R).** Order comes from the *specificity of the class*, not from registration time. The spec gives the reason for the before/after asymmetry: subclass C1's before runs before all of C2's methods and C1's after after all of C2's, regardless of where C2's behaviour is defined (same page). Same-class order is never a user concern because two methods with the same specializers+qualifiers *replace* each other.
- **Other combinations (F).** Built-ins `+ and append list max min nconc or progn` (and `standard`) fold primary methods with an operator; `:around` still works; `define-method-combination` lets the *generic function's author* define new ones. [CLHS 7.6.6.3–4](http://www.lispworks.com/documentation/HyperSpec/Body/07_ffd.htm). **I:** the key property is that the *extension point's owner chooses the combination* (`or`, `progn`, `list`...). Emacs's `run-hook-with-args-until-success` etc. are the same idea, but chosen by the caller of the hook, and `add-function` combinators are chosen by the advisor.
- **Removal / redefinition (F).** `remove-method`; redefining the method replaces it. Methods belong to the generic function, so redefining the *function body* is not a concept; you add a method.
- **Visibility (F).** The effective method is computable (`compute-applicable-methods`, `describe`); I did not verify tooling details beyond the spec.
- **Cost (I).** Requires the target be declared generic up front; that is the point, and also the limitation.

## 2. Allegro CL fwrappers and LispWorks defadvice (wrapping a plain function, improved)

- **Allegro's own critique of its older advice (R).** Encapsulation installs a new non-`eq` function object at the function spec, so a `#'foo` captured earlier is not wrapped, and an encapsulated function loses its trace when redefined by `defun`/`compile`/load; advice is forms-based and needs the argument list consed. [Allegro "Fwrapping and Advice" §1.1](https://franz.com/support/documentation/current/doc/fwrappers-and-advice.htm). fwrappers replace it.
- **fwrap model (F).** An fwrapper is defined independently (`def-fwrapper`, nothing wrapped), then applied with `(fwrap function indicator fwrapper)`. Each wrapper has an *indicator* name; reusing an indicator **replaces** that wrapper. Wrappers call `call-next-fwrapper`. Outer-to-inner order; a new wrapper goes outermost; `fwrap-order` queries and sets outermost/innermost, one adjustment per call ("no way to specify the order in one action"). `funwrap` removes by indicator; `describe` shows wrappers. Redefining the *fwrapper object* does not change an already-applied wrapper until `fwrap` is called again. Same page §2.
- **Survives redefinition (F, R).** The wrapper is attached to the function *object/name slot* so that captured function objects and redefinition keep the wrapping (the stated motivation in §1.1). I did not verify the exact mechanism for redefinition by `defun` beyond this claim.
- **LispWorks `defadvice` (F).** Three kinds: `:before`, `:after`, `:around`, always combined as around → before → original → after; `:around` uses `call-next-advice`. Advice has a per-function unique **name**; reusing it redefines; `where :start|:end` positions within its section; optional documentation string; removed by `remove-advice`/`delete-advice`. [LispWorks defadvice](https://www.lispworks.com/documentation/lw80/lw/lw-lispworks-23.htm).
- **I:** LispWorks fixes the *combination structure* (like CLOS) rather than Emacs's ten freely-stackable combinators; the before/after "don't mutate arguments, ignored result" discipline is CLOS's. A named, documented advice entry with `:start/:end` is a lighter ordering API than Emacs's numeric `depth`, but both are positional.

## 3. Clojure: Vars, `alter-var-root`, `with-redefs`, robert.hooke

- **Why redefinition works (F).** `defn` stores functions in Vars; the compiler resolves free symbols to interned Var objects, which are "stable references"; invoking a function dereferences the Var. [Vars reference](https://clojure.org/reference/vars). Direct linking removes the indirection, so "var redefinitions will not be seen by code compiled with direct linking"; `^:redef` or `^:dynamic` opts a var out; core itself is direct-linked since 1.8. [Compilation reference](https://clojure.org/reference/compilation). **I:** this is the same trade ADR 1 makes with `block` vs `separate`. Clojure's version is *per-definition metadata* (`^:redef`) rather than per-module; Tuna could expose per-binding opt-in/out.
- **Scoped redefinition (F).** `with-redefs` is global (all threads) and temporary; `binding` is thread-local but only for `^:dynamic` vars. The Vars page says rebinding "enables many of the possibilities of aspect- or context-oriented programming", e.g. wrapping only in certain threads. **I:** parameters in Gerbil match `binding`; the thread-scoped variant is the only one safe in a concurrent test.
- **robert.hooke (F).** `add-hook #'target #'hook-fn`: hooks receive the original (or composition of remaining hooks) as first argument; identity by *Var* so reload doesn't duplicate; `with-hooks-disabled`; `with-scope` records and restores hook changes (noting "all threads share the scope"). [README](https://github.com/technomancy/robert-hooke). **The README opens: "no longer maintained, and you are strongly advised against using it. In every case where it was adopted long-term in a codebase, it created more problems than it solved, causing situations that were difficult to debug and reason about… develop something more structured that facilitates debugging and understanding."** It also says hooking a `defmulti` is discouraged and that "if you own the target function there are obviously better ways". This is the strongest single data point against unstructured wrapping (R, by the library's authors).
- **Good ideas in it (F).** Identity-by-Var avoids duplicate hooks on reload (same issue Tuna solved with owner+name); `with-scope` is a receipt-like undo.

## 4. Racket: chaperones, contracts, parameters

- **Model (F).** An impersonator wraps a *value* and redirects selected operations (procedures, struct accessors, hash tables, vectors, boxes...). It is `equal?` but not `eq?` to the original. A **chaperone** is the restricted form: it may only raise exceptions or chaperone the values going in/out, not substitute them. Programs "should avoid `impersonator?` and treat impersonators the same as non-impersonator values". [Racket Reference 14.5](https://docs.racket-lang.org/reference/chaperones.html). Contracts are built on these wrappers (my background knowledge; not re-verified here).
- **I (the transferable idea).** Racket *separates* wrappers that can only observe/veto/validate (chaperone) from ones that can replace behaviour (impersonator), and gives the weaker one a guarantee. For Tuna: `before`, `after`, `filter-*` that cannot change control flow are analysable and safe to run for profilers/loggers; `around`/`override` change behaviour. The brief can classify the combinators by power and let observers be non-failing.
- **Survives redefinition?** Not applicable: wrappers wrap *values*, not names. Redefinition is the responsibility of the binding layer. The profiler would need a name-based layer anyway.
- **Parameters (F-adjacent, I).** Parameterization gives scoped, thread-inherited rebinding; this is ADR 9 and covers `let`-binding of settings.

## 5. Guile hooks (the plain model)

- **F.** A hook is created with a declared arity (`make-hook n`); procedures must accept that arity. `add-hook!` has an `append?` flag (default: front), `remove-hook!` by procedure, `reset-hook!`, `hook->list` returns procedures in call order; `run-hook` return value unspecified. [Hooks](https://www.gnu.org/software/guile/manual/html_node/Hooks.html), [Hook Reference](https://www.gnu.org/software/guile/manual/html_node/Hook-Reference.html).
- **I.** Declared arity makes mis-shaped callbacks an error at add time rather than at run time. Tuna's hooks already differ by being typed objects (Cordis alignment D5, `agents/research/cordis-alignment/README.md:167-180`). Guile has no owner concept: removal is by procedure identity, so a reload of the owner must remember its closures. Tuna's owner+name replace and receipts solve this.

## 6. Cordis (ownership, order, disposal)

- **F (from the Tuna summary, not re-read in the PDF).** Every effect carries an inverse; unload applies inverses in LIFO order; the inverse "reverts the effect at the state where it was applied"; correctness of inverses is the author's obligation. A table of independently-identified entries (routes, event listeners) is *commutative*: registrations are order-independent and individually withdrawable. Cordis's own events (`on/emit/parallel/serial/bail/waterfall`, `prepend`) are ordered chains that the paper's theorems do not cover. `agents/research/cordis-alignment/README.md:15-24, 75-82, 167-180`.
- **I.** This gives a design rule: **a hook is a commutative table only if callbacks do not depend on order**; where they do (advice stacks, `waterfall`), order must be *declared*, never be an accident of load order. This matches ADR 2's amendment ("equal priorities go to the plugin declared later in `init.ss`", `agents/adr/0002-plugins-contexts-and-services.md:17`). Advice is inherently an ordered chain, so it must carry declared depth and a deterministic tie-break.

## 7. Editor extension systems with ownership and disposal

- **VS Code (F).** Subscription APIs return a `Disposable` (`dispose()`), `Disposable.from(...)` combines several, constructor takes a `callOnDispose` function. [VS Code API](https://code.visualstudio.com/api/references/vscode-api). Extensions push these onto `context.subscriptions`, disposed on deactivation (documented in the extension guides; not re-fetched here). Contribution *points* (commands, views, keybindings) are declared in `package.json`, so tooling can list them without running the extension (background; not re-verified). Note the doc remark that dispose functions aren't awaited.
- **Atom event-kit (F).** `Emitter::on` returns a `Disposable`; `CompositeDisposable` collects several and disposes together; an `Emitter` is itself disposed with its owner. [event-kit README](https://github.com/atom/event-kit) (archived Dec 2022 per README banner).
- **Neovim/Vim autocmd groups (F).** `autocmd` appends "regardless of whether they are already present. When your .vimrc is sourced twice the autocommands will appear twice"; the cure is a named group, `augroup name | autocmd! | … | augroup END`; groups can be deleted, listed, and run selectively; `:verbose` shows which script defined each; buffer-local autocmds are removed with the buffer; `++once`. [autocmd.txt](https://raw.githubusercontent.com/neovim/neovim/master/runtime/doc/autocmd.txt) (sections `autocmd-groups`, `autocmd-remove`, `autocmd-buflocal`). **I:** Vim's groups are an after-the-fact fix for exactly the duplicate-on-reload problem Emacs `add-hook` has; Tuna's owner+name replacement is the same fix made structural, and "clear my group first" is what a plugin receipt does automatically.
- **None of the three has function advice.** They offer many *declared events* and disposal; arbitrary wrapping is absent. **I:** a large, successful ecosystem (VS Code) runs on declared events plus disposables.

## 8. Aspect-oriented programming (AspectJ) and its criticisms

- **Model (F).** Advice (`before/after/around`, `after returning/throwing`) attached via *pointcuts* (`call(int C.foo(Object,int))`), with `proceed(...)` in around advice. Precedence is *specified*: `declare precedence` across aspects; subaspect over superaspect; otherwise "it is undefined which one has precedence"; within one aspect textual order, reversed for `after`; circularity is a compile error; `proceed` runs the next-precedence advice. [AspectJ advice semantics](https://eclipse.dev/aspectj/doc/released/progguide/semantics-advice.html). Also `thisJoinPoint` reflection.
- **Obliviousness (F).** Filman & Friedman define AOP as "quantified programmatic assertions over programs written by programmers oblivious to such assertions" [RIACS TR 01.12](https://homepages.cwi.nl/~storm/teaching/reader/FilmanFriedman00.pdf). **I:** the oblivious target is exactly what makes robert.hooke-style surprises (§3) possible: the code you read isn't the code that runs.
- **Fragile pointcuts (F).** Koppen & Störzer: "expressions written using today's mainstream pointcut languages are fragile, as non-local changes may easily change pointcut semantics", an obstacle to evolution. [PCDiff, 2004](https://pp.ipd.kit.edu/uploads/publikationen/stoerzer04eiwas.pdf). Steimann's essay questions AOP's success on similar grounds ([OOPSLA 2006](https://oopsla.org/2006/submission/essays/the_paradoxical_success_of_aspect-oriented_programming.html); abstract only read, full text blocked).
- **I:** Emacs `advice-add` has *no* pattern matching (one named function per call), so it dodges fragile *pointcuts*; but `elp` and "advise every function in a package" reintroduce quantification. Tuna's `profile-plugin` (profiler brief item 2) is a quantified pointcut and should be a generated, listed set of per-binding advices, not a standing rule.

## 9. Python wrapt and decorators-on-rebinding

- **F.** `FunctionWrapper(wrapped, wrapper)`; the wrapper receives `(wrapped, instance, args, kwargs)`, so one wrapper works for functions, methods, classmethods and classes; wrapping a bound method must go through the descriptor protocol (`BoundFunctionWrapper`), which "complicates things"; `__wrapped__` reaches the original; the proxy is transparent for attributes/docs. `wrapt.function_wrapper` is used "when performing monkey patching". [wrapt Proxies and Wrappers](https://wrapt.readthedocs.io/en/master/wrappers.html).
- **Survival (I, from how Python binds; not on this page).** A decorator/monkey-patch replaces a *name binding*; references captured earlier (`from m import f`) keep the original. Same failure Allegro names for non-`eq` encapsulation (§2) and Clojure for direct linking (§3). Tuna's `separate` + module-export `set!` has the same limit: a wrapper installed by `set!` is seen by importers through the binding but not by anything that captured the procedure value earlier (e.g. stored in a hook list or table). **Observed in ADR 1 only for imports.**
- **Cost.** Per-call wrapper frame plus instance/arg tuple handling; wrapt's value is correctness of introspection (docs, signature, `__wrapped__`), i.e. *debuggability of the wrapper*.

## Cross-cutting comparison

| System | Who declares what can be wrapped | Order | Removal | Redefinition | Visibility |
|---|---|---|---|---|---|
| CLOS | Generic function author, combination chosen by owner | specificity (declared by classes); same-spec replaces | `remove-method` | add methods, not redefine | effective method computable |
| Allegro fwrap | anyone, any named function | outer-to-inner; `fwrap-order` | `funwrap` by indicator | indicator replace; fwrap survives defun (R) | `describe`, `fwrap-order` |
| LispWorks | anyone | fixed sections + `:start/:end` | `remove-advice` by name | same name redefines | docstring, named |
| Clojure/hooke | anyone, via Var | reverse add | `remove-hook`, `with-scope` | Var identity avoids dups; direct-link breaks | none; maintainers advise against |
| Racket | the value's holder | nesting | drop the wrapper value | n/a (values) | `impersonator?` discouraged |
| Guile | hook owner, declared arity | front/back flag | by procedure | n/a | `hook->list` |
| VS Code/Atom | event owner | undefined | `Disposable` | n/a | `subscriptions` |
| Vim | event owner | definition order | group clear/delete | group clear on re-source | `:autocmd` listing, `:verbose` |
| AspectJ | anyone, by pointcut | declared precedence; compile error on cycles | recompile | n/a | IDE markers (not verified) |

## Implications for Tuna

Evidence-based recommendations (my inference unless marked):

1. **Keep two tiers, and say so.** (a) *Declared* extension points: hooks and service methods, typed, arity-checked at add time (Guile), where the owner may choose the combination (CLOS built-ins; Emacs `run-hook-with-args-until-*`). (b) *Advice* on commands, service methods and `separate` exports as the escape hatch. Prefer (a); make advice on core services subject to the same listing and removal as hooks. Robert.hooke's epitaph is the warning for (b) with no structure.
2. **Owner-scoped everything.** Advice entries are owner-tagged, one per (owner, target, name), replace on re-add (Allegro indicator, LispWorks name, Tuna ADR 2), removed by the receipt in any order. Do not add a global `advice-remove` that bypasses ownership except as a debugging tool that reports the owner.
3. **Declared, deterministic order.** Use depth (as for hooks) plus plugin declaration order, never registration time (ADR 2 amendment; Cordis finding §6). Allegro's "one adjustment per call" `fwrap-order` shows imperative reordering is awkward; avoid a "put me outermost" API. AspectJ shows that cyclic or undefined precedence must be an error or a documented rule, not silent.
4. **Make "who wraps what" a first-class query.** An `advice-list target` returning, in call order, owner, name, combinator, depth and source location (the same origin metadata ADR 1 already records), plus a `describe` that shows the chain. Vim's `:verbose`/listing, Allegro `describe`, Guile `hook->list`. This is the cheapest answer to the obliviousness criticism and a direct improvement over Emacs, where `advice--p` inspection is ad hoc.
5. **Classify combinators by power.** Borrow Racket's chaperone/impersonator split and CLOS's "before/after results ignored": `before`, `after` (and maybe pure `filter-*`) are observers; `around`, `override`, and the `*-while/until` family can change control flow. Observers should not alter results, and a failing observer should be disabled with a notice (as hooks already do). Consider shipping fewer combinators first (`before`, `after`, `around`, `filter-args`, `filter-return`) and treating the four `before-while`-style variants as library macros over `around`; the evidence for their need is only Emacs's own usage (not examined here).
6. **Redefinition: make the wrapper live on the binding or generic function, not on a captured value.** Allegro (non-`eq` objects, lost on `defun`), Clojure (direct linking) and wrapt (`from m import f`) all document the same hazard. Tuna's `separate` set!-on-binding approach inherits it. Decide explicitly: advice is on the *binding* and re-applies when the module is reloaded (owner's receipt re-adds), and values captured earlier (hook callbacks stored by value) are looked up late by name (already true for hooks). State that advice on a captured procedure value is not supported.
7. **Per-binding opt-in/out rather than only per-module.** Clojure's `^:redef` / direct-linking split suggests a documented "this export is a stable extension point" marker (and a documented advisory that others are advisable but unsupported), in line with ADR 1's block/separate rule.
8. **Scoped, thread-local temporary wrapping for tests.** Clojure `binding` vs `with-redefs` (global) and robert.hooke `with-scope` ("all threads share the scope") show the concurrency trap. Offer temporary advice only as a receipt scope owned by the test/context, and note that in Tuna's threaded runtime a global temporary rewrap affects other tasks.
9. **Observability of failures.** A throwing advice in an `around` chain is not the same as a throwing hook callback: removing an `around` mid-chain changes the result. Decide per combinator (observer: disable and notice; control-flow: propagate and show the chain). I found no prior-art source that resolves this; it is open.
10. **Avoid:** pattern-based "advise everything matching X" as a *standing* declaration (fragile pointcuts; use generated listed per-binding advice for profiling); advice on kernel `block` modules (ADR 1 already forbids); implicit ordering by load time; wrappers that are invisible in `describe`/help; hooks whose combination mode is chosen at the call site by each caller when the owner could declare it once.

## Gaps and caveats

- I did not read the Cordis PDF or source myself for this note; Cordis statements rely on `agents/research/cordis-alignment/README.md`.
- VS Code `context.subscriptions`, `package.json` contribution points, and Racket contracts-as-chaperones are background knowledge, not re-fetched here.
- Steimann's full text and the Allegro `fwrap` redefinition mechanism were not verified beyond the vendor's stated rationale.
- Emacs `nadvice` itself was not re-read (Emacs is out of scope for this note); the ADR's list of combinators is taken from ADR 1.
- Tuna's own `hooks.ss` was not re-read; hook behaviour is taken from ADR 2 and `docs/emacs-equivalents.md:74`.

```acceptance-report
{
  "criteriaSatisfied": [
    {"id": "criterion-1", "status": "satisfied", "evidence": "Wrote prior-art.md covering CLOS, Allegro/LispWorks, Clojure, Racket, Guile, Cordis, VS Code/Atom/Vim, AspectJ, wrapt, with cited sources and Implications for Tuna."}
  ],
  "changedFiles": ["agents/research/hooks-advice/prior-art.md"],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {"command": "read-only repo greps and web fetches", "result": "passed", "summary": "ADR 1/2, emacs-equivalents, profiler brief, Cordis summary read; primary docs fetched"}
  ],
  "validationOutput": ["Sources fetched and quoted from primary docs; unverified items listed under Gaps and caveats."],
  "residualRisks": ["Cordis, VS Code subscriptions, Racket contracts, Steimann full text, Allegro redefinition mechanism not independently verified", "Tuna hooks.ss not re-read"],
  "noStagedFiles": true,
  "diffSummary": "One new research note.",
  "reviewFindings": ["no blockers"],
  "manualNotes": "Neovim doc fetched from master raw file (no commit pin). robert.hooke README quote is from master."
}
```
