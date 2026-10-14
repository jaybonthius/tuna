# Tuna consumer-owned contracts: throwaway spike

## Result

**Consumer-owned operation lists work in Gerbil, including raw buffers, nodes, views, and change records crossing between real plugins. They do not eliminate a shared protocol.** The default and toy providers both run the actual minibuffer and HTML renderer. Neither provider imports either consumer. Activation rejects a missing operation by name. No kernel file changed.

The decisive catch: Tuna's existing `implement Buffers` definitions are **interface-qualified**, not the unqualified methods another independently declared interface discovers. Both providers had to expose unqualified `defmethod` methods instead. Structural checking checks names, not compatible signatures or meaning.

My recommendation: allow small consumer-owned need interfaces, but retain an explicit shared vocabulary and rules for values, events, positions, and lifecycle. Do not choose “only the slot name is shared” as the complete model. The spike demonstrates independence from the provider's **record representation**, not independence from an agreed protocol.

## What was built

Worktree: `/home/jay/Code/workbench-gerbil/tuna__contract-spike`.
Branch: `contract-spike`, based on `91aa6e9`.
Commit: **`c98339ecfc2b2967e7db891bd99d921a8a51c4ce`** — `Spike consumer-owned buffers contracts`.
Throwaway only; do not merge this implementation.

| File | Change / owner |
|---|---|
| `tuna/plugins/minibuffer/buffer-needs.ss` | Minibuffer-owned interface: 25 operations, opaque values, local editing/registration conveniences. |
| `tuna/plugins/minibuffer.ss` | Actual minibuffer imports its own need module instead of `services/buffers`; checks fit before effects. |
| `tuna/plugins/html-renderer/buffer-needs.ss` | Renderer-owned interface: 31 operations, including node traversal, views, text lines, and highlights. |
| `tuna/plugins/html-renderer.ss` | Actual renderer uses its own need module; local display conveniences avoid using central buffer dispatchers from the renderer service. |
| `tuna/plugins/minibuffer/change-needs.ss` | Independent event observer's five operations: get the hook and read four fields of an opaque change. |
| `tuna/plugins/buffers.ss` | Provider-owned unqualified methods replace the `implement Buffers` block; adds 29 supplemental operations for opaque values and conveniences. Four benchmark-only direct exports. |
| `tuna/test-support/toy-buffers.ss` | Same structural exposure, with its existing vector children and different undo implementation. No consumer imports. |
| `tuna/lib/contract-fit.ss` | Generic 21-line plugin-side presence check, including interface unwrapping and clear diagnostics. |
| `tuna/services/minibuffer.ss` | `Prompt` buffer/answer return signatures become `:t`: imported nominal return names prevented a consumer-free `implement Prompt` expansion. |
| `tuna/integration/contract-spike-test.ss` | Seven behavior tests: structural vs qualified methods, wrong arity, cast failure, cached failure diagnostics, activation rejection, and both real providers sharing prompt values/events. |
| `tuna/test-support/contract-benchmark.ss` | Compiled direct/cached-interface/repeated-slot benchmarks. |
| `build.ss` | Builds the helper and the three consumer-owned modules; does not build test support. |

**Deliberate limit:** this is not a conversion of every Tuna plugin. Providers, layout, input, and remaining consumers still use existing central vocabulary. The two changed plugins directly import neither the buffers contract nor the buffers plugin for their buffer operations. Their other contracts still transitively import buffers; `prompt-display` and external prompt helpers remain nominal. That remaining coupling is not hidden by the success of this narrower seam.

### Boundary inventory

- Minibuffer imports contracts **commands, keys, renderer, layout, minibuffer, settings, session**, plus its own private module. Requires **commands, input, its local buffers slot, layout, settings, session**.
- Renderer imports contracts **keys (selected names), settings, renderer (interface/slot/settings only), layout**, plus its own private module. Requires **its local buffers slot, layout, settings**. Input remains optional as before.
- Default and toy providers import contracts **text-store, settings, buffers**, and the jobs library. Require **text-store, settings**. They import no consumer declaration.
- The private need modules import only **kernel facade, `std/interface`, contract-fit library**. The library imports only Gerbil runtime interface reflection and `std/interface`.
- The changed minibuffer contract still imports **buffers**; no re-export or cycle added. Tests alone import test support. Kernel growth: **zero**; existing mechanical boundary tests pass.

## Gerbil semantics: observed and sourced

Runtime: **Gerbil v0.19-dev-63-g1cfb032c**, Gambit **v4.9.8-19-gea114fc3**. The general Gerbil checkout is newer (`1c6c1538`), so citations below use the installed source tree `/opt/gerbil/v0.19-dev-63-g1cfb032c/src`. SHA-256 comparisons confirmed its three cited source files exactly match checkout commit **`1cfb032c7a1612637da6205f5f8a15683eba3ba0`**. No toolchain source was edited.

1. **Structural satisfaction exists, but “has methods” means Gerbil's method table, not fields or arbitrary exported functions.** An unqualified `(defmethod {read-value structural-reader} ...)` satisfies two unrelated interfaces. No `implement` declaration is required. Interface construction searches the class method table for each required name. [G1, G2]
2. **`implement` is not required and is not equivalent to registering unqualified methods.** It expands to `defmethod` with `interface: Interface`, then pre-creates a prototype. The interface-qualified method name is generated from that interface's namespace. An object implementing only `ReaderOne` does not satisfy unrelated `ReaderTwo`, even when both declare `read-value`. This was also the actual initial failure with both existing buffers providers. [G3, G4]
3. **A missing method fails at cast time**, before calling any method. A first failing cast says “missing method”; `is-Interface?` returns false and caches the miss. A later cast of a cached miss can lose the operation name. The helper inspects required names directly so diagnostics remain clear after a failed predicate. [G2, G5]
4. **Wrong arity can pass the cast and fail at call time.** The test casts a zero-argument `read-value` implementation into a consumer declaration requiring one string argument. The fit succeeds; the call raises `wrong-number-of-arguments-exception`. Cast construction does not compare signatures. Typed generated call sites and `implement`-generated method bodies provide contracts, but structural cast itself does not validate the provider's signature. [G2, G4]
5. **Same names do not collide as Scheme bindings:** generated consumer APIs are interface-prefixed and their qualified names differ. But independent interfaces fall back to the **same unqualified method** on a provider. If one consumer means pixels and another means characters, both fit and receive the same implementation; Gerbil cannot detect that semantic mismatch. Qualified implementations can distinguish them only if the provider knows those interfaces, which violates this proposal's provider-independence rule. [G1, G4]
6. **Casting the provider through another consumer view works.** The runtime can unwrap an existing interface instance and construct the other interface around the underlying receiver. Each new shell contains method slots plus the object; the raw object is unchanged. [G5]

Citations (commit-pinned source; matching installed files available locally):

- **[G1]** `src/gerbil/core/contract.ss:1839–1858`: each interface namespace; qualified names followed by unqualified fallback. [source](https://git.cons.io/mighty-gerbils/gerbil/src/commit/1cfb032c7a1612637da6205f5f8a15683eba3ba0/src/gerbil/core/contract.ss#L1839)
- **[G2]** `src/gerbil/runtime/interface.ss:95–151`: prototype construction looks up method names and reports/caches absence. [source](https://git.cons.io/mighty-gerbils/gerbil/src/commit/1cfb032c7a1612637da6205f5f8a15683eba3ba0/src/gerbil/runtime/interface.ss#L95)
- **[G3]** `src/std/interface.ss:6–15,30–42`: `implement` expansion and prototype creation. [source](https://git.cons.io/mighty-gerbils/gerbil/src/commit/1cfb032c7a1612637da6205f5f8a15683eba3ba0/src/std/interface.ss#L30)
- **[G4]** `src/gerbil/core/contract.ss:2716–2756`: qualified method generation and signature-bearing implementation body. [source](https://git.cons.io/mighty-gerbils/gerbil/src/commit/1cfb032c7a1612637da6205f5f8a15683eba3ba0/src/gerbil/core/contract.ss#L2716)
- **[G5]** `src/gerbil/runtime/interface.ss:153–232`: cross-interface unwrapping, cached misses, shell creation, predicate. [source](https://git.cons.io/mighty-gerbils/gerbil/src/commit/1cfb032c7a1612637da6205f5f8a15683eba3ba0/src/gerbil/runtime/interface.ss#L153)

### Consumer declaration and fit check

Excerpt from the actual minibuffer declaration (not its full operation list):

```scheme
(interface MinibufferBuffers
  (make-text (initial : :string)) => :t
  (make-text-node (text : :t)) => :t
  (make-buffer (name : :string) (root : :t)) => :t
  (buffer-root (buffer : :t)) => :t
  (node-text (node : :t)) => :t
  (view-showing (view : :t)) => :t
  (text-string (text : :t)) => :string)
```

Actual activation-side call:

```scheme
(require-interface! 'minibuffer-plugin 'buffers
                    (service-provider buffers-service)
                    (@interface-descriptor MinibufferBuffers))
```

Example diagnostic: **`Plugin minibuffer-plugin: slot buffers missing operation add-buffer!`**. The helper handles these ordinary class-backed provider shells; it is not a replacement for all of Gerbil's interface-on-interface casting behavior. The check runs first in the actual minibuffer and renderer activation bodies. The runtime's existing receipt rollback handles failure; the test confirms the rejecting consumer stays inactive and never reaches its effect.

**No kernel change is needed for explicit plugin-side checks.** Gerbil gives the cast, predicate, method table, and missing-method error; the library adds stable diagnostics and the activation placement. For *automatic* checks, the runtime would need to associate a consumer's fit function/interface with each requirement and run it before activation (and before adaptation when providers change). Today `requirements-met?` checks only presence, not the requirement descriptor's predicate (`tuna/kernel/plugins.ss:538–552`). Nothing implements that hypothetical runtime feature here.

Slot lookup and dependency tracking already use the service name (`plugins.ss:334–340,538–540`). However, service descriptors also contain tier, documentation, and handover policy. `remember-service!` overwrites the name's metadata on provider registration and consumer activation (`plugins.ss:334–335,595–604`). Identically named independent descriptors are enough for this live buffers experiment, **not proof that conflicting lifecycle metadata is safe**. A full model needs one authority for those policies.

## Values and events

The experiment keeps raw provider-owned values and asks operations about them through each consumer's provider view. It does **not** put another interface shell around every node.

The behavior test starts the real prompt on the editor loop:

1. Minibuffer constructs text, answer node, root, buffer, and places the buffer in a layout view using its declaration.
2. `prompt-buffer` returns that same raw buffer. Renderer-owned `buffer-root`, `node-children`, `node-kind`, and `text-node-content` read it.
3. Identity assertions confirm both consumer views see the same root, answer node, and text, not copied or re-encoded values.
4. The actual HTML renderer produces both “Spike question:” and “answer”.
5. A text insertion emits the actual after-change event. The independent observer gets the hook through the provider and reads the change without importing `services/buffers`. It observes **`[revision 1, start 7, removed "", inserted "x"]`**.
6. Prompt exit resumes the suspended task and cleanup runs.

Both providers pass the same scenario. Their internal node child collections differ (list versus vector), so consumer declarations do not depend on that representation.

The hook itself cannot be independently re-created by its name: hooks own their callback lists (`tuna/kernel/hooks.ss:1–15,32–47`). Two `new-hook 'after-change` calls create separate objects. Returning the provider's actual hook solves this without a shared hook module. The getter name, callback arguments, position units, revision meaning, order, and ownership are still shared protocol.

## Cost measurements

Machine: Linux x86-64, AMD Ryzen 9 7940HS. Compiled with `gxc -O`, separate compilation, no unsafe declarations or full-program optimization. Five samples, repeated in a second process; garbage collection before each timed sample. No browser timing claim.

- **Editing:** 50,000 insert/delete pairs on fresh, constant-sized default-provider texts per path (100,000 actual edits). Includes real rope updates, journal, undo records, and hook dispatch. Direct calls go to the provider's `replace!`; cached-interface calls execute the same operation. Repeated-slot calls use the actual local facade.
- **Redraw hot path:** 20,000 sweeps of 256 real default nodes (5,120,000 kind reads). A sink retains results. Direct getter can inline; cached interface has indirect method dispatch; repeated-slot facade retrieves and casts the current provider for every operation. This measures one traversal operation, not full HTML rendering or child-range copying.

First process medians:

| Path | Seconds / measured batch | Nanoseconds / operation |
|---|---:|---:|
| Edit, direct | 0.11974 | 1,197 |
| Edit, cached interface | 0.10844 | 1,084 |
| Edit, repeated slot + cast | 0.12258 | 1,226 |
| Kind read, direct getter | 0.00799 | 1.56 |
| Kind read, cached interface | 0.03266 | 6.38 |
| Kind read, repeated slot + cast | 1.23540 | 241.29 |

Second process: edit 1,175 / 1,066 / 1,221 ns; kind read 1.54 / 6.34 / 240.93 ns, respectively. Editing ranges overlap (first-process direct 0.102–0.137 s; cached 0.106–0.112 s; repeated slot 0.122–0.168 s). **Do not infer that interfaces make editing faster.** Allocation, collection, and ordering dominate that small difference. Dispatch is negligible beside an edit, but measurable for tiny repeated reads.

Cached kind dispatch costs about four times an inlined getter, yet only roughly **1.6 microseconds for 256 reads**. The repeatedly cast facade costs roughly **62 microseconds for 256 reads**, or about 2.4 milliseconds for 10,000 reads. Cache one consumer interface per redraw/task if this model is pursued; don't retain it across unhandled provider replacement. Repeated retrieval is a spike convenience, not the unavoidable cost of consumer-owned interfaces. The current central facade also retrieves/casts, so these numbers are not a baseline claim that this model slows Tuna by 150 times.

Raw samples: `benchmark.csv`, `benchmark-repeat.csv` beside this report. Reproduce from this worktree:

```sh
make deps
make test
GERBIL_PATH=$PWD/.gerbil gxc -O -d .gerbil/lib tuna/test-support/kernel.ss
GERBIL_PATH=$PWD/.gerbil gxc -O -d .gerbil/lib tuna/test-support/contract-benchmark.ss
GERBIL_PATH=$PWD/.gerbil gxi -e '(import :tuna/test-support/contract-benchmark) (main)'
```

## Boilerplate and awkward points

Counts include `(interface ...)` opening/closing lines, excluding blank lines/comments:

| Consumer | Central import today | Own interface only | Whole private need module |
|---|---:|---:|---:|
| Minibuffer | 1 import operand | 26 lines, 25 operations | 132 physical lines; 109 nonblank/noncomment |
| HTML renderer | 1 import operand | 32 lines, 31 operations | 145 physical lines; 110 nonblank/noncomment |
| Event observer | One central import would expose record/hook | 6 lines, 5 operations | 41 physical lines; 29 nonblank/noncomment |

The minibuffer and renderer repeat eight operation declarations. The rest of the module cost is local wrappers, slot lookup, fit checking, registration, and editing conveniences. Declaration-only counts do not conceal that cost. A macro could reduce mechanical code, but this spike deliberately did not invent a new declarative framework.

- **Types:** the provider retains precise concrete classes; the consumer intentionally sees `:t` for raw buffers/nodes/texts/views/changes. Primitive results remain typed. This loses compile-time distinctions: a node can be passed where a buffer is needed until a provider's checked operation rejects it. Consumer-owned per-value interfaces could restore method-level typing, but require wrapping/unwrapping and identity conventions; this variant was not built or measured.
- **`using`:** it works on typed service interfaces, but `(using (n : node) n.id)` imports the shared nominal type. Here `using` remains for the plugins' own classes; foreign values use declared operations, never dotted record access.
- **Imported typed interfaces/macros:** removing the buffers import first made `implement Prompt` fail expansion on the nominal `node` return type. Widening the two `Prompt` return types to `:t` fixed it. External prompt helper procedures and `prompt-display` remain central/nominal in this bounded spike, showing the next coupling rather than pretending it disappeared.
- **`defcommand`:** unchanged real minibuffer commands compile and execute. Command registration and its context are independent of who declares buffer operations. The prelude still imports its existing command/key/settings contracts; this is not evidence that *all* contract imports can disappear.
- **Emacs-style reading:** local direct-style helpers remain possible. The minibuffer uses `goto-char` and `point-max` unchanged. A package wanting `(insert "x")` can write a local helper using selected view, focused text, point, text replacement, and point movement. That helper adds declarations and either repeats editing policy or imports a shared editing library. The syntax is not the obstacle; maintaining one agreed point/undo/relocation policy is.
- **Hooks:** provider-owned getters work; independently named hook objects do not. Hooks are not supplied by Gerbil interface satisfaction itself.
- **Records:** fields can be private and consumed through provider operations, as tested for changes and spans. Meaning and ownership cannot be private. Buffered job snapshots, change rebasing, and provider handover still need stable rules; they were not redesigned here.
- **Registrations:** node kinds and renderers need the actual shared provider tables. The minibuffer asks the provider to create kind metadata rather than constructing the central record itself. This adds declaration surface for behavior that previously came free from one import.
- **Provider changes:** replacing `implement` with unqualified methods works and existing swap tests remain green. It also gives up the easy single-interface declaration that injects argument/return contracts into implementation lambdas. The provider must annotate its methods/procedures itself and rely on tests for semantic fit.

## Provider-defined alternative

If the provider publishes `Buffers` and its value/event vocabulary in a public module, consumers import that interface rather than defining their own. This is the provider-defined option in the question, not a separately implemented Cordis experiment.

Compared with today's central contract:

- The runtime dispatch and nominal records can be exactly the same. `implement Buffers` works naturally because both ends know the same interface. No kernel change or structural fallback is required.
- Ownership/location changes: the API is versioned and shipped by the provider's package rather than Tuna's central contracts package. Consumers and replacement providers depend on that **API module/package**, even when they never load the implementation.
- Consumer boilerplate falls back to one import; precise buffer/node/view signatures and common editing conveniences remain available.
- A small separately loadable API module is essential; importing the implementation just to get types would entangle activation/package dependencies. Existing package-layout research identifies package-level cycles when current contracts are bundled with their providers (`agents/research/package-layout/README.md:202–206`); this spike did not resolve them.
- A monolithic interface still makes a consumer appear to require operations it does not actually use. Publishing several coherent interfaces or allowing private consumer subsets are separate choices from where shared value vocabulary lives.

Thus “provider-defined versus central” mainly changes API ownership and packaging. “Consumer-defined versus either” changes declarations, structural method exposure, typing, and fit checking. They are not interchangeable packaging options.

## Validation and honest limits

- `make deps`: succeeded, worktree-local dependencies.
- Initial baseline `make test`: failed loading `minibuffer~1.scm` (`%#declare` illegal expression); the preceding first build also hit the tool timeout. Normal subsequent local rebuilding cleared this artifact/context problem without a toolchain or kernel edit. No claim that a root cause was proven.
- First spike run exposed the important qualified-method failure; provider conversion fixed it.
- Focused MCP test run: **PASSED**, all seven spike cases.
- Final `make test`: **OK**, all Gerbil suites including the new spike suite; all 12 frontend tests; demo configuration load check. Log: `make-test.log`.
- Gerbil MCP balance and syntax checks ran around edits. Inline checks stripped source prelude markers and normalized relative imports to their real module paths where needed; the actual build/test expanded modules in their proper context. `build.ss`'s inline check lacked its file macro context; its actual `gerbil build` succeeded.
- Browser smoke test: started only this worktree's server on port 8129 with state under `.gerbil/spike-state`. Actual `C-c r` prompt rendered, typed `spike`, RET renamed the buffer. `C-c B` swapped to toy buffers; the same prompt renamed it to `toy`. Verified subsequent browser snapshots showed `Renamed to spike`, `Buffers: toy`, and `Renamed to toy`. Screenshot: `toy-browser.png`. The owned server was stopped. No normal user state or primary checkout was touched.
- `git diff --check`: passed. Worktree clean after commit; no staged files. `git diff 91aa6e9..HEAD -- tuna/kernel tuna/kernel.ss` is empty.
- No checks intentionally skipped. A complete removal of shared contracts, incompatible slot-policy tests, a direct per-value-interface design, browser latency benchmarking, and automatic runtime fit checking were **not built** and are not claimed.

## Assessment for the owner

**What worked:** independently declared smaller operation lists; no provider-to-consumer imports; both existing provider implementations; real prompts and real HTML rendering; shared raw identities; change observation without record-type imports; explicit activation diagnostics; unchanged command style; a green full test suite and browser behavior.

**What failed or became awkward:** existing `implement` exposure was invisible to independent interfaces; nominal return types leaked into macro expansion; per-operation wrapper boilerplate grew; hook names alone did not identify hook objects; structural fit accepted incompatible arity and cannot protect meaning; service-name-only descriptors do not settle lifecycle authority.

A shared nominal `node` class is **not technically necessary for these two consumers**. A shared definition of “node,” parent/child order, revisions, text position units, change semantics, view selection, and event ownership **is necessary**. It can be documented and tested as a protocol instead of one all-encompassing nominal interface, but it remains a shared contract in the ordinary sense.

I would choose **consumer-owned subsets over an agreed shared vocabulary/protocol**, not “share nothing but a slot name.” Whether that vocabulary is centrally owned or published by a provider's API package remains a packaging/ownership decision this experiment does not settle. Keep the throwaway branch as evidence, not as the final architecture.
