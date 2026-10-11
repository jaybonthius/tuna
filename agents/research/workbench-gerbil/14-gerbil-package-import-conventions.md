# Gerbil package naming and public import conventions

## Decision

Use `/home/jay/Code/workbench-gerbil/datastar-gerbil` as the package root with this layout:

```text
datastar-gerbil/
├── gerbil.pkg       ; (package: datastar)
├── build.ss         ; target "http"
├── http.ss          ; public façade, imported as :datastar/http
├── http/            ; optional implementation modules
└── http-test.ss     ; or other *-test.ss files
```

**Do not place `http.ss` at `datastar-gerbil/datastar/http.ss` while the parent `gerbil.pkg` says `(package: datastar)`.** That combination conventionally produces `:datastar/datastar/http`, not `:datastar/http`.

A statement that “a `datastar` package exposes `:datastar/http` from a `datastar/` directory” is correct only when that `datastar/` directory is itself the package root and contains `gerbil.pkg` beside `http.ss`. The package-root directory’s basename is not included; child directories below it are.

## Findings

### High — Package prefix and source-relative directories are cumulative

Gerbil finds the nearest ancestor `gerbil.pkg`, accumulates intervening directory names, then prepends its `package:` value:

- `/home/jay/Code/gerbil/src/gerbil/expander/module.ss:361-390`
- In particular, directory components are accumulated at lines 385-390 and the manifest prefix is prepended at lines 371-378.

The documented build rule is equally explicit: prefix `legs` plus source `foo/bar.ss` produces module `legs/foo/bar`, imported as `:legs/foo/bar`:

- `/home/jay/Code/gerbil/doc/reference/std/make.md:124-131`
- `/home/jay/Code/gerbil/src/std/make.ss:89-95,130-132`

Therefore:

| `gerbil.pkg` at package root | Source path relative to root | Public module |
|---|---|---|
| `(package: datastar)` | `http.ss` | `:datastar/http` |
| `(package: datastar)` | `datastar/http.ss` | `:datastar/datastar/http` |
| empty manifest | `datastar/http.ss` | `:datastar/http` |
| `(package: owner/datastar)` | `http.ss` | `:owner/datastar/http` |
| `(package: owner)` | `datastar/http.ss` | `:owner/datastar/http` |

The empty-manifest alternative is supported by `/home/jay/Code/gerbil/doc/guide/intro.md:1392-1395`, but it is less suitable for a published library because the package-manager guide says the manifest should nominally declare a common `package:` prefix: `/home/jay/Code/gerbil/doc/guide/package-manager.md:24-29`.

### High — The conventional root puts `gerbil.pkg`, `build.ss`, and source-relative modules together

The canonical documentation creates:

```text
example/
├── gerbil.pkg       ; (package: example)
└── util.ss
```

and imports it as `:example/util`:

- `/home/jay/Code/gerbil/doc/guide/intro.md:1210-1235`

For package-manager distribution, a public repository is expected to contain `gerbil.pkg` and `build.ss` at its package root:

- `/home/jay/Code/gerbil/doc/guide/package-manager.md:22-35`

`defbuild-script` uses the directory containing `build.ss` as `srcdir`, and reads the package prefix from that directory’s `gerbil.pkg`:

- `/home/jay/Code/gerbil/doc/reference/std/make.md:116-131`

First-party stdlib follows the same rule:

- `/home/jay/Code/gerbil/src/std/gerbil.pkg:1` declares `(package: std)`.
- `/home/jay/Code/gerbil/src/std/markup/sxml.ss:1-8` is below that root and exposes `:std/markup/sxml`.
- `/home/jay/Code/gerbil/src/std/markup/sxml-test.ss:1-3` imports that exact name.

### Medium — Repository locator and module namespace are separate

Provider-qualified names such as `github.com/mighty-gerbils/gerbil-utils` identify repositories to the package manager; they do not automatically become import prefixes:

- `/home/jay/Code/gerbil/doc/guide/package-manager.md:39-49`

Representative maintained libraries demonstrate independently chosen module namespaces:

1. **gerbil-utils** declares `clan`, with root `json.ss` becoming `:clan/json`.
   - [`gerbil.pkg:1-2`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/gerbil.pkg#L1-L2)
   - [`t/json-test.ss:3-10`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/t/json-test.ss#L3-L10)

2. **gerbil-libxml** declares `clan`, builds `xml/libxml`, and documents `:clan/xml/libxml`.
   - [`gerbil.pkg:1`](https://github.com/mighty-gerbils/gerbil-libxml/blob/e190703385b5fd3d2642133c3ebf38bf932368b0/gerbil.pkg#L1)
   - [`build.ss:3-12`](https://github.com/mighty-gerbils/gerbil-libxml/blob/e190703385b5fd3d2642133c3ebf38bf932368b0/build.ss#L3-L12)
   - [`README.md:19-22`](https://github.com/mighty-gerbils/gerbil-libxml/blob/e190703385b5fd3d2642133c3ebf38bf932368b0/README.md#L19-L22)

3. **gerbil-crypto** declares the compound prefix `clan/crypto` and builds root files such as `random.ss`, yielding `:clan/crypto/random`.
   - [`gerbil.pkg:1-4`](https://github.com/mighty-gerbils/gerbil-crypto/blob/c8c17ac0e996ebfb65c4b9024b2a93a21d40df7c/gerbil.pkg#L1-L4)
   - [`build.ss:18-31`](https://github.com/mighty-gerbils/gerbil-crypto/blob/c8c17ac0e996ebfb65c4b9024b2a93a21d40df7c/build.ss#L18-L31)
   - [`t/random-test.ss:3-8`](https://github.com/mighty-gerbils/gerbil-crypto/blob/c8c17ac0e996ebfb65c4b9024b2a93a21d40df7c/t/random-test.ss#L3-L8)

A maintained local example uses a distinctive project name directly: `/home/jay/Code/gerbil-mcp/gerbil.pkg:1-3` declares `gerbil-mcp`; root-relative modules are built in `/home/jay/Code/gerbil-mcp/build.ss:5-24` and imported as `:gerbil-mcp/...` in `/home/jay/Code/gerbil-mcp/lib.ss:4-12`.

## When to use an owner-qualified prefix

Gerbil recommends a top-level namespace to avoid collisions, and its project generator defaults that prefix to the username:

- `/home/jay/Code/gerbil/doc/guide/getting-started.md:106-123`
- The generated example uses `(package: vyzo)` plus `hello/lib.ss`: `/home/jay/Code/gerbil/doc/guide/getting-started.md:127-155`.

Use `:<owner>/datastar/http` when:

- this is an unofficial or owner-specific Datastar binding;
- the direct `datastar` namespace is not intended to represent the canonical Gerbil Datastar SDK;
- the owner maintains several libraries under one durable namespace; or
- collision/provenance protection outweighs import brevity.

Use `:datastar/http` when the library is intended as the canonical, ecosystem-facing Gerbil Datastar package. Gerbil does not automatically enforce or reserve that name, so this is a public identity commitment rather than a technical entitlement.

For an owner-qualified design, prefer:

```scheme
(package: owner/datastar)
```

with root `http.ss`. The equivalent `(package: owner)` plus `datastar/http.ss` also works, but the compound prefix more clearly makes this repository’s package identity `owner/datastar`, matching the maintained `clan/crypto` precedent.

## Tailored recommendation

Adopt the direct canonical identity:

```scheme
;; datastar-gerbil/gerbil.pkg
(package: datastar)
```

Build root target `"http"` and expose a deliberately small façade from `datastar-gerbil/http.ss`. Place implementation modules under `datastar-gerbil/http/`, producing names such as `:datastar/http/sse`, while keeping `:datastar/http` stable.

This matches the requested public API, avoids duplicated path components, and follows both the canonical documentation and maintained-library practice.

## Current constraints and residual risks

- **Medium — Publishing root:** `/home/jay/Code/workbench-gerbil/datastar-gerbil` is currently an ordinary nested directory, not a separate Git repository. Evidence: `/home/jay/Code/workbench-gerbil/research/09-target-repository-and-environment.md:13-24`. If `workbench-gerbil` itself is published through `gxpkg`, a manifest only under `datastar-gerbil/` will not match the documented repository-root layout. Publish that directory as the standalone package repository/subtree, or deliberately make the outer repository the package root.
- **Medium — Namespace ownership:** `datastar` is concise but globally collision-prone. The choice assumes canonical SDK intent.
- **High, current-state only:** the target is empty and has no manifest, build, source, or tests: `/home/jay/Code/workbench-gerbil/research/09-target-repository-and-environment.md:30-43`. No project build can yet attest the proposed import.
- **Confidence:** high for module-name mechanics and layout; medium-high for the direct-name recommendation because canonical ownership is a product identity matter rather than a Gerbil rule.

## Evidence-backed validation after implementation

The complete toolchain is at `/opt/gerbil/bin`, not inherited through `PATH`: `/home/jay/Code/workbench-gerbil/research/00-research-synthesis.md:94-116`.

Focused:

```sh
cd /home/jay/Code/workbench-gerbil/datastar-gerbil
unset GERBIL_PATH
/opt/gerbil/bin/gerbil build
/opt/gerbil/bin/gerbil env /opt/gerbil/bin/gxi -e '(import :datastar/http)'
/opt/gerbil/bin/gerbil test -q ./http-test.ss
```

Full:

```sh
cd /home/jay/Code/workbench-gerbil/datastar-gerbil
unset GERBIL_PATH
/opt/gerbil/bin/gerbil deps -i   # when depend: entries exist
/opt/gerbil/bin/gerbil build
/opt/gerbil/bin/gerbil test -q ./...
```

Gerbil documents recursive package testing at `/home/jay/Code/gerbil/doc/reference/dev/build.md:591-603` and build-in-current-directory at `/home/jay/Code/gerbil/doc/guide/getting-started.md:214-230`. No evidence-backed Gerbil formatter or linter exists in the reviewed material.