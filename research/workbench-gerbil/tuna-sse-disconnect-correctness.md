# Tuna SSE peer-disconnect correctness report

## Conclusion

**Only Tuna should change.** `sse-gerbil` correctly preserves transport failures, `datastar-gerbil` correctly delegates, and Gerbil owns HTTP response finalization. Tuna owns the policy that an expected peer departure is not an application failure.

The current unstaged Tuna fix is **not safe**: its catch spans the entire Server-Sent Events (SSE) callback and can swallow renderer or other application errors that happen to be an `OSError` with a listed errno.

## Findings

### Blocker — application errors can be swallowed

`tuna/tuna/private/http.ss:193-213` catches around all of:

- SSE response begin and close;
- initial and subsequent rendering;
- snapshot access;
- subscription waiting;
- Datastar framing and transport writes.

The renderer is dynamically replaceable and may raise arbitrary exceptions (`tuna/tuna/private/render.ss:72-84`). Consequently, an application renderer raising `EPIPE`, `ECONNRESET`, or `ECONNABORTED` is silently treated as a client departure.

The test at `tuna/tuna/test/server-runtime-test.ss:326-335` verifies only a free-standing predicate. It does not prove transport provenance, renderer propagation, handler behavior, or subscription cleanup.

### Important — `ECONNABORTED` is not evidenced as a peer reset

Public Gerbil v19 provides `OSError?`, `OSError-errno`, and errno constants through `:std/os/error` (`gerbil/src/std/os/error.ss:6-18,96-128`). On this installation:

- `EPIPE`: “Broken pipe”
- `ECONNRESET`: “Connection reset by peer”
- `ECONNABORTED`: “Software caused connection abort”
- `EIO`: “Input/output error”

Gerbil socket sends propagate non-timeout send errors as `OSError` unchanged (`gerbil/src/std/io/socket/client.ss:31-48`).

**Recommended classifier:** accept only transport-provenanced `EPIPE` and `ECONNRESET`. Treat `ECONNABORTED` as a genuine failure until a supported-platform reproduction establishes that peer teardown produces it. The current positive assertion for `ECONNABORTED` is unsupported.

### Important — no current behavior-facing Tuna protocol test

The staged gate runs SSE, Datastar, and Tuna suites (`tuna/tuna/test/run-server-runtime-validation.sh:93-117`), but explicitly requires both former server-protocol fixtures to be absent (`:148-155`). Therefore the current checkout has no Tuna-level TCP test that proves abrupt disconnect containment and clean process shutdown.

Prior investigation documented that such a raw multi-client scenario had caught the actual `Broken pipe`/exit-70 failure, but that seam is absent from the current staged tree.

### Note — Gerbil can report a second close failure

Gerbil:

1. invokes the handler;
2. logs any escaping handler exception and attempts a 500;
3. always closes the request and response (`gerbil/src/std/net/http/server/server.ss:230-246`);
4. catches later cleanup failures in an outer logger (`:248-260`).

The response closer closes compressed/chunked writers and the connection writer (`gerbil/src/std/net/http/server/request.ss:202-209`). Thus even after Tuna contains the original send failure, Gerbil may log a later best-effort close failure. Tuna cannot suppress that server-owned close using public APIs. Validation must distinguish the original application-log blocker from a possible outer server cleanup diagnostic.

## Ownership

### Change Tuna

Tuna owns:

- deciding which peer-loss conditions are expected;
- containing those conditions at `/subscribe`;
- ensuring its state subscription is unregistered;
- ensuring renderer, snapshot, wait, Datastar-validation, timeout, and other failures propagate.

Keep the classifier/helper private to `:tuna/private/http`; the current export exists only to support a weak predicate test.

### Do not change `sse-gerbil`

`call-with-sse`:

- begins the streaming response;
- invalidates the session on every exit;
- latches and re-raises the first write/flush failure;
- skips normal writer close after transport failure.

Evidence: `sse-gerbil/sse.ss:11-17,19-38,40-58`; lifecycle tests at `sse-gerbil/sse-test.ss:191-224`.

That is correct generic transport behavior. Swallowing peer loss there would impose Tuna policy on every consumer and hide failures from applications that require them.

### Do not change `datastar-gerbil`

`call-with-datastar-sse` validates and delegates directly (`datastar-gerbil/http/api.ss:121-125`). `patch-elements` validates/builds a frame and ultimately calls `sse-send!` (`datastar-gerbil/http/private/core.ss:377-423`). It should continue propagating failures unchanged.

### Do not change Gerbil

Gerbil exposes the required public response and error APIs. Project rules also prohibit agent changes or rebuilding Gerbil.

## Recommended implementation design

Use a Tuna-private transport marker plus explicit lifecycle phase:

1. Maintain a phase: `begin`, `application`, or `end`.
2. Invoke rendering and all application operations while in `application`.
3. Pass the already-evaluated rendered fragment to a narrow send helper.
4. The helper catches only around `patch-elements`.
5. If that exact call raises a transport-provenanced `EPIPE` or `ECONNRESET`, replace it with a unique Tuna-private peer-disconnected marker.
6. Reraise every other exception unchanged.
7. The outer SSE boundary swallows only:
   - that unique marker;
   - a matching `OSError` while still in `begin`, where the callback has not started;
   - a matching `OSError` after the callback has completed and phase is `end`.
8. Never classify a raw matching `OSError` while phase is `application`; renderer, snapshot, subscription-wait, and application failures must escape unchanged.
9. Retain the subscription `finally` around the complete response lifecycle.

Replacing a send failure with a unique marker is compatible with current `sse-gerbil`: callback exceptions propagate through `call-with-sse` while its `finally` invalidates the session (`sse-gerbil/sse.ss:28-38`).

## Cleanup guarantees

For every registered Tuna subscription:

- `state-subscription-close!` runs on normal EOF, expected disconnect, rendering error, non-disconnect transport error, begin/close failure, and shutdown.
- Closing is idempotent, removes the subscription under the runtime lock, and closes its channel (`tuna/tuna/lib/runtime.ss:338-350`).
- The SSE session becomes unusable on every exit (`sse-gerbil/sse.ss:11-17,28-38`).
- Tuna must not attempt a second HTTP response after streaming has begun.
- Idle disconnect detection remains write-driven: a dead idle client remains registered until a later patch or shutdown.

## Smallest behavior-facing tests

1. **Deterministic handler test**
   - Use an instrumented public `ResponseHandler` writer.
   - Raise `EPIPE` during the initial Datastar frame write.
   - Assert the subscription runner returns normally and its retained subscription observes EOF afterward.
   - Repeat with `ECONNRESET`.
   - Raise `EIO` from the same transport seam and assert the exact exception escapes.

2. **Renderer non-swallow regression**
   - Configure `tuna-render-state` to raise the exact same synthetic `EPIPE` object.
   - Assert the exact object escapes the subscription runner.
   - This is the critical regression missing from the current predicate-only test.

3. **Focused real-TCP acceptance**
   - Receive an initial `/subscribe` frame, close the client, trigger bounded subsequent state updates, and require handler/subscription cleanup by deadline.
   - Do not assert which TCP write fails.
   - Require clean Tuna stop/exit and absence of the original “unhandled exception in handler” application-log failure.

The first two can share one package-private subscription-runner seam; no new public Tuna product API is necessary.

## Rejected alternatives

- **Current whole-callback catch:** swallows matching renderer/application errors.
- **Catch all `OSError`:** hides disk, descriptor, timeout, and general I/O failures.
- **Match error-message text such as “Broken pipe”:** localized and implementation-dependent.
- **Swallow failures in `sse-gerbil` or `datastar-gerbil`:** wrong policy ownership and breaks their exact propagation contract.
- **Wrap rendering inside the transport catch:** argument evaluation becomes indistinguishable from transport failure.
- **Modify Gerbil response internals:** unnecessary, private, and prohibited.

## Git/diff state

Tuna currently has:

- **22 staged files**, 1,974 insertions and 31 deletions.
- **2 unstaged files**, adding 25 lines:
  - `tuna/tuna/private/http.ss`
  - `tuna/tuna/test/server-runtime-test.ss`

There are staged files; `noStagedFiles` is therefore false. `sse-gerbil` and `datastar-gerbil` are clean. The Gerbil checkout has pre-existing unstaged generated C modifications and was not modified or rebuilt.

## Validation

Commands executed:

- `git -C tuna status --short`, staged/unstaged diff inspection.
- `git -C tuna diff --check` — passed.
- `git -C tuna diff --cached --check` — passed.
- Gerbil public errno/message probe — passed.
- Dependency and Gerbil status inspection — passed.

No build or test suite was run during this read-only investigation.

### Focused validation after correction

Use a disposable stage, building dependencies in order:

```sh
export GERBIL_PATH="$(mktemp -d)/gerbil"
export GERBIL_GXC=/opt/gerbil/bin/gxc
export GERBIL_LOADPATH=
mkdir -p "$GERBIL_PATH"

(cd sse-gerbil && /opt/gerbil/bin/gxi ./build.ss compile)
(cd datastar-gerbil && /opt/gerbil/bin/gxi ./build.ss compile)
(cd tuna/tuna && /opt/gerbil/bin/gxi ./build.ss compile)
(cd tuna/tuna && /opt/gerbil/bin/gerbil test -v 0 ./test/server-runtime-test.ss)
```

### Full evidence-backed gate

```sh
GERBIL_BINDIR=/opt/gerbil/bin \
GO_BINDIR=/usr/local/go/bin \
ESBUILD=/home/jay/.nix-profile/bin/esbuild \
tuna/tuna/test/run-server-runtime-validation.sh
```

The full gate should include or be followed by the real-TCP disconnect scenario described above.

## Residual risks and confidence

- **Medium:** `ECONNABORTED` portability remains unevidenced; do not suppress it by default.
- **Medium:** Gerbil may separately log a response-close failure after Tuna contains the original failed send.
- **Known:** idle disconnects remain until a subsequent write or shutdown.
- **High confidence:** package ownership and the current catch-scope defect follow directly from source.
- **Medium-high confidence:** the phase/marker design preserves renderer/application errors without changing dependency APIs.