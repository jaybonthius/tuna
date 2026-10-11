# Tuna extensible web seam options

## Concise answer

**Recommended:** add a narrow stylesheet-definition seam, not a generic web-extension framework.

Use:

```scheme
(defstylesheet tuna-counter package: counter-css)
(defstylesheet jay-tuna-theme user: theme-css)
```

with a low-level equivalent:

```scheme
(define-stylesheet! 'tuna-counter 'package counter-css)
```

The private page shell should emit links in this fixed order:

1. `/assets/tuna-core-v1.css`
2. package stylesheets, in first-registration order
3. user stylesheets, in first-registration order

Core CSS should be embedded and served with a versioned immutable URL. Live package/user styles should use stable Tuna-owned URLs and `Cache-Control: no-store`; re-evaluating `defstylesheet` atomically replaces one named sheet, visible on the next request/page reload. Keep `tuna-render-state` fragment-only.

Do **not** add generic route registration, middleware, arbitrary head nodes, external asset URLs, cache-policy parameters, a CSS build system, or live browser hot-reload yet.

## Current behavior and constraints

| Severity | Finding |
|---|---|
| **High** | Tuna has no CSS asset route or package/user stylesheet seam. Its page head is a fixed string containing only scripts and an optional inline profiler style: `tuna/tuna/private/http.ss:128-145`; `tuna/tuna/private/profiler-render.ss:5-9`. |
| **High** | The renderer is intentionally host-neutral and returns only the complete `#state` fragment. HTTP-specific head data must not be added to its contract: `tuna/tuna/private/render.ss:67-82`; `tuna/tuna/README.md:29-35`. |
| **High** | Existing architecture research explicitly rejects public handler/route registries until a concrete non-infrastructure endpoint exists: `research/tuna-server-core-runtime-boundary.md:189-212`; `research/tuna-integrated-web-application-shape.md:144-183,325-347`. |
| **Medium** | The profiler’s CSS is one inline `<style>` string. Moving it into core CSS would establish clear asset ownership and better match the repository guidance to avoid inline styles and repair the cascade instead: `tuna/tuna/private/profiler-render.ss:5-9`; `docs/agents/html-css.md:33-51`. |
| **Medium** | HTML responses are `no-store`, while both versioned JavaScript assets are currently served as immutable for one year: `tuna/tuna/private/http.ss:20-28,335-351`. A stable live stylesheet URL must not inherit the immutable policy. |
| **Medium** | User configuration is sequential and nontransactional, loaded before host construction. That is a suitable deterministic registration lane, but a later failed form leaves earlier stylesheet definitions applied: `tuna/tuna/lib/config.ss:29-41`; `tuna/tuna/main.ss:15-23`. |
| **Medium** | Tuna has live functions, transitions, and values, but no running attached evaluator. Runtime CSS replacement is therefore a ready semantic seam, not currently an exposed product workflow: `tuna/tuna/README.md:470-477`; `research/tuna-attached-repl-final-recommendation.md:50-78,119-151`. |
| **Low** | Existing protocol tests exercise state/profiler streams but do not assert asset cache headers or stylesheet ordering. The current validation script checks only JavaScript embedding and hashes: `tuna/tuna/test/run-server-runtime-validation.sh:63-104`. |

No Tuna `CONTEXT.md`, `CONTEXT-MAP.md`, or ADR was found. The relevant durable decisions are the research documents cited above.

## Recommended API and semantics

### Public authoring surface

Add one definition form to `:tuna/lib/prelude`:

```scheme
(defstylesheet tuna-counter
  package:
  ".tuna-counter { ... }")

(defstylesheet jay-tuna-theme
  user:
  ":root { ... }")
```

Its low-level operation should be:

```scheme
(define-stylesheet! name tier css)
```

Contract:

- `name` is an interned, package-prefixed symbol.
- `tier` is exactly `package` or `user`; core is private and cannot be claimed by extensions.
- `css` is valid UTF-8 text copied at definition time.
- First definition creates one stable identity and ordering slot.
- Re-evaluating the same name atomically replaces its bytes without adding or moving a link.
- Reusing a name with a different tier is an error.
- A user override should define a distinct user-tier sheet rather than move a package sheet.
- No public removal/unload operation is necessary initially; redefining to empty CSS is sufficient until package unloading is real.

This mirrors Tuna’s deliberate stable-cell behavior: registry publication is synchronized, names are stable, and one replacement is atomic, while multi-form replacement is not transactional (`tuna/tuna/lib/bindings.ss:69-149,345-422`; `tuna/tuna/README.md:526-532`). It does not need aliases, advice, documentation descriptors, local values, or another general callable kind.

### Package and user registration

Package modules should own and export their CSS text. For file-backed package CSS, use Gerbil’s supported compile-time embedding:

```scheme
(def counter-css
  (utf8->string
   (this-source-content "../web/counter.css")))
```

`this-source-content` embeds ancillary bytes into the object so the runtime file is unnecessary: `gerbil/doc/reference/std/source.md:90-103`; current Tuna use is `tuna/tuna/private/web-assets.ss:1-11`.

The package build must list the file under `extra-inputs:` so incremental builds notice CSS-only changes: `gerbil/doc/reference/std/make.md:40-57`; current Tuna precedent is `tuna/tuna/build.ss:16-19`.

User configuration then determines explicit order:

```scheme
(import :tuna/lib/prelude
        (only-in :tuna-example-counter/web counter-css))

(defstylesheet tuna-counter package: counter-css)
(defstylesheet jay-tuna-theme user: "...")
```

This avoids depending on the initialization order of several modules inside one import form. The selected config still follows Tuna’s existing single-source precedence and sequential evaluation model: `tuna/tuna/README.md:164-183`; `tuna/tuna/lib/config.ss:29-41`.

Do not add runtime filesystem serving or file watching. A user may read a CSS file from trusted configuration, but Tuna should retain copied text, not a path.

## Ordering, URLs, and cache behavior

### Cascade order

The private registry should retain two ordered lists:

1. package names by first successful registration;
2. user names by first successful registration.

The page shell always prepends core CSS. Thus source order is deterministic:

```html
<link rel="stylesheet" href="/assets/tuna-core-v1.css">
<link rel="stylesheet" href="/assets/styles/tuna-counter.css">
<link rel="stylesheet" href="/assets/styles/jay-tuna-theme.css">
```

This provides predictable source-order fallback without inventing numeric priorities, `before`/`after` graphs, or cascade-layer policy. Extensions must still keep specificity low and avoid IDs and `!important`, as required by `docs/agents/html-css.md:33-51`.

Names should be encoded with Gerbil’s public `uri-encode` rather than accepted as raw paths; its unreserved set and encoder are implemented at `gerbil/src/std/net/uri.ss:8-14,36-47`.

### Cache policy

| Asset | URL | Headers | Reason |
|---|---|---|---|
| Core CSS | `/assets/tuna-core-v1.css` | `text/css; charset=utf-8`; `public, max-age=31536000, immutable` | Compiled bytes and versioned identity, matching current JavaScript policy. |
| Package/user CSS | `/assets/styles/<encoded-name>.css` | `text/css; charset=utf-8`; `no-store` | Stable URL may return a later live definition. |
| HTML | `/` | Existing `no-store` | Reload must receive the current ordered link list. |

`no-store` is deliberately simpler than premature Entity Tag (ETag), `Last-Modified`, generation-retention, or content-addressed URLs. Marking a stable live URL immutable would allow stale CSS indefinitely. Content-hashed URLs would require retaining old generations or ensuring the URL and response bytes cannot diverge.

A running page does not automatically update when CSS is redefined. Reload is the explicit boundary, consistent with the current profiler’s page-presence semantics at `tuna/tuna/private/http.ss:147-149` and `tuna/tuna/README.md:46-49`.

## Page shell and HTTP boundary

Keep `tuna-render-state` unchanged. Add a private helper such as:

```scheme
(render-stylesheet-links)
```

to the HTTP/page module. `render-page` should snapshot the ordered stylesheet descriptors once and insert their generated links after `<title>` and before scripts. The current fixed head is at `tuna/tuna/private/http.ss:128-145`.

Move `tuna-profiler-style` into the core stylesheet. Profiler markup remains conditional, but harmless selectors can always be present.

Use:

- one exact fixed route for core CSS;
- one `rest:` rule for `/assets/styles`;
- a private registry lookup by exact encoded request path;
- GET-only behavior matching existing assets.

Gerbil’s current static mux preserves rule order and supports exact and prefix rules: `gerbil/src/std/net/http/server/mux/static.ss:21-54,57-82`. Closure handlers adapt a procedure to the `RequestHandler` interface: `gerbil/src/std/net/http/server/handlers/closure.ss:8-19`.

Handlers must still call exactly one response method: `gerbil/src/std/net/http/server/interface.ss:35-70`.

The older `:std/net/httpd` documentation describes dynamic handler registration (`gerbil/doc/reference/std/net/httpd.md:53-83`), but Tuna imports the newer `:std/net/http/server` API and currently constructs `new-static-mux` once during host startup (`tuna/tuna/private/http.ss:340-351`; `tuna/tuna/private/host.ss:162-178`). The old facility is evidence that Gerbil can support dynamic routing, not a reason for Tuna to expose it.

## Performance and thread ownership

- Gerbil creates listener and HTTP handler threads; request work is concurrent: `gerbil/src/std/net/http/server/server.ss:26-48,154-168`.
- The stylesheet registry should have its own small mutex, separate from application-state and live-binding mutexes.
- Definition copies UTF-8 bytes under or before publication and updates one descriptor on a cold path.
- Page rendering snapshots the ordered link list under the stylesheet mutex, then releases it before rendering or network writes.
- A CSS handler snapshots one immutable bytevector under the mutex, releases it, then calls `ResponseHandler-write!`.
- Never invoke package code or perform filesystem/network I/O while holding the registry mutex.
- Never register/rebuild CSS on Tuna’s command-owner thread. That thread exclusively serializes application transitions and state installation: `tuna/tuna/private/runtime.ss:168-193,195-233,315-355`.
- Startup config is the present registration owner. A future attached evaluator should serialize definitions on its separate evaluation lane, never the command owner: `research/tuna-attached-repl-final-recommendation.md:50-78,175-207`.

Per-sheet delivery makes page rendering O(number of registered sheets), lookup O(1), and network writes O(sheet size). Registration is cold. Separate links avoid rebuilding/concatenating every sheet and preserve ordinary standalone stylesheet semantics. The request count is acceptable for a loopback application until measurements show otherwise.

## Material alternatives

### 1. One aggregated `/assets/tuna.css`

**Advantages:** one request, one coherent generation, fixed head link.

**Disadvantages:** every replacement must rebuild the aggregate; arbitrary stylesheet concatenation can invalidate late `@import`/`@charset`; source URLs and diagnostics become less clear. Wrapping contributions in cascade layers would add CSS-language policy prematurely.

Use only if package counts or request measurements justify it.

### 2. Content-addressed per-sheet URLs

**Advantages:** immutable caching for every generation.

**Disadvantages:** hashing and generation retention are required; page reload and old cached URLs must map to exact old bytes. This is needless complexity for small local CSS.

### 3. Generic asset/head/route registry

**Reject now.** It would require contracts for:

- route conflicts and precedence;
- methods and `HEAD`;
- MIME and cache policies;
- arbitrary request/response ownership;
- authentication and Cross-Site Request Forgery policy;
- streaming and shutdown;
- arbitrary script/meta/head injection;
- handler replacement during active requests.

The existing CSS need establishes none of those requirements.

## What should not be generalized yet

Do not add:

- `register-route!`, mutable mux access, middleware, or arbitrary handlers;
- generic assets with caller-selected URL, MIME type, or cache headers;
- arbitrary `<head>` node or script registration;
- CSS parsing, minification, preprocessors, design tokens, or generated frameworks;
- cascade-layer wrapping or numeric priority systems;
- runtime file serving, filesystem watches, package unload, or automatic reload;
- browser-side CSS hot replacement or Datastar head morphing;
- CSS or web configuration inside the authoritative application root;
- a second runtime, broadcaster, or state store.

These exclusions preserve the established separation of process-wide live definitions from instance-owned application state: `research/tuna-host-neutral-state-architecture.md:5-16,121-157`.

## Risks and unresolved gaps

- **High:** no implementation or behavior tests currently attest stylesheet ordering, routing, headers, or replacement.
- **Medium:** first registration from racing threads has mutex-linearized but scheduling-dependent order. Normal registration should remain on sequential config/evaluator lanes.
- **Medium:** several stylesheet replacements are not transactional; a page may fetch a mixture of generations. This matches current multi-binding semantics but may eventually justify an aggregate generation.
- **Medium:** Tuna has no attached evaluator yet, so post-start live redefinition is not currently reachable through a supported product endpoint.
- **Medium:** importing an already loaded package does not rerun initialization; registration should be explicit rather than rely on re-import: `tuna/tuna/README.md:502-508`.
- **Low:** `no-store` refetches package/user CSS on each reload. This is intentional until measured.
- **Low:** user CSS is trusted configuration and may contain remote `url(...)` references; it is not a sandbox.
- **Low:** core version changes require changing the URL whenever bytes change.

**Confidence:** high for the boundary, cache distinction, renderer ownership, Gerbil mux/thread mechanics, and exclusions; medium-high for the exact macro spelling and registration-order policy.

## Validation commands

No build or test was run during this read-only investigation.

### Focused after implementation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
gerbil build
gerbil test -v 0 \
  ./test/documentation-test.ss \
  ./test/server-runtime-test.ss \
  ./test/server-protocol-test.ss
test/run-command-runtime-matrix.sh
```

Gerbil explicitly supports passing files and directories to `gerbil test`: `gerbil/doc/reference/dev/test.md:17-25`. The matrix compiles Tuna in source, normal, and `gxc -O` modes and checks worktree stability: `tuna/tuna/test/run-command-runtime-matrix.sh:49-147`.

Focused tests should cover:

- core/package/user head order;
- duplicate definition replacement without duplicate/moved links;
- tier-change rejection;
- exact CSS MIME/cache headers;
- GET/405/404 behavior;
- complete old-or-new bytes during concurrent replacement;
- no stylesheet link changes during body-only SSE patches;
- core CSS embedding and `extra-inputs:`.

### Full repository gate

```sh
cd /home/jay/Code/workbench-gerbil/tuna
make test

cd /home/jay/Code/workbench-gerbil
tuna/tuna/test/run-server-runtime-validation.sh
```

`make test` builds Tuna and both example packages and runs their suites: `tuna/Makefile:27-35`. The server gate runs the recursive suite, source/normal/optimized matrix, executable checks, and deterministic assets: `tuna/tuna/test/run-server-runtime-validation.sh:14-104`.

Repository inspection found active Gerbil `v0.19-dev-32-g4531c21b`, so the older dev31 chunk-terminator blocker recorded in prior research is stale. Tuna is at `0fb795ad59c954e1d0c6245b298e8718bcb6a3df` with a pre-existing unstaged `.gitignore` modification; neither the outer nor Tuna repository has staged files.