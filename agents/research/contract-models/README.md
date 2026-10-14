# Contract models: who defines what one plugin needs from another

Research for the parked package-layout brief (STATUS, "Repository and package layout"). Read-only; no Tuna code changed.

Labels: **Fact** (cited source, or something I ran), **Inference** (my reasoning from facts), **Unverified** (not checked).

Pinned sources:
- Cordis `a71c658` (2026-10-14), minato `67a8674`, Koishi `97d5c39`, cloned in `/home/jay/Code/reference-repos/`.
- Gerbil: installed `/opt/gerbil/src` (v0.19-dev-63-g1cfb032c; the earlier package-layout research found these files identical to checkout `/home/jay/Code/workbench-gerbil/gerbil` at `1c6c153`). Documentation: `doc/reference/std/interface.md` in that checkout.
- GNU Emacs checkout `/home/jay/Code/emacs` at `541f693`.
- Tuna `main` as of 2026-10-14 (`91aa6e9` is the latest commit in the spike worktree; this checkout was read in place).
- Web documents are cited by URL. They are living pages with no pinned version.

## Answer in brief

1. **No mature system with many replaceable providers lets each consumer write its own version of a large service interface.** Each has one neutral owner for a seam's shape:
   - the host's central API: VS Code `vscode.d.ts`, Neovim `vim.api`, Emacs core;
   - a shared API package: OSGi API bundles, Rust `log`, minato's `@cordisjs/plugin-database`;
   - the single consumer of an extension point: Eclipse extension points, Atom's `autocomplete.provider`, nvim-cmp sources, Emacs `project.el`/`xref` generics.

   Go's consumer-defined interfaces are the exception, and they work for small capabilities whose value types come from a shared standard library (**Inference** from the sources in Q1).
2. **Cordis/Koishi is provider-defined for one implementation and shared-package-defined for several.** The provider's package declares the service's type by augmenting `Context` (timer, server). With several implementations, a separate package declares the type and the abstract base that drivers implement (minato: `Database`, `Driver`). Consumers name the service by string (`inject = ['database']`) and import the declaring package for its types only. At run time nothing checks the shape, only the name and an optional `check()`. **Fact** (Q1.1).
3. **Gerbil's `:std/interface` is structural, with a catch that matters for user-defined contracts.**
   - A cast finds methods by name in the object's class; no `implement` is needed (**Fact**).
   - But `implement` and `defmethod … interface: I` define *namespaced* methods (`ns::I::m`). A consumer interface `J` looks for `ns'::J::m` and then plain `m`, so it never finds them. Today's buffers plugin uses `implement Buffers`, so a minibuffer-defined interface would **not** match it. I observed this.
   - Arity is not checked when casting, and a failed check is cached per class. Both are **Fact** (Q4).
4. **Recommendation: keep central contracts (model a), with each contract's default plugin bundled in the `tuna` package as the owner specified, and adopt one rule from the other models:** an extension point with one consumer and many providers is defined by its consumer.
   - Tuna already does this for completion styles, the completion UI, node kinds and renderers.
   - Reject user-defined contracts (c) for services that many plugins use (buffers, layout, keys, commands). They duplicate 15–50-method signatures in every user and split the semantic contract (positions are 1-based; `text-replace!` runs `after-change-hook`) from any single document. They still need a shared home for values (`buffer`, `node`, `change`, `posn`) and hooks. They make Emacs-style `(insert "x")` code harder to port. And in Gerbil, providers would have to give up `implement`.
   - Reject provider-defined contracts (b). A replacement provider would depend on the default's package, and the keys↔layout package cycle returns.

   Details and the table follow.

## What a Tuna contract file holds today

A contract file mixes five kinds of things, and the models below treat each kind differently. **Fact** (read from the files):

| Kind | Examples |
|---|---|
| 1. Value vocabulary: records and identity classes passed between plugins | `change`, `span`, `snapshot`, `text`/`node`/`buffer` identity classes, `view` (`buffers.ss:162-189`); `posn`, `key-event`, `input-target` (`keys.ss`); `frame-target`, `layout-description` (`layout.ss`); `candidate`, `completion-table` (`completion.ss`) |
| 2. Behavior interface | `Buffers` (about 50 methods, `buffers.ss:230-303`), `Keys` (mixes `Input`), `Layout`, `Completion`, `CompletionSession`, `CompletionUI` |
| 3. The service slot object | `buffers-service` with its predicate `is-Buffers?`, tier, and handover (`buffers.ss:305-311`; `new-service` takes an `implements?` predicate, `tuna/kernel/plugins.ss:314`) |
| 4. Hook objects | `after-change-hook` (payload: the text and a `change`), `buffer-list-update-hook`, `kill-buffer-hook` |
| 5. An Emacs-shaped convenience API: dispatchers to the current provider | `insert`, `point`, `goto-char`, `new-buffer`, `current-buffer` (`buffers.ss:799-806`: `insert` calls `text-replace!` on `(current-text)`); `read-string`; `completing-read` |

- **Fact:** the minibuffer plugin imports eight contracts (`tuna/plugins/minibuffer.ss:23-33`) and calls about 15 buffers operations: `new-buffer`, `new-node`, `new-text`, `new-text-node`, `add-buffer!`, `text-replace!`, `set-node-keymap!`, `kill-buffer`, `selected-view` and others.
- **Fact:** the keys↔layout loop:
  - the layout contract imports `posn` from the keys contract (`layout.ss:47`);
  - the keys plugin imports `posn-view` and `posn-node` from the layout contract (`tuna/plugins/keys.ss:26`);
  - the keys contract imports `node` from buffers (`keys.ss:38`).

  All modules are acyclic; the cycle appears only when contracts move into plugin packages (`agents/research/package-layout/README.md`, Q5 item 1).

## Q1. How real plugin systems define what one plugin needs from another

### 1.1 Cordis / Koishi

- **Who declares a service's type.**
  - **Fact:** the provider package augments the core `Context` type. `plugin-timer` says `declare module 'cordis' { interface Context … { timer: TimerService } }` and provides `TimerService` (`cordis/packages/timer/src/index.ts:3-15`). The loader and hmr do the same (`loader/src/index.ts:17`, `hmr/src/index.ts:15`).
  - **Fact:** with several implementations, a shared package declares the type: minato core (npm `@cordisjs/plugin-database` 4.2.0) declares `Context.database: Database` and the event `database/model` (`minato/packages/core/src/index.ts:13-23`), and defines the abstract `Driver` class every driver implements (`core/src/driver.ts:58-83`). Drivers peer-depend on it (`packages/sqlite/package.json`: `"peerDependencies": {"@cordisjs/plugin-database": "^4.2.0"}`). A driver `@Inject('model')`s the shared `Database`, registers itself in `ctx.model.drivers`, then provides `'database'` (`driver.ts:85-100`). So the database contract has one owner, the shared package, and **many providers coexist**: tables route to drivers through `getDriver` (`database.ts:117-121`).
  - **Fact:** consumers extend shared *data* types themselves through declaration merging: `declare module '@cordisjs/plugin-database' { interface Tables { dtypes: DType … } }` (`minato/packages/tests/src/model.ts:77`). The value vocabulary is open and extended by its users. Gerbil has no declaration merging (**Inference**).
- **How consumers depend.**
  - **Fact:** by name, at run time: `export const inject = ['database']` (`koishi/plugins/common/bind/src/index.ts:11`).
  - **Fact:** types come from importing the declaring package for its side effect: `import {} from '@koishijs/plugin-server'` (`koishi/plugins/mock/src/webhook.ts:2`).
  - **Fact:** Koishi's market metadata states service roles in `package.json`: `"koishi": {"service": {"required": ["database"]}}` (bind) and `{"implements": ["server"]}` (`plugins/server/package.json:39-44`).
- **Runtime checks.**
  - **Fact:** one provider per name per isolation scope. A second `provide` throws `service "…" has been registered` (`cordis/packages/core/src/reflect.ts:186-201`).
  - **Fact:** the only runtime check of a provider is an optional `check()` predicate (`reflect.ts:186`, `fiber.ts:377-381`).
  - **Fact:** using a service without declaring it throws "cannot get property … without inject" (`reflect.ts` around line 75).
  - **Inference:** the shape is checked only by TypeScript at compile time, against whichever declaration the consumer imported.

### 1.2 Atom services

- **Fact:** a provider lists `providedServices: {name: {versions: {"1.2.3": "provideX"}}}`, and a consumer lists `consumedServices` with semver *ranges* mapped to methods. The consumer method is called whenever a matching provider activates, and returns a `Disposable` (flight manual, `interacting-with-other-packages-via-services.md`, archived at `github.com/atom/flight-manual.atom.io`).
- **Fact:** service-hub's README shows a provider shimming an old major version by providing both `1.0.0` and `2.0.0`. Incompatible consumers "would just fail to discover the service" (<https://github.com/atom/service-hub>).
- **Who documents the shape:** whichever side owns the seam.
  - **Fact:** `status-bar` *provides* `status-bar` (`1.1.0`, plus `0.58.0` → `legacyProvideStatusBar`) (`atom/status-bar/package.json`).
  - **Fact:** `autocomplete-plus` *consumes* `autocomplete.provider` at versions `1.0.0`–`4.0.0`, so the consumer defines the shape that many providers implement (`atom/autocomplete-plus/package.json`).
  - **Inference:** the shape is prose in the owner's README; nothing checks it.

### 1.3 VS Code

- **Fact:** one central API (`vscode.d.ts`). Multiple providers register through it: `registerCompletionItemProvider(selector, provider)` returns a `Disposable`, and the API defines the provider interfaces (<https://code.visualstudio.com/api/references/vscode-api>).
- **Fact:** an extension may return an object from `activate`. Others list it in `extensionDependencies` and read `extensions.getExtension(id).exports` (same page, "extensions"; `Extension<T>.exports: T`).
- **Fact** (from usage examples, not from the API page): the git extension's consumers copy a `git.d.ts` typings file and call `getAPI(1)`, which is versioned by an argument (StackOverflow 46511595). **Inference:** the extension-to-extension shape is provider-defined and typed only by copied declarations.

### 1.4 Eclipse / OSGi

- **Fact:** "Plug-ins can define extension points… When a plug-in contributes an implementation for an extension point, we say that it adds an extension… Defining an extension point is much like defining any other API" (Eclipse help, "The runtime plug-in model"). The extension point's owner is the plug-in that *consumes* the contributions. This is a consumer-defined contract, declared in `plugin.xml` with an `.exsd` schema, and readable without running the plug-in.
- **Fact:** OSGi separates API packages from their implementations. An API package "has two users: the consumers that use the API and the providers that implement the API". A minor version bump is compatible for consumers but not for providers (<https://docs.osgi.org/whitepaper/semantic-versioning/>, executive summary and background).
- **Fact:** several services may be registered under one interface, ordered by `service.ranking`, highest first (OSGi Core 8, §5 Service Layer).
- **Inference:** OSGi resolves the "who owns the shape" question by a third bundle (the API bundle) that neither the consumers nor the providers own. That is model (a) per subsystem.

### 1.5 Go interfaces

- **Fact:** "Go interfaces generally belong in the package that uses values of the interface type, not the package that implements those values. The implementing package should return concrete… types… Do not define interfaces before they are used" (Go wiki, CodeReviewComments, "Interfaces").
- **Fact** (Go spec and FAQ, from memory; **Unverified** against the current text): satisfaction is implicit; a type implements an interface by having its methods, checked at compile time wherever a value is assigned to the interface type.
- **Inference:** consumer interfaces stay small (`io.Reader` has one method) and mention only types every package already imports (`[]byte`, `error`, `context.Context`). The shared vocabulary is the standard library. Mismatches are compile errors, which Gerbil's runtime cast cannot give (Q4).

### 1.6 Neovim

- **Fact:** core exposes one central API (`vim.api`, `vim.lsp`). Plugin modules under `lua/` load when `require(…)`d (`runtime/doc/lua-plugin.txt`, <https://neovim.io/doc/user/lua-plugin/>).
- **Fact:** plugin-to-plugin use is a direct `require` of the other plugin's module. lazy.nvim's `dependencies` only makes sure the other plugin is installed and loaded (<https://lazy.folke.io/spec>).
- **Fact:** extension points are consumer-defined and duck-typed. nvim-cmp documents a source table whose `complete` method is required and the rest optional, registered with `cmp.register_source(name, source)` (`doc/cmp.txt`, `lua/cmp/init.lua`).
- **Inference:** no versions and no checks; a mismatch is a Lua error at call time.

### 1.7 Emacs

- **Fact:** `provide`/`require` work on named features: "The file that defines them should provide the feature. Another program that uses them may ensure they are defined by requiring the feature" (Elisp manual, "Named Features").
- **Fact:** where Emacs needs interchangeable backends, the framework package defines a protocol and backends register:
  - `project.el` defines `cl-defgeneric project-root`, `project-files` and others, plus `project-find-functions` (`lisp/progmodes/project.el:192,299,384`);
  - `xref.el` defines `xref-backend-functions` and generics (`xref.el:99-113,237`);
  - `completion-at-point-functions` is a hook of functions (`minibuffer.el:3232`).
- **Fact:** hooks pass plain values: `after-change-functions` callbacks receive `(beg end old-len)` (Elisp manual, "Change Hooks"; **Unverified** in this pass, but long-standing).
- **Inference:** "no contracts at all" holds only for core functions (`insert` is simply global). For replaceable parts Emacs uses the consumer-defined extension-point pattern, written with generic functions.

### 1.8 Rust `log` (facade crate)

- **Fact:** "Libraries should link only to the `log` crate… the consumer of those libraries can choose the logging implementation". Implementations implement the `Log` trait and install it with `set_logger` (`rust-lang/log` `src/lib.rs` docs, <https://docs.rs/log>).
- **Inference:** a contract package with no implementation inside, deliberately. It is the shape the owner calls wrong ("contracts in the core without their plugin"). It works for logging because the contract is tiny and stable.

## Q2. How each model handles the hard parts

Cells are short; the sources are in Q1.

| Model | Shared values | Events and payloads | Several providers | Versioning | Mismatch detected | Package loops | Author ergonomics |
|---|---|---|---|---|---|---|---|
| Cordis/Koishi | TS types in the provider or shared package; users extend them by merging | String names; payload types declared by augmentation in the emitter's package; any plugin may emit | One per name per scope; several via a shared package plus drivers (minato) | npm semver on the declaring package | Compile time (TS); at run time only name and `check()` | Type-only imports are erased (**Inference**); run time is by name | Good: `inject`, `ctx.foo` |
| Atom | Whatever the service object returns; prose docs | Methods on the service object | Consumer called once per provider | Semver per service, several versions provided side by side | When discovered: a version mismatch means no match; shape at call | None: no imports between packages | Fair: shims per version |
| VS Code | Central `vscode.d.ts` types; exports untyped unless typings copied | Central `Event<T>` types | Central `register*Provider` | Engine version; API arguments (`getAPI(1)`) | Compile time against `.d.ts`; exports at call | Central API is a hub | Good centrally, weak between extensions |
| Eclipse/OSGi | API bundle types | Extension point schema; OSGi event admin | Many extensions per point; ranked services | Semantic versioning of packages (consumer vs provider rules) | At resolve time (OSGi wiring), schema at load | API bundles break them | Heavy (XML, manifests) |
| Go | Standard library types | Channels or callbacks typed by the consumer | Any value that satisfies the interface | Module semver | Compile time, structural | Consumer interfaces avoid importing the implementation | Excellent for small interfaces |
| Neovim | Lua tables, no types | Autocommands with untyped `data` | Plugin-specific registries | None | At call | `require` cycles possible at load | Easy, fragile |
| Emacs | Global symbols, plain lists | Hooks with positional plain arguments | Hooks, `*-functions` lists, generics | Package version only | At call | `require` cycles are a load error | Easiest to write; nothing reverts it |
| Rust `log` | Facade crate types (`Record`, `Level`) | n/a | One global logger | Crate semver | Compile time | Facade breaks them | Good |

## Q3. Mapping onto Tuna

The same scenario under each model: the minibuffer creates its prompt buffer with an answer text node, and the buffers plugin provides buffers. Pseudocode is Gerbil-like and shortened.

### (a) Central contracts, default plugin bundled in the `tuna` package

```scheme
;; tuna/services/buffers.ss  (tuna package; plugins/buffers is its default, also in tuna)
(interface Buffers (make-buffer (name : :string) (root : node)) => :t  …)
(def buffers-service (new-service 'buffers is-Buffers? tier: 'live …))
(def (new-buffer name root) (Buffers-make-buffer (current-buffers) name root))
(def (insert s) …)                          ; the Emacs-shaped API
;; plugins/buffers (the default; any replacement writes the same)
(implement Buffers registry (make-buffer (lambda (self name root) …)) …)
(context-provide! ctx buffers-service (Buffers reg))
;; minibuffer
(import :tuna/services/buffers)
(defplugin (minibuffer-plugin ctx) requires: [buffers-service …]
  (add-buffer! (new-buffer " *Minibuf*" (new-node 'minibuffer [] [(new-text-node (new-text ""))]))))
```

- **Values and hooks:** one home each, in the contract, with typed signatures (`node`, `change`). The `after-change-hook` object and the `change` record live together. **Fact** (today).
- **keys↔layout:** acyclic modules in one package; no package cycle. **Fact** (package-layout Q5).
- **Live replacement:** `handover` is defined once, in the contract. **Fact** (`buffers.ss:305-311`).
- **Porting Emacs:** `(insert "x")` works after one import. **Fact.**
- **Independence:** a plugin depends on `tuna`, never on another plugin. A replacement buffers plugin implements `Buffers` without knowing the default. **Inference.**
- **Cost:** the `tuna` package grows by every default that owns a contract, and the owner's condition requires that. A plugin with an unusual need has to change a contract that every other plugin shares. **Inference.**

### (b) Provider-defined (Cordis-like): each plugin package exports its own interface

```scheme
;; plugins/buffers/contract.ss  (package tuna-buffers)
(interface Buffers …) (def buffers-service …) (def (insert s) …)
;; minibuffer: depends on the tuna-buffers package
(import :tuna/plugins/buffers/contract)
;; a replacement buffers plugin: must ALSO import the default's package
(import :tuna/plugins/buffers/contract)
(implement Buffers my-registry …)
```

- **Fact:** the package cycles (keys↔layout, and `tuna`'s prelude importing the commands, keys and settings contracts) appear, as package-layout Q5 found.
- **Inference:** a replacement depends on the package it replaces, which violates "plugins must be independent". Cordis escapes this by moving the shared shape into a third package (minato), which is model (a) for that subsystem.

### (c) User-defined (Go-like): each user declares what it needs

```scheme
;; plugins/minibuffer/needs.ss
(interface MinibufferBuffers
  (make-buffer (name : :string) (root : :t)) => :t   ; buffer/node: no shared type to name
  (make-node (kind : :symbol) (attrs : :list) (children : :list)) => :t
  (make-text (initial : :string)) => :t
  (add-buffer! (b : :t)) => :void
  (text-replace! (t : :t) (start : :fixnum) (end : :fixnum) (s : :string) (point-before :? :fixnum)) => :void
  …)                                                  ; about 15 methods
(defplugin (minibuffer-plugin ctx) requires: ['buffers]
  (let (b (MinibufferBuffers (service-ref 'buffers)))   ; the cast checks names now
    (MinibufferBuffers-add-buffer! b (MinibufferBuffers-make-buffer b " *Minibuf*" …))))
;; plugins/buffers: plain methods, no implement (Q4), provided under a bare name
(defmethod {make-buffer registry} (lambda (self name root) …))
(context-provide! ctx 'buffers reg)
```

- **Values:** `buffer`, `node`, `text`, `view`, `change` and `posn` still need one definition that both sides import, or every signature degrades to `:t`, which goes against the AGENTS.md rule on specific types. **Inference.**
- **Hooks:** `after-change-hook` must be one shared object, or a by-name hook table. ADR 12 removed the kernel's hook table, so that would need an amendment. **Inference.**
- **Semantics:** the meaning of a method (1-based positions; `text-replace!` stamps nodes and runs the hook) has no single document. Each consumer restates the signature, and the provider's doc is the only real contract. **Inference.**
- **Duplication:** today the minibuffer, renderer, layout, completion and basic-editing plugins would each declare overlapping 10–20-method subsets. **Inference**, from the minibuffer count above.
- **Porting Emacs:** ported code that calls `insert` needs a global `insert` somewhere. Either a central dispatcher, which is (a) again, or every ported package declares its own buffers interface and threads a handle through, which is much worse than Emacs. **Inference.**
- **Live replacement:** each user re-casts at swap time. A provider may satisfy one user and not another, so activation must check per user. Today the slot's predicate is checked at provide time (`new-service … implements?`), so (c) moves the check into each `requires:`. That changes the kernel interface (ADR 12). **Inference.**
- **What it does buy:**
  - no plugin imports another plugin's interface module;
  - a toy provider implements only what its users call;
  - test doubles are trivially small.

### (d) Hybrid: a shared value vocabulary, behavior per seam

- **Vocabulary:** a small vocabulary layer in `tuna` holds identity classes and plain records: `text`, `node`, `buffer`, `view`, `change`, `span`, `posn`, `candidate`.
- **Behavior:** two rules decide who owns each interface.
  - **Service seams** (one provider, many users: buffers, layout, keys, commands) stay central, as (a), so the Emacs-shaped API and hooks have one home.
  - **Extension points** (one user, many providers: completion styles, `CompletionUI`, node kinds and renderers, future xref/project-like backends) are defined by that one user, as Eclipse, Atom's autocomplete, nvim-cmp and Emacs `project.el` do. The user's plugin is the default bundled with its contract, so the owner's condition holds.
- **Inference:** this is (a) plus a stated rule, and Tuna already follows it: `completion.ss` defines `CompletionUI` for the engine's UI providers, and buffers defines `context-define-node-renderer!`. Splitting vocabulary out of `buffers.ss` would mainly make the dependency graph clearer: `keys.ss` imports buffers only for `node`, and `layout.ss` imports keys only for `posn`.

## Q4. Gerbil specifics: is `:std/interface` structural?

**Yes, by method name, with three important limits.**

1. **Structural satisfaction (Fact).**
   - `cast`, `try-cast` and `satisfies?` build a *prototype* by looking up each interface method in the object's class method table (`specialize-class`, then `symbolic-table-ref`). They cache it per class and interface (`gerbil/runtime/interface.ss`, `do-create-prototype`, `@cast`).
   - No declaration is needed. The documentation's `LinearAccumulator` example defines plain `defmethod`s and casts with `(Operation acc)` (`doc/reference/std/interface.md`, "When to use interfaces").
   - `is-X?` "check[s] whether an object satisfies the interface (i.e. implements the required methods)" (same doc).
   - Casting an interface instance to another interface tries the instance's class and then unwraps to the underlying object (`@cast`, branch `interface-subclass?`).
2. **`implement` makes methods private to the interface (Fact; observed).**
   - Each interface method is looked up under a list of names: `ns::Iface::m`, then the namespaced name from each mixin, then plain `m` (`gerbil/core/contract.ss:1847-1858`, `make-method-name-spec`).
   - `implement` expands to `(defmethod {m klass} proc interface: I)` (`std/interface.ss:30-42`). A method defined with `interface: I` gets the name `ns::I::m` and is wrapped with I's signature (`contract.ss:2722-2733`).
   - In gxi (`/tmp/ifc/t.ss`), a class set up with `implement Provider` was **not** `is-ConsumerNeeds?` for a consumer interface with the same method name, and neither was `(Provider r)`. A class with a plain `defmethod {make-buffer …}` was.
   - Tuna's providers use `implement` (`tuna/plugins/buffers.ss:451`, `implement Buffers buffer-registry`).
3. **Arity and types are not checked when casting (Fact).**
   - `std/interface.ss` carries the comment `TODO extract interface method signature and check/set argument contracts`.
   - In gxi, a class whose `make-buffer` takes no argument satisfied the consumer interface and failed only at the call, with "Wrong number of arguments".
   - The consumer interface's safe facade checks its *own* declared argument contracts before dispatching (interface doc, "Defining interfaces").
   - `implement`, by contrast, builds the prototype at module load and raises "missing method" then (`@implement` calls `create-prototype`).
4. **A failed check is cached per class (Fact; observed in gxi).**
   - On a miss, `do-create-prototype` stores `#!void` in the class's prototype table.
   - A class that failed `is-Needs?` still failed after the missing `defmethod` was added. This matters for Tuna's live reload.
   - Redefining an existing method with `rebind: #t` *was* seen through an earlier cast in gxi.
   - **Unverified:** both behaviors in compiled code. The parallel spike should check them.

**What this means for (c)** (**Inference**):
- Providers must define plain, un-namespaced methods. Method names then share one global namespace of symbols, so unrelated services that both define `node-kind` with different meanings collide silently.
- Providers lose `implement`'s load-time completeness check and its signature wrapping.
- A missing method is caught at the cast, which can run at activation if `requires:` names the interface. Wrong arity or argument types are caught only on the call.
- The negative cache can make a fixed provider look broken until the class is redefined.
- None of these block (c), but each makes it weaker than Go's version, where all of this is a compile error.

## Comparison

++ strong, + adequate, − weak, −− poor. Based on Q1–Q4; the ratings are **Inference**.

| Criterion | (a) central + bundled default | (b) provider-defined | (c) user-defined | (d) hybrid = (a) + consumer-defined extension points |
|---|---|---|---|---|
| Plugins independent of other plugins | ++ (depend on `tuna` only) | −− (replacements import the default) | ++ | ++ |
| No package cycles | ++ (one package holds the contracts) | −− (keys↔layout, prelude) | + (needs a vocabulary home) | ++ |
| Shared values (`node`, `change`, `posn`) with typed signatures | ++ | + | −− (`:t`, or a shared vocabulary = (d)) | ++ |
| Hooks with payloads (`after-change-hook`) | ++ | + | − (a by-name hook table; kernel change) | ++ |
| Several providers / extension points | + | + | ++ (any shape fits) | ++ |
| Live replacement and handover | ++ (one handover per contract) | + | − (per-user re-cast; no one place for handover) | ++ |
| Mismatch detection | + (`implement` at load; predicate at provide) | + | − (names at cast; arity at call; negative cache) | + |
| Porting Emacs (`(insert "x")`) | ++ | + | −− | ++ |
| Semantics documented once | ++ | ++ | − | ++ |
| Author boilerplate | + | + | − (repeat signatures per user) | + |
| Owner: contract ships with its default | ++ (by construction) | ++ | n/a | ++ |
| Owner: modernize Emacs, no legacy | + | + | + | + |
| Size of `tuna` package | − (all contract defaults inside) | ++ | ++ | − |

## Recommendation for Tuna

Adopt **(d)**: model (a) with the extension-point rule written down. Concretely:

1. **Contracts for services stay central in the `tuna` package, and each one's default plugin moves into the same package.** It stays an ordinary plugin, replaceable, loaded through `init.ss`, and gets no privileged access. This is the owner's stated condition, and it removes the package cycles found in the package-layout research.
2. **Extension points are owned by their single consumer**, as in Eclipse, Atom's autocomplete, nvim-cmp and Emacs `project.el`. Write this as the rule for placing an interface: "an interface lives with the one plugin that calls it when it has many implementers; with a central contract when it has many callers". Then contracts never serve a single consumer by accident, which is AGENTS.md's concern.
3. **Split value vocabulary from behavior inside the `tuna` contracts** (for example `posn` and `node` into vocabulary modules), so `keys.ss` and `layout.ss` stop importing each other's contracts for one type each. This is optional and mechanical.
4. **Do not adopt (c) for services.**
   - Its main benefit (no import of another plugin's interface) is already true under (a), where all plugins import only `tuna`.
   - Its costs land on Tuna's goals: duplicated signatures, no single semantic contract, a shared vocabulary needed anyway, harder porting of Emacs packages, and in Gerbil, giving up `implement` (Q4).
5. **Let a plugin narrow a large interface locally when it wants a small test double** (Go's real use). Since `implement` hides methods, the cheap form is a plain record of procedures or a small local wrapper, not a structural cast. **Inference;** not needed now.
6. **Keep hook payloads as records in the contract** (modernizes Emacs's positional `beg end len`), and keep ADR 12's "no kernel hook table".

## Owner decisions

1. **Contract model.** Recommended: (d), central service contracts plus consumer-owned extension points. Alternative: (c) for everything, which the spike tests. (b) is not recommended.
2. **What moves into the `tuna` package.** Under (a)/(d), every default plugin whose contract lives in `tuna`: buffers, layout, keys/input, commands, minibuffer, completion engine, settings, session, renderer, echo area, text store (rope), web transport? Plugins that own no contract (Orderless, M-x, vertical list, help buffer, view commands) remain separate plugin packages. Decide where the web transport goes. It is a startup-tier seam (`Input`/`Display` live in the kernel), and it carries the gerbil-datastar dependency.
3. **The extension-point rule as an ADR.** It is hard to reverse and has real alternatives, so it qualifies; it would amend ADR 2's "Services" or ADR 12's "Few, coarse contracts".
4. **The STATUS entry** "`plugins/<name>/` holds its contract if it defines one" would change to "for third-party plugins only; Tuna's own contracts and their defaults live in `tuna`".

## What is shallow

- The Gerbil interface behavior was observed only in gxi (interpreted): the negative cache, `rebind:` seen through a cast, and arity checked only on the call. Compiled behavior is **Unverified**; the spike should confirm it. I did not check whether return-type annotations are enforced.
- Go spec wording, VS Code typings practice (`git.d.ts` copied by users), and Emacs `after-change-functions` arguments come from memory or secondary sources, not fetched primary text.
- Atom's service-hub and VS Code's extension host source were not read, only their documentation. Eclipse and OSGi come from documentation only.
- I counted contract use only for the minibuffer. The claim that other plugins would declare overlapping 10–20-method subsets under (c) is an estimate.
- I did not read Cordis's loader or hmr to see how type-only imports behave across package cycles in practice; "erased at run time" is **Inference**.
- I did not look at the contract-spike's results; where they conflict with Q4, they take precedence on Gerbil behavior.
