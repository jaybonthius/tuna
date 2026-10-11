# Tuna web-terminal build, asset, and browser-validation findings

## Concise recommendation

Use an independent package at:

- path: `/home/jay/Code/workbench-gerbil/tuna/packages/tuna-web-terminal`
- Gerbil identity: `tuna-web-terminal`
- module prefix: `:tuna-web-terminal/...`
- executable: `tuna-web-terminal`
- package prelude: `:tuna/lib/prelude`
- production runtime capacity: `256`
- production listener: `inet4:127.0.0.1:8001`

Build `sse-gerbil`, `datastar-gerbil`, Tuna, then the host into one newly created `GERBIL_PATH`. Keep `GERBIL_LOADPATH` empty during build provenance checks and execution. Reject dirty or unexpected dependency revisions.

Use the official committed Datastar v1.0.2 bundle verbatim rather than claiming to rebuild it. Build only the application plugin, with its `"datastar"` import externalized. Embed both JavaScript byte sequences in a generated private Gerbil module so the installed executable never depends on its current working directory.

Use pinned Playwright for Chromium, Firefox, and WebKit. The available `agent-browser` installation is useful for exploratory Chromium checks but cannot satisfy three-engine acceptance.

## Findings and concrete contract corrections

### 1. Independent package and fixed runtime values

Recommended metadata:

```scheme
(package: tuna-web-terminal prelude: :tuna/lib/prelude)
```

The package build should end in:

```scheme
(exe: "main" bin: "tuna-web-terminal")
```

Keep the executable as the only public surface. Do not add dependencies to Tuna’s build or executable.

Set private production constants:

```scheme
+command-capacity+ = 256
+listen-host+      = "127.0.0.1"
+listen-port+      = 8001
+listen-address+   = "inet4:127.0.0.1:8001"
```

Evidence:

- Tuna already uses a fixed capacity of 256: `tuna/tuna/main.ss:8-21`.
- Tuna’s independent-package example installs into an explicit environment with `GERBIL_LOADPATH=`: `tuna/tuna/README.md:42-56`.
- The existing Gerbil Datastar example uses loopback port 8001: `datastar-gerbil/README.md:33-41`; `datastar-gerbil/example.ss:120-153`.
- Oracle requires exact package/executable/capacity/listen values: `research/tuna-web-terminal-oracle-review.md:51-66`.

**Severity: medium.** The package does not exist yet, so these names remain proposed contract details rather than validated implementation facts.

### 2. Private ephemeral-port seam

Keep the public executable fixed at port 8001. Add a package-private host constructor that accepts capacity and an `InetAddress`; production `main` supplies the constants above.

For browser and HTTP fixtures, build a separate test-only launcher, not installed as a package-public executable. It may accept a private environment value such as:

```text
TUNA_WEB_TERMINAL_TEST_PORT=<selected port>
```

The Playwright fixture should:

1. ask Node’s `net.Server` for `127.0.0.1:0`;
2. read the assigned port;
3. close that reservation;
4. launch the private test host on that port;
5. wait for an HTTP readiness response;
6. retry the allocation/start sequence if the bind loses the small close-to-rebind race.

Use `--workers=1` so tests do not compete over shared runtime state.

Gerbil’s public HTTP `Server` interface accepts listen addresses but exposes only start, stop, connection count, configuration, and restart—not the actual address selected after binding port zero: `gerbil/src/std/net/http/server/interface.ss:82-132`. Existing Datastar tests therefore hard-code port 21091: `datastar-gerbil/http/test-support/listener.ss:7-43`.

**Residual gap:** an atomic port-zero handoff is not available through the public Gerbil HTTP server. The close-and-rebind retry is the smallest package-private seam; fixed-port test fixtures remain susceptible to collisions.

### 3. Reproducible Gerbil staging

Current package identities and build surfaces:

- SSE: `(package: gerbil-sse)`, one module, `sse-gerbil/gerbil.pkg:1`, `sse-gerbil/build.ss:1-5`.
- Datastar: `(package: gerbil-datastar ...)`, depends on SSE, `datastar-gerbil/gerbil.pkg:1-2`; builds four modules, `datastar-gerbil/build.ss:1-5`.
- Tuna: `(package: tuna prelude: :tuna/lib/prelude)`, `tuna/tuna/gerbil.pkg:1`; its build owns only Tuna and executable `tuna`, `tuna/tuna/build.ss:1-14`.

Recommended dependency lock:

| Dependency | Exact source identity |
|---|---|
| `sse-gerbil` | `1a8609ec82bb76fb13ff6755e21c6c7b3b3053b3` |
| `datastar-gerbil` | `a0d020caf50ab74d00e6d99d7696362a2a06d41d`, clean |
| Tuna | `46783db86177317c18cb3a29a07cf69098926ae6` |
| Gerbil minimum | active commit must be `4531c21b90fa6ee04f374af905ae3ddb9d89d590` or a descendant |

The current `datastar-gerbil` tree is dirty across 13 source/test files. Its build is therefore not currently reproducible from commit identity alone. Either restore the clean pinned commit or commit the intended changes and update the lock; do not call `a0d020c` an exact source identity while those changes are present.

Use one clean staging environment:

```sh
set -eu

WORKBENCH=/home/jay/Code/workbench-gerbil
GERBIL_SOURCE="$WORKBENCH/gerbil"
GERBIL_BINDIR=/path/to/qualifying-gerbil/bin
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/tuna-web-terminal.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

export PATH="$GERBIL_BINDIR:/usr/bin:/bin"
export GERBIL_GXC="$GERBIL_BINDIR/gxc"
export GERBIL_PATH="$STAGE/gerbil"
export GERBIL_LOADPATH=
mkdir -p "$GERBIL_PATH"

(cd "$WORKBENCH/sse-gerbil" &&
  "$GERBIL_BINDIR/gerbil" build)

(cd "$WORKBENCH/datastar-gerbil" &&
  "$GERBIL_BINDIR/gerbil" build)

(cd "$WORKBENCH/tuna/tuna" &&
  "$GERBIL_BINDIR/gerbil" build)

(cd "$WORKBENCH/tuna/packages/tuna-web-terminal" &&
  "$GERBIL_BINDIR/gerbil" build)
```

This order ensures every nonstandard import resolves from the same staging `lib`, not from package-local `.gerbil` trees or `~/.gerbil`.

Gerbil documents that:

- `GERBIL_PATH/lib` is automatically on the load path;
- build products go to `GERBIL_PATH/lib` and `GERBIL_PATH/bin`;
- empty/unset `GERBIL_LOADPATH` adds no site-specific directories.

Evidence: `gerbil/doc/guide/env-vars.md:6-25`. Gerbil resolves compiled `.ssi` files by walking `load-path`: `gerbil/src/gerbil/expander/module.ss:412-452`.

Run the compiled host as:

```sh
env \
  GERBIL_PATH="$GERBIL_PATH" \
  GERBIL_LOADPATH= \
  "$GERBIL_PATH/bin/tuna-web-terminal"
```

### 4. Module-provenance attestation

Before tests or execution, use the active `gxi` and Gerbil’s public expander resolver:

```sh
env GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gxi" -e '
    (import :gerbil/core/expander)
    (for-each
      (lambda (module)
        (displayln module " => "
          (core-resolve-library-module-path module)))
      (quote
        (:gerbil-sse/sse
         :gerbil-datastar/http
         :tuna/lib/runtime
         :tuna/lib/keymap
         :tuna-web-terminal/main)))'
```

Require every printed path to begin exactly with:

```text
$GERBIL_PATH/lib/
```

Also attest the complete runtime load path and reject any package checkout `.gerbil`, `$HOME/.gerbil`, or unexpected site directory:

```sh
env GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gxi" -e '(displayln (load-path))'
```

The expected entries are the staging `lib` and the qualifying Gerbil installation’s standard `lib`. A local probe confirmed `core-resolve-library-module-path` reports concrete `.ssi` paths.

### 5. Active Gerbil prerequisite

The source checkout is at the required fix, but the active tools are still:

```text
/opt/gerbil/bin/{gerbil,gxi}
Gerbil v0.19-dev-31-g4a4d1a30
```

That fails acceptance. The checkout’s version source says `v0.19-dev-32-g4531c21b`: `gerbil/src/gerbil/runtime/version.ss:1`.

Do not validate merely by checking the checkout. Parse each active tool’s embedded version hash, resolve it against the matching source repository, and test ancestry:

```sh
set -eu

REQUIRED=4531c21b90fa6ee04f374af905ae3ddb9d89d590
GERBIL_SOURCE=/path/to/source-used-to-build-active-tools
GERBIL_BINDIR=/path/to/active/bin

gxi_version=$("$GERBIL_BINDIR/gxi" -v 2>&1)
gxc_version=$("$GERBIL_BINDIR/gxc" -v 2>&1)
gerbil_version=$("$GERBIL_BINDIR/gerbil" --version 2>&1)

test "$gxi_version" = "$gxc_version"
test "$gxi_version" = "$gerbil_version"

short=$(
  printf '%s\n' "$gxi_version" |
    sed -n 's/.*-g\([0-9a-f][0-9a-f]*\) on Gambit.*/\1/p'
)
test -n "$short"

active=$(
  git -C "$GERBIL_SOURCE" rev-parse "$short^{commit}"
)
git -C "$GERBIL_SOURCE" merge-base --is-ancestor "$REQUIRED" "$active"

printf 'active Gerbil commit: %s\n' "$active"
```

The fix requirement and current block are recorded at:

- `plans/tuna-web-terminal/spec.md:299-323`
- `research/tuna-web-terminal-oracle-review.md:15,101-106`
- `research/tuna-datastar-server-mechanics.md:320-357`

### 6. Datastar v1.0.2 provenance

Authoritative release chain:

- annotated tag `v1.0.2`
- tag object `5cce9fcdda43cb443b4e5e596b67cef903619831`
- commit `e24f04d43ca4445d662b4a035e5bfe9ed68de57c`
- official bundle path `bundles/datastar.js`
- release: <https://github.com/starfederation/datastar/releases/tag/v1.0.2>
- commit: <https://github.com/starfederation/datastar/commit/e24f04d43ca4445d662b4a035e5bfe9ed68de57c>
- bundle: <https://raw.githubusercontent.com/starfederation/datastar/e24f04d43ca4445d662b4a035e5bfe9ed68de57c/bundles/datastar.js>

Observed canonical bundle:

```text
bytes:   34083
SHA-256: 2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a
banner:  // Datastar v1.0.2
```

Commit this exact byte sequence as, for example:

```text
assets/source/datastar-v1.0.2.js
```

Record its URL, commit, byte length, checksum, and MIT license notice.

**Important provenance limitation:** the v1.0.2 tag includes TypeScript source, committed bundles and a `Taskfile.yml`, but no root/library `package.json` or `pnpm-lock.yaml`. The Taskfile still references `pnpm i` and `pnpm build`. Therefore the repository does not provide a complete locked recipe for independently reproducing the official bundle. Treat the committed official bundle as the release artifact; do not claim byte-for-byte source rebuild provenance.

The Gerbil conformance test independently pins the official SDK runner to the same commit: `datastar-gerbil/http/conformance-test.ss:19-20,60-94`.

### 7. Exact HTML module graph

Place the import map first in `<head>`, followed by exactly one plugin module script:

```html
<script type="importmap">{"imports":{"datastar":"/assets/datastar-v1.0.2.js"}}</script>
<script type="module" src="/assets/tuna-terminal-v1.js"></script>
```

Do not add another direct Datastar module script. The plugin’s dependency import loads the mapped Datastar module once.

The plugin source must begin with the public external import:

```js
import { action } from "datastar";
```

Its esbuild configuration must include:

```js
{
  bundle: true,
  external: ["datastar"],
  format: "esm",
  minify: true
}
```

Evidence:

- The official v1.0.2 Datastar bundle publicly exports `action`.
- The pinned starter imports `action` from `"datastar"`, externalizes `"datastar"`, and documents import-map-before-plugin loading: `research/datastar-keyboard-terminal-plugin.md:301-321`.
- Oracle explicitly requires that graph and ordering: `research/tuna-web-terminal-oracle-review.md:68-79`.

### 8. Frontend source, package manager and output strategy

Recommended package-local inventory:

```text
package.json
pnpm-lock.yaml
.node-version
frontend/
  src/tuna-terminal-v1.ts
  esbuild.mjs
  verify-output.mjs
  playwright.config.ts
  test/*.spec.ts
assets/
  source/datastar-v1.0.2.js
  generated/tuna-terminal-v1.js
  SHA256SUMS
private/
  assets.generated.ss
```

Pin exact versions:

- Node `24.14.0` in `.node-version`
- package manager from the pinned starter:
  `pnpm@10.24.0+sha512.01ff8ae71b4419903b65c60fb2dc9d34cf8bb6e06d03bde112ef38f7a34d6904c424ba66bea5cdcf12890230bf39f9580473140ed9c946fef328b6e5238a345a`
- `esbuild` `0.27.0`
- `typescript` `5.9.3`
- Datastar development/type source:
  `github:starfederation/datastar#e24f04d43ca4445d662b4a035e5bfe9ed68de57c`
- `@playwright/test` `1.62.1`

Use exact versions, not caret ranges, and commit `pnpm-lock.yaml`. The starter’s versions and commands are evidenced at `Regaez/datastar-plugin-starter@cf4392425bce4e7c307bdce614c5808c905ca614` and summarized in `research/datastar-keyboard-terminal-plugin.md:303-314,355-362`.

Recommended checks:

```sh
corepack pnpm install --frozen-lockfile
corepack pnpm run build:check
sha256sum -c assets/SHA256SUMS
```

`build:check` should build the plugin into a clean temporary directory and byte-compare it with committed `assets/generated/tuna-terminal-v1.js`. The verifier should also inspect the esbuild metafile to establish that:

- `"datastar"` remains external;
- no Datastar source is included in the output;
- only the intended entry point contributes application code;
- no timestamp or absolute source path enters the bundle.

Generate `private/assets.generated.ss` deterministically from the two committed JavaScript files as immutable UTF-8 bytevector constants. A second check regenerates that module in a temporary directory and byte-compares it with the committed generated module.

This makes the HTTP routes use compiled constants through `ResponseHandler-write!`; no runtime file access or current-directory calculation is needed.

#### Material alternatives

1. **Recommended — compiled embedding:** strongest working-directory and installation independence; small assets make the generated module reasonable.
2. **Install assets under a package data root:** avoids generated Scheme but requires an explicit installation/data-directory contract and relocation tests, neither of which exists today.
3. **Combined Datastar/plugin bundle:** technically possible, but deliberately rejected by the current design because it obscures official-bundle provenance and couples plugin rebuilding to Datastar.

### 9. Asset freshness and runtime verification

Require all three layers:

1. official source asset checksum:
   `2837d87a…d3fd24a`;
2. rebuilt plugin equals committed plugin output;
3. regenerated embedded Gerbil module equals its committed output.

HTTP tests must additionally hash the exact response bodies and compare them with the recorded source asset checksums. This proves that the executable serves the audited bytes rather than merely keeping an unused matching file in the tree.

Use:

```text
Content-Type: text/javascript; charset=utf-8
Cache-Control: public, max-age=31536000, immutable
```

for both versioned asset routes.

### 10. Pinned real-browser harness

Use Playwright Test `1.62.1` with three named projects:

```ts
projects: [
  { name: "chromium", use: { browserName: "chromium" } },
  { name: "firefox",  use: { browserName: "firefox" } },
  { name: "webkit",   use: { browserName: "webkit" } },
]
```

Provision the browser revisions tied to that package version:

```sh
corepack pnpm exec playwright install --with-deps
corepack pnpm exec playwright test --workers=1
```

Playwright documents that every Playwright release requires specific browser binaries and that projects are the supported way to run Chromium, Firefox, and WebKit: <https://playwright.dev/docs/browsers#install-browsers> and <https://playwright.dev/docs/browsers#run-tests-on-different-browsers>.

Recommended partition:

- **Public fixed executable:** real-browser page load, local module loading, prevented keydown, exact envelope, ordinary `i` increments, SSE morphing, multi-tab convergence, and duplicate-listener checks against `127.0.0.1:8001`.
- **Private ephemeral test host:** browser protocol error injection and controlled delayed/failing fixture behavior.
- **Gerbil package-internal tests:** capacity `1` overload, `not-running`, dequeue-time policy replacement, completion failure, observer drain, and direct lifecycle races.

Do not rely only on the private test host; at least one smoke per browser project must launch or connect to the actual staged `tuna-web-terminal` executable.

#### Available local tooling

- Node `24.14.0`, Corepack `0.34.6`, and pnpm `10.25.0` are installed.
- Nix Chromium and system Firefox are present.
- No Playwright browser cache or local WebKit runtime was found, so provisioning is required.
- `agent-browser` is installed at version `0.30.1`. Its own skill states that it uses Chrome/Chromium through the Chrome DevTools Protocol and has no Playwright/Puppeteer dependency. It is not a Firefox/WebKit acceptance harness.
- The native wrapper is suitable for exploratory Chromium checks and screenshots: `/home/jay/Code/pi-agent-browser-native/README.md:1-54`; its audited target is `agent-browser 0.30.1`: `/home/jay/Code/pi-agent-browser-native/docs/SUPPORT_MATRIX.md:27-32`.
- Job Getter has no Playwright, Selenium, or other real-browser dependency. Its tests use Stario `TestClient`; its development dependencies are pytest/type/lint tools only: `/home/jay/Code/job-getter/pyproject.toml:15-27`. Its quality commands are `/home/jay/Code/job-getter/README.md:85-92`. It is not a reusable real-browser harness.

### 11. Exact package and conformance commands

Proposed declared focused test target:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/packages/tuna-web-terminal
GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 ./test/all-test.ss
```

`test/all-test.ss` should aggregate the package’s focused Gerbil suites so test discovery does not depend on repository traversal.

Datastar official conformance under the same active runtime and staged modules:

```sh
cd /home/jay/Code/workbench-gerbil/datastar-gerbil
GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 \
    -D datastar-conformance ./http/conformance-test.ss
```

This is the package-documented command: `datastar-gerbil/README.md:25-29`. It launches the commit-pinned Go runner with a bounded timeout: `datastar-gerbil/http/conformance-test.ss:45-94`.

### 12. Focused and full validation

#### Focused

```sh
# Active-runtime and source-revision preflight first.
# Then create and populate the single clean GERBIL_PATH as shown above.

cd /home/jay/Code/workbench-gerbil/tuna/packages/tuna-web-terminal
corepack pnpm install --frozen-lockfile
corepack pnpm run build:check
sha256sum -c assets/SHA256SUMS

GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 ./test/all-test.ss

corepack pnpm exec playwright test \
  --project=chromium --workers=1
```

#### Full

```sh
# Clean exact dependency revisions, active-Gerbil ancestry check,
# frontend freshness, shared staging build, and module-provenance checks first.

cd /home/jay/Code/workbench-gerbil/sse-gerbil
GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 ./sse-test.ss

cd /home/jay/Code/workbench-gerbil/datastar-gerbil
GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 ./...
GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 \
    -D datastar-conformance ./http/conformance-test.ss

cd /home/jay/Code/workbench-gerbil/tuna/tuna
PATH="$GERBIL_BINDIR:/usr/bin:/bin" \
  test/run-command-runtime-matrix.sh

cd /home/jay/Code/workbench-gerbil/tuna/packages/tuna-web-terminal
GERBIL_PATH="$GERBIL_PATH" GERBIL_LOADPATH= \
  "$GERBIL_BINDIR/gerbil" test -v 0 ./test/all-test.ss

corepack pnpm exec playwright install --with-deps
corepack pnpm exec playwright test --workers=1
```

The Tuna matrix itself captures absolute active `gxi`/`gxc` paths and runs compiled executables with `GERBIL_LOADPATH=`: `tuna/tuna/test/run-command-runtime-matrix.sh:5-10,56-89`.

## Current blockers and residual risks

- **Blocker — active runtime:** `/opt/gerbil` is dev31 at `4a4d1a30`, before the required chunk-terminator fix.
- **High — dirty Datastar dependency:** current `datastar-gerbil` cannot be represented exactly by its HEAD commit until the intended changes are committed or removed.
- **Medium — official bundle rebuild gap:** Datastar v1.0.2 supplies the official bundle but not a complete package-manager/lockfile build recipe at that tag.
- **Medium — ephemeral port race:** Gerbil’s public HTTP server does not expose the selected port after binding port zero; private fixtures need close/rebind retry.
- **Medium — browser provisioning:** WebKit and Playwright-managed revisions are not currently installed.
- **Low — fixed-port collisions:** production browser smoke and Datastar conformance use fixed ports 8001 and 21091 respectively.
- **Low — proposed scripts unvalidated:** the host package, frontend scripts, embedded asset generator, and Playwright configuration do not exist yet.

**Confidence:** high for Gerbil staging/load-path behavior, current dependency identities, Datastar bundle provenance/checksum, starter module graph, and Playwright’s three-engine role; medium for the exact private port launcher until implemented against Gerbil’s server lifecycle.