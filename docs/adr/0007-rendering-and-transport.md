# 7. Server-rendered HTML frames over Datastar; the browser is a terminal

Status: accepted (2026-10-11)

## Context

The browser is the primary display, used like a terminal: every user action is sent to the server, and the server sends back the new view. Datastar supports this with command `POST`s and a long-lived server-sent-event stream that morphs HTML into the page. Weevil proved the approach in Racket, including server-side viewport slicing. Client-side reactivity (Datastar Rocket) may be added later for things like smooth scrolling.

## Decision

- **Input.** A small Datastar plugin captures keyboard (and later mouse, paste, composition, resize) events and `POST`s them in order to `/commands`. The server answers `204` on receipt and enqueues the event ([ADR 3](0003-command-loop-and-jobs.md)). Responses never carry UI.
- **Output.** Each browser connection holds one `GET` SSE stream. After the editor loop decides to redisplay, it renders the whole frame and each connection's writer thread sends the newest frame as a Datastar element patch (a "fat morph"). A slow connection skips intermediate frames; it never blocks the editor.
- **Rendering pipeline.** Editor state → renderer service → SXML → HTML. The `Renderer` is a `std/interface` service, so a terminal renderer can be added later. Node kinds supply their own render procedures to the active renderer.
- **Viewport.** Text nodes render only the lines visible in their window, plus a small margin. Scrolling is a server command for now.
- **Identity.** Rendered elements carry stable node identifiers so clicks and other pointer events can be mapped back to nodes and positions.
- **HTML.** Semantic elements, CSS custom properties for design tokens, and no CSS class soup ([html-css guide](../agents/html-css.md)). Text is always escaped; only renderer code creates elements.
- **Sessions.** Initially every browser tab mirrors the same editor frame, like attaching to one tmux session. Per-tab frames are a later feature.

## Consequences

- The browser holds no editor state; reconnecting simply receives the current frame.
- Whole-frame morphs are simple but cost bandwidth and render time proportional to visible content. Latency from keydown to patched DOM is measured from the first prototype; finer-grained patches are an optimization behind the same pipeline.
- Browser-owned editing widgets (`contenteditable`, `<textarea>`) are not used for buffers; text input arrives as key and composition events. Full IME support is later work.

## Alternatives considered

- **Client-side editor component (CodeMirror, Monaco).** Rejected: splits editor state between client and server.
- **WebSocket protocol with custom diffing.** Rejected for now: Datastar's SSE morphing already works and keeps the client tiny.
