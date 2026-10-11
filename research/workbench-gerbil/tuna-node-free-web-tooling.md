# Tuna: Node-free web tooling and Gerbil protocol test

**Recommendation:** replace `test/server-protocol.mjs` with one in-process Gerbil v0.19 protocol suite using Tuna’s private host lifecycle and Gerbil’s public TCP/buffered-I/O APIs. Keep the existing validation shell orchestrator, but remove all Node, pnpm, and TypeScript tooling. Compile and verify the browser plugin with the installed standalone esbuild 0.27.2 CLI directly—do not add a build script.

Repository paths below are relative to `/home/jay/Code/workbench-gerbil`.

## Why this is the smallest supported replacement

The Node test currently combines:

- executable spawning, pseudo-terminal Ctrl-C, and port probes: `tuna/tuna/test/server-protocol.mjs:8-78`;
- configuration precedence and startup failures: `:215-257`;
- HTTP routes, headers, assets, and invalid requests: `:259-286`;
- two live raw Server-Sent Events (SSE) clients, fanout, replacement, terminal chunks, and listener release: `:288-331`.

The protocol itself can be tested without a subprocess because Tuna already exposes a complete private in-process host seam:

- construction/start/wait/stop exports: `tuna/tuna/private/host.ss:15-27`;
- validated construction before service/listener allocation: `:100-126`;
- start with the public Gerbil HTTP server: `:159-180`;
- deterministic cleanup order: service ingress close, runtime join, server stop, observer stop: `:134-157`;
- public `tuna-host-stop!` and service accessor: `:191-205`.

This directly exercises the same HTTP handlers and state service as the installed executable. It avoids the current unsupported lifecycle workaround: `/usr/bin/script`, pseudo-terminal input, and literal Ctrl-C at `server-protocol.mjs:16-24,47-60`.

## Exact test/module shape

### 1. Add `tuna/tuna/test/server-protocol-test.ss`

Suggested header:

```scheme
prelude: :tuna/lib/prelude

(import :std/interface
        :std/io
        :std/io/socket/api
        :std/net/address
        :std/test
        :std/time/timeout
        :tuna/private/host
        :tuna/private/web-assets)

(export server-protocol-test)
```

Use a single file rather than introducing a reusable test-support module. Its private helpers should be:

- `wire-client`, `wire-response` structures;
- `open-wire-client`, `close-wire-client`, `wire-send`;
- bounded `read-crlf-line`, `split-header`, `header-ref`, `read-exact`;
- `read-response-head`, `read-response-body`;
- `read-chunk` that consumes and verifies the complete zero chunk, including the final empty CRLF line;
- `request` for one-shot HTTP calls;
- `open-sse-client`, `expect-sse-frame`;
- `state-event`.

This follows the established raw-wire implementation in:

- `sse-gerbil/sse-test.ss:68-160`;
- `datastar-gerbil/http/test-support/listener.ss:1-166`;
- Datastar’s real HTTP/SSE checks at `datastar-gerbil/http/httpd-test.ss:154-180`.

One deliberate improvement is needed: the upstream helpers recognize a zero-sized chunk but do not consume the final trailer terminator (`sse-test.ss:153-160`; Datastar listener `:117-129`). Tuna’s replacement should explicitly require the wire sequence corresponding to `0\r\n\r\n`, preserving the stronger Node assertion at `server-protocol.mjs:185-188`.

### 2. One protocol test case with deterministic unwind

Use a dedicated fixed loopback port, distinct from existing test ports, for example `18766`. The current suite already uses `18765` (`server-runtime-test.ss:372-399`), while SSE and Datastar use `21090` and `21091`.

Test structure:

1. Install a deterministic test renderer equivalent to the current `valid-test-renderer` (`server-runtime-test.ss:43-52`).
2. Construct and start:
   ```scheme
   (make-tuna-host "127.0.0.1" 18766 8)
   (tuna-host-start! host)
   ```
3. Use `try/finally`; always close owned sockets and call `tuna-host-stop!`. Stop is idempotent by design (`host.ss:128-157,191-203`).
4. After the main host stops and both surviving SSE clients receive terminal chunks, construct/start/stop a second host on exactly `18766`. Successful immediate rebinding proves listener release without opening a private socket or using a port-probe server.

### 3. Exact HTTP assertions

Cover the fixed mux implemented at `tuna/tuna/private/http.ss:208-217`:

| Request | Required assertion |
|---|---|
| `GET /` | 200; `Content-Type: text/html; charset=utf-8`; `Cache-Control: no-store`; keyboard attribute; import map precedes keyboard module; initial state present |
| `GET /missing` | 404 |
| `PUT /` | 405; `Allow: GET, POST` |
| `POST /subscribe` | 405; `Allow: GET` |
| `POST /assets/datastar-v1.0.2.js` | 405; `Allow: GET` |
| both asset GETs | 200; JavaScript content type; immutable one-year cache header; exact response bytes |
| POST without Datastar marker | 400 |
| POST with non-JSON content type | 415 |
| malformed JSON | 400 |
| extra JSON field | 400 |
| composing keydown | 400 |

These statuses are defined by the handlers at `private/http.ss:140-174,176-206`; the current Node expectations are at `server-protocol.mjs:259-286`.

For assets, compare response bodies directly with the embedded `datastar-javascript` and `tuna-keyboard-javascript` byte vectors exported by `private/web-assets.ss:3-11`. This avoids adding OpenSSL solely for test hashing. The shell gate should retain byte-count and SHA-256 checks already present at `run-server-runtime-validation.sh:133-139`.

### 4. Exact concurrent SSE sequence

Keep two TCP clients connected simultaneously:

1. Open client A and client B on `/subscribe`.
2. For each, assert:
   - status 200;
   - `Content-Type: text/event-stream`;
   - `Cache-Control: no-cache`;
   - chunked transfer encoding;
   - identity content encoding and connection-close behavior, matching Datastar’s authoritative wire test at `httpd-test.ss:169-179`.
3. Both receive:
   ```text
   event: datastar-patch-elements
   data: selector #state
   data: elements <pre id="state">(tuna (revision 0) (counter 0))</pre>

   ```
4. POST the exact keydown JSON and assert 204 with no response body.
5. Both receive revision/counter `1`.
6. Close client A with public socket shutdown/close APIs.
7. POST again; client B receives revision/counter `2`.
8. Open replacement client C; its initial frame must be the latest snapshot, revision/counter `2`.
9. POST again; B and C both receive revision/counter `3`.
10. Call `tuna-host-stop!` while B and C remain connected.
11. Both clients must read a complete zero terminal chunk.
12. Start a replacement host on the same port and stop it.

This proves:

- simultaneous subscriptions;
- initial and latest snapshot behavior;
- POST fanout;
- disconnected subscriber cleanup;
- replacement subscriber behavior;
- service shutdown propagation through subscriptions;
- terminal HTTP chunks;
- deterministic host cleanup and listener release.

The production subscription rereads the latest snapshot after each coalesced invalidation (`private/http.ss:176-201`), while service shutdown closes ingress and runtime subscriptions (`private/service.ss:104-135`).

### 5. Runner integration

Update `tuna/tuna/test/command-runtime-suite-main.ss`:

- import `./server-protocol-test` after `./server-runtime-test`;
- add `server-protocol-test` to the suite list at the equivalent of current lines `21-28`.

Update the focused compile loop in `test/run-server-runtime-validation.sh:101-112` to compile `server-protocol-test`.

Delete `test/server-protocol.mjs` and remove its separate Node invocation at `run-server-runtime-validation.sh:128-130`.

## Configuration and invalid startup coverage

Do not duplicate invalid-renderer variants in the new protocol suite. Existing in-process coverage is already stronger than the Node cases:

- invalid listener values;
- unbound renderer;
- action renderer;
- state-transition renderer;
- renderer returning a non-string;
- successful valid host construction.

Evidence: `tuna/tuna/test/server-runtime-test.ss:322-349`. Construction validates the renderer and performs the initial render before service or HTTP resources are created (`private/host.ss:111-126`).

Add one small test case to `server-runtime-test.ss` for configuration selection:

- import `:std/io/tempfile` and `:tuna/lib/startup`;
- use `call-with-temporary-directory`;
- save and restore `XDG_CONFIG_HOME` with public `getenv`/`setenv`;
- assert:
  - absent default returns `#f`;
  - existing `${XDG_CONFIG_HOME}/tuna/config.ss` is selected for no arguments;
  - with both default and explicit files present, `["--config" explicit]` selects only the explicit file;
  - `["--no-config"]` returns `#f`;
  - mixed/extra arguments and missing explicit files raise.

The selection behavior is implemented at `tuna/tuna/lib/startup.ss:6-30`; `main` loads exactly that one selected path before snapshotting listener values (`tuna/tuna/main.ss:12-31`).

The current listener-snapshot scenario at `server-protocol.mjs:237-243` can be replaced by a small in-process assertion that a renderer mutating the global port during initial rendering cannot change the already supplied host port. The relevant snapshot boundary is `main.ss:18-23` and host copying/validation is `private/host.ss:100-126`.

## Supported Gerbil v0.19 APIs

The inspected checkout and installed tools are the pinned Gerbil commit `4531c21b90fa6ee04f374af905ae3ddb9d89d590`, reporting:

```text
Gerbil v0.19-dev-32-g4531c21b on Gambit v4.9.7-6-g64f4d369
```

Supported APIs used by the recommendation:

- `tcp-connect` is publicly exported and typed for `InetAddress` plus `IOTimeout`: `gerbil/src/std/io/socket/api.ss:22-32,40-48`.
- socket timeout, reader, writer, shutdown, and close interfaces are public: `gerbil/src/std/io/interface/socket.ss:10-68`; implementations at `socket/api.ss:146-204`.
- `InetAddress` and `localhost4` are exported: `gerbil/src/std/net/address/api.ss:9-23`.
- `IOTimeout` and `!NoTimeout` are public: `gerbil/src/std/time/timeout.ss:6-13`.
- buffered readers/writers are public: `gerbil/src/std/io/bio/api.ss:21-42,103-144`.
- `test-suite`, `test-case`, checks, and `gerbil test` are documented: `gerbil/doc/reference/dev/test.md:8-32,48-78`; `reference/std/test.md:9-41,110-115`.
- safe temporary directories are public: `gerbil/src/std/io/tempfile.ss:10-15,47-67`.

Gerbil’s public `open-process`, `run-process`, and `process-status` facilities exist (`gerbil/src/std/misc/process.ss:27-78`; usage at `gerbil/src/gerbil/test/gxc-test.ss:23-31`), but they are not needed here. A running Tuna subprocess has no supported process-control operation that reproduces terminal user interrupt and guarantees bounded cleanup without returning to signal or pseudo-terminal behavior.

## Installed executable behavior not proven in-process

**Medium residual gap:** in-process host tests do not prove:

- the staged `$GERBIL_PATH/bin/tuna` entry point invokes `main`;
- `tuna-host-wait!` installs the user-interrupt handler;
- an interactive terminal Ctrl-C reaches that handler;
- `main` exits zero after its outer cleanup.

Those paths are `main.ss:12-33` and `host.ss:182-203`. The build gate should at least assert the staged executable exists and is executable. Interactive Ctrl-C behavior should remain a separate packaging/manual acceptance smoke test unless Tuna gains a supported programmatic shutdown seam. Do not recreate the Node test’s `/usr/bin/script` pseudo-terminal workaround or use private Gambit/signal hooks.

## Exact Node/tooling removal and updates

### Delete

- `tuna/tuna/.node-version`
- `tuna/tuna/package.json`
- `tuna/tuna/pnpm-lock.yaml`
- `tuna/tuna/tsconfig.json`
- `tuna/tuna/web/datastar.d.ts`
- `tuna/tuna/web/build.mjs`
- `tuna/tuna/test/server-protocol.mjs`

The current package metadata pins Node, pnpm, esbuild 0.27.0, and TypeScript 5.9.3 at `package.json:1-15`; the lock’s root dependencies are `pnpm-lock.yaml:1-16`.

### Modify

- `tuna/.gitignore:4`: remove `/tuna/node_modules/`.
- `tuna/tuna/README.md:36-44`: remove `NODE_COREPACK_BINDIR`; document only Gerbil and Go requirements plus the fixed standalone esbuild path.
- `tuna/tuna/web/README.md:17-19`: replace pnpm instructions with the exact esbuild command below and document version 0.27.2.
- `tuna/tuna/test/run-server-runtime-validation.sh`:
  - remove `NODE_COREPACK_BINDIR` requirement at line 5;
  - remove `FRONTEND_PATH` at line 17;
  - remove node/corepack checks at lines 23-25;
  - replace lines 117-132 with standalone esbuild version and byte-for-byte validation;
  - remove the Node protocol invocation;
  - add the Gerbil protocol suite to the focused compiled suite.
- `tuna/tuna/test/command-runtime-suite-main.ss`: import/run the new suite.
- `tuna/tuna/test/server-runtime-test.ss`: retain invalid renderer/cleanup cases; add configuration-selection and listener-snapshot assertions.
- Add `tuna/tuna/test/server-protocol-test.ss`.

### Keep unchanged

- `web/tuna-keyboard-v1.ts`;
- committed `web/tuna-keyboard-v1.js`;
- committed Datastar artifact;
- `build.ss` asset inputs at `tuna/tuna/build.ss:11-14`;
- asset hashes and lengths.

Deleting `tsconfig.json` and `datastar.d.ts` also removes `tsc --noEmit` semantic type checking. esbuild parses and transforms TypeScript but is not a TypeScript type checker. Keeping those two files without a checker would create dead, misleading configuration; deleting them is the smallest honest option.

## Direct documented esbuild command

From `tuna/tuna`:

```sh
/home/jay/.nix-profile/bin/esbuild \
  web/tuna-keyboard-v1.ts \
  --bundle \
  --external:datastar \
  --format=esm \
  --minify \
  --platform=browser \
  --target=es2022 \
  --legal-comments=none \
  --log-level=silent \
  --outfile=web/tuna-keyboard-v1.js
```

No package installation and no new shell build script are needed.

The installed binary reports `0.27.2`. Its output with these transformation flags is exactly 920 bytes and retains the current SHA-256:

```text
017dd4807ba8fee14862b88b8a649ffa2a96a605e911abb5b06a732a5109f14d
```

### Non-mutating direct validation

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna

test "$(/home/jay/.nix-profile/bin/esbuild --version)" = 0.27.2

/home/jay/.nix-profile/bin/esbuild \
  web/tuna-keyboard-v1.ts \
  --bundle \
  --external:datastar \
  --format=esm \
  --minify \
  --platform=browser \
  --target=es2022 \
  --legal-comments=none \
  --log-level=silent |
  cmp - web/tuna-keyboard-v1.js

test "$(wc -c < web/tuna-keyboard-v1.js)" -eq 920
test "$(sha256sum web/tuna-keyboard-v1.js | cut -d ' ' -f 1)" = \
  017dd4807ba8fee14862b88b8a649ffa2a96a605e911abb5b06a732a5109f14d
```

Byte-for-byte comparison against a direct CLI rebuild also preserves the determinism and external-import assurances formerly implemented in `web/build.mjs:10-80`.

## Validation commands after implementation

Focused:

```sh
cd /home/jay/Code/workbench-gerbil
GERBIL_BINDIR=/opt/gerbil/bin \
GO_BINDIR=/usr/local/go/bin \
  tuna/tuna/test/run-server-runtime-validation.sh
```

The updated orchestrator should perform the fresh staged SSE → Datastar → Tuna build, compile and run the new Gerbil suite, run the runtime matrix, execute direct esbuild validation, and retain the existing byte/hash/worktree checks.

Additional inventory check:

```sh
cd /home/jay/Code/workbench-gerbil/tuna
test ! -e tuna/.node-version
test ! -e tuna/package.json
test ! -e tuna/pnpm-lock.yaml
test ! -e tuna/tsconfig.json
test ! -e tuna/web/datastar.d.ts
test ! -e tuna/web/build.mjs
test ! -e tuna/test/server-protocol.mjs
```

## Risks and confidence

- **Medium:** installed executable Ctrl-C/main-finally behavior becomes a separate manual or packaging acceptance check.
- **Medium:** removing TypeScript loses semantic type checking; esbuild supplies syntax, resolution, bundling, and deterministic output checks only.
- **Low:** a fixed test port may collide with an unrelated local process. It is consistent with the existing SSE, Datastar, and Tuna tests; suite execution is sequential.
- **Low:** direct source execution against the existing local `.gerbil` failed due an apparently stale/incompatible compiled Tuna prelude. The authoritative validation remains the repository’s fresh staged compile path.
- **Confidence:** high for the Gerbil wire-test and tooling design; medium-high for final implementation until the new suite is run through the fresh hermetic gate.