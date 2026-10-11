# Idiomatic Gerbil testing conventions

## Concise answer

Gerbil’s portable convention is **`foo-test.ss` exporting `foo-test`**. File location is flexible:

- Co-location is the documented rule for Gerbil **stdlib contributions**, but not a runner requirement or universal third-party convention.
- `t/foo-test.ss` and `test/foo-test.ss` work with recursive `gerbil test` because discovery depends only on the `-test.ss` suffix.
- `foo/test.ss` is not conventionally named and is invisible to directory and recursive discovery. It works only when passed explicitly and still must export a runtime binding ending in `-test`.
- `gerbil test ./...` recursively enters every directory, without excluding `.gerbil`, `build-deps`, vendored dependencies, `t`, or `test`, and selects every basename ending exactly in `-test.ss`.
- External-service or expensive suites are idiomatically gated with `cond-expand` and enabled using `gerbil test -D feature`. Gerbil has no built-in unit/integration category.
- Test-support files should avoid the `-test.ss` suffix, avoid import-time external effects, and normally remain outside the production build. Compile them only when the test specifically requires compiled support.

For a small third-party HTTP library, the current hybrid—co-located `*-test.ss` files, a private `test-support/` directory, and a feature-gated conformance file—is well supported. A separate `t/` tree is also established ecosystem practice but is not more “official.”

## Authoritative findings

### 1. Naming and placement

| Layout | Status | Evidence and consequence |
|---|---|---|
| `foo-test.ss` | **Canonical** | Official documentation says test files conventionally end in `-test.ss`, and its example pairs `mylib.ss` with `mylib-test.ss`: `/home/jay/Code/gerbil/doc/reference/dev/test.md:8-10,35-65`. |
| Co-located `foo.ss` / `foo-test.ss` | **Stdlib standard; third-party option** | Gerbil’s contribution guide says tests for a file “should live next to that file”: `/home/jay/Code/gerbil/CONTRIBUTING.md:166-174`. Generic testing documentation does not impose a directory. |
| `t/foo-test.ss` | **Established ecosystem convention** | `gerbil-utils` explicitly defines a convention of recursively located `t/` directories and `*-test.ss` files. See pinned [`testing.ss:1-6,32-48`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/testing.ss#L1-L48) and [`README.md:52-67`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/README.md#L52-L67). `gerbil-crypto`, `gerbil-persist`, `gerbil-poo`, and `gerbil-ethereum` follow this family of conventions. |
| `test/foo-test.ss` | **Technically valid, less evidenced as third-party convention** | Recursive discovery does not special-case directory names; any directory works. Gerbil itself uses `src/gerbil/test/` for core/compiler suites, while stdlib mostly co-locates tests. |
| `foo/test.ss` | **Not idiomatic; not auto-discovered** | Discovery tests the basename for exact suffix `-test.ss`: `/home/jay/Code/gerbil/src/tools/gxtest.ss:101-124`. An explicit file argument is accepted without checking its name at lines 112-113, but its suite export must still end in `-test`. |

Therefore, co-location is **standard for Gerbil’s stdlib**, common elsewhere, but not a general requirement of Gerbil packages.

### 2. What `gerbil test` actually discovers

The implementation at `/home/jay/Code/gerbil/src/tools/gxtest.ss` establishes:

1. No argument means the current directory, non-recursively: lines 38-45.
2. A directory argument scans only its direct entries ending in `-test.ss`: lines 101-113.
3. An argument ending literally in `/...` recursively traverses all subdirectories: lines 105-106,115-124.
4. Directory entries are sorted lexically: lines 126-127.
5. There is **no pruning rule** for hidden, generated, dependency, `t`, or `test` directories: lines 115-124.
6. Collected files are imported before suites execute: lines 61-64,129-140.
7. Only runtime exports whose names end in `-test` become suites: lines 142-164.
8. Optional runtime exports named exactly `test-setup!` and `test-cleanup!` are recognized: lines 152-159.
9. `-r` filters suite export names only after every selected file has been imported: lines 61-66,170 onward.
10. Cleanup executes under `finally`: lines 67-89. Import or test failures produce a nonzero exit (`42`): lines 91-99.

Official documentation summarizes file, directory, and `/...` arguments at `/home/jay/Code/gerbil/doc/reference/dev/test.md:17-25`.

**Medium risk:** `gerbil test ./...` can discover dependency or generated-source tests if directories such as `build-deps` contain matching files. The current package ignores `build-deps` and `.gerbil` in `datastar-gerbil/.gitignore:1-3`, but `gxtest` itself does not exclude them.

**Medium risk:** `-r` is not an isolation mechanism for imports. A filtered-out integration module can still perform top-level network, process, or configuration work. Use exact file selection or `cond-expand` for genuine isolation.

### 3. Unit, integration, and conformance separation

Gerbil does not assign formal categories. Supported mechanisms are:

- **Separate file/path invocation:** run only an exact unit or integration file/directory.
- **Suite-name filtering:** `-r regex`, suitable only when module import is harmless.
- **Feature gating:** `-D feature1,feature2`, documented specifically as enabling tests requiring external services at `/home/jay/Code/gerbil/src/tools/gxtest.ss:30-56`.
- **Custom harness and naming:** ecosystem-specific rather than native `gxtest`.

First-party examples:

- PostgreSQL wraps the entire suite in `cond-expand (enable-postgresql-test ...)`, including its imports and setup: `/home/jay/Code/gerbil/src/std/db/postgresql-test.ss:1-14,40-44`.
- A flaky race test is disabled by default behind `enable-rwlock-test`: `/home/jay/Code/gerbil/src/std/misc/rwlock-test.ss:4-8`.
- Optional badssl cases are nested behind `enable-badssl-test`: `/home/jay/Code/gerbil/src/std/net/ssl-test.ss:99-113,152-155`.

Representative ecosystem alternative:

- `gerbil-utils` defines `*-test.ss` as unit tests and `*-integrationtest.ss` as integration tests requiring external services: pinned [`README.md:54-67`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/README.md#L54-L67).
- Its custom runner finds units with `-test.ss$` and integrations with `-integrationtest.ss$`: pinned [`testing.ss:45-48,75-121`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/testing.ss#L45-L121).
- Native `gerbil test ./...` will **not** discover `*-integrationtest.ss`, because that name does not end in `-test.ss`.
- `gerbil-ethereum` runs build, unit, service startup, integration, and shutdown as distinct commands: pinned [`unit-tests.ss:21-39`](https://github.com/mighty-gerbils/gerbil-ethereum/blob/850a0a36310d962da207e504defed2c47d8b20d8/unit-tests.ss#L21-L39). A representative integration suite performs external connection setup at module import: pinned [`t/10-json-rpc-integrationtest.ss:1-20`](https://github.com/mighty-gerbils/gerbil-ethereum/blob/850a0a36310d962da207e504defed2c47d8b20d8/t/10-json-rpc-integrationtest.ss#L1-L20).

For a small library, Gerbil’s native `-D` approach avoids maintaining a custom runner.

### 4. Test-support modules

No official document mandates one support layout. Source precedent implies these expectations:

- Do not name support files `*-test.ss`; otherwise recursive discovery imports them as candidate test modules.
- Avoid top-level external effects because all collected test files are imported before test execution or `-r` filtering.
- Keep support out of the production build unless compilation is required.
- Use `test-setup!`/`test-cleanup!` or per-test `try`/`finally` for owned servers, sockets, processes, and temporary state.

First-party variants:

- `foreign-test-support.ss` is a compiled FFI support module imported by `foreign-test.ss`; it is explicitly listed in `/home/jay/Code/gerbil/src/std/build-spec.ss:11-14`, with the import at `/home/jay/Code/gerbil/src/std/foreign-test.ss:1-8`.
- `loader-test-support.ss` is compiled into a temporary test environment during `test-setup!`: `/home/jay/Code/gerbil/src/std/actor-v18/loader-test.ss:27-48`.
- `gerbil-utils/t/test-support.ss` is a small re-exporting compatibility shim: pinned [`t/test-support.ss:1-3`](https://github.com/mighty-gerbils/gerbil-utils/blob/f45a4ef3bfecd2af39e114ed736ce9082cbb8244/t/test-support.ss#L1-L3).

Material options for shared HTTP fixtures:

1. **Textual `include`**
   - Pros: remains test-only; no package namespace or build target; convenient for a small fixture.
   - Cons: depends on each including module’s imports and lexical environment; definitions are duplicated into every test module; harder to validate independently.

2. **Private test-support module**
   - Pros: explicit imports/exports; one independently testable seam; less ambient coupling.
   - Cons: may require package-path handling or compilation if loaded by namespace; risks accidental publication if added to the production build.

3. **Per-file helpers**
   - Pros: clearest ownership for very small fixtures.
   - Cons: duplication and inconsistent cleanup as integration coverage grows.

## Current package behavior

The package currently follows the official co-location convention:

- Public façade test: `datastar-gerbil/http-test.ss:1-14`.
- HTTP integration-style test: `datastar-gerbil/http/httpd-test.ss:1-20`.
- Private unit tests:
  - `datastar-gerbil/http/private/core-test.ss:1-8`
  - `datastar-gerbil/http/private/request-test.ss:1-16`
- Conformance suite: `datastar-gerbil/http/conformance-test.ss:1-19,84-121`.
- Shared fixture: `datastar-gerbil/http/test-support/listener.ss:1-256`.
- Production build includes only four production targets, not tests or support: `datastar-gerbil/build.ss:1-8`.

The listener is textually included by both public and HTTP tests (`http-test.ss:14`; `http/httpd-test.ss:14`) and by conformance (`http/conformance-test.ss:15`).

The external Go conformance execution is correctly gated by `datastar-conformance` at `http/conformance-test.ss:104-121`. However:

**Medium finding:** the default, feature-disabled branch still runs the GNU `timeout` process-tree fault injection at lines 114-121. Thus the normal recursive suite is offline, but it is not a pure in-process unit suite and still depends on `/usr/bin/timeout`, `/bin/sh`, process signaling, and timing behavior.

## Pros and cons for a small third-party HTTP library

### Keep current co-location

**Pros**

- Directly matches official stdlib guidance.
- Subject/test correspondence remains obvious.
- Native `gerbil test ./...` finds everything without custom tooling.
- Private implementation tests can use simple relative imports.
- Current five-suite package remains small enough that source/test mixing is manageable.

**Cons**

- Recursive default includes hermetic HTTP integration tests and the disabled conformance placeholder/fault injection, not just fast units.
- Published source tree visibly mixes implementation and tests.
- Every future external suite must be carefully gated because `./...` includes every `*-test.ss`.

### Move tests to `t/` or `test/`

**Pros**

- Clear production/test boundary.
- `t/` has strong Mighty Gerbils ecosystem precedent.
- Focused commands such as `gerbil test t/...` are straightforward.
- Fixtures and conformance assets can be grouped together.

**Cons**

- Less aligned with Gerbil stdlib contribution guidance.
- Imports become less local and may expose package/private-module assumptions.
- `gerbil test ./...` still includes the tree; relocation alone does not feature-gate integration tests.
- A `t/` custom harness is unnecessary unless adopting its non-native `*-integrationtest.ss` convention.

### Use `foo/test.ss`

**Pros:** groups a single subject’s test assets.

**Cons:** not auto-discovered, departs from official naming, and requires explicit commands. `foo/foo-test.ss` or `test/foo-test.ss` provides grouping without losing discovery.

## Focused and full validation commands

These commands are established by Gerbil’s documented runner behavior and prior project validation; they were not rerun during this read-only research task.

Focused unit:

```sh
cd /home/jay/Code/workbench-gerbil/datastar-gerbil
unset GERBIL_PATH
/opt/gerbil/bin/gerbil build
/opt/gerbil/bin/gerbil test -q ./http/private/core-test.ss
/opt/gerbil/bin/gerbil test -q ./http/private/request-test.ss
```

Focused public/HTTP behavior:

```sh
/opt/gerbil/bin/gerbil test -q ./http-test.ss
/opt/gerbil/bin/gerbil test -q ./http/httpd-test.ss
```

Full normal recursive suite:

```sh
/opt/gerbil/bin/gerbil test -q ./...
```

Feature-gated official conformance:

```sh
/opt/gerbil/bin/gerbil test -q -D datastar-conformance ./http/conformance-test.ss
```

## Residual risks and confidence

- **Medium:** recursive discovery has no dependency/generated-directory exclusions.
- **Medium:** default conformance fallback still executes process/timing fault injection.
- **Low:** `include`-based listener support has ambient import coupling, although current ownership and cleanup are deliberately bounded.
- **Low:** ecosystem evidence is representative rather than a complete census; it consistently shows both co-location and `t/`.
- **Confidence:** high for runner mechanics, official naming, feature gating, and current package behavior; medium-high for relative ecosystem prevalence.