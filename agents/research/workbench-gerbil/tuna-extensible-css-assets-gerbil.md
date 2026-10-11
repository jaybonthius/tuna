# Research: extensible embedded CSS assets in Gerbil v19

## Concise answer

Gerbil v19 already provides the smallest idiomatic compile-time file embedding mechanism: import `:std/source` and use:

```scheme
(def application-css
  (this-source-content "application.css"))
```

`this-source-content` reads the file during macro expansion and emits a quoted `u8vector`, so the deployed executable or compiled package does not need the source CSS file at runtime. Tuna already uses exactly this mechanism for both embedded JavaScript assets in `tuna/tuna/private/web-assets.ss:3-11`.

Every embedding module must be a `gxc:` build target with the CSS file listed under `extra-inputs:`. Otherwise changing only the CSS may leave stale compiled bytes. The macro path is relative to the source form’s file; `extra-inputs:` paths are relative to the build package root, so the two spellings may intentionally differ.

**Recommended:** let each independently compiled package embed its own CSS bytes with `this-source-content`, then have configuration explicitly register those bytes in stylesheet order before Tuna creates the host. Tuna should freeze/copy the registrations after configuration, concatenate them once with safe newline separators, and expose one external `/assets/tuna.css` route plus one `<link rel="stylesheet">`. This keeps core ignorant of package files, preserves explicit cascade order, avoids inline styles, and requires only one fixed HTTP route.

For the smallest correct version, serve the aggregate with `Content-Type: text/css; charset=utf-8` and `Cache-Control: no-store`; do not compute an ETag. A later cached version can compute one aggregate SHA-256 once when registrations freeze, or use that digest in the URL. Computing a digest per request or at every package’s macro phase is unnecessary.

## Evidence and current behavior

### Compile-time byte inclusion

- `tuna/tuna/private/web-assets.ss:3-11` imports `:std/source` and embeds both JavaScript files with `this-source-content`.
- `gerbil/src/std/source.ss:11-30` defines its support procedures at syntax phase. It derives the source file directory and reads the selected path with `read-file-u8vector`.
- `gerbil/src/std/source.ss:54-58` expands `this-source-content` into a quoted value, making the file contents part of compiled code rather than a runtime file read.
- `gerbil/src/std/source-test.ss:11-18` confirms source-relative paths and that the result is byte-oriented.
- Gerbil documents syntax-phase execution at `gerbil/doc/guide/intro.md:308-336` and `gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:20-24`.

A custom CSS macro is therefore possible, but not required. A wrapper is justified only if Tuna wants one form that both embeds and constructs/registers a CSS descriptor. Such a wrapper must retain the caller’s syntax location when resolving the path; directly using `this-source-content` in each asset-owning module is the least surprising form.

Gerbil’s ordinary `(include path)` is not appropriate for CSS: it includes and parses the target as Gerbil forms, rather than returning bytes (`gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:94-99`).

### Path semantics

`this-source-content`:

1. obtains the source filename from the syntax object;
2. takes that file’s directory;
3. joins the supplied literal path components with `subpath`;
4. reads the resulting file during expansion.

Evidence:

- `gerbil/src/std/source.ss:20-30`
- `gerbil/src/std/string/path.ss:26-28`

Consequences:

- Paths are anchored to the module containing the macro call, not Tuna’s launch directory.
- Tuna’s existing `../web/...` paths are therefore correct from `private/web-assets.ss`.
- Prefer committed relative paths. Absolute paths would make package builds machine-specific.
- Missing or unreadable files fail compilation.
- The arguments effectively need to be compile-time path data; ordinary runtime variables cannot select a file.
- Moving the embedding form to a wrapper module can change the source anchor unless the wrapper deliberately uses the caller syntax location.

### Rebuild dependencies

Tuna correctly declares the JavaScript files as explicit build inputs:

- `tuna/tuna/build.ss:16-19`

Gerbil documents `extra-inputs:` specifically for files read at build time:

- `gerbil/doc/reference/std/make.md:48-57`

The implementation adds extra inputs to each target’s input set and rebuilds when any input is newer than an output:

- `gerbil/src/std/make.ss:162-171`
- `gerbil/src/std/make.ss:248-258`

The standard build macro establishes the package’s build directory from `build.ss`:

- `gerbil/src/std/build-script.ss:21-24`
- `gerbil/doc/reference/std/make.md:112-122`
- `gerbil/src/std/make.ss:199-203`

Therefore an embedding module nested under `private/` might use:

```scheme
(this-source-content "../web/application.css")
```

while its build target uses:

```scheme
(gxc: "private/assets"
      (extra-inputs: ("web/application.css")))
```

The first is source-module-relative; the second is package-build-root-relative.

**High implementation risk:** omitting `extra-inputs:` does not prevent the initial embed, but CSS-only edits may not trigger recompilation. Gerbil’s own documentation warns that undeclared included/read files can make targets appear current incorrectly (`gerbil/doc/reference/std/make.md:143-150`).

### Executable and package behavior

Tuna’s build compiles the web asset module and then the executable:

- `tuna/tuna/build.ss:16-28`

Gerbil’s executable path compiles the main module and its dependency graph:

- `gerbil/src/std/make.ss:592-622`

For independent packages:

- package namespaces and preludes are declared in `tuna/packages/dummy/gerbil.pkg:1` and `tuna/packages/counter/gerbil.pkg:1`;
- they have independent build scripts at `tuna/packages/dummy/build.ss:1-5` and `tuna/packages/counter/build.ss:1-5`;
- the root Makefile builds Tuna and both packages separately into the same Gerbil environment at `tuna/Makefile:27-34`;
- configuration explicitly imports compiled packages at `tuna/config.ss:1-4`;
- the config loader requires explicit compiled-package imports and evaluates forms sequentially at `tuna/tuna/lib/config.ss:29-41`.

Thus:

- core CSS embedded in a transitively imported Tuna module is available to the Tuna executable without an external CSS file;
- package CSS is embedded in that package’s compiled module and becomes available when configuration imports the package;
- package CSS is not literally added retroactively to an already-built Tuna executable. Producing one closed executable containing selected package assets would require statically importing those packages before building that executable, which is materially different from Tuna’s current runtime-configurable package model.

Tuna explicitly has no unload/reload semantics (`tuna/tuna/README.md:502-508`), making a startup-frozen stylesheet registry consistent with current behavior.

### Renderer and HTTP constraints

Current HTML:

- renders fixed JavaScript asset references at `tuna/tuna/private/http.ss:128-145`;
- injects profiler CSS as an inline `<style>` string at `tuna/tuna/private/profiler-render.ss:5-9`;
- has no external stylesheet link.

Current assets:

- are byte vectors written directly through `ResponseHandler-write!` at `tuna/tuna/private/http.ss:118-122`;
- use JavaScript-only headers with immutable caching at `tuna/tuna/private/http.ss:20-28`;
- are served from fixed mux routes at `tuna/tuna/private/http.ss:335-351`.

The application renderer cannot currently contribute document-head assets: its contract is one complete state fragment (`tuna/tuna/README.md:29-35`). CSS extension therefore belongs beside page/HTTP asset construction, not in `tuna-render-state`.

Configuration finishes before host creation (`tuna/tuna/main.ss:15-23`), while the HTTP mux is created only when the host starts (`tuna/tuna/private/host.ss:162-175`). This gives a natural boundary at which to freeze stylesheet registrations without supporting concurrent or late route mutation.

The project CSS guidance requires source ownership and ordering, and discourages inline styles:

- `docs/agents/html-css.md:33-42`

Moving reusable/core CSS to source-owned `.css` files and linking one external aggregate is more consistent with that guidance than extending the existing profiler inline string pattern.

## Representation and metadata

### Bytes

**Precompute at compile time.** Keep CSS as `u8vector` bytes from `this-source-content` and serve those bytes directly. This matches Tuna’s existing response path and avoids decoding then re-encoding on every request.

Because byte vectors are mutable Gerbil objects, registration/freezing should copy package-provided vectors or otherwise establish trusted immutable ownership before retaining them.

When aggregating multiple stylesheets, insert at least one newline between each contribution. Raw concatenation can accidentally merge the end of one token or comment with the next stylesheet.

### String

**Do not precompute a string unless inline HTML is selected.** External CSS serving needs only bytes. Converting to a string adds UTF-8 decoding, re-encoding, and HTML-embedding concerns without benefit.

### Content type

**Centralize rather than package-precompute.** For a CSS-only registry, Tuna can use one constant:

```text
Content-Type: text/css; charset=utf-8
```

Packages should contribute CSS bytes and an identity/order position, not arbitrary media types. A generic future asset registry could carry media type in a descriptor, but that is more API than this bounded CSS requirement needs.

### ETag and caching

**Do not calculate an ETag per request.** Three coherent policies are available:

1. **Smallest:** fixed `/assets/tuna.css`, `Cache-Control: no-store`, no ETag.
2. Fixed URL with revalidation: compute one strong aggregate ETag when registrations freeze, handle `If-None-Match`, and return `304 Not Modified` correctly.
3. Content-addressed URL: compute SHA-256 once at freeze time, use it in the route/link, and serve with long-lived immutable caching. An ETag is then largely redundant.

Gerbil provides SHA-256 over a `u8vector` (`gerbil/doc/reference/std/crypto.md:10-22,131-138`), but importing native cryptographic support at macro phase merely to hash each package’s CSS is not the smallest mechanism. A per-package hash also is not the final aggregate hash because ordering and separators affect the aggregate bytes.

Tuna’s current JavaScript assets use long-lived immutable caching but no ETag (`tuna/tuna/private/http.ss:23-25,335-351`). The existing validation script verifies their committed lengths and SHA-256 values, but not conditional HTTP caching (`tuna/tuna/test/run-server-runtime-validation.sh:63-95`).

## Minimal implementation options

### Option 1 — Explicit ordered registry and one aggregate route

Each package:

- owns a `.css` source file;
- embeds it with `this-source-content`;
- declares it in that package’s `extra-inputs:`;
- exports the resulting bytes.

Configuration explicitly registers package CSS after imports, in desired cascade order. Tuna freezes/copies registrations before host creation, builds one aggregate byte vector, adds one `<link rel="stylesheet" href="/assets/tuna.css">`, and serves one fixed route.

**Advantages**

- Smallest HTTP and renderer change.
- Core knows no package file paths or package modules.
- Explicit config order satisfies stylesheet ordering.
- One request and one route.
- Package CSS remains independently compiled and runtime-file-free.
- Compatible with Tuna’s sequential pre-start configuration lifecycle.

**Costs/constraints**

- All CSS invalidates together.
- Registration identities, duplicate policy, ownership copying, and late-registration rejection need defined behavior.
- A fixed URL should initially use `no-store`, or caching must be implemented coherently.

**Recommendation:** this option, with explicit registration rather than import-time auto-registration. Explicit calls make cascade order visible and avoid relying on sibling module initialization order.

### Option 2 — Registered per-package descriptors and routes

Each package registers an identity, URL-safe route name, bytes, and optionally cache metadata. Tuna freezes the descriptor list, creates one mux route and one `<link>` per descriptor.

**Advantages**

- Independent package caching and invalidation.
- Browser/devtools retain package asset identity.
- No aggregate copy.

**Costs**

- More route and HTML generation logic.
- Must reject path collisions and unsafe names.
- Must define duplicate registration and ordering behavior.
- More protocol tests and cache metadata surface.
- Dynamic route list is a larger change than Tuna’s current two fixed asset routes.

Choose this only if independent cacheability or package-level asset diagnostics are required.

### Option 3 — Inline concatenated `<style>` contribution

Packages embed or export CSS text and Tuna inserts it into the page head.

**Advantages**

- No CSS route or second HTTP request.
- No caching or ETag work.

**Costs**

- Conflicts with the repository guideline to avoid inline styles.
- Requires UTF-8 conversion and safe handling of HTML-significant style termination.
- Couples package CSS to HTML generation and complicates a future Content Security Policy.
- Repeats all CSS in every page response.

Not recommended.

Gerbil’s `copy:` build target is another possible deployment mechanism, but it copies a runtime data file rather than embedding it. It introduces runtime path/deployment concerns and does not satisfy this task’s embedding requirement.

## Findings by severity

- **High — rebuild correctness:** every CSS file read at expansion must appear in the embedding module’s `extra-inputs:`. Otherwise CSS-only edits can leave stale compiled assets. Evidence: `gerbil/doc/reference/std/make.md:48-57,143-150`; `gerbil/src/std/make.ss:162-171,248-258`.
- **Medium — no current package CSS seam:** Tuna’s page and static mux know only two fixed JavaScript assets, and the renderer can only return the state fragment. Evidence: `tuna/tuna/private/http.ss:128-145,335-351`; `tuna/tuna/README.md:29-35`.
- **Medium — hidden import side effects would obscure cascade order:** compiled package imports run module initialization, but explicit registration after imports better matches sequential configuration and the CSS ordering guideline. Evidence: `tuna/tuna/lib/config.ss:36-41`; `tuna/packages/dummy/plugin.ss:6-13`; `docs/agents/html-css.md:35-42`.
- **Medium — cache policy must match URL stability:** applying the existing immutable JavaScript headers to a mutable `/assets/tuna.css` URL would allow stale styles. Use `no-store`, revalidation with a functioning ETag, or a content-addressed URL.
- **Low — validation gap:** the current asset gate checks embedded source forms, inputs, lengths, and hashes, but repository searches found no HTTP tests for asset content type, body, cache headers, or unsupported methods. Evidence: `tuna/tuna/test/run-server-runtime-validation.sh:63-104`; existing routes at `tuna/tuna/private/http.ss:335-351`.
- **Low — existing inline profiler style:** `tuna-profiler-style` is an inline `<style>` string, contrary to the general preference against inline styles. It is a migration candidate for the same embedded CSS mechanism, not a blocker to package CSS. Evidence: `tuna/tuna/private/profiler-render.ss:5-9`; `docs/agents/html-css.md:41-42`.

## Residual risks and unresolved gaps

- Product policy is still needed for duplicate asset identities, whether registration after startup is rejected, and whether no-config Tuna serves an empty or core-only stylesheet.
- Explicit stylesheet ordering should be documented as registration order; automatic package initialization order should not become an accidental cascade contract.
- Registration must prevent later mutation of retained package byte vectors.
- CSS declared as UTF-8 should be validated or treated as trusted package input.
- If caching is added, tests must cover exact ETag quoting, `If-None-Match`, `304` responses, and matching body hashes.
- A normal independently loaded package contributes compiled CSS at runtime, but cannot modify the physical bytes of an already-built Tuna executable.
- Confidence: **high** for Gerbil embedding, path, and rebuild semantics; **medium-high** for the recommended registry boundary because exact registration and cache policy remain product/API choices.

## Evidence-backed validation commands

No build or test was run because this research task is read-only and these commands update `.gerbil` outputs.

Focused after implementation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
GERBIL_PATH="$(pwd)/.gerbil" GERBIL_LOADPATH= gerbil build
GERBIL_PATH="$(pwd)/.gerbil" GERBIL_LOADPATH= \
  gerbil test -v 0 test/server-protocol-test.ss
```

Gerbil explicitly accepts individual test files (`gerbil/src/tools/gxtest.ss:21-33`), and Tuna’s isolated environment/build invocation is established by `tuna/Makefile:27-34`.

Full project validation:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
make test
cd /home/jay/Code/workbench-gerbil
tuna/tuna/test/run-server-runtime-validation.sh
```

The second gate should be extended with CSS source/hash/inventory checks analogous to its current embedded JavaScript checks at `tuna/tuna/test/run-server-runtime-validation.sh:63-104`.