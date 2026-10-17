# Brief: send input without waiting

**Date:** 2026-10-14. **Status:** approved 2026-10-14 (owner: keep it simple; one tab; no sign-in). Changes [ADR 7](../../agents/adr/0007-rendering-and-transport.md) (input) and [ADR 10](../../agents/adr/0010-security-clients-and-trust.md) (client identity).

## What this is and why

Today the browser sends one key press, waits for the server's "got it", and only then sends the next (`plugins/web/frontend/input-queue.ts`: "at most one POST is in flight"). Every key therefore costs a full round trip. At 200 ms of latency you can type at most five keys a second, and fast typing piles up and lags.

The fix, your idea: **the browser sends every key the moment it is pressed, without waiting.** The server puts keys back in order before the editor runs them, because requests sent in parallel can arrive out of order. Your Go terminal (`~/Code/go-web-terminal-singular/example/main.go`, `commandInbox`) already does exactly this; Tuna copies its design.

Two rules stay as they are and get stricter:
- **The server answers "got it" (204) immediately, always:** before running anything, and also for input it rejects (malformed, duplicate, too many waiting). It never answers with an error a tab could act on. All feedback reaches you through the screen stream, because the screen is drawn only from the editor's state.
- **The editor still runs input strictly in the order you typed it.**

## The picture

![How keys stay in order when the browser does not wait](../diagrams/input-ordering.svg)

**Status:** planned. Today step 2 waits for step 1's "got it".

## A walkthrough

1. You type `a`, `b`, `c` quickly over a slow connection. The browser numbers them 1, 2, 3 and sends all three at once.
2. Each request gets "got it" the moment it reaches the server.
3. `a` arrives first: the server hands it to the editor.
4. `c` overtakes `b` on the network. The server holds `c`, because 2 has not come yet.
5. `b` arrives: the server hands over `b`, then the held `c`.
6. The editor runs `a b c` in order and the new screen arrives over the stream.

## How it works (for the implementer, briefly)

- **Numbering.** The page numbers its input 1, 2, 3, … from the moment it loads. When a page opens its screen stream, the server starts expecting 1 again, so a reload or a server restart needs nothing special. *Corrected 2026-10-16 (ADR 7): the reset happens when the page is served, because the stream can reopen without a reload.* One tab is assumed; nothing here plans for several.
- **Server.** The web plugin keeps the next number it expects and the items that arrived early. It hands items to the editor's input queue strictly in order. The kernel does not change.
- **Lost requests.** The browser keeps each item until it gets *any* answer, and resends it with the same number if the network failed. The server ignores a number it has already seen. If 64 later items are waiting for one that never came, the server gives up on that one (a line in the log, nothing shown) and carries on with the rest.
- **Unchanged:** keys and clicks share one numbering, so "type, click, type" stays in order (ADR 7); Datastar's screen stream is untouched.

## A code sample (the browser side)

```ts
// Send at once; the server orders by number. Resend only if the network failed.
function send(item: object): void {
  const body = JSON.stringify({ sequence: ++sequence, ...item });
  const post = () => fetch("/commands", { method: "POST", headers, body })
    .catch(() => setTimeout(post, 250));
  post();
}
```

## Also: no launch token

Owner, 2026-10-14: remove the launch token and session cookie (ADR 10). Tuna prints a plain `http://127.0.0.1:PORT/` and any tab on this machine can open it. Kept, invisibly: the server listens only on 127.0.0.1, and rejects requests whose Host or Origin header is not Tuna's own address, so a web page you visit cannot send Tuna keys. Every request to `/commands` that passes those checks gets 204.

## Why numbers, not timestamps

A timestamp says which key came first, but not whether an earlier key is still on its way. With numbers, the server knows that after 1 comes 2: if 3 arrives and 2 has not, it waits for 2, and otherwise runs each key the moment it arrives. With timestamps it could never tell, so it would have to wait a fixed time before running every key, which adds the lag back.
