# Firefox multi-tab subscription investigation

## Conclusion

**Firefox remains a browser-acceptance blocker in this environment.** The failure occurs before Tuna receives the second subscription: Playwright reports the request, but headless Playwright Firefox 153 opens no second TCP connection and receives no response headers.

The evidence excludes a Tuna state/publication defect, a generic Gerbil HTTP concurrency limit, and Datastar automatic cancellation as primary causes. It localizes the problem to the interaction between Datastar v1.0.2 initialization timing and Playwright’s patched headless Firefox networking. The exact browser-side mechanism remains unproven.

No product change can presently make Firefox pass while preserving all approved constraints. In particular, sequential foregrounding is already implemented and fails; separate browser contexts would not prove the required two-tab behavior; reload/retry would mask the failure; and a server readiness counter would only confirm what a `200` response already proves.

WebKit can run in this environment and has passed the full gate, but its 4/5 repeated result is not yet sufficiently stable for checked acceptance.

## Contract and implementation trace

- The contract requires one handler-owned Server-Sent Events (SSE) subscription per tab, fixed routes, no heartbeat, and no second state owner/broadcaster: `plans/tuna-server-runtime/spec.md:11-25`.
- The highest acceptance seam explicitly requires real HTTP in Chromium, Firefox, and WebKit, with two tabs converging: `plans/tuna-server-runtime/spec.md:199-215`.
- Only `/`, `/subscribe`, and the two fixed asset routes are permitted: `plans/tuna-server-runtime/spec.md:148-169`.

### Exact document and initialization

The page is constructed at `tuna/tuna/private/http.ss:123-134`:

- the document-level keyboard directive is on `<html>`;
- the import map precedes the sole module script;
- `/assets/tuna-keyboard-v1.js` imports `action` from `"datastar"`;
- `<body>` owns `data-init="@get('/subscribe', {openWhenHidden: true})"`.

Datastar’s bundle imports its fetch action before the `init` attribute plugin:

- `.../datastar/library/src/bundles/datastar.ts:17-27`.

Attribute registration is queued through a zero-delay timer, after which attributes are applied:

- `.../datastar/library/src/engine/engine.ts:61-85`.

The `init` plugin invokes its expression synchronously when applied:

- `.../datastar/library/src/plugins/attributes/init.ts:11-33`.

Therefore module/plugin order is coherent: `@get` exists before `data-init` executes, and the Tuna keyboard action is registered before the queued attribute scan runs. No missing-plugin or duplicate-initialization evidence was found.

### Datastar request shape

For this GET, Datastar v1.0.2:

- defaults `requestCancellation` to `auto`: `fetch.ts:30-55`;
- creates an `AbortController`: `fetch.ts:46-64`;
- sends `Accept: text/event-stream, text/html, application/json` and `Datastar-Request: true`: `fetch.ts:73-95`;
- serializes empty signals into the query string, producing effectively `/subscribe?datastar=%7B%7D`: `fetch.ts:127-140,203-205`;
- sets `openWhenHidden: true`, so it does **not** install its visibility-change abort/reopen handler: `fetch.ts:464-502`;
- ultimately calls `window.fetch` with the GET method, headers, and internal signal: `fetch.ts:517-546`;
- consumes the response body as SSE after status `200`: `fetch.ts:574-599,642-661`.

The abort-controller map is module state keyed by method and URL, but browser tabs have separate JavaScript realms. Each page invokes only one `@get`, and the trial with `requestCancellation: 'disabled'` still failed. Cancellation is therefore not the explanation.

No explicit `credentials`, `cache`, `keepalive`, or fetch priority option is supplied; browser defaults apply.

## Firefox findings

### Reproduction

Recorded application probe output showed:

```text
request 0
response 0 200
request 1
goto 1
tick 0..9 true false
```

Thus:

1. the first application page receives subscription headers;
2. the second application page evaluates Datastar sufficiently to issue its request;
3. no second response event or request failure occurs for at least ten seconds.

During the acceptance stall, `ss -tnp` showed exactly one established Firefox-to-Tuna connection. This establishes that the second Playwright request event occurred before a TCP connection/server handler existed.

Playwright documents that:

- `request` means the page issued a request;
- `response` means status and headers were received;
- `requestfailed` is emitted for a network failure.

See `tuna/tuna/node_modules/.pnpm/playwright-core@1.62.1/node_modules/playwright-core/types/types.d.ts:1160-1177,21835-21850`.

The tested pinned browser is Playwright Firefox revision 1538 / Firefox 153.0:

- `.../playwright-core/browsers.json:32-38`.

### What has been excluded

**Not a generic Gerbil HTTP/SSE connection limit — high confidence.**

Two Firefox pages performing direct fetches both received `200` within approximately one second. The control also passed with Datastar’s `Accept`, `Datastar-Request`, and `AbortController` shape. Tuna’s handler registers the subscription before beginning the SSE response:

- `tuna/tuna/private/http.ss:176-201`.

The SSE writer flushes every frame:

- `sse-gerbil/sse.ss:40-58`.

**Not Tuna command admission or publication — high confidence.**

The Firefox failure occurs before commands are admitted. Runtime snapshots and capacity-one invalidations are protected by the same runtime mutex:

- installation and invalidation: `tuna/tuna/lib/runtime.ss:124-153`;
- atomic subscription registration: `tuna/tuna/lib/runtime.ss:314-330`.

The focused tests cover coherent coalescing and subscribe/install wakeups:

- `tuna/tuna/test/state-runtime-test.ss:196-248,250-292`.

**Not Datastar automatic cancellation — high confidence.**

Disabling cancellation did not change the result. Each realm has only one GET for the URL.

**Not merely background-tab visibility — medium/high confidence.**

The document uses `openWhenHidden: true`. The test already:

- waits for the first subscription before creating the second;
- brings the second page to the front before navigation;
- waits for its response before admitting commands.

See `tuna/tuna/frontend/test/browser.spec.ts:58-65,114-123`. Additional foregrounding and popup creation also failed. Playwright defines `bringToFront` as activating the tab at `types.d.ts:2102-2105`.

### Remaining attribution gap

The direct-fetch controls were not completely identical to Datastar initialization:

- they did not include Datastar’s `?datastar=%7B%7D` query;
- they ran after a minimal page had settled rather than during module/data-init startup;
- they did not execute through Datastar’s full fetch-event-source stack.

Consequently, the evidence supports but does not prove whether the defect belongs specifically to Datastar v1.0.2, Playwright’s patched headless Firefox, or their interaction. There is no evidence that stock headed Firefox behaves the same.

Classification:

| Category | Finding |
|---|---|
| Tuna product defect | No evidence; failure precedes the second handler/subscription. |
| Gerbil HTTP limitation | Effectively excluded by two concurrent direct SSE fetches. |
| Datastar v1.0.2 | Initialization/fetch stack is part of the trigger, but no standalone Datastar defect is proven. |
| Playwright/headless Firefox | Most likely environment-specific component; exact mechanism unresolved. |
| Test-design race | Existing readiness correctly exposes the stall, although its fetch monkeypatch is unnecessarily invasive. |

## Harness effects

`prepareSubscriptionProbe` at `tuna/tuna/frontend/test/browser.spec.ts:30-55` replaces `globalThis.fetch` using `addInitScript`. It:

1. calls a bound native fetch;
2. adds an extra Promise/microtask layer;
3. calls a Playwright-exposed function when headers arrive.

This changes page scheduling and fetch identity. However, the application probe reproduced the failure without this wrapper, so it is not sufficient to cause the defect.

The smallest harness cleanup is to replace the monkeypatch with Playwright’s native `page.waitForResponse` started before navigation. Playwright explicitly recommends starting the response wait before the triggering action:

- `types.d.ts:5574-5601`.

That would prove receipt of status/headers without altering application JavaScript. It is not expected by itself to make Firefox pass.

The first-page POST routing begins only after its subscription is ready and is removed before opening the second page: `browser.spec.ts:66-112`. It does not intercept `/subscribe`.

## Options and what they prove

### 1. Sequential foregrounding until the server observes registration

**Already implemented; does not resolve Firefox.**

A subscription response is stronger than a counter: because registration occurs before `call-with-datastar-sse`, receiving `200` proves the server subscription exists. The second page never reaches this point.

### 2. Separate browser contexts

This could determine whether Firefox’s scheduling problem is scoped to one browser context. Playwright describes contexts as independent sessions, while a popup remains in its parent context:

- `types.d.ts:8998-9006`.

It would prove two isolated Datastar clients subscribe to and converge on one Tuna root. It would **not** prove the approved same-context two-tab contract and therefore cannot replace acceptance.

### 3. Reload or retry the second page

A reload may cancel the never-connected attempt and schedule a later initialization after page load. It would:

- create more than one subscription request attempt;
- mask the initialization failure;
- require a timeout/retry policy not present in the contract;
- no longer prove stable first-load behavior.

Not recommended for acceptance.

### 4. Package-private test-only server readiness counter

A counter could prove handler registration but would not prove:

- response headers reached the browser;
- Datastar consumed the initial SSE frame;
- DOM morphing works.

The current `200` readiness proof already implies registration, and exposing the counter to the out-of-process browser harness would require a new route, output channel, or test executable. Those would weaken the fixed-route/highest-seam contract. Not recommended.

### 5. Nonintrusive response readiness plus exact diagnostic matrix

**Recommended diagnostic/harness change.**

Use `page.waitForResponse` rather than overriding fetch, then run these non-acceptance controls:

1. exact direct URL including `?datastar=%7B%7D`;
2. minimal page with pinned Datastar and the exact `data-init`;
3. same page invoking `@get` only after `datastar-ready`;
4. two pages in one context versus separate contexts;
5. Playwright headless versus headed Firefox if the environment supports headed execution.

Interpretation:

- minimal `data-init` failure isolates Datastar/Firefox from Tuna’s keyboard plugin;
- delayed action success isolates initialization timing;
- separate-context-only success isolates same-context Firefox scheduling;
- headed success isolates headless/Playwright behavior.

Until that matrix identifies a contract-preserving change, Firefox should remain a visible failure rather than be skipped or weakened.

## WebKit convergence timeout

The repeated WebKit run produced four passes and one failure:

```text
Expected: 3
Received: 2
Timeout 15000ms
browser.spec.ts:132
```

All three POSTs had returned `204`, but `204` is admission-only by contract:

- `plans/tuna-server-runtime/spec.md:152-167`.

Therefore the current test conflates:

1. authoritative Tuna completion reaching counter 3; and
2. each SSE client rendering counter 3.

The smallest rigorous improvement is to poll existing `GET /` until its rendered authoritative counter reaches `initial + 3`, then retain the unchanged per-tab convergence assertions. This adds no route, state, heartbeat, sleep, or weakened assertion. It would classify a future timeout:

- server remains at 2: command/completion issue;
- server is 3 while a tab is 2: browser/SSE delivery or background-processing issue.

The runtime’s lock/coalescing design does not expose an obvious lost-wakeup gap, and its focused tests cover that race. With only one failure, the precise WebKit cause remains unresolved.

## Bounded implementation handoff

1. Replace `prepareSubscriptionProbe`’s fetch override with a pre-navigation `page.waitForResponse` predicate for GET `/subscribe`, status `200`; retain per-page request counts and add failure-only request/response/requestfailed diagnostics.
2. Before tab convergence, poll existing `GET /` for authoritative counter `initial + 3`; do not change the convergence value or timeout.
3. Keep Firefox as a required same-context two-tab project. Do not substitute contexts, reloads, retries, skips, or expected failures.
4. Run the exact diagnostic matrix above. Change product code only if it reproduces outside the Tuna page or identifies a standards-compliant initialization change compatible with the pinned markup/Datastar contract.
5. Repeat Firefox and WebKit at least five times, then run the full staged gate.

## Acceptance status in this environment

- **Firefox:** cannot validly pass the approved acceptance contract presently. Same-context two-tab Datastar initialization deterministically fails before the second server connection.
- **WebKit:** executable and capable of passing the full gate, but 4/5 repetition is insufficient for reliable checked acceptance. The authoritative-state barrier should be added and repetitions rerun.
- **Chromium:** passed 5/5 and the full-gate scenario.

## Validation evidence

Recorded validation from the authoritative implementation report:

- frontend check: passed;
- source/normal/optimized Gerbil matrix: passed;
- Chromium repeat: 5/5 passed;
- Firefox original repeat: 5/5 failed;
- Firefox deterministic readiness: failed before second subscription headers;
- WebKit repeat: 4/5 passed;
- full gate: all non-browser gates, Chromium, and WebKit passed; Firefox failed;
- dependency/worktree baselines remained unchanged.

Focused commands:

```sh
cd /home/jay/Code/workbench-gerbil/tuna/tuna
PATH=/home/jay/.nix-profile/bin:/usr/bin:/bin corepack pnpm run check

cd /home/jay/Code/workbench-gerbil
PATH=/opt/gerbil/bin:/usr/bin:/bin tuna/tuna/test/run-command-runtime-matrix.sh
```

Full gate:

```sh
cd /home/jay/Code/workbench-gerbil
GERBIL_BINDIR=/opt/gerbil/bin \
NODE_COREPACK_BINDIR=/home/jay/.nix-profile/bin \
GO_BINDIR=/usr/local/go/bin \
tuna/tuna/test/run-server-runtime-validation.sh
```

## Risks and confidence

- **Blocker:** Firefox same-context two-tab subscription establishment.
- **High:** the prior direct control was not exact in URL and initialization phase, so final Datastar-versus-Playwright attribution remains open.
- **Medium:** WebKit has one unexplained convergence timeout.
- **Medium:** current fetch monkeypatch perturbs the page, although a wrapper-free application probe reproduced Firefox.
- **Confidence:** high for excluding Tuna state, Gerbil concurrency, and cancellation; medium for Datastar/headless-Firefox interaction; low for the exact browser-network mechanism.

No files were changed by this read-only investigation. Outer, Tuna, Datastar, SSE, and Gerbil indexes contain no staged files. Existing unstaged Tuna implementation and the three pre-existing Gerbil generated-C modifications remain.