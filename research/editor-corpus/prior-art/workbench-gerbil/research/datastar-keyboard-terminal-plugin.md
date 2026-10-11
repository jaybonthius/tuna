# Datastar browser keyboard transport for Tuna

## Conclusion

**Stock Datastar can perform the narrow browser operation**:

- listen for every `keydown` that reaches the top-level `document`;
- listen in capture phase;
- synchronously call `preventDefault()`;
- read the `KeyboardEvent` through `evt`;
- build a JSON payload from explicit fields; and
- invoke `POST /` once per handler invocation.

A stock-only attribute can therefore serve as a prototype:

```html
<html
  data-on:keydown__document__capture__prevent="
    @post('/', {
      payload: {
        version: 1,
        type: 'keydown',
        key: evt.key,
        code: evt.code,
        location: evt.location,
        repeat: evt.repeat,
        isComposing: evt.isComposing,
        altKey: evt.altKey,
        ctrlKey: evt.ctrlKey,
        metaKey: evt.metaKey,
        shiftKey: evt.shiftKey
      },
      requestCancellation: 'disabled',
      retry: 'never'
    })
  "
>
```

This remains a dumb transport: it names no state, mode, prefix, keymap, command, transition, or binding.

**Stock `@post` is not sufficient for a robust ordered terminal protocol**, however:

1. Its default cancellation aborts an earlier in-flight `POST` to the same method and URL.
2. Disabling cancellation permits concurrent requests but does not guarantee server arrival, processing, or response-patch order.
3. Datastar v1.0.2 documentation says `retry: 'never'` disables retry, but its network-error catch path calls `retryRequest()` without checking that setting.
4. Browser delivery across disconnects cannot be exactly-once; retrying an ambiguously failed `POST` can duplicate it.

**Recommendation:** retain stock `data-on:keydown__document__capture__prevent`, but use one very small custom **action plugin** for event snapshotting and ordered transport. This is smaller and safer than a custom listener attribute and uses only Datastar’s public `action()` extension API.

---

## Repository constraints

The settled Tuna design says:

- the browser submits an event rather than a target command;
- server-side state performs current-root resolution;
- browser capture/default behavior is host-owned;
- browser protocol choices for layout, repeat, composition and modifiers remain open.

Evidence:

- `plans/tuna-input-keymaps/spec.md:34-58`
- `plans/tuna-input-keymaps/spec.md:102-114`
- `plans/tuna-input-keymaps/spec.md:144-146`
- `plans/tuna-input-keymaps/spec.md:224-233`
- `research/tuna-input-keymap-api-options.md:42-53`
- `research/tuna-input-keymap-api-options.md:179-186`
- `research/tuna-input-keymap-api-options.md:443-450`

The implemented resolver accepts application-controlled domains and canonical Tuna modifiers `(control meta shift super hyper alt)`:

- `tuna/tuna/lib/keymap.ss:28-52`
- `tuna/tuna/lib/keymap.ss:57-96`
- `tuna/tuna/lib/keymap.ss:100-123`

The browser plugin must not map `metaKey` to Tuna `meta` or `super`, select logical versus physical identity, or intern arbitrary `key`/`code` strings. Those are server-side host-adapter decisions.

---

## Official Datastar evidence

Sources below are pinned to official Datastar v1.0.2 commit:

`e24f04d43ca4445d662b4a035e5bfe9ed68de57c`

### Event placement, capture and synchronous cancellation

`library/src/plugins/attributes/on.ts:15-25` selects the element, `window`, or `document` target. Lines `34-38` construct capture/passive/once listener options. Lines `55-65` call `preventDefault()` before invoking the expression callback. Lines `65-68` install the listener and return removal cleanup.

Thus:

```html
data-on:keydown__document__capture__prevent="..."
```

installs a non-passive document capture listener and performs cancellation synchronously. Calling `preventDefault()` on a non-cancelable event is merely ineffective; it does not need to be delayed or delegated to the server.

Official reference:

- `https://data-star.dev/reference/attributes`, generated text around `data-on`: `evt` is available; `__capture`, `__document`, and `__prevent` are supported.

### Event payload and action expression syntax

`library/src/engine/engine.ts:488-519` rewrites `@action(...)` expressions and passes the current event in `ActionContext.evt`. Official type evidence:

- `library/src/engine/types.ts:24-31` — `ActionContext` includes `evt?: Event`.
- `library/src/engine/types.ts:107-112` — public action plugin shape.
- `library/src/bundles/datastar.ts:1-15` — `action` is publicly exported.

Official attributes documentation also states that expressions support JavaScript object/array literals and that `evt` represents the event object.

### JSON requests

`library/src/plugins/actions/fetch.ts:28-44` exposes `payload`, headers, cancellation and retry options. Lines `73-80` add:

- `Accept: text/event-stream, text/html, application/json`
- `Datastar-Request: true`
- `Content-Type: application/json`

Lines `127-140` select the custom payload and synchronously `JSON.stringify()` it. Lines `229-233` register `@post`.

A short event endpoint should return **204 No Content**, avoiding an unnecessary long-lived Server-Sent Events (SSE) response.

### Cancellation and concurrency

In v1.0.2, `library/src/plugins/actions/fetch.ts:16-18,46-63` tracks abort controllers by method and URL. The official actions reference says:

- `requestCancellation: 'auto'` cancels an in-flight request to the same method and URL;
- `'disabled'` allows concurrent requests.

Therefore the default is incorrect for rapid keyboard input. `requestCancellation: 'disabled'` is mandatory for a stock-only design.

### Retry discrepancy

Official actions documentation says:

- `retry: 'auto'` retries network errors;
- `retry: 'never'` disables retries.

But v1.0.2 source `library/src/plugins/actions/fetch.ts:672-680` invokes `retryRequest()` for any non-abort network exception without testing `retry`. This is a source/documentation discrepancy and a reason not to rely on stock `@post` for exact transport behavior.

### Morph lifecycle and duplicate prevention

`library/src/engine/engine.ts` provides the relevant lifecycle:

- `:58-59` tracks cleanup by element and attribute;
- `:117-127` executes cleanup when elements are removed;
- `:154-200` observes removed/added nodes and changed data attributes;
- `:367-384` applies a replacement plugin instance, cleans the previous instance, and records the new cleanup.

The stock `data-on` cleanup removes its exact listener. A normal fat morph therefore does not accumulate listeners when the same annotated element/attribute is reapplied.

Constraints:

- Put the keyboard attribute on exactly one stable element, preferably `<html>`.
- Include it in full-document morph output.
- Normal `outer` morphing preserves matched root elements; replacing `document.documentElement` outright is riskier because Datastar observes the document element rather than `Document`.
- Multiple separate elements carrying the document listener will each receive the same event. Datastar prevents reapplication leaks; it does not enforce application-wide singleton markup.

---

## Keyboard wire fields

The smallest layout-neutral payload should preserve raw standardized browser facts:

| Field | Meaning |
|---|---|
| `version` | Transport schema version, not Tuna state |
| `type` | Constant `keydown` |
| `key` | Logical/layout-sensitive key value |
| `code` | Physical-position-oriented code |
| `location` | Standard/left/right/numpad location |
| `repeat` | Browser auto-repeat boolean |
| `isComposing` | Whether the event occurred within an Input Method Editor composition session |
| `altKey` | Standard modifier boolean |
| `ctrlKey` | Standard modifier boolean |
| `metaKey` | Standard modifier boolean |
| `shiftKey` | Standard modifier boolean |

Do not serialize the DOM target, command names, modes, bindings, pending prefixes, or Tuna state.

Do not replace `key` with `code`:

- `KeyboardEvent.key` reflects locale, layout and modifiers and can be a character, standardized named key, `Dead`, or `Unidentified`.
- `KeyboardEvent.code` represents physical position and does not reveal the generated character.

Both must be preserved so the server-side host adapter can select a Tuna key domain. MDN authoritative summaries:

- `https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/key`
- `https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/code`

The four browser modifier booleans should be transmitted separately. Mapping them to Tuna’s six-symbol vocabulary is not browser transport work.

### Fields to omit

- `keyCode`, `which`, and `charCode` are legacy/deprecated.
- `timeStamp` is not a portable wall-clock value.
- `defaultPrevented` merely reflects the capture policy.
- `target` leaks DOM/UI details.
- A computed “primary modifier” would embed platform/keymap policy.

### Composition limitation

`isComposing` is worth preserving, but it is not a complete text-input protocol. MDN notes that the first composition `keydown` can precede `compositionstart` and the final one can follow `compositionend`. Capturing only `keydown` also does not transmit committed composed text.

The plugin should forward these events without interpreting them. Unconditional cancellation can disrupt Input Method Editor (IME), native editing and accessibility behavior; this is a high-risk product constraint already recognized at `plans/tuna-input-keymaps/spec.md:224-233`.

---

## Ordering and delivery

### Built-in-only

With cancellation disabled, every delivered event invokes `@post`, but requests are independent and concurrent. Network and HTTP/2 processing may reorder them; concurrent Datastar responses can also patch the browser in completion order rather than keyboard order.

A sequence number can detect reordering, but stock actions do not themselves serialize admission. A promise chain could technically be embedded in an attribute expression, but that turns the markup into fragile transport code and still inherits Datastar’s retry discrepancy.

### Smallest custom plugin

Use a public **action plugin**, invoked as:

```html
data-on:keydown__document__capture__prevent="@terminalKey()"
```

Its behavior should be limited to:

1. Require `ctx.evt` to be a `keydown` `KeyboardEvent`.
2. Immediately snapshot the canonical fields above.
3. Optionally add a per-page transport stream identifier and monotonic sequence number for duplicate/reorder detection.
4. Suppress a second invocation for the same `KeyboardEvent` object, for example when malformed duplicate document listeners exist.
5. Append the immutable snapshot to a module-owned promise queue.
6. Perform at most one same-origin `fetch('/')` at a time.
7. Send JSON with `Content-Type: application/json` and `Datastar-Request: true`.
8. Continue the queue after failures rather than leaving it permanently rejected.
9. Perform no automatic retry unless the protocol also defines an idempotency/deduplication identifier.

It needs no Tuna state and no listener lifecycle of its own. Stock `data-on` owns capture, synchronous prevention, morph cleanup and reattachment.

The required Datastar extension API is only:

- `import { action } from 'datastar'`
- `action({ name, apply(ctx) { ... } })`
- `ActionContext.evt`

A custom **attribute** plugin is materially larger and is justified only if the project wants a single `data-terminal-keyboard` attribute that installs the listener itself. It would need `attribute()`, a document capture listener, singleton ownership and a returned removal cleanup. It is not the smallest extension.

### Exactly-once is impossible in the browser

If a connection fails after the server accepted the body but before the response arrives, the browser cannot know whether retrying will duplicate the event. A page reload also loses an in-memory queue.

The defensible choices are:

- no retry and possible loss;
- retry with a stream/event identifier and server deduplication;
- a more substantial acknowledged transport.

That is a protocol/product choice, not something stock Datastar or a tiny plugin can hide.

---

## Reserved shortcuts and capture boundaries

A document listener can capture only events delivered to that document:

- operating-system or browser-reserved shortcuts may never be delivered;
- keyboard events focused in another iframe belong to that frame’s document;
- a listener on `window` earlier in capture order can stop propagation before `document`;
- keys pressed before Datastar initializes are not captured.

The experimental Keyboard Lock API exists specifically to capture keys normally reserved by the user agent or operating system, but it is limited-availability, secure-context only, requires user activation, and still cannot capture keys withheld by the operating system. It should not be assumed for Tuna:

- `https://developer.mozilla.org/en-US/docs/Web/API/Keyboard_API`
- `https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/lock`

Therefore “every keydown” can only mean **every keydown delivered to the top-level document after listener installation**.

---

## CSRF and headers

`POST /` is same-origin, and Fetch credentials default to `same-origin`; normal session cookies will be included.

`Datastar-Request: true` is a marker, not a secret. The JSON content type and custom header make the request non-simple, which blocks ordinary cross-origin scripted requests unless the server deliberately permits them through Cross-Origin Resource Sharing (CORS). The server should still:

- require `application/json`;
- require the Datastar/custom request header;
- reject cross-site `Origin` or `Sec-Fetch-Site`;
- use a Cross-Site Request Forgery (CSRF) token if the deployment’s authentication model requires one;
- avoid permissive credentialed CORS.

Official Datastar actions documentation supports explicit `headers`, including a CSRF-token example. MDN background:

- `https://developer.mozilla.org/en-US/docs/Web/Security/Practical_implementation_guides/CSRF_prevention`
- `https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS`

---

## Distribution and loading

Plugin-starter evidence is pinned at:

`Regaez/datastar-plugin-starter@cf4392425bce4e7c307bdce614c5808c905ca614`

Relevant paths:

- `src/index.ts:1-17` — public `action()` registration example.
- `esbuild.config.mjs:1-10` — ESM bundle with `datastar` external.
- `README.md:48-64` — prefer public API; internal APIs are unstable.
- `README.md:117-139` — import map plus plugin module loading.
- `package.json:18-27` — `pnpm build`; starter currently depends on Datastar v1.0.0.
- `pnpm-lock.yaml:9-18` — dependency resolves through annotated v1.0.0 tag object `3cab74bf...`; dereferenced Datastar commit is `ecb1d4c4043524c1c5c58681c8337ded544f7a3a`.

Two valid distribution forms:

1. **Separate plugin ESM — recommended.** Self-host a pinned official `datastar.js`, map `"datastar"` to it, and load the compiled plugin module once. This is exactly the plugin-starter model and honors the explicit custom-plugin exception.
2. **One custom Datastar bundle.** Build an entry point importing Datastar and the plugin, producing one application-owned `datastar.js`. This satisfies a literal one-script interpretation but couples distribution more tightly to a Datastar version.

Do not ship application-authored imperative page JavaScript. The only invocation remains a data attribute. Pin the plugin and Datastar to the same release; the starter’s v1.0.0 pin should not silently coexist with a v1.0.2 browser import.

Datastar expressions use `Function()`, so the official security reference requires Content Security Policy (CSP) `unsafe-eval`. A custom action plugin does not remove that existing Datastar constraint.

---

## Option comparison

| Option | Capture/cancel | Event payload | Ordering | Retry control | Morph lifecycle | Assessment |
|---|---|---|---|---|---|---|
| Stock `data-on` + stock `@post` | Yes | Yes | Concurrent; not guaranteed | Documentation/source discrepancy | Built in | Good prototype, weak terminal transport |
| Stock `data-on` + custom action | Yes | Yes | Can enforce one in flight | Directly controlled | Built in | **Recommended smallest robust option** |
| Custom attribute plugin | Yes | Yes | Can enforce | Directly controlled | Must implement cleanup/singleton | Larger than necessary |
| Keyboard Lock | Broader only where supported | N/A | N/A | N/A | Separate lifecycle | Experimental; not a baseline dependency |

---

## Risks and unresolved gaps

- **High — accessibility/IME:** unconditional prevention interferes with native editing, assistive technology and composition.
- **High — delivery semantics:** disconnects make lossless exactly-once keyboard delivery impossible without identifiers and server acknowledgements.
- **High — stock ordering:** concurrent `POST /` requests and responses can reorder.
- **High — reserved shortcuts:** some browser/OS shortcuts are never delivered.
- **Medium — unsettled wire contract:** Tuna has no current HTTP adapter or owner-approved browser event schema; the field set above is the minimal standards-based transport, not an existing repository contract.
- **Medium — modifier mapping:** browser `metaKey` does not settle Tuna `meta` versus `super`; there are no browser `superKey` or `hyperKey` properties.
- **Medium — Datastar retry mismatch:** v1.0.2 source does not honor `retry: 'never'` in its network-exception path.
- **Medium — root replacement:** ordinary fat morphing is handled, but outright replacement of the observed document element needs browser testing.
- **Medium — version drift:** the plugin starter pins v1.0.0 while current official release is v1.0.2.
- **Low — duplicate markup:** multiple singleton attributes create multiple listeners; a unique root annotation and optional event-object deduplication mitigate this.

**Confidence:** High for Datastar event placement, synchronous prevention, action payload access, request headers, cancellation behavior and plugin API; high for browser key/code distinctions; medium for final Tuna wire-envelope fields because the repository deliberately leaves that contract unsettled.

---

## Validation commands

The starter exposes no automated test script. Its evidence-backed focused toolchain validation is:

```sh
corepack pnpm install --frozen-lockfile
corepack pnpm build
```

A full acceptance check must additionally exercise real Chromium, Firefox and WebKit behavior for:

- normal, named, modifier-only and repeated keys;
- left/right/numpad `location`;
- dead keys and non-US layouts;
- composition boundaries;
- rapid key bursts and FIFO server admission;
- duplicate listener prevention after repeated full-document morphs;
- 204 responses, failures, disconnect and recovery;
- reserved browser/OS shortcuts;
- CSRF rejection and same-origin authenticated requests.

No browser automation harness currently exists in the inspected plugin starter, so no unsupported test command is asserted.