# Research: Datastar server-side HTTP/SSE protocol

## Summary
For an SDK HTTP module, implement the Datastar SDK contract: `text/event-stream`, ordered SSE records named `datastar-patch-elements` or `datastar-patch-signals`, each terminated by a blank line. Each SSE `data:` value is a Datastar sub-record (`key + space + value`); repeated keys are newline-joined by the client. This brief is pinned to Datastar main `ab49c217c3d17578f262e7356b84808e892667dc` (commit date 2025-12-17; bundle RC.7), with the official SDK ADR and golden tests as the primary server-implementation authority.

## Findings
1. **Required response setup.** The SDK ADR says a generator must accept request/response objects and set `Content-Type: text/event-stream`, `Cache-Control: no-cache`, and (HTTP/1.1 only) `Connection: keep-alive`; it should flush immediately and preserve ordered delivery. Do not buffer emitted events. [SDK ADR (pinned)](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md)

2. **Exact SSE envelope and event names.** Supported SDK event names are exactly `datastar-patch-elements` and `datastar-patch-signals`. Write fields in this order: `event: TYPE\n`; optional `id: ID\n`; `retry: MS\n` only when non-default (SDK default 1000 ms); one `data: VALUE\n` per payload line; then one additional `\n` to dispatch the event. The blank line is mandatory. [SDK ADR](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md) · [golden: all element options](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/test/get-cases/patchElementsWithAllOptions/output.txt)

3. **Datastar `data:` grammar and multiline rule.** Every `data:` value must be `NAME` followed by one ASCII space and its value (for example `data: elements <div…>` or `data: signals {"x":1}`). The client splits the SSE event data on LF, splits each resulting line at its first space, groups same-name records, then LF-joins their values. Therefore physical multiline HTML must be emitted as separate `data: elements ...` records—not raw continuation lines. This is confirmed by the official multiline golden. [client source](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/library/src/plugins/actions/fetch.ts) · [golden: multiline elements](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/test/get-cases/patchElementsWithMultilineElements/output.txt)

4. **Element-patch payload.** `datastar-patch-elements` accepts `elements` (one or more complete HTML elements; required unless removal), plus optional `selector`, `mode`, `useViewTransition`, and `namespace`. Defaults: `mode outer`, `useViewTransition false`, `namespace html`; modes are `remove|outer|inner|replace|prepend|append|before|after`; namespaces are `html|svg|mathml`. If no selector is supplied, only `outer`/`replace` are valid and top-level elements need target IDs; `remove` uses a selector and may omit elements. Emit non-default options before `elements`; emit every physical HTML line as an `elements` record. [SDK ADR](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md) · [client watcher](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/library/src/plugins/watchers/patchElements.ts)

5. **Signal-patch payload and JSON convention.** `datastar-patch-signals` carries `data: signals VALUE`; optional `data: onlyIfMissing true` precedes it. The SDK contract calls the input a valid JSON string and applies RFC 7386 merge-patch semantics (`null` deletes; objects merge recursively). Use compact, valid JSON as the portable SDK output—the golden tests do. The browser parser first tries `JSON.parse`, then deliberately falls back to evaluating a JavaScript object expression; that fallback is client convenience/compatibility, **not** an SDK wire requirement. For JSON containing escaped newlines, retain `\n` within one JSON record; for physically formatted JSON, repeat `data: signals ` on every source line so the client reconstructs LF-separated text. [SDK ADR](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md) · [golden: signals](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/test/get-cases/patchSignalsWithAllOptions/output.txt) · [golden: physical multiline JSON](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/test/get-cases/patchSignalsWithMultilineJson/output.txt) · [parser fallback](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/library/src/utils/text.ts)

6. **`id`, `retry`, and reconnect behavior.** `id` and `retry` are standard SSE fields, exposed by the SDK as optional `eventId` and `retryDuration`; SDK output suppresses `retry` at its 1000-ms default. On an ID-bearing event, Datastar stores the ID and sends it as `Last-Event-ID` on its next retry; an empty ID clears that header. A received numeric `retry` becomes the reconnection base interval. Its fetch client has additional policy (default exponential retries, max count 10, visibility/cancellation behavior), so servers must support replay only if they intentionally issue IDs and honor `Last-Event-ID`; it is not otherwise required to retain history. [SDK ADR](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md) · [Datastar SSE client](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/library/src/plugins/actions/fetch.ts)

7. **Cache and compression.** `Cache-Control: no-cache` is an SDK requirement. The ADR warns compression middleware can prevent immediate flush; it does **not** forbid HTTP content compression or prescribe `Content-Encoding`. Treat compression as deployment transport behavior: only enable it if the server/proxy preserves streaming/flushing and does not buffer the event stream. No Datastar-specific anti-buffering header is specified by the official SDK contract. [SDK ADR](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md)

8. **Conformance target.** Implement `ReadSignals`: GET reads URL-encoded JSON from query parameter `datastar`; non-GET reads JSON from the request body; invalid JSON is an error. Validate a `/test` endpoint with the official SDK test runner and goldens, which exercise defaults, omitted defaults, IDs/retry, multiline elements/signals/JSON, scripts, removals, and two-event output. [SDK test README](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/tests/README.md) · [test cases](https://github.com/starfederation/datastar/tree/ab49c217c3d17578f262e7356b84808e892667dc/sdk/test/get-cases)

## Protocol requirements vs out-of-scope sugar

**Implement in the HTTP module:** response headers; serialized SSE envelope; blank-event terminator; ordered/flushable writes; both event names; the data sub-record grammar; element and signal payload records; optional ID/retry; `ReadSignals`; validation against golden output.

**Do not add as protocol surface:** language/framework response wrappers; fluent builders; script helper (`ExecuteScript` is specified as a convenience that emits an element patch with a `<script>` tag); browser action syntax; non-SSE `text/html`, `application/json`, and `text/javascript` response shortcuts; permissive JS-object parsing for signals; retry/backoff/cancellation controls belonging to the browser action client.

## Sources
- **Kept:** [Datastar SDK ADR, pinned main](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/sdk/ADR.md) — normative SDK construction, serialization, payload and request-reading contract.
- **Kept:** [Official SDK golden cases, pinned main](https://github.com/starfederation/datastar/tree/ab49c217c3d17578f262e7356b84808e892667dc/sdk/test/get-cases) — executable expected wire bytes.
- **Kept:** [Datastar client SSE parser, pinned main](https://github.com/starfederation/datastar/blob/ab49c217c3d17578f262e7356b84808e892667dc/library/src/plugins/actions/fetch.ts) — direct evidence for actual multiline, ID, retry, and connection behavior.
- **Kept:** [Official SSE events reference](https://data-star.dev/reference/sse_events) — public event/payload reference; useful but less precise than pinned source for SDK implementation.
- **Dropped:** third-party SDK docs/blogs — derivative and version-skew prone.

## Gaps
The current public SSE reference includes `viewTransitionSelector`, while the pinned main client watcher/SDK ADR evidence above does not show it as an implemented SDK option. Do not implement that field without selecting and pinning a Datastar release whose client source and SDK contract both support it. The official ADR does not prescribe proxy-specific anti-buffering configuration or a compression algorithm; integration tests must verify the chosen Gerbil server and deployment proxy flush actual bytes promptly.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete protocol findings and source permalinks are in .pi-subagents/artifacts/outputs/2ae1f4a5-8048-4df2-b7d6-7d81a5ca926e/research/06-datastar-protocol-authoritative.md."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/2ae1f4a5-8048-4df2-b7d6-7d81a5ca926e/research/06-datastar-protocol-authoritative.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "web research: official Datastar docs, pinned GitHub source, and official golden tests",
      "result": "passed",
      "summary": "Sources retrieved and cross-checked; no project code was executed."
    }
  ],
  "validationOutput": [
    "Artifact written at the required path.",
    "Protocol claims are sourced to pinned Datastar main commit ab49c217c3d17578f262e7356b84808e892667dc."
  ],
  "residualRisks": [
    "Public docs and pinned client source differ on viewTransitionSelector; do not implement it until a target release is pinned.",
    "Compression/proxy buffering behavior needs deployment-specific integration validation."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added research artifact only; no application source or tests changed.",
  "reviewFindings": [
    "no blockers: authoritative ADR, client parser, and official golden tests agree on core envelope, event names, ordering, and multiline encoding."
  ],
  "manualNotes": "The artifact separates minimum protocol work from optional SDK sugar and browser-client conveniences."
}
```