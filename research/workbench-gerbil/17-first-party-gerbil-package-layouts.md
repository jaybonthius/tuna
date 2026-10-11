# First-party Gerbil package layout survey

## Scope and conclusion

Surveyed `/home/jay/Code/gerbil` at commit `0618730d4e30bf3f48538d6b09722ad3b6056414`. The census covers Gerbil-owned `src/` code and excludes the vendored Gambit subtree.

**Bottom line:** third-party packages should copy Gerbil’s documented package-level contract—root `gerbil.pkg`, root `build.ss`, namespace-mirroring source directories, co-located `*-test.ss` modules, and `gerbil pkg env gxtest ./...`. They should **not** copy stdlib bootstrapping, the monorepo-wide `build-spec.ss`, the separate core compiler test package, reserved namespaces, or the pregexp upstream manifest.

## Quantified census

| Item | Count | Interpretation |
|---|---:|---|
| `src/**/*.ss` | 828 | Gerbil source census |
| `src/**/*-test.ss` | 103 | Actual discovery naming convention |
| `src/**/test.ss` | 1 | `src/std/test.ss`, the testing library—not an aggregator |
| stdlib `*-test.ss` | 92 | Spread across 26 source directories |
| tools `*-test.ss` | 3 | All suite modules at `src/tools` root |
| core `src/gerbil/test/**/*-test.ss` | 7 | Separate core/compiler test package |
| lang `*-test.ss` | 1 | Co-located under `src/lang/scheme` |
| std literal `test/` or `tests/` directories | 0 | Unit tests are co-located |
| explicit `private/`, `internal/`, or `internals/` directories in std/tools | 0 | No such directory convention |
| `src/**/gerbil.pkg` | 19 | Includes package roots and nested test fixtures |
| `src/**/build.ss` | 16 | Every build has a sibling `gerbil.pkg` |
| package markers without sibling `build.ss` | 3 | `src/gerbil/test`, its support subtree, and umbrella `src/tutorial` |
| checked-in `manifest.ss`/`*.manifest` | 0 | No normal first-party version manifest |
| std README files | 8 | Mostly imported or specialized components |
| tools README files | 0 | Tool documentation is not package-local |
| std/tools `doc(s)/` or `example(s)/` directories | 0 | Documentation/examples are centralized |

Of the 92 stdlib test files, **82 have an immediate same-directory production sibling with the same stem**. The remaining 10 are module-level or grouped suites such as `protobuf/protobuf-test.ss`, `text/json/json-test.ss`, and `net/websocket/websocket-test.ss`.

## Sample surveyed

1. `src/std/misc` — 70 `.ss` files, 30 `*-test.ss`.
2. `src/std/net/s3` plus `src/std/net/s3.ss` — façade/API/interface structure, one co-located test.
3. `src/std/net/httpd` plus `src/std/net/httpd.ss` and `httpd-test.ss` — composite module with parent-level façade/test.
4. `src/std/protobuf` — five `.ss` modules, one grouped suite, two `.proto` fixtures.
5. `src/std/actor-v18` — 32 `.ss` files, seven suites, three test-support modules.
6. `src/std/pregexp` plus `src/std/pregexp.ss` — imported upstream sources, README and upstream file-list manifest.
7. `src/tools` with `gxhttpd` and `gxensemble` — three root suites and nested fixture projects.
8. `src/gerbil/test` — seven separate core/compiler regression suites.
9. `src/lang/scheme` — one co-located implementation suite.

## Findings

### 1. `*-test.ss` is both documented and enforced

The official test guide says test files use `-test.ss`, are generally not compiled, and export suites whose names end in `-test`; optional setup/cleanup hooks are also defined there (`doc/reference/dev/test.md:6-20`). Its worked example places `mylib-test.ss` directly beside `mylib.ss` (`doc/reference/dev/test.md:35-65`).

`gxtest` implements that convention rather than merely recommending it:

- direct and recursive directory discovery only accepts filenames ending in `-test.ss` (`src/tools/gxtest.ss:101-124`);
- it only treats runtime exports ending in `-test` as suites (`src/tools/gxtest.ss:142-151`);
- `test-setup!` and `test-cleanup!` are recognized specially (`src/tools/gxtest.ss:152-161`).

A representative simple suite imports its production sibling and `:std/test`, exports `deque-test`, then defines that suite (`src/std/misc/deque-test.ss:1-13`). S3 follows the same pattern (`src/std/net/s3/sigv4-test.ss:1-20`).

**Constraint:** names such as `test-lib.ss`, `loader-test-support.ss`, or `test.ss` are support/library names and will not be recursively discovered as suites.

Three std test files also define a `main`, but they still retain the `*-test.ss` convention; standalone entry points are exceptional rather than an alternative naming system.

### 2. Tests are normally co-located, not under a separate test tree

The contribution guide explicitly requires tests to live beside the file they cover, or use the module name when covering a whole module (`CONTRIBUTING.md:166-174`). The census found no literal `test/` or `tests/` directory in `src/std` and no such unit-test structure in `src/tools`.

Examples of grouped placement:

- `src/std/net/httpd-test.ss` sits beside façade `src/std/net/httpd.ss`, while implementation files live in `src/std/net/httpd/`. The suite imports the public module and exports hooks plus `httpd-test` (`src/std/net/httpd-test.ss:1-18`).
- `src/std/protobuf/protobuf-test.ss` lives with the protobuf implementation and `.proto` fixtures, exporting one grouped suite (`src/std/protobuf/protobuf-test.ss:1-23`).
- Actor tests and their support files are mixed with implementation modules. For example, `ensemble-test.ss` uses relative implementation imports and `test-util`, and exports setup/cleanup (`src/std/actor-v18/ensemble-test.ss:1-30`).

Two important monorepo exceptions are not general package templates:

- `src/gerbil/test` is a separate `(package: test)` tree for compiler/runtime regression testing (`src/gerbil/test/gerbil.pkg:1`). Compiler tests dynamically compile fixture modules from that tree (`src/gerbil/test/compiler-test.ss:1-41`).
- Tool integration suites remain at `src/tools/*-test.ss`, but create isolated fixture projects in `gxhttpd-test/` and `gxensemble-test/project/`. The HTTP suite builds its fixture and launches a server in setup (`src/tools/gxhttpd-test.ss:1-31`); the fixture has its own minimal build and package files (`src/tools/gxhttpd-test/build.ss:1-5`, `src/tools/gxhttpd-test/gerbil.pkg:1`).

### 3. There are no `test.ss` aggregators

The sole `test.ss` is `src/std/test.ss`, the `:std/test` framework. Discovery is performed dynamically by `gxtest`, so first-party packages do not maintain hand-written suite aggregators.

This also explains why normal tests are absent from build specifications: the test guide says they are generally not compiled (`doc/reference/dev/test.md:8-15`). The std build spec contains production modules such as HTTP and deque (`src/std/build-spec.ss:311-320`, `356-375`), but no `*-test.ss`; `foreign-test-support` is an explicitly compiled support module (`src/std/build-spec.ss:11-14`).

### 4. `gerbil.pkg` belongs at the package root; directories extend its namespace

The std and tools roots contain minimal namespace declarations:

- `src/std/gerbil.pkg:1` — `(package: std)`
- `src/tools/gerbil.pkg:1` — `(package: gerbil/tools)`

The language guide explains that `gerbil.pkg` defines the root prefix and nested directories extend it (`doc/guide/intro.md:1378-1395`).

Subdirectories such as `src/std/misc`, `src/std/protobuf`, and `src/std/actor-v18` are therefore **modules/subpackages within one std package**, not independent distributable packages. They do not contain their own `gerbil.pkg` or `build.ss`.

For a public third-party repository, the package guide is stricter: it should have `gerbil.pkg` with nominal `package:` and `depend:` properties and a `build.ss` supporting package-manager actions (`doc/guide/package-manager.md:22-35`).

### 5. Build conventions split between reusable and core-only patterns

`src/tools/build.ss` is a reusable-looking `:std/build-script` declaration listing modules and output directories (`src/tools/build.ss:1-30`). `src/lang/build.ss` similarly uses `defbuild-script` (`src/lang/build.ss:1-37`). These are closer to what a third-party package should follow.

The stdlib is different:

- `src/std/build.ss` performs custom load-path, Gambit include and dynamic build-module setup (`src/std/build.ss:1-16`);
- every std module must be entered into the monorepo-level `src/std/build-spec.ss`, as documented in `CONTRIBUTING.md:137-144`.

That machinery exists to bootstrap Gerbil’s own standard library and should not be copied into ordinary packages.

### 6. Public façade/API/interface organization is common; named private directories are not

The documented stdlib convention is:

- a same-named façade file beside a same-named directory;
- `api.ss` for public API;
- `interface.ss` for exported interfaces;
- other implementation files should generally not be imported externally (`CONTRIBUTING.md:146-164`).

S3 is the canonical example: `src/std/net/s3.ss` imports and re-exports `./s3/api` and `./s3/interface` (`src/std/net/s3.ss:1-5`).

No directory literally named `private`, `internal`, or `internals` exists in std/tools. Privacy is expressed through exports and façade boundaries, with implementation-oriented names such as `base`, `types`, `impl`, `api`, and `interface`. A third-party package may copy the façade pattern, but there is no evidence for a first-party `private/` directory convention.

### 7. Manifests are not normal checked-in package layout files

The only source file named `manifest` is `src/std/pregexp/manifest`. Its contents are an upstream distribution file list—including `COPYING`, `pregexp.scm`, dialects and known-bug files (`src/std/pregexp/manifest:1-14`)—not a Gerbil dependency/version manifest.

No `manifest.ss` or `*.manifest` is checked into `src/`. Gerbil’s build guide describes `manifest.ss` as a generated exact-version record containing project, Gerbil, Gambit and dependency revisions (`doc/reference/dev/build.md:402-420`). It should not be inferred as a mandatory source-layout file from this monorepo.

### 8. Documentation and examples are centralized

The sampled mature modules generally have reference documentation under `doc/reference/std`, not beside source:

- `doc/reference/std/misc/deque.md:1-13`
- `doc/reference/std/net/httpd.md:1-7`
- `doc/reference/std/protobuf.md:1-8`
- `doc/reference/std/actor.md:1-10`
- `doc/reference/std/net/s3.md:1-8`

HTTP examples are in centralized tutorial documentation and `src/tutorial/httpd`, rather than under `src/std/net/httpd` (`doc/tutorials/httpd.md:23-31`).

This is a core documentation-site convention, not evidence that third-party repositories should omit README or package-local docs.

### 9. CI and test invocation

Core CI installs the completed toolchain and runs:

```sh
gxtest -q src/gerbil/test/... src/std/... src/lang/... src/tools/...
```

Evidence: `.github/workflows/ci.yml:60-69`.

The root convenience target is:

```sh
make check
# invokes ./build.sh env gxtest ./...
```

Evidence: `Makefile:9-10`; the contribution guide also identifies `make check` and `./build.sh env gerbil test ./...` as full pre-PR checks (`CONTRIBUTING.md:176-183`).

For an isolated third-party package, the documented command is:

```sh
gerbil pkg env gxtest ./...
```

This supplies the package-local `GERBIL_PATH` (`doc/reference/dev/build.md:593-603`).

## What third-party packages should copy

1. Root `gerbil.pkg` with a non-core namespace and declared external dependencies.
2. Root executable `build.ss`, preferably using `:std/build-script`.
3. Directory hierarchy mirroring the package namespace.
4. Co-located `foo-test.ss` beside `foo.ss`, exporting one or more names ending in `-test`.
5. Optional exported `test-setup!`/`test-cleanup!` for file-level fixtures.
6. `gerbil pkg env gxtest ./...` for package-local full testing.
7. A façade plus `api.ss`/`interface.ss` split where module depth warrants it.
8. Separate nested fixture projects only when integration tests genuinely need package isolation.

## What third-party packages should not copy

1. The custom stdlib bootstrap in `src/std/build.ss`.
2. The monorepo-wide `src/std/build-spec.ss` registration process.
3. Reserved prefixes such as `std`, `gerbil`, or `gerbil/tools`.
4. `src/gerbil/test` as a general separate-test-directory precedent.
5. `src/std/pregexp/manifest` as a package manifest template.
6. The absence of package-local README/docs; Gerbil itself has a centralized documentation site.
7. A `test.ss` aggregator—`gxtest` performs discovery.

## Evidence-backed validation commands

Focused suite, using the Gerbil checkout environment:

```sh
cd /home/jay/Code/gerbil
./build.sh env gxtest src/std/misc/deque-test.ss
```

Focused third-party package:

```sh
cd /path/to/package
gerbil pkg env gxtest path/to/module-test.ss
```

Full third-party package:

```sh
cd /path/to/package
gerbil pkg env gxtest ./...
```

Full Gerbil monorepo:

```sh
cd /home/jay/Code/gerbil
make check
```

CI-equivalent scope after installing the built toolchain:

```sh
gxtest -q src/gerbil/test/... src/std/... src/lang/... src/tools/...
```

These execution commands were not run because this assignment was read-only and some tool integration suites create build trees, launch processes, bind ports, and clean fixtures.

## Risks and confidence

- **No blockers found.**
- **Medium caution:** core stdlib layout is optimized for a bootstrapped monorepo and is misleading as a standalone package template.
- **Low caution:** counts are filename/static-layout counts, not proof that every discovered suite currently passes.
- **Low caution:** this is a single commit snapshot; conventions may evolve.
- The existing untracked `/home/jay/Code/gerbil/.scheme-langserver.log` predates this survey; no tracked or staged files were changed.
- Confidence: **high** for naming, placement, package/build, discovery and CI conclusions; **medium-high** for documentation/manifest conclusions because package ecosystems may add conventions not represented in the core repository.