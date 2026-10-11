# Tuna SSE / Datastar fanout investigation

## Diagnosis

**No Tuna fanout, `sse-gerbil`, or `datastar-gerbil` defect reproduces outside Playwright.** A fresh current-source stage served three concurrent raw Transmission Control Protocol (TCP) clients correctly:

- two clients received identical exact initial Datastar frames at revision/counter 0;
- one committed keydown update reached both at revision/counter 1;
- after disconnecting client A, client B received revision/counter 2;
- a replacement client immediately received the latest revision 2 snapshot;
- another commit reached both remaining clients at revision/counter 3;
- controlled Tuna shutdown produced complete `0\r\n\r\n` terminal chunks for both clients and exited 0.

This strongly excludes Tuna publication/fanout, Datastar patch generation, SSE flushing, and Gerbil chunk framing as causes of the stale WebKit/second-client symptom. Browser or runner request/render scheduling remains the best-supported attribution.

## Component findings

### Tuna fanout: no defect reproduced

- Every subscription is atomically registered with its initial snapshot: `tuna/tuna/lib/runtime.ss:314-330`.
- Every committed state root iterates all active subscriptions and non-blockingly invalidates each capacity-one channel: `tuna/tuna/lib/runtime.ss:132-153`.
- Coalescing cannot leave a connected reader permanently stale: an invalidation tells the handler to reread the latest snapshot.
- `/subscribe` sends an initial full `#state` patch, then sends a fresh full snapshot after every invalidation: `tuna/tuna/private/http.ss:176-200`.
- Cleanup is guaranteed around the complete SSE session: `tuna/tuna/private/http.ss:184-201`; removal and channel close are idempotent at `tuna/tuna/lib/runtime.ss:338-350`.
- Existing runtime tests cover coherent/coalesced publication, 50 concurrent subscription registrations without a missed-wakeup gap, explicit cleanup, and shutdown closure: `tuna/tuna/test/state-runtime-test.ss:196-245,250-307`.

**Severity:** no finding.

### `sse-gerbil`: no framing or flush defect reproduced

- Each response owns an independent writer/session; frames are mutex-serialized, written, and explicitly flushed: `sse-gerbil/sse.ss:19-38,40-58`.
- Normal callback completion closes the writer: `sse-gerbil/sse.ss:28-38`.
- Its raw-wire test verifies headers, immediate UTF-8 frame visibility, and terminal zero chunk: `sse-gerbil/sse-test.ss:305-330`.

**Severity:** no finding.

### `datastar-gerbil`: no patch-generation defect reproduced

- `call-with-datastar-sse` delegates directly to the independent SSE session: `datastar-gerbil/http/api.ss:121-142`.
- `patch-elements` validates and constructs a complete deterministic event per invocation, with no shared client state: `datastar-gerbil/http/private/core.ss:381-423`.
- Existing wire tests assert exact Datastar frames and terminal completion: `datastar-gerbil/http-test.ss:61-82`.
- Raw Tuna output exactly matched:

```text
event: datastar-patch-elements
data: selector #state
data: elements <pre id="state">(tuna (revision N) (counter N))</pre>

```

**Severity:** no finding.

### Gerbil v19 HTTP framing/concurrency: no defect reproduced

- Streaming responses use chunked encoding and return a buffered chunk writer: `gerbil/src/std/net/http/server/request.ss:143-183`.
- Response close closes the chunked writer: `gerbil/src/std/net/http/server/request.ss:202-209`.
- The pinned chunk writer emits and flushes the required complete `0\r\n\r\n` terminator: `gerbil/src/std/net/http/common/chunked.ss:102-116`; covered at `gerbil/src/std/net/http/common/chunked-test.ss:20-47`.
- Each accepted connection gets its own handler thread: `gerbil/src/std/net/http/server/server.ss:150-166`.

**Severity:** no finding.

## Constraints and separate observations

- **Known operational constraint, low severity:** dead clients are discovered only by a later write or server shutdown because Tuna has no heartbeat and uses `!NoTimeout`. This is explicitly documented at `datastar-gerbil/README.md:31` and configured at `tuna/tuna/private/host.ss:160-172`. An idle disconnected subscriber may therefore remain registered temporarily, but it cannot block or starve other subscribers.
- **Separate unresolved lifecycle risk, medium severity:** two exploratory runs against the actual executable’s pseudo-terminal Ctrl-C path did not complete the streams. One logged:

```text
^C------------- REPL is now in #<thread #9 httpd/handler> -------------
*** INTERRUPTED IN ##wr-complex
```

  Tuna parameterizes the interrupt handler only around the main wait at `tuna/tuna/private/host.ss:182-189`, while HTTP handlers are separate threads. Deterministic service-stop through a temporary current-source host wrapper completed both streams and exited cleanly. This is unrelated to stale WebKit delivery but warrants separate lifecycle investigation if multi-client Ctrl-C reliability is contractual.

## Test-gap assessment and recommended acceptance seam

A checked-in non-browser multi-client protocol test **is warranted**. Current coverage is split:

- the installed Tuna protocol test has only one SSE reader and one update: `tuna/tuna/frontend/test/protocol.mjs:167-188`;
- Tuna runtime tests cover multiple in-memory subscriptions but not HTTP transport;
- package tests cover exact framing but only one response session.

**Recommended seam:** a raw `node:net` test against the freshly staged Tuna executable, run before Playwright from `run-server-runtime-validation.sh`. It should assert:

1. two simultaneous `/subscribe` responses and exact initial frames;
2. one committed POST update reaches both;
3. disconnect one client, commit again, and verify the survivor;
4. connect a replacement client and verify its initial snapshot is current;
5. commit once more and verify both remaining clients;
6. parse chunk boundaries and `0\r\n\r\n` on deterministic shutdown;
7. assert clean process exit and no listener remains.

This seam distinguishes server/package correctness from browser scheduling without duplicating browser behavior. A simpler two-`fetch` extension would test fanout but would not expose raw chunk framing.

## Validation performed

Fresh isolated build, in dependency order:

```sh
env -i HOME="$stage/home" TMPDIR="$stage/tmp" \
  PATH=/opt/gerbil/bin:/usr/bin:/bin \
  GERBIL_GXC=/opt/gerbil/bin/gxc GERBIL_PATH="$stage/gerbil" GERBIL_LOADPATH= \
  /opt/gerbil/bin/gxi ./build.ss compile
```

Run separately in `sse-gerbil`, `datastar-gerbil`, then `tuna/tuna`: **passed**. Module resolution confirmed all four relevant modules came from the temporary stage.

Raw protocol validation:

```sh
env TUNA_SERVER_COMMAND="env GERBIL_PATH='$stage/gerbil' GERBIL_LOADPATH= \
  /opt/gerbil/bin/gxi /tmp/tuna-auto-stop.ss" \
  node /tmp/tuna-raw-fanout-autostop.mjs
```

**Passed:** revisions `0 → 1 → 2 → 3`, first update reached both original clients, replacement got latest state, subsequent update reached both remaining clients, both terminal chunks were complete, exit code 0.

Focused package/runtime suites:

```sh
gerbil test -v 0 ./sse-test.ss
gerbil test -v 0 ./http-test.ss ./http/private/core-test.ss
gerbil test -v 0 ./test/state-runtime-test.ss
```

With the isolated environment: **passed (`OK`)**.

Evidence-backed full gate:

```sh
GERBIL_BINDIR=/opt/gerbil/bin \
NODE_COREPACK_BINDIR=/home/jay/.nix-profile/bin \
GO_BINDIR=/usr/local/go/bin \
tuna/tuna/test/run-server-runtime-validation.sh
```

Not rerun for this bounded investigation. The implementation report records all non-browser/package gates passing, Chromium passing, WebKit passing in the full run, and Firefox failing second-subscription readiness: `research/tuna-server-runtime-implementation-report.md:68-85`. It separately records repeated WebKit at 4/5 with authoritative state already converged in the failure: lines 45-53.

**Confidence:** high that no server/package fanout or framing defect explains the reported symptom; medium-high for browser/runner attribution; medium for the separate Ctrl-C observation.