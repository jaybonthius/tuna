# Gerbil v19 static asset embedding research

## Conclusion

**Gerbil v19 has a supported public facility for this use case:** `this-source-content` from `:std/source`.

It reads an ancillary file as exact bytes during macro expansion and expands to a quoted `u8vector` embedded in the compiled object. Gerbil’s documentation explicitly says the file is “burnt into your object file at compile time” and need not exist at runtime (`gerbil/doc/reference/std/source.md:90-103`).

Tuna can therefore replace its generated 124,541-byte `private/assets-generated.ss` with a small hand-written module using `this-source-content`, while retaining:

- normal `gerbil build`;
- exact bytes;
- executable relocation and current-working-directory independence;
- direct `gxc` and `gxc -O` compilation;
- no runtime asset files.

There is no evidence of a separate Go-style embedded filesystem, resource table, wildcard resource directive, or supported executable-appended-resource API. `this-source-content` is the idiomatic public Gerbil equivalent for fixed ancillary files.

**Recommendation:** use `:std/source` and declare both asset files as `extra-inputs:` in `build.ss`. This is less complex than the current generator and uses the facility specifically documented for ancillary source content.

**Confidence: high (0.95)** for the inspected checkout, Gerbil `v0.19-dev-32-g4531c21b`.

## Recommended shape

A hand-written module can preserve the current public module interface:

```scheme
prelude: :gerbil/core

(import :std/source)

(export datastar-javascript tuna-keyboard-javascript)

(def datastar-javascript
  (this-source-content "../assets/source/datastar-v1.0.2.js"))

(def tuna-keyboard-javascript
  (this-source-content "../assets/generated/tuna-keyboard-v1.js"))
```

Its build target should track files read during expansion:

```scheme
(gxc: "private/assets-generated"
      (extra-inputs:
       ("assets/source/datastar-v1.0.2.js"
        "assets/generated/tuna-keyboard-v1.js")))
```

The paths intentionally differ:

- `this-source-content` resolves relative to the invoking source file, hence `../assets/...`;
- `extra-inputs:` is evaluated with the project source directory as the build working directory, hence `assets/...`.

Keeping the existing module name minimizes downstream changes, although renaming it from `assets-generated` to `assets` would better describe a hand-written module.

## Authoritative evidence

### Public byte embedding facility

- `gerbil/doc/reference/std/source.md:1-12` identifies `:std/source` as the public library for source locations and ancillary files.
- `gerbil/doc/reference/std/source.md:90-103` documents `this-source-content`, its `u8vector` result, compile-time embedding, and absence of any runtime file requirement.
- `gerbil/src/std/source.ss:24-30` resolves paths from the source form’s directory and reads the file with `read-file-u8vector`.
- `gerbil/src/std/source.ss:54-58` implements `this-source-content` by inserting that bytevector into a quoted expansion.
- `gerbil/src/std/source-test.ss:6-18` exercises the public macro and verifies embedded source bytes.
- `gerbil/src/std/build-spec.ss:203-206` includes `source` in the v19 standard-library build, so this is not merely abandoned or private source.

The underlying Gambit operation also has public byte-exact semantics:

- `gerbil/src/gambit/doc/gambit.txi:17110-17129` documents `read-file-u8vector` as returning “the bytes in the file”; character encoding applies only to string readers.
- `gerbil/src/gambit/lib/_nonstd.scm:2287-2318` allocates `u8vector` storage, reads bytes with `read-subu8vector`, shrinks to the actual count, and returns the vector.

### Compiler and optimizer support

The macro expansion is an ordinary quoted homogeneous vector:

- `gerbil/src/std/source.ss:54-58` expands directly to `(quote content)`.
- `gerbil/src/gerbil/compiler/compile.ss:832-860` explicitly accepts `u8vector` and all other homogeneous vectors in compiled quoted constants.
- `gerbil/src/gerbil/compiler/optimize-top.ss:855-880` recognizes `u8vector` as a sequence with the `u8vector::t` optimizer type.
- `gerbil/src/gerbil/gxc-main.ss:31-64,104-109` shows `-O` sets the ordinary Gerbil optimizer option.
- `gerbil/src/std/make.ss:512-527` passes the build tool’s optimization setting to `compile-module`; normal `:std/make` builds default to optimization according to `gerbil/doc/reference/std/make.md:152-160`.
- Gerbil’s executable regression suite invokes `gxc -O` for modules and executables and covers full-program and static variants (`gerbil/src/gerbil/test/gxc-test.ss:33-82`).

Because `this-source-content` produces the same compiled constant category as Tuna’s current literal bytevectors, there is no distinct optimizer path that would make it less compatible with `gxc -O`.

### Build dependency tracking

A macro reading a file does not make that file automatically visible to `:std/make`’s timestamp cache:

- `gerbil/doc/reference/std/make.md:48-57` defines `extra-inputs:` specifically for files included or otherwise read at build time.
- `gerbil/src/std/make.ss:162-171` adds declared extra inputs to a target’s inputs.
- `gerbil/src/std/make.ss:198-203` runs builds with the project source directory as `current-directory`.
- `gerbil/doc/reference/std/make.md:143-150` warns that omitted dependencies can cause outputs to be considered up to date incorrectly.

**Severity: medium:** omitting `extra-inputs:` could leave stale embedded bytes after an asset-only change. Compilation itself remains correct when forced or run directly, but incremental `gerbil build` would not be dependable.

## Tuna’s current behavior

- `tuna/tuna/frontend/generate-gerbil-assets.mjs:7-15` reads both assets as Node buffers and emits decimal `#u8(...)` literals.
- `tuna/tuna/private/assets-generated.ss:1-9` is the resulting generated module.
- The generated source is 124,541 bytes, representing asset files of 34,083 and 920 bytes.
- `tuna/tuna/build.ss:4-20` compiles the generated module before the HTTP and executable modules.
- `tuna/tuna/private/http.ss:203-217` serves the two bytevectors directly.
- `tuna/tuna/test/run-server-runtime-validation.sh:117-132` validates pinned tools, source checksums, regeneration, and exact generated-source equality.
- `tuna/tuna/test/run-server-runtime-validation.sh:134-136` runs the installed binary with an empty `GERBIL_LOADPATH`, demonstrating the current deployment expects embedded rather than runtime files.
- `tuna/tuna/test/run-command-runtime-matrix.sh:61-114` directly compiles the assets module and dependent modules in both normal and `gxc -O` modes.
- Protocol tests assert the served SHA-256 hashes at `tuna/tuna/frontend/test/protocol.mjs:264-273`.

Current hashes:

- Datastar: `2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a`
- Tuna keyboard: `017dd4807ba8fee14862b88b8a649ffa2a96a605e911abb5b06a732a5109f14d`

## Distinctions among available mechanisms

| Mechanism | Supported/public? | Exact arbitrary bytes? | Runtime independent? | Assessment |
|---|---:|---:|---:|---|
| `this-source-content` | Yes | Yes | Yes | **Recommended.** Designed for ancillary files embedded in objects. |
| Generated `#u8(...)` source | Yes | Yes | Yes | Current approach works, but requires a generator, checked generated artifact, and synchronization test. |
| Custom compile-time macro using `read-file-u8vector` | Yes | Yes | Yes | Supported, but reinvents `:std/source` and adds macro-phase/path complexity. |
| Runtime files plus `(copy: file)` | Yes | Yes | No | Supported package sidecars, but not a self-contained executable. |
| Gerbil `(include path)` | Yes | No | N/A | Reads and expands textual Scheme forms, not arbitrary file bytes. |
| `include-text` | Not usable in this checkout | Text only | Yes if available | Stale documentation points to a module absent from the staging tree; unsuitable for arbitrary bytes regardless. |
| `@bytes` | Yes | UTF-8 text only | Yes | Converts a Scheme string literal to UTF-8 bytes, not a file embedding API. |
| Literal `#u8(...)` | Yes | Yes | Yes | Native homogeneous-vector reader syntax, but does not read files by itself. |
| `(static-include: file)` | Yes, build API | Only through custom C machinery | Potentially | Means C/C++ compilation, not static resource inclusion. Excessive complexity here. |
| Gambit `##...` facilities | Internal/unsafe seam | Potentially | Varies | No private primitive is needed; avoid coupling to internals. |
| Appending bytes to executable | No supported Gerbil API found | Potentially | Platform-dependent | Requires custom offsets/parsing and may conflict with signing/tooling. |
| `executable-path` plus sidecar | Public Gambit API | Yes | CWD-independent only | Finds the executable (`gerbil/src/gambit/doc/gambit.txi:13435-13453`) but still requires distributing external files. |

### Textual Scheme `include`

Gerbil documents `(include path)` as including the path’s contents wrapped in `begin` (`gerbil/doc/reference/gerbil/prelude/core-expander-syntax.md:94-100`). Its implementation resolves the file and calls `read-syntax-from-file` (`gerbil/src/gerbil/expander/core.ss:307-319,411-426`). It is therefore source splicing, not resource embedding.

R7RS `include-ci` and `include-library-declarations` are also Scheme-source inclusion forms (`gerbil/src/v0.19-WIP/v0.19-TODIE-top/lang/scheme/base-impl.ss:171-195`; `.../scheme/r7rs.ss:64-66,95-109`).

### `include-text`

The documentation still advertises `:std/misc/text` and says it expands to file text (`gerbil/doc/reference/std/misc/text.md:1-19`), but `src/std/misc/text.ss` is absent at the inspected staging HEAD. Its old implementation survives under `src/v0.19-WIP/v0.19-TODO-std/misc/text.ss:1-15`.

A divergent `v0.19-std` branch moved it to `:std/text/include`, but that commit is not an ancestor of the requested `v0.19-staging` checkout. Even where available, it reads a string rather than preserving arbitrary binary bytes.

**Severity: low:** documentation drift could mislead an implementation toward a module unavailable in the target toolchain.

### Static bytevector literals and `@bytes`

Gambit’s documented homogeneous-vector reader syntax includes `#u8(...)` (`gerbil/src/gambit/doc/gambit.txi:17925-17952`). This is the mechanism used by Tuna’s generator, but it is only a literal representation.

Gerbil’s public `@bytes` macro converts a literal string to UTF-8 during expansion (`gerbil/src/gerbil/core/more-sugar.ss:209-214`; `gerbil/doc/reference/gerbil/prelude/macros.md:341-347`). It can change the representation of text and cannot directly embed arbitrary file bytes.

### Runtime package data

`:std/make` supports `(copy: file)` for Scheme files, objects, or data that must remain present wherever the package is installed (`gerbil/doc/reference/std/make.md:103-105`; implementation at `gerbil/src/std/make.ss:662-674`).

This is installation, not embedding. Runtime load paths are initialized from the user and Gerbil library directories (`gerbil/src/gerbil/runtime/init.ss:206-228`), while the loader’s internal search only resolves module `.oN` and `.scm` files (`gerbil/src/gerbil/runtime/loader.ss:107-128`). No public package-data lookup API or `gerbil.pkg` data-file key was found. The package manager recognizes package metadata such as `package:`, `depend:`, and `build:`, not embedded resources (`gerbil/doc/guide/package-manager.md:22-37`; `gerbil/src/tools/gxpkg.ss:1035-1064`).

Runtime files would therefore require an application-owned lookup and deployment convention and would fail Tuna’s self-contained relocation requirement.

### C/static/private/appended alternatives

`static-include:` means compiling C or C++ into the application and requires a corresponding Scheme interface (`gerbil/doc/reference/std/make.md:68-80`). A custom C byte array could be built this way, but it would add generated C or platform tooling and Foreign Function Interface code.

Gerbil delegates low-level foreign compilation to Gambit (`gerbil/doc/guide/ffi.md:1-15`). Gambit executable creation uses generated target files, object files, and the C linker (`gerbil/src/gambit/doc/gambit.txi:1369-1396`); the inspected manuals and sources expose no supported arbitrary resource section or appended-resource reader.

The public `executable-path` can support sidecars but does not embed them. Any `##` primitive, custom linker section, `objcopy`, or appended payload would be a materially more complex private/platform-specific solution.

## Option comparison

### 1. Hand-written `this-source-content` module — recommended

**Advantages**

- Public and specifically documented for this purpose.
- Exact byte preservation.
- No Node-based Gerbil source generator.
- Source remains small and reviewable.
- CWD and relocation independent after compilation.
- Produces an ordinary quoted `u8vector` accepted by normal and optimized compiler paths.

**Constraints**

- Asset files must exist at compile time.
- `extra-inputs:` is required for correct incremental builds.
- Each asset path is explicit; this is not an embedded filesystem or glob API.

### 2. Keep generated bytevector source

**Advantages**

- Already proven by Tuna’s current normal/optimized matrix.
- Exact and fully self-contained.
- Generated `.ss` file itself naturally drives rebuild timestamps.

**Disadvantages**

- 124 KB generated source for about 35 KB of assets.
- Requires Node generation and an equality gate.
- Duplicates the public facility already supplied by Gerbil.

### 3. Custom compile-time macro

A local macro could resolve a source-relative path, invoke public `read-file-u8vector`, and quote the result. This is supported by Gerbil’s compile-time evaluation model, but it would essentially duplicate `gerbil/src/std/source.ss:24-30,54-58`. It is justified only if Tuna later needs transformations, manifests, globbing, compression, or richer diagnostics.

### 4. Runtime sidecar files

Use `(copy:)` and read with `read-file-u8vector` at runtime. This avoids increasing executable size and can permit live asset replacement, but introduces filesystem deployment and lookup behavior. It does not meet the stated standalone executable requirement.

### 5. Native resource/appended/C alternatives

No supported native Gerbil resource form beyond compile-time bytevector embedding was found. C arrays, linker sections, or executable-appended data are possible engineering techniques, not idiomatic Gerbil APIs, and are substantially more complex and less portable.

## Validation commands

No compilation or tests were executed during this read-only research task. After implementation, the evidence-backed focused validation is:

```sh
(cd tuna/tuna && gerbil build)
(cd tuna/tuna && test/run-command-runtime-matrix.sh)
```

This validates normal compilation and direct `gxc -O` compilation; the matrix’s implementation is at `tuna/tuna/test/run-command-runtime-matrix.sh:61-114`.

The full validation is the repository’s documented hermetic gate:

```sh
GERBIL_BINDIR=/opt/gerbil/bin \
NODE_COREPACK_BINDIR=/home/jay/.nix-profile/bin \
GO_BINDIR=/usr/local/go/bin \
  tuna/tuna/test/run-server-runtime-validation.sh
```

Evidence:

- documented at `tuna/tuna/README.md:36-44`;
- validates source/normal/`gxc -O` modes at `tuna/tuna/test/run-server-runtime-validation.sh:114-115`;
- verifies source asset hashes at lines 117-131;
- exercises the installed executable and HTTP protocol at lines 134-136;
- protocol assertions compare exact served asset hashes at `tuna/tuna/frontend/test/protocol.mjs:264-273`.

The old regeneration equality assertion at `run-server-runtime-validation.sh:129-132` would need replacement by an assertion appropriate to the hand-written module; preserving source asset SHA-256 checks and HTTP response hashes provides behavior-facing exactness coverage.

## Risks and unresolved gaps

1. **Medium — build dependency declaration:** failure to add both files to `extra-inputs:` can cause stale incremental builds.
2. **Low — development-version API movement:** the checkout identifies itself as `v0.19-dev`, not a final release. `:std/source` is present, public, documented, tested, and in the build spec at the exact requested commit, but v19 is still under active staging.
3. **Low — documentation drift:** `:std/misc/text` documentation does not match this branch’s source tree.
4. **Low — validation not executed:** `gxc -O` compatibility is strongly supported by the direct macro/compiler source path, but the proposed Tuna replacement was not compiled because this assignment was strictly read-only.
5. **Low — size/performance:** the resulting executable still contains the same bytes. This removes generated source bulk but does not reduce embedded payload size.

## Repository state

- Gerbil: `4531c21b90fa6ee04f374af905ae3ddb9d89d590`, reported as `v0.19-dev-32-g4531c21b`.
- Installed `gerbil` and `gxc`: `/opt/gerbil/bin`, same reported version.
- No staged files were present in the outer repository, Gerbil checkout, or Tuna repository.
- Pre-existing unstaged/untracked work was present in all three worktrees; this research made no source or test changes.