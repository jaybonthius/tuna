# Package layout for Tuna in Gerbil v0.19

Toolchain: Gerbil v0.19-dev-63-g1cfb032c on Gambit v4.9.8-19 (`/opt/gerbil`). Source citations are to `/opt/gerbil/src/` (the installed tree). The files cited are byte-identical to the checkout `/home/jay/Code/workbench-gerbil/gerbil` at `1c6c1538`, which I checked with `diff -q` on `tools/gxpkg.ss`, `tools/gxtest.ss`, `tools/env.ss`, `std/make.ss`, `std/build-script.ss`, `gerbil/expander/module.ss` and `gerbil/runtime/loader.ss`.

Experiments are in `/tmp/pkgexp` (three linked packages and two executables), `/tmp/nested` (a one-repository workspace with nested packages), `/tmp/tuna-linked` (a copy of Tuna with every plugin really linked) and `/tmp/cfgmin`.

Labels:
- **Fact**: I read it in the cited source or ran it myself.
- **Inference**: my reasoning from facts.
- **Unverified**: not checked.

## Answer in brief

- **Loading built-in plugins at run time is already what Tuna does.** `tuna/main.ss` says its `(only-in :tuna/plugins/X)` imports link the plugins into the executable. They do not. The executable links only the web plugin, which main uses by name. The other plugins are loaded at run time from `.gerbil/lib` as compiled `.oN` shared objects. **Fact**, details in Q3.
- **Measured start-up:**
  - Tuna as built today: 824 ms. The same Tuna with every plugin really linked: 845 ms.
  - Synthetic test: 20 modules loaded at run time 230.1 ms, the same 20 linked 230.8 ms.
  - Nearly all of the time is the expander processing imports, not loading code.
- **A package prefix may contain slashes, and a separate package can contribute modules under `:tuna/...`.** **Fact.**
  - One root `build.ss` can build several packages, each with its own `gerbil.pkg`, into one `.gerbil/lib` in a single `gerbil build`. Rebuilds are incremental. **Fact.**
  - `gerbil test ./tuna/... ./plugins/... ./tests/...` finds tests in nested `tests/unit` and `tests/integration` directories. **Fact.**
- **The blocker is where contracts live, not Gerbil.** If each contract moves into its default plugin's package:
  - the keys and layout packages depend on each other;
  - `tuna/prelude.ss` and the config language, which belong to `tuna/`, import the commands, keys and settings contracts.

  Both create cycles between packages, although the modules themselves have none. **Fact** (import table, Q5). Recommendation: built-in contracts stay in the `tuna` package, so every plugin package depends only on `tuna`.
- **Neither Gerbil's build nor `depend:` enforces imports.** Anything on the load path can be imported. The boundary test remains the enforcement. **Fact.**

## Q1. Gerbil packages

1. **`gerbil.pkg` fields.** **Fact.**
   - Read by the expander (`expander/module.ss:358-394`):
     - `package:` is the module prefix;
     - `namespace:` is the default namespace;
     - `prelude:` is the default prelude for every module under the file.
   - Read by the package manager (`tools/gxpkg.ss`):
     - `depend:` lists dependencies (417-421, 652-680);
     - `build:` names an alternative build script (1056-1064);
     - `description:` is used in package directories (798).
   - A module file can also carry `prelude:`, `package:` and `namespace:` header lines (`module.ss:227-253`). Gerbil's own sources do this, for example `package: gerbil/runtime` in `runtime/loader.ss:2`.
2. **How the prefix maps to a module name.** **Fact.**
   - Starting from the source file, the expander walks up to the nearest `gerbil.pkg` and stops there (`module.ss:358-394`).
   - module id = `package:` + the directories between that `gerbil.pkg` and the file + the file's base name (`module.ss:269-272`).
   - The namespace defaults to the full id, so equal base names in different directories do not collide.
   - With no `package:` (Tuna today: `gerbil.pkg` holds only `depend:`), the directory path is the prefix: `tuna/kernel.ss` → `:tuna/kernel`.
   - With `package: host`, the file `host/kernel.ss` became `:host/host/kernel`; I hit this in `/tmp/pkgexp`.
3. **Slashes in the prefix.** **Fact.**
   - `package:` is a symbol or string, joined with `/` (`module.ss:244-252, 380-384`). `std/make` requires a symbol and puts output under `lib/<prefix>/` (`std/make.ss:94, 131-133`).
   - Tested: a separate package with `package: host/plugins/plug` compiled to `lib/host/plugins/plug/m1.ssi` and so on. The `host` executable imported `:host/plugins/plug/m1` at run time.
   - Tested: `/tmp/nested/plugins/foo/gerbil.pkg` with `(package: tuna/plugins/foo)` produced `:tuna/plugins/foo/foo` and `:tuna/plugins/foo/private`, next to the root package's `:tuna/kernel`.
4. **Package name versus package prefix.** **Fact.**
   - The package manager's *name* (for example `git.cons.io/jay/gerbil-datastar`) is a path under `$GERBIL_PATH/pkg/`.
   - For `install`, the name is also the git clone URL (`gxpkg.ss:469-501`). For `link`, it is just a symlink (`gxpkg.ss:573-585`).
   - The name is unrelated to the module prefix.
   - `pkg-list` stops descending at the first directory that has a `gerbil.pkg` (`gxpkg.ss:753-772`). So package *names* must not nest. Linking `tuna` and also `tuna/plugins/buffers` would make the second invisible, or put it inside the first's symlink (**Inference** from the code). Use flat names such as `tuna` and `tuna-buffers`.
   - `gerbil pkg install` clones one repository and reads `gerbil.pkg` at its root (`gxpkg.ss:1051-1054`). A package in a subdirectory of a monorepo cannot be installed separately. **Fact.**
5. **`GERBIL_PATH`, `gerbil env` and the load path.** **Fact.**
   - `gerbil build`, `test` and `env` set `GERBIL_PATH=./.gerbil` only when the current directory has a `gerbil.pkg` and `GERBIL_PATH` is unset (`tools/env.ss:27-36`).
   - The load path is `$GERBIL_PATH/lib`, then `$GERBIL_HOME/lib`, plus `GERBIL_LOADPATH`. Observed `(load-path)` under `gerbil env`: `(…/tuna/.gerbil/lib /opt/gerbil/…/lib)`.
   - A load-path directory that holds a `gerbil.pkg` with a `package:` serves source modules under that prefix (`module.ss:414-452, 487-492`). This is how a package's own relative imports resolve while it builds.
6. **`gerbil pkg link`.** **Fact.**
   - It only creates a symlink at `$GERBIL_PATH/pkg/<name>`.
   - `pkg list` and `pkg build` run `git branch --show-current` in the linked directory (`gxpkg.ss:508-518`); outside a git repository they fail. I observed this.
   - Building a linked package writes `manifest.ss` into its source directory and `<name>.manifest` next to the link (`gxpkg.ss:705-726`).
7. **Build order across local packages.** **Fact.**
   - `gerbil pkg build all` sorts packages by dependents and builds dependencies first. Observed: host, then plug, then linked.
   - `gerbil build` in a package directory (`pkg-build "."`) runs only that package's `build.ss compile`. It never builds dependencies, and `-d` has no effect there (`gxpkg.ss:600-650`).
   - It does read every `depend:` entry's `<dep>.manifest` from `$GERBIL_PATH/pkg` (`gxpkg.ss:670-680`). So a sibling must have been built through `gerbil pkg build` first; otherwise the manifest step cannot open the file (**Inference**, not run).
   - `list-sort` with a membership predicate is not a true topological sort; deep graphs might misorder (**Inference**).
8. **What `build.ss` and `std/make` do with `depend:`.** Nothing. `std/make` compiles against whatever is on the load path (`std/make.ss:66-115`). **Fact.**
   - `gerbil deps -i` installs each `depend:` entry by `git clone`/`fetch`/`pull`. On an entry that is linked locally, it runs `git fetch` (and possibly `pull`) inside the linked directory (`gxpkg.ss:398-421, 469-501`). Do not list local siblings in `depend:` unless they are linked (**Inference**).
9. **`build.ss` is a program.** **Fact (tested in `/tmp/nested`).** A root `build.ss` that calls `(make specs srcdir: dir)` once per package directory works:
   - `tuna/` uses the root `gerbil.pkg`; `plugins/foo` and `plugins/bar` each have `(package: tuna/plugins/<name>)`.
   - Everything builds into one `.gerbil/lib` in one `gerbil build`.
   - A second `gerbil build` compiled nothing.
   - No `pkg link` or git setup is needed.
10. **Pitfalls with nested prefixes.** **Fact.**
    - Listing a nested package's files in the *root* `build.ss` (spec `plugins/foo/foo`) fails. `std/make` first imports each spec to learn its id (`std/make.ss:237-244`), and `:tuna/plugins/foo/private` resolves against the root, where no `tuna/plugins/foo/private.ss` exists.
    - A per-file `package:` header built from the root works only when the file has no same-package imports, and then it recompiles on every build: `std/make` looks for output at `lib/plugins/bar/bar.ssi`, but the file was written to `lib/tuna/plugins/bar/bar.ssi`.
    - Rule: one `make` call per `gerbil.pkg` directory, with specs relative to that directory.

## Q2. Options for the repository

Current state for comparison (**Fact**):
- Plugins import only the kernel facade, libraries and `tuna/services/*` contracts. No plugin imports another plugin.
- `layout/tree` is private to layout; `web/embed` is private to web.

### (a) One package; directories `tuna/` and `plugins/<name>/`

- **Module names.** Directory-derived: `:plugins/buffers/buffers`, `:plugins/web/web`. The top-level prefix `plugins` is generic, and every name changes when packages split. **Fact** (Q1 item 2) / **Inference**.
- Renaming to `:tuna/plugins/...` inside one package is not possible: a nested prefix means a separate `gerbil.pkg` and a separate `make` call (Q1 item 10), which is option (b).
- **Build.** One `build.ss`; any module order works because there are no package boundaries.
- **Boundary checks.** Nothing enforces them except `boundary-test.ss`, extended to `plugins/`.
- **init.ss.** `(import :plugins/buffers/buffers)`.
- **Tests.** `gerbil test ./tuna/... ./plugins/... ./tests/...`. Ids come from paths, for example `plugins/buffers/tests/unit/buffers-test`.
- **Web assets.** As today, with the paths changed.

### (b) One package for Tuna and one per plugin, in one repository

- **Module names.** `plugins/buffers/gerbil.pkg` holds `(package: tuna/plugins/buffers)`. A file `plugins/buffers/plugin.ss` becomes `:tuna/plugins/buffers/plugin`; a private `x.ss` becomes `:tuna/plugins/buffers/x`.
  - `package: tuna/plugins` with `plugins/buffers/buffers.ss` would give `:tuna/plugins/buffers`. But every plugin's `tests/unit/*.ss` would then share the id prefix `tuna/plugins/tests/unit/`, and two `foo-test.ss` files would collide (**Inference**). Avoid it.
- **Build.** A root `build.ss` with one `make` call per package (Q1 item 9). This is simpler than `gerbil pkg link` plus `pkg build all`, which need git per linked package and `manifest.ss` files written into source directories.
  - The order is `tuna` first, then the plugins in any order, provided contracts stay in `tuna` (Q5).
  - Each plugin's `gerbil.pkg` lists only external dependencies (web: `gerbil-datastar`) until it is published.
- **Boundary checks.** The build does not enforce `depend:`: one shared `.gerbil/lib` puts everything on the load path.
  - Real enforcement would mean building each plugin with a `GERBIL_PATH` that holds only `tuna` and its declared dependencies, so a stray import fails with "cannot find library module". That is feasible, but it costs separate library directories and a union load path at run time (**Inference**, not built).
  - Recommendation: keep the boundary test, made to read each plugin's `gerbil.pkg` and allow `:tuna/...` (kernel facade, libraries, contracts), its own prefix, its declared external dependencies and `:std`/`:gerbil`.
- **init.ss.** `(import :tuna/plugins/buffers/plugin)`. Nothing changes in how it is loaded: `import-module` resolves `.ssi` files from the load path.
- **Tests.**
  - A file under `plugins/buffers/tests/unit/` gets the id `tuna/plugins/buffers/tests/unit/<file>`, which cannot collide. **Fact** (tested).
  - Top-level `tests/integration/` falls under the root `gerbil.pkg`; tested `tests/integration/both-test.ss`, which imports two plugin packages.
  - `gerbil test` loads every test file as source into one process and harness (`tools/gxtest.ss:69-125`). Tests run against compiled modules, so the packages must be built first.
  - Today's string-path imports such as `"../test-support/kernel"` work only inside the repository (**Inference**).
- **Web assets.** `plugins/web/` holds `web/`, `frontend/` and the frontend tests.
  - `(embed-directory "../../web" "/static")` resolves relative to the source file at compile time (`tuna/plugins/web/embed.ss`), so the path becomes `"web"` or similar.
  - The web package's `make` call keeps `(gxc: "plugin" (extra-inputs: ,assets))`.
  - Embedded bytes are a literal in the compiled module, so loading it at run time changes nothing (**Inference**).
  - The `esbuild` rule in the Makefile moves with it.

### (c) Hybrid: directories now, packages later

- With (a) names, splitting later renames every plugin module, every `init.ss` import and the demo. The no-backward-compatibility rule allows that, but it is a second big change. **Inference.**
- The (b) structure costs only one `gerbil.pkg` and one `make` call per plugin, and its names are final.
- The real "later" step is separate repositories, because `gerbil pkg install` cannot install a subdirectory (Q1 item 4). That needs no renaming under (b).
- **Recommendation: do (b) now inside one repository and one `gerbil build`. "Later" means only moving a directory into its own repository.**

## Q3. Loading built-in plugins at run time

1. **Today's executable already does this.** **Fact.**
   - `.gerbil/bin/tuna__exe.scm` lists the built-in modules linked in. The only plugin modules there are `tuna/plugins/web` and `tuna/plugins/web/embed`, because `main.ss` names `web-transport-plugin`. Also linked: kernel, boot, control, config-blocks, the configuration and session contracts, and the others they reach.
   - `(only-in :mod)` with no names links nothing. Reproduced in `/tmp/pkgexp`: the size stayed the same until I referenced `p1 … p20`.
   - `strace` of `tuna check --config starter/init.ss` shows each plugin's runtime code opened as `lib/tuna/plugins/<name>~0.oN`, for example `commands~0.o2` and `html-renderer~0.o21`. Libraries `jobs` and `timers` and several contracts are loaded the same way.
   - `X.scm` is a stub that calls `load-module` on the dependencies and on `X~0`. `X~0` is the runtime code; `X~1` is the macro (phase-1) code.
2. **Requirements.**
   - **Fact:** Gambit dynamic loading of `.oN` shared objects; the loader picks the highest-numbered `.oN` (`runtime/loader.ss:32-129`).
   - **Fact:** the `.ssi` files on the load path, for the expander. Tuna adds `../lib` beside the executable (`tuna/boot.ss:217-224`).
   - **Fact:** a fully static `--release` build of the host executable (`statically linked` by `file`, with glibc `dlopen` warnings) still loaded all 20 `.o1` modules.
   - **Fact:** with only the generated `.scm` files (no `.oN`), loading failed in the executable with "Bad syntax; illegal expression" on `(declare (block) …)`.
   - Plain `.ss` source also loads but runs interpreted, about 100 times slower (`agents/research/configuration/01-gerbil-runtime.md`, finding 3).
   - Shared state is safe:
     - **Fact:** modules linked into the executable are registered as `builtin` and never loaded again; `strace` shows no `tuna/kernel*~0` file opened.
     - **Fact:** in the experiment, a counter in the linked `host/kernel` was incremented by all 20 dynamically loaded modules (`registered=20`).
     - **Fact:** the plugin macro `defplugin` from the host package expanded and worked in the separately compiled package.
3. **Start-up, measured** (hyperfine `-N`, 8–15 runs; `σ` is standard deviation):

   | Case | Wall time |
   |---|---|
   | Synthetic host exe, no expander, 20 modules linked | 5.5 ms ± 0.4 |
   | Same, expander loaded, nothing imported | 84.0 ms ± 1.1 |
   | 20 modules imported at run time from `GERBIL_PATH` (`.o1`) | 230.1 ms ± 3.1 |
   | 20 modules linked, then imported through the expander | 230.8 ms ± 3.2 |
   | Same as the run-time row, `--release` static executable | import 141 ms (in-process timer) |
   | Tuna today, `tuna check`, starter `init.ss` (21 plugins loaded at run time) | 824.2 ms ± 5.2 (33.9 MB exe) |
   | Tuna with all 21 plugins really linked (`/tmp/tuna-linked`) | 844.7 ms ± 11.1 (39.1 MB exe) |
   | Tuna, `init.ss` with no imports | 297.7 ms ± 3.9 |
   | Tuna, `init.ss` importing only the commands plugin | 300.6 ms ± 2.5 |
   | Full start until "is running" (5 runs) | at run time 808–851 ms; linked 820–859 ms |

   - The first import costs about 120 ms (the prelude's macro modules); each further small module about 1 ms. **Fact.**
   - For Tuna, the starter's 21 plugins add about 525 ms over an empty config, roughly 25 ms each, whether linked or not. **Fact** (difference of the measurements).
   - That cost is the expander reading `.ssi` files and loading each module's phase-1 `~1.oN`, not `dlopen` (**Inference**: linking saved nothing).
4. **Optimization.** **Fact** for the declaration; the rest **Inference**.
   - A module's code is the same either way. Gerbil's cross-module optimization reads `.ssxi.ss` at compile time.
   - The `~0.scm` header is `(declare (block) (standard-bindings) (extended-bindings))` whether the module is then linked or loaded.
   - The only optimization lost is full-program optimization (`--optimized`), which ADR 1 already avoids. It cannot apply to modules loaded at run time.
5. **`(declare (separate))`.**
   - **Fact:** `#lang :tuna/prelude` inserts `(declare (separate))` (`tuna/prelude.ss:20-28`).
   - **Inference:** linking or loading does not change it, because globals are Gambit globals either way.
   - **Fact:** the `block` hazard reproduced incidentally in `/tmp/nested`. A macro from another module `set!` a counter defined in a `block` module. The defining module's own `(thing-count)` still returned 0, since Gambit treats a global never mutated in its module as constant. Plugins and helpers that must be redefined live need `separate`, linked or not.
6. **Build-artifact growth.** **Fact.**
   - Every rebuild adds another `.oN` (`html-renderer~0.o21`); `.gerbil` is 365 MB.
   - The loader always takes the highest `N`.
   - Stale `.oN` files are harmless but grow without bound until `gerbil clean`.

## Q4. What `tuna/main.ss` must stop knowing

**Fact**, from the imports and calls in `tuna/main.ss`:
- **21 no-op `(only-in :tuna/plugins/… )` imports**, plus `tuna/config`, `lib/jobs` and `lib/timers`. They link nothing (Q3 item 1). Delete them; behavior does not change. **Inference**, but the `strace` evidence is direct.
- **`web-transport-plugin`**, through `override-plugin-option! web-transport-plugin 'port port "--port"`. The override is keyed by plugin *value* (`tuna/lib/plugin-options.ss:142`).
- **`web-transport-url`**, to print "Open URL".
- **`:tuna/services/session`**, to call `restore-session` and `save-session` around the loop.
- **`command-ref 'show-config-report`** from the commands contract, to word the start-up summary.

The `Input`, `Display` and `Messages` services are kernel seams (ADR 12), so main may use them.

Design options:
1. **Notices through the configuration contract (recommended).**
   - `tuna/services/configuration.ss` is Tuna's own contract, provided by its own `config-service` plugin. Add a context operation such as `(context-add-notice! ctx "Open http://…")`, undone by its receipt like every other registration.
   - Main prints the current notices in the "Tuna is running" line; a reload that moves the port updates them.
   - reload-config can register "show-config-report shows it" the same way, which removes the `command-ref` call.
   - Either one more contract operation, or a library on `context-defer!`. Not a kernel change (**Inference**).
2. **The web plugin prints its own line on activation.** Simplest, but the line is not owned or ordered with the start-up report, and reloads print again.
3. **`--port`.**
   - Option: a generic `--option PLUGIN.OPTION=VALUE`, applied by plugin *name* when boot matches the declaration (an override table keyed by name in `lib/plugin-options`).
   - Option: keep `--port` as built-in sugar meaning `web-transport.port`. Main would still name a plugin, as a string.
4. **Session.** Save and restore belong to the session plugin.
   - Restore on activation looks workable.
   - Saving at shutdown must happen before the plugins that own session slots are turned off. Deactivation runs dependents first, so it needs a "before shutdown" announcement: a kernel lifecycle hook, which needs an ADR 12 amendment, or a configuration-contract notice (**Inference**; not designed here).

## Q5. Risks and unknowns

1. **Package cycles if contracts move into plugin directories.** **Fact**, from the current imports:
   - The `keys` plugin imports the `layout` contract, and the `layout` contract imports the `keys` contract. As packages "keys = keys contract + plugin" and "layout = layout contract + plugin", each depends on the other.
   - `tuna/prelude.ss` imports the commands, keys and settings contracts, and `tuna/config.ss` re-exports the prelude. If those contracts left `tuna`, the `tuna` package and the plugin packages would depend on each other.
   - Either cycle breaks ordering by package (`gxpkg` raises "Circular dependency"; one `make` per package cannot order them), though the modules are acyclic.
   - Replacement plugins and contract doubles would also have to depend on the default implementation's package.
2. **Test doubles across packages.** Plugin tests import doubles by string path (`"../test-support/kernel"`), which only works inside the repository.
   - Doubles of `tuna`-owned contracts can stay in `tuna/test-support` and keep relative paths while everything is in one repository.
   - At a real repository split they need to become a compiled `tuna-test-support` package (**Inference**).
3. **gerbil-datastar is not pinned.** `gerbil.pkg` lists `"git.cons.io/jay/gerbil-datastar"` with no `@tag`; installed is `a0d020c`, and it depends on `gerbil-sse` `1a8609e` (`manifest.ss`). **Fact.**
   - `gerbil deps -u`/`-i` will move to HEAD.
   - Only the web plugin's `gerbil.pkg` should carry it.
   - Pin with `@<tag>` once the upstream has tags (`gxpkg.ss:398-415`). **Unverified:** behavior with a commit hash rather than a tag.
4. **Macros across packages.** They work. **Fact:** `defplugin` from the host package, and the `defstruct` constructor, were used by the separately compiled package and at run time. The `~1.oN` macro code loads per imported module.
   - The real risk is version skew. The executable links `tuna`'s kernel and contracts; plugins are compiled against `tuna`'s `.ssi` files in `lib`.
   - Rebuilding `tuna`'s library without relinking the executable, or two `tuna/*.ssi` on the load path, gives struct and macro shapes that do not match the linked code (**Inference**; prior research reproduced the struct case).
   - One `gerbil build` that rebuilds both avoids it.
5. **`prelude:`.** A `gerbil.pkg` may set `prelude:` for every module below it (`module.ss:387`). **Fact.**
   - Per-file headers keep working and take precedence.
   - `#lang :tuna/prelude` still needs `:tuna/prelude` on the load path when a plugin compiles; under (b) it is in the `tuna` package (**Inference**).
   - **Unverified:** whether the expander's default prelude is exactly `:gerbil/core`, which would make the headers redundant.
6. **One test process.** `gerbil test` loads all test files into one harness (`gxtest.ss:96-106`). Plugin tests that register global state can interfere, as today.
7. **Phase-1 cost grows with plugins.** About 25 ms per plugin at start-up (Q3 item 3). Splitting packages does not change it; linking does not cut it.
8. **The linked package manager touches source trees.** `gerbil pkg link`/`build` writes `manifest.ss` into each linked source directory and needs git. One root `build.ss` avoids both (Q1 items 6, 9).

## Recommended layout and package structure

```
gerbil.pkg            (depend: ())                 ; root: prefix from directories
build.ss              ; (make tuna-specs srcdir: ".") then one (make specs srcdir: "plugins/<p>") per plugin
tuna/                 ; :tuna/kernel, :tuna/lib/jobs, :tuna/services/buffers (contracts stay here),
  tests/{unit,integration}/   :tuna/prelude, :tuna/config, :tuna/boot, :tuna/main
  test-support/
plugins/buffers/      gerbil.pkg: (package: tuna/plugins/buffers)
  plugin.ss           ; :tuna/plugins/buffers/plugin
  tests/unit/…        ; :tuna/plugins/buffers/tests/unit/plugin-test
plugins/layout/       plugin.ss, tree.ss → :tuna/plugins/layout/tree (private)
plugins/web/          gerbil.pkg: (package: tuna/plugins/web depend: ("git.cons.io/jay/gerbil-datastar@<tag>"))
  plugin.ss embed.ss web/ frontend/ tests/{unit,integration}/
tests/integration/    ; cross-plugin tests, ids tests/integration/…
starter/init.ss       ; (import :tuna/plugins/buffers/plugin …)
```

- Every plugin package depends only on `tuna`, plus its external dependencies. The build order is `tuna`, then all plugins.
- Naming the entry module `plugin.ss` everywhere is a suggestion; the owner may prefer `<name>.ss` (`:tuna/plugins/buffers/buffers`).
- `make test`: `gerbil test ./tuna/... ./plugins/... ./tests/...`, plus the frontend tests under `plugins/web/tests/`.

## Migration order

1. Delete the no-op `(only-in …)` imports from `tuna/main.ss` and fix its comment. Check that `make test` and `make run` behave identically.
2. Add notices to the configuration contract. The web plugin announces its URL, reload-config announces its command, and main prints notices instead of calling `web-transport-url` and `command-ref`.
3. Decide `--port` (owner decision 2). Then make the option override keyed by plugin name and drop main's `web-transport-plugin` import.
4. Move session save and restore out of main: a session-plugin design with a shutdown announcement (owner decision 3).
5. Write the root `build.ss` with one `make` per package. Create `plugins/<name>/gerbil.pkg`, then move each plugin with its private files and tests. Update `starter/init.ss`, `demo/`, the tests and the boundary test in the same change. The web plugin also takes `web/`, `frontend/` and the `esbuild` rule.
6. Move tests into `tests/{unit,integration}`: Tuna's own under `tuna/tests/`, cross-plugin ones (today's `tuna/integration/`) under top-level `tests/integration/`. Extend `make test` to every root.
7. Rewrite the boundary test per package. Pin gerbil-datastar in the web package.
8. Later, and only when wanted: move a plugin directory into its own repository and `depend:` on `tuna` by URL.

## Owner decisions

1. **Where built-in contracts live.**
   - Options: in `tuna` (today's `tuna/services/`); inside each plugin's directory and package; or as separate per-contract packages.
   - Recommendation: **in `tuna`**.
   - Why: inside the plugin packages creates the keys↔layout and `tuna`↔plugins cycles (Q5 item 1). Separate packages add about 15 tiny packages for no current gain.
   - Cost: "a plugin's contract sits next to it" then holds for third-party plugins only. The STATUS entry would need amending.
2. **`--port`.**
   - Options: a generic `--option PLUGIN.OPTION=VALUE`; or keep `--port` as sugar for the web plugin's port.
   - Recommendation: **the generic flag**, so main names no plugin. The cost is a longer command for the common case. The demo and Makefile use `--port`.
3. **Session save at shutdown.**
   - Options: a new kernel lifecycle hook (an ADR 12 amendment); or a shutdown notice through the configuration contract.
   - Recommendation: **the configuration contract**, which keeps the kernel unchanged. Decide this when that step is designed.
4. **Entry-module name.**
   - Options: `:tuna/plugins/buffers/plugin`; or `:tuna/plugins/buffers/buffers`.
   - Recommendation: **`plugin`**, because it is uniform. It is a naming choice only.

## What is shallow

- The per-plugin start-up cost (about 25 ms) is a difference of totals; I did not profile how it splits between `.ssi` reading, phase-1 loading and expansion.
- Not run:
  - `gerbil pkg build -d` on linked siblings;
  - `gerbil deps -i` against a linked package;
  - the manifest failure when a dependency was never built.
  These are read from the code.
- Real build-time enforcement of plugin dependencies (per-plugin `GERBIL_PATH`) was not built.
- The notices and session designs are sketches. Only the extension point (the configuration contract) was checked.
- The fully static `--release` run was tested on the synthetic executable only, not on Tuna (OpenSSL linking may differ).
- I did not move Tuna's real files; the layout was tested on the toy workspace `/tmp/nested`.
- **Unverified:** whether `X~1` macro loading can be avoided for plugins `init.ss` only names (`use-plugin`), which could cut start-up.
